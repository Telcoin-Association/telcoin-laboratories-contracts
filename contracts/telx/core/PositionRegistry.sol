// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionManager, PoolKey, PositionInfo} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";

/**
 * @title PositionRegistry
 * @author Robriks 📯️📯️📯️.eth
 * @notice Thin registry tracking which Uniswap v4 LP positions have opted into TELx governance.
 * @dev A subscription index plus a view layer over Uniswap's own PositionManager and StateView.
 *      It stores no liquidity, fee growth or reward state; reward distribution is owned by Merkl,
 *      and the Snapshot strategy `uni-v4-telx-lp` reads `getSubscriptions`. The only state owned
 *      here is the per-LP / global subscription index that Uniswap v4 has no native enumerable
 *      equivalent for, plus the admin allowlist of pools that count.
 *
 *      Two rules keep that state safe against anyone but the position's owner:
 *
 *      1. No removal from the index decides on anything a third party can move. Entries leave on
 *         pool allowlisting, position ownership, the position's own liquidity, or an admin call.
 *         The pool's aggregate liquidity and its current tick never decide a removal, because
 *         both can be set to anything inside a single `PoolManager.unlock` for the cost of gas.
 *         The one write that reads the tick is the in-range gate at subscribe time, which can only
 *         refuse, never remove, and runs under the guard below.
 *      2. Every entry point that adds to or prunes the index refuses to run while the PoolManager
 *         is unlocked, mirroring `PositionManager.onlyIfPoolManagerLocked`. That closes the class
 *         of flash-state attacks rather than any one instance of it.
 *
 *      Voting correctness never depended on the index being pruned: `getSubscriptions` filters
 *      eligibility live at the read block. Removal from storage exists only to free cap slots, and
 *      `resubscribe` lets anyone put back an entry that v4 still considers opted in.
 */
contract PositionRegistry is IPositionRegistry, AccessControlDefaultAdminRules {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    // -----------
    // Roles
    // -----------

    /// @notice Held by TELxSubscriber; gates the subscription-lifecycle entry points.
    bytes32 public constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    /// @notice Held by an operational multisig; gates `erc20Rescue`.
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    // -----------
    // Caps
    // -----------

    /// @notice Maximum subscriptions a single LP may hold.
    /// @dev A plain index bound. The registry only ever performs O(1) swap-and-pop on this array;
    ///      the one linear path is the `getSubscriptions` view, which has a paginated overload.
    uint256 public constant MAX_SUBSCRIPTIONS = 1_000;
    /// @notice Maximum distinct LPs in the global subscribed set, across all pools.
    /// @dev Global, not per pool. Filling it requires that many distinct owners each holding, at
    ///      the same time, a position in an allowlisted pool at or above that pool's liquidity
    ///      floor. With a floor set that is capital locked per slot; with the floor at zero it is
    ///      gas, which is why the deploy batch sets one for every pool. A drained position is
    ///      prunable by anyone, so capital cannot be withdrawn and reused while the slot is held.
    uint256 public constant MAX_SUBSCRIBED = 50_000;

    /// @notice Delay before a scheduled transfer of DEFAULT_ADMIN_ROLE can be accepted.
    /// @dev The admin role is held by the governance Safe and can only move through the two-step,
    ///      delayed transfer of `AccessControlDefaultAdminRules`; it cannot be granted to a second
    ///      address or renounced in one call.
    uint48 public constant ADMIN_TRANSFER_DELAY = 3 days;

    // -----------
    // Subscription index
    // -----------

    /// @notice The set of LPs with at least one active subscription.
    address[] private subscribed;
    mapping(address => uint256) private subscribedIndex;
    /// @notice Subscribed tokenIds per owner.
    mapping(address => uint256[]) public subscriptions;
    /// @notice Whether an address has any active subscription.
    mapping(address => bool) public isSubscribed;
    /// @notice Whether a tokenId is currently in the subscription index.
    mapping(uint256 => bool) public isTokenSubscribed;
    mapping(uint256 => uint256) private subscriptionIndex;
    /// @dev Subscriber of record per subscribed tokenId. Retained so unsubscribe knows which
    ///      `subscriptions[owner]` list to mutate even after a v4 transfer changes `ownerOf`.
    mapping(uint256 => address) private subscriptionOwner;

    // -----------
    // Configuration
    // -----------

    /// @inheritdoc IPositionRegistry
    mapping(PoolId => bool) public poolAllowed;

    /// @inheritdoc IPositionRegistry
    mapping(PoolId => uint128) public minLiquidity;

    /// @notice Whether a position must be in range to be subscription-eligible. Defaults to true;
    ///         the admin can toggle it so the in-range gate can be relaxed without a redeploy.
    bool public inRangeRequired;

    // -----------
    // External dependencies
    // -----------

    IPositionManager public immutable positionManager;
    StateView public immutable stateView;
    /// @dev Read from `stateView` at construction; only used for the unlock check.
    IPoolManager public immutable poolManager;

    /**
     * @param positionManager_ Uniswap v4 PositionManager, the source of truth for live position data.
     * @param stateView_ Uniswap v4 StateView lens, used for pool liquidity and price reads.
     * @param admin Holder of DEFAULT_ADMIN_ROLE.
     */
    constructor(IPositionManager positionManager_, StateView stateView_, address admin)
        AccessControlDefaultAdminRules(ADMIN_TRANSFER_DELAY, admin)
    {
        // A wrong immutable deploys fine at the CREATE3 address and burns it, so the arguments are
        // checked here as well as by the verify script. The StateView read doubles as its code
        // check: a codeless lens cannot answer. A zero admin is refused by the base constructor.
        if (address(positionManager_).code.length == 0) revert NotAContract(address(positionManager_));
        positionManager = positionManager_;
        stateView = stateView_;
        poolManager = stateView_.poolManager();
        inRangeRequired = true;
    }

    // -----------
    // Guards
    // -----------

    /// @dev Refuses to run inside a `PoolManager.unlock` callback. Inside one, a caller can add
    ///      and remove arbitrary liquidity and move the price freely before settling, so any
    ///      decision that reads pool state there is a decision the caller controls.
    modifier whenPoolManagerLocked() {
        if (poolManager.isUnlocked()) revert PoolManagerUnlocked();
        _;
    }

    // -----------
    // Subscription lifecycle
    // -----------

    /// @inheritdoc IPositionRegistry
    function handleSubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) whenPoolManagerLocked {
        _index(tokenId);
    }

    /// @inheritdoc IPositionRegistry
    function resubscribe(uint256 tokenId) external whenPoolManagerLocked {
        // v4 is the authority on whether the position is opted in. Its subscriber for this token
        // must be one this registry trusts, so nobody can index a position through a subscriber
        // of their own.
        ISubscriber current = positionManager.subscriber(tokenId);
        if (!hasRole(SUBSCRIBER_ROLE, address(current))) revert NotSubscribedOnUniswap(tokenId);
        _index(tokenId);
    }

    /**
     * @dev Adds `tokenId` to the index under its current owner after the full eligibility check.
     *      A token already indexed under that owner is a no-op, so a repeated notification cannot
     *      push a duplicate. A token indexed under a previous owner (an unsubscribe notification
     *      the v4 gas limit swallowed, followed by a transfer) is moved: the stale record is
     *      removed first so the new owner's opt-in is recorded rather than silently dropped.
     */
    function _index(uint256 tokenId) internal {
        // approved operators may initiate the subscribe flow, but the NFT owner is what counts
        address tokenOwner = IERC721(address(positionManager)).ownerOf(tokenId);

        if (isTokenSubscribed[tokenId]) {
            if (subscriptionOwner[tokenId] == tokenOwner) return;
            _removeSubscription(tokenId, subscriptionOwner[tokenId]);
        }

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        if (!poolAllowed[poolId]) revert PoolNotAllowed(poolId);
        if (!_initialized(poolId)) revert PoolNotInitialized(poolId);

        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        if (!_meetsMinimum(poolId, currentLiquidity)) revert LiquidityBelowThreshold(currentLiquidity);
        // an out-of-range position provides no live liquidity; gated unless the admin disabled it
        if (inRangeRequired && !_isInRange(poolId, info)) revert OutOfRange(tokenId);

        uint256[] storage ownerSubscriptions = subscriptions[tokenOwner];
        if (ownerSubscriptions.length >= MAX_SUBSCRIPTIONS) revert MaxSubscriptions();
        // only add to the global subscribed set on the owner's first subscription
        if (ownerSubscriptions.length == 0) {
            if (subscribed.length >= MAX_SUBSCRIBED) revert MaxSubscribed();

            subscribed.push(tokenOwner);
            subscribedIndex[tokenOwner] = subscribed.length - 1;
            isSubscribed[tokenOwner] = true;
        }
        // store and index the new subscription for O(1) removal
        subscriptionIndex[tokenId] = ownerSubscriptions.length;
        isTokenSubscribed[tokenId] = true;
        subscriptionOwner[tokenId] = tokenOwner;
        ownerSubscriptions.push(tokenId);

        emit Subscribed(tokenId, tokenOwner);
    }

    /// @inheritdoc IPositionRegistry
    function handleUnsubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        // INVARIANT: guard before mutating arrays so `_removeSubscription` cannot underflow, and so
        // a stray notification can never revert a Uniswap v4 transfer/unsubscribe.
        if (!isTokenSubscribed[tokenId]) return;
        _removeSubscription(tokenId, subscriptionOwner[tokenId]);
    }

    /// @inheritdoc IPositionRegistry
    function handleBurn(uint256 tokenId, address) external onlyRole(SUBSCRIBER_ROLE) {
        if (!isTokenSubscribed[tokenId]) return;
        _removeSubscription(tokenId, subscriptionOwner[tokenId]);
    }

    /// @inheritdoc IPositionRegistry
    function pruneSubscription(uint256 tokenId) external whenPoolManagerLocked {
        if (!isTokenSubscribed[tokenId]) revert NotSubscribed(tokenId);
        address ownerOfRecord = subscriptionOwner[tokenId];

        // Only position-local facts qualify. Ownership changes only on a transfer or burn the
        // owner initiates; liquidity reaches zero only when the owner removes it. Neither the
        // pool's aggregate liquidity nor its tick appears here, because a third party can set
        // both to anything inside one unlock.
        bool transferredOrBurned = _ownerOf(tokenId) != ownerOfRecord;
        bool drained = positionManager.getPositionLiquidity(tokenId) == 0;
        if (!transferredOrBurned && !drained) revert NotPrunable(tokenId);

        _removeSubscription(tokenId, ownerOfRecord);
    }

    /**
     * @notice Removes `tokenId` from `subscriptions[owner]` and, if it was the owner's last
     *         subscription, from the global `subscribed` set. Both removals are O(1) swap-and-pop.
     */
    function _removeSubscription(uint256 tokenId, address owner) internal {
        uint256 subscriptionIdx = subscriptionIndex[tokenId];
        uint256[] storage list = subscriptions[owner];
        uint256 lastIndex = list.length - 1;

        // if it is not the last token, swap the last token into its spot before popping
        if (subscriptionIdx != lastIndex) {
            uint256 lastTokenId = list[lastIndex];
            list[subscriptionIdx] = lastTokenId;
            subscriptionIndex[lastTokenId] = subscriptionIdx;
        }
        list.pop();
        delete subscriptionIndex[tokenId];
        delete isTokenSubscribed[tokenId];
        delete subscriptionOwner[tokenId];

        // if the owner has no more subscriptions, remove them from the global set
        if (list.length == 0) {
            uint256 subscribedIdx = subscribedIndex[owner];
            address lastOwner = subscribed[subscribed.length - 1];

            subscribed[subscribedIdx] = lastOwner;
            subscribedIndex[lastOwner] = subscribedIdx;

            subscribed.pop();
            delete subscribedIndex[owner];

            isSubscribed[owner] = false;
        }

        emit Unsubscribed(tokenId, owner);
    }

    // -----------
    // Subscription eligibility
    // -----------

    /// @inheritdoc IPositionRegistry
    function subscriptionEligible(uint256 tokenId) public view returns (bool) {
        return _subscriptionEligible(tokenId);
    }

    /// @dev Eligibility in a single pass: one PositionManager lookup feeds the allowlist, minimum
    ///      liquidity and in-range checks. The in-range leg is skipped while `inRangeRequired` is
    ///      disabled. This is a read-only judgement and the only place the live tick is consulted.
    function _subscriptionEligible(uint256 tokenId) internal view returns (bool) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        if (!poolAllowed[poolId]) return false;
        if (!_meetsMinimum(poolId, positionManager.getPositionLiquidity(tokenId))) return false;
        if (inRangeRequired && !_isInRange(poolId, info)) return false;
        return true;
    }

    /// @inheritdoc IPositionRegistry
    function belowSubscriptionThreshold(uint256 tokenId) public view returns (bool) {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        return !_meetsMinimum(key.toId(), positionManager.getPositionLiquidity(tokenId));
    }

    /**
     * @dev A position qualifies when it holds any liquidity and at least the pool's admin-set
     *      minimum. The minimum is absolute, so no third party can move a position across it. It
     *      defaults to zero; the Snapshot strategy values positions in USD, so dust already votes
     *      as dust and a floor is only needed if index bloat ever becomes a problem.
     */
    function _meetsMinimum(PoolId poolId, uint128 positionLiquidity) internal view returns (bool) {
        if (positionLiquidity == 0) return false;
        return positionLiquidity >= minLiquidity[poolId];
    }

    /// @inheritdoc IPositionRegistry
    function isInRange(uint256 tokenId) public view returns (bool) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        return _isInRange(key.toId(), info);
    }

    /**
     * @dev A position is in range, and thus earning live liquidity, when the pool's current tick
     *      sits within [tickLower, tickUpper). An out-of-range position holds a single currency and
     *      provides nothing to the pool, regardless of its liquidity parameter.
     */
    function _isInRange(PoolId poolId, PositionInfo info) internal view returns (bool) {
        (, int24 currentTick,,) = stateView.getSlot0(poolId);
        return info.tickLower() <= currentTick && currentTick < info.tickUpper();
    }

    // -----------
    // Views
    // -----------

    /// @inheritdoc IPositionRegistry
    function validPool(PoolId id) public view returns (bool) {
        return poolAllowed[id] && _initialized(id);
    }

    /// @dev A pool is initialized once it has a non-zero sqrtPriceX96.
    function _initialized(PoolId id) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(id);
        return sqrtPriceX96 != 0;
    }

    /// @inheritdoc IPositionRegistry
    function getPosition(uint256 tokenId)
        external
        view
        returns (address owner, PoolId poolId, int24 tickLower, int24 tickUpper)
    {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        return (_ownerOf(tokenId), key.toId(), info.tickLower(), info.tickUpper());
    }

    /// @inheritdoc IPositionRegistry
    function getPositionDetails(uint256 tokenId) external view returns (PositionDetails memory) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        return PositionDetails({
            owner: _ownerOf(tokenId),
            poolId: key.toId(),
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: positionManager.getPositionLiquidity(tokenId),
            poolKey: key
        });
    }

    /// @inheritdoc IPositionRegistry
    function getLiquidityLast(uint256 tokenId) external view returns (uint128) {
        return positionManager.getPositionLiquidity(tokenId);
    }

    /// @inheritdoc IPositionRegistry
    function getSubscriptions(address owner) external view returns (uint256[] memory) {
        (uint256[] memory votable,) = _votable(owner, 0, subscriptions[owner].length);
        return votable;
    }

    /// @inheritdoc IPositionRegistry
    function getSubscriptions(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory votable, uint256 total)
    {
        return _votable(owner, offset, limit);
    }

    /// @dev Filters `subscriptions[owner][offset, offset + limit)` to the currently votable set: a
    ///      position still owned by `owner` and eligible. Clamps the window to the array.
    function _votable(address owner, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory votable, uint256 total)
    {
        uint256[] storage stored = subscriptions[owner];
        total = stored.length;
        if (offset >= total) return (new uint256[](0), total);

        // compare before adding so a huge `limit` clamps instead of overflowing
        uint256 remaining = total - offset;
        uint256 end = limit >= remaining ? total : offset + limit;

        uint256[] memory buffer = new uint256[](end - offset);
        uint256 count;
        for (uint256 i = offset; i < end; ++i) {
            uint256 tokenId = stored[i];
            if (_ownerOf(tokenId) == owner && _subscriptionEligible(tokenId)) {
                buffer[count] = tokenId;
                ++count;
            }
        }
        votable = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            votable[i] = buffer[i];
        }
    }

    /// @inheritdoc IPositionRegistry
    function getSubscriptionsRaw(address owner) external view returns (uint256[] memory) {
        return subscriptions[owner];
    }

    /// @inheritdoc IPositionRegistry
    function getSubscribed() external view returns (address[] memory) {
        return subscribed;
    }

    /// @inheritdoc IPositionRegistry
    function getSubscribed(uint256 offset, uint256 limit) external view returns (address[] memory page, uint256 total) {
        total = subscribed.length;
        if (offset >= total) return (new address[](0), total);

        uint256 remaining = total - offset;
        uint256 end = limit >= remaining ? total : offset + limit;

        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = subscribed[i];
        }
    }

    /// @inheritdoc IPositionRegistry
    /// @dev The amounts a position of `liquidity` over [tickLower, tickUpper) holds at the pool's
    ///      current price, rounded down, computed from the core `SqrtPriceMath` the PoolManager
    ///      itself uses. This is the "what is it worth" direction: below the range the position is
    ///      all currency0, above it all currency1, inside it both.
    function getAmountsForLiquidity(PoolId poolId, uint128 liquidity, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
    {
        (sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtLower > sqrtUpper) (sqrtLower, sqrtUpper) = (sqrtUpper, sqrtLower);

        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    /// @dev Resolves the NFT owner, returning address(0) instead of reverting for a token that
    ///      has been burned or never existed. Keeps the view functions safe for off-chain callers.
    function _ownerOf(uint256 tokenId) internal view returns (address) {
        try IERC721(address(positionManager)).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    // -----------
    // Administration
    // -----------

    /// @inheritdoc IPositionRegistry
    function registerPool(PoolKey calldata key) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolId poolId = key.toId();
        if (poolAllowed[poolId]) revert AlreadyRegistered(poolId);
        poolAllowed[poolId] = true;
        emit PoolRegistered(poolId, key);
    }

    /// @inheritdoc IPositionRegistry
    function deregisterPool(PoolId poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!poolAllowed[poolId]) revert PoolNotAllowed(poolId);
        poolAllowed[poolId] = false;
        // a pool that is registered again later starts with no floor rather than an old one
        if (minLiquidity[poolId] != 0) {
            delete minLiquidity[poolId];
            emit MinLiquiditySet(poolId, 0);
        }
        emit PoolDeregistered(poolId);
    }

    /// @inheritdoc IPositionRegistry
    function setMinLiquidity(PoolId poolId, uint128 minLiquidity_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minLiquidity[poolId] = minLiquidity_;
        emit MinLiquiditySet(poolId, minLiquidity_);
    }

    /// @inheritdoc IPositionRegistry
    function setInRangeRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        inRangeRequired = required;
        emit InRangeRequiredSet(required);
    }

    /// @inheritdoc IPositionRegistry
    function forceUnsubscribe(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _forceUnsubscribe(tokenId);
    }

    /// @inheritdoc IPositionRegistry
    function forceUnsubscribeBatch(uint256[] calldata tokenIds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < tokenIds.length; ++i) {
            _forceUnsubscribe(tokenIds[i]);
        }
    }

    function _forceUnsubscribe(uint256 tokenId) internal {
        if (!isTokenSubscribed[tokenId]) return;
        _removeSubscription(tokenId, subscriptionOwner[tokenId]);
    }

    /// @inheritdoc IPositionRegistry
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
    }
}

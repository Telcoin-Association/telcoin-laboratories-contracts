// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionManager, PoolKey, PositionInfo} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/**
 * @title PositionRegistry
 * @author Robriks 📯️📯️📯️.eth
 * @notice Thin registry tracking which Uniswap v4 LP positions have opted into TELx governance.
 * @dev Following the removal of the TELxIncentiveHook, this contract is a subscription index
 *      plus a view layer over Uniswap's own PositionManager and StateView. It no longer stores
 *      liquidity, fee growth, reward balances, JIT/active/passive weights, or a pool registry:
 *      reward distribution is owned by Merkl, and the Snapshot strategy `uni-v4-telx-lp` reads
 *      the view functions below. The only state owned here is the per-LP / global subscription
 *      index that Uniswap v4 has no native enumerable equivalent for.
 */
contract PositionRegistry is IPositionRegistry, AccessControl {
    using SafeERC20 for IERC20;

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
    /// @dev Raised from 100 to 1,000 after the V4-hook removal: the cap was a gas-safety bound on
    ///      on-chain iteration over `subscriptions[owner]`, and no such iteration remains. The
    ///      registry only ever performs O(1) swap-and-pop on this array. See INVARIANTS.md.
    uint256 public constant MAX_SUBSCRIPTIONS = 1_000;
    /// @notice Maximum distinct LPs in the global subscribed set.
    uint256 public constant MAX_SUBSCRIBED = 50_000;

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

    /// @notice Whether a position must be in range to be subscription-eligible. Defaults to true;
    ///         the admin can toggle it so the in-range gate can be relaxed without a redeploy.
    bool public inRangeRequired;

    // -----------
    // External dependencies
    // -----------

    IPositionManager public immutable positionManager;
    StateView public immutable stateView;

    /**
     * @param positionManager_ Uniswap v4 PositionManager, the source of truth for live position data.
     * @param stateView_ Uniswap v4 StateView lens, used for pool liquidity and price reads.
     * @param admin Holder of DEFAULT_ADMIN_ROLE.
     */
    constructor(IPositionManager positionManager_, StateView stateView_, address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        positionManager = positionManager_;
        stateView = stateView_;
        inRangeRequired = true;
    }

    // -----------
    // Subscription lifecycle
    // -----------

    /// @inheritdoc IPositionRegistry
    function handleSubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        if (!validPool(poolId)) revert InvalidPool(poolId);

        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        if (!_meetsSubscriptionThreshold(poolId, currentLiquidity)) {
            revert LiquidityBelowThreshold(currentLiquidity);
        }
        // an out-of-range position provides no live liquidity; gated unless the admin disabled it
        if (inRangeRequired && !_isInRange(poolId, info)) revert OutOfRange(tokenId);

        // approved operators may initiate the subscribe flow, but the NFT owner is what counts
        address tokenOwner = IERC721(address(positionManager)).ownerOf(tokenId);

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
    function pruneSubscription(uint256 tokenId) external {
        if (!isTokenSubscribed[tokenId]) revert NotSubscribed(tokenId);
        address ownerOfRecord = subscriptionOwner[tokenId];

        // prunable when the position was transferred or burned, or is no longer subscription-eligible
        bool transferredOrBurned = _ownerOf(tokenId) != ownerOfRecord;
        if (!transferredOrBurned && _subscriptionEligible(tokenId)) revert NotPrunable(tokenId);

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
    function belowSubscriptionThreshold(uint256 tokenId) public view returns (bool) {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        return !_meetsSubscriptionThreshold(key.toId(), liquidity);
    }

    /**
     * @dev A position meets the threshold when it holds at least 1bps (0.01%) of the pool's total
     *      liquidity. Pools at or below 10,000 total liquidity accept any non-zero position.
     */
    function _meetsSubscriptionThreshold(PoolId poolId, uint128 positionLiquidity) internal view returns (bool) {
        if (positionLiquidity == 0) return false;

        uint128 totalLiquidity = stateView.getLiquidity(poolId);
        if (totalLiquidity <= 10_000) return true;

        uint128 subscriptionThreshold = totalLiquidity / 10_000;
        return positionLiquidity >= subscriptionThreshold;
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

    /// @inheritdoc IPositionRegistry
    function subscriptionEligible(uint256 tokenId) public view returns (bool) {
        return _subscriptionEligible(tokenId);
    }

    /// @dev Eligibility in a single pass: one PositionManager lookup feeds both the liquidity
    ///      threshold and the in-range check. The in-range leg is skipped while `inRangeRequired`
    ///      is disabled.
    function _subscriptionEligible(uint256 tokenId) internal view returns (bool) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        if (!_meetsSubscriptionThreshold(poolId, positionManager.getPositionLiquidity(tokenId))) return false;
        if (inRangeRequired && !_isInRange(poolId, info)) return false;
        return true;
    }

    // -----------
    // Views
    // -----------

    /// @inheritdoc IPositionRegistry
    function validPool(PoolId id) public view returns (bool) {
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
        uint256[] storage stored = subscriptions[owner];
        uint256 len = stored.length;
        uint256[] memory buffer = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len; ++i) {
            uint256 tokenId = stored[i];
            // a votable position is still owned by `owner` and currently eligible
            if (_ownerOf(tokenId) == owner && _subscriptionEligible(tokenId)) {
                buffer[count] = tokenId;
                ++count;
            }
        }
        uint256[] memory votable = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            votable[i] = buffer[i];
        }
        return votable;
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
    function getAmountsForLiquidity(PoolId poolId, uint128 liquidity, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
    {
        (sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
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
    function setInRangeRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        inRangeRequired = required;
        emit InRangeRequiredSet(required);
    }

    /// @inheritdoc IPositionRegistry
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
    }
}

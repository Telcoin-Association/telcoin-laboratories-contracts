// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPositionRegistry
 * @notice External surface of the thin TELx PositionRegistry.
 * @dev The registry is a subscription index plus a small view layer over Uniswap's own
 *      PositionManager and StateView. It stores no liquidity, fee growth or reward state; reward
 *      distribution is owned by Merkl, and the Snapshot strategy reads `getSubscriptions`.
 *
 *      Everything the registry decides is decided from facts a third party cannot move: whether a
 *      pool is on the admin allowlist, who owns a position, and whether that position has any
 *      liquidity at all. The pool's aggregate liquidity and the current tick are deliberately not
 *      inputs to any state-changing path, because both can be set to anything inside a single
 *      `PoolManager.unlock` for the cost of gas.
 */
interface IPositionRegistry {
    // -----------
    // Structs
    // -----------

    /// @notice Position data with multipool detail, assembled live for off-chain consumption.
    struct PositionDetails {
        address owner;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        PoolKey poolKey;
    }

    // -----------
    // Events
    // -----------

    /// @notice Emitted when a position opts into the TELx subscription index.
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when a subscription is removed from the index, by any path.
    event Unsubscribed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when the admin adds a pool to the allowlist.
    event PoolRegistered(PoolId indexed poolId, PoolKey key);

    /// @notice Emitted when the admin removes a pool from the allowlist.
    event PoolDeregistered(PoolId indexed poolId);

    /// @notice Emitted when the admin sets a pool's absolute minimum position liquidity.
    event MinLiquiditySet(PoolId indexed poolId, uint128 minLiquidity);

    /// @notice Emitted when the admin toggles the in-range subscription requirement.
    event InRangeRequiredSet(bool required);

    // -----------
    // Errors
    // -----------

    error ZeroAddress();
    error NotAContract(address target);
    error PoolManagerUnlocked();
    error PoolNotAllowed(PoolId poolId);
    error PoolNotInitialized(PoolId poolId);
    error AlreadyRegistered(PoolId poolId);
    error LiquidityBelowThreshold(uint128 currentLiquidity);
    error OutOfRange(uint256 tokenId);
    error MaxSubscriptions();
    error MaxSubscribed();
    error NotSubscribed(uint256 tokenId);
    error NotPrunable(uint256 tokenId);

    // -----------
    // Subscription lifecycle (subscriber-gated)
    // -----------

    /**
     * @notice Records a position's opt-in to the TELx subscription index.
     * @dev Callable only by an address holding SUBSCRIBER_ROLE, i.e. TELxSubscriber, and only
     *      while the PoolManager is locked. Reverts if the position's pool is not on the allowlist
     *      or not initialized, the position has no liquidity or less than the pool's minimum, it is
     *      out of range while `inRangeRequired` is set, or either cap is reached. A tokenId that is
     *      already indexed is a no-op, so a repeated notification can never corrupt the index.
     */
    function handleSubscribe(uint256 tokenId) external;

    /**
     * @notice Removes a position from the subscription index.
     * @dev Callable only by SUBSCRIBER_ROLE. No-op if `tokenId` is not currently subscribed,
     *      so it can never revert a Uniswap v4 transfer/unsubscribe notification.
     */
    function handleUnsubscribe(uint256 tokenId) external;

    /**
     * @notice Removes a burned position from the subscription index.
     * @dev Callable only by SUBSCRIBER_ROLE. Behaves identically to `handleUnsubscribe`; the
     *      separate entry point is retained for v4 burn-notification clarity and ABI stability.
     */
    function handleBurn(uint256 tokenId, address owner) external;

    // -----------
    // Permissionless cleanup
    // -----------

    /**
     * @notice Removes a stale subscription entry. Callable by anyone, only while the PoolManager
     *         is locked.
     * @dev Prunes `tokenId` only on facts nobody but the position's owner can change: the position
     *      has been transferred or burned (live owner no longer matches the subscriber of record),
     *      or its liquidity is zero. The pool's aggregate liquidity and current tick are not
     *      consulted, so no third party can make a healthy position prunable.
     *      Reverts `NotSubscribed` if the token is not subscribed and `NotPrunable` otherwise.
     */
    function pruneSubscription(uint256 tokenId) external;

    // -----------
    // Views
    // -----------

    /**
     * @notice Returns whether `tokenId` currently satisfies subscription eligibility: its pool is
     *         allowlisted and initialized, it holds at least the pool's minimum liquidity (and more
     *         than zero), and, when `inRangeRequired` is enabled, it is in range.
     * @dev This is what `getSubscriptions` filters on. The in-range leg reads the live tick and is
     *      therefore movable at the read block by anyone willing to hold price there; that is the
     *      accepted property of concentrated liquidity (an out-of-range position genuinely provides
     *      none), and it affects reads only, never storage.
     */
    function subscriptionEligible(uint256 tokenId) external view returns (bool);

    /// @notice Returns whether `tokenId`'s liquidity is zero or below its pool's minimum.
    function belowSubscriptionThreshold(uint256 tokenId) external view returns (bool);

    /**
     * @notice Returns whether `tokenId` is currently in range: the pool's current tick sits within
     *         the position's [tickLower, tickUpper).
     * @dev Reports the position's geometric state regardless of whether `inRangeRequired` is
     *      enabled, so off-chain consumers can always apply their own in-range filter.
     */
    function isInRange(uint256 tokenId) external view returns (bool);

    /// @notice Returns whether a position must be in range to be subscription-eligible.
    function inRangeRequired() external view returns (bool);

    /// @notice Returns whether `poolId` is on the admin allowlist.
    function poolAllowed(PoolId poolId) external view returns (bool);

    /// @notice Returns the admin-set minimum position liquidity for `poolId`. Zero means "any".
    function minLiquidity(PoolId poolId) external view returns (uint128);

    /**
     * @notice Returns whether a pool is both allowlisted and initialized on chain.
     * @dev Allowlisting is the TELx decision; initialization is the Uniswap fact. Both are needed
     *      for a subscription to mean anything.
     */
    function validPool(PoolId id) external view returns (bool);

    /**
     * @notice Computes currency0 & currency1 amounts for given liquidity at the current tick price.
     * @dev Exposes Uniswap V3/V4 concentrated-liquidity math publicly for TELx frontend use.
     */
    function getAmountsForLiquidity(PoolId poolId, uint128 liquidity, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96);

    /// @notice Returns position ownership and range, read live from the V4 PositionManager.
    function getPosition(uint256 tokenId)
        external
        view
        returns (address owner, PoolId poolId, int24 tickLower, int24 tickUpper);

    /// @notice Returns position detail with multipool data, read live from the V4 PositionManager.
    function getPositionDetails(uint256 tokenId) external view returns (PositionDetails memory);

    /// @notice Returns a position's current liquidity, read live from the V4 PositionManager.
    function getLiquidityLast(uint256 tokenId) external view returns (uint128);

    /// @notice Returns the list of all addresses that have active subscriptions.
    function getSubscribed() external view returns (address[] memory);

    /**
     * @notice Returns an owner's currently votable subscribed tokenIds: those still owned by
     *         `owner` and satisfying `subscriptionEligible`. Evaluated live against the call's
     *         block, so a pinned-block read returns exactly the set eligible for voting power at
     *         that block. The Snapshot strategy consumes this directly.
     * @dev Linear in the owner's stored subscriptions, with several external reads per entry. For
     *      an owner near `MAX_SUBSCRIPTIONS` use the paginated overload.
     */
    function getSubscriptions(address owner) external view returns (uint256[] memory);

    /**
     * @notice Paginated form of `getSubscriptions`: filters the stored entries in
     *         `[offset, offset + limit)` and reports the total stored count so callers can iterate.
     * @dev Filtering happens after slicing, so a page can return fewer than `limit` entries while
     *      more pages remain; iterate until `offset + limit >= total`.
     */
    function getSubscriptions(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory votable, uint256 total);

    /// @notice Returns an owner's full stored subscription set, unfiltered. For ops and prune bots.
    function getSubscriptionsRaw(address owner) external view returns (uint256[] memory);

    /// @notice Returns whether `tokenId` is currently in the subscription index.
    function isTokenSubscribed(uint256 tokenId) external view returns (bool);

    // -----------
    // Administration
    // -----------

    /// @notice Adds a pool to the allowlist. Gated to DEFAULT_ADMIN_ROLE.
    function registerPool(PoolKey calldata key) external;

    /// @notice Removes a pool from the allowlist. Gated to DEFAULT_ADMIN_ROLE. Existing
    ///         subscriptions in that pool stop being eligible but are not evicted.
    function deregisterPool(PoolId poolId) external;

    /// @notice Sets a pool's absolute minimum position liquidity. Gated to DEFAULT_ADMIN_ROLE.
    function setMinLiquidity(PoolId poolId, uint128 minLiquidity_) external;

    /// @notice Toggles whether a position must be in range to be subscription-eligible.
    /// @dev Gated to DEFAULT_ADMIN_ROLE.
    function setInRangeRequired(bool required) external;

    /**
     * @notice Removes any subscription from the index regardless of its state. Gated to
     *         DEFAULT_ADMIN_ROLE.
     * @dev The backstop for an index entry that should never have existed. With the allowlist in
     *      place this should never be needed, which is the right property for a backstop. No-op if
     *      the token is not subscribed.
     */
    function forceUnsubscribe(uint256 tokenId) external;

    /// @notice Recovers ERC20 tokens sent to the contract in error. Gated to SUPPORT_ROLE.
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external;
}

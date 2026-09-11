// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPositionRegistry
 * @notice External surface of the thin TELx PositionRegistry.
 * @dev Post V4-hook-removal the registry is a subscription index plus a small view layer over
 *      Uniswap's own PositionManager and StateView. It no longer stores liquidity, fee growth,
 *      reward balances, weights, or a pool registry; reward distribution is owned by Merkl.
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

    /// @notice Emitted when a subscription is removed from the index.
    event Unsubscribed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when the admin toggles the in-range subscription requirement.
    event InRangeRequiredSet(bool required);

    // -----------
    // Errors
    // -----------

    error InvalidPool(PoolId poolId);
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
     * @dev Callable only by an address holding SUBSCRIBER_ROLE, i.e. TELxSubscriber.
     *      Reverts if the position's pool is not initialized, the position's live liquidity is
     *      below the subscription threshold, or either per-LP / per-registry cap is reached.
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
     * @notice Removes a stale subscription entry. Callable by anyone.
     * @dev Prunes `tokenId` if the position has been transferred or burned (live owner no longer
     *      matches the subscriber of record) or its live liquidity has fallen below the
     *      subscription threshold. Reverts `NotSubscribed` if the token is not subscribed and
     *      `NotPrunable` if the subscription is still healthy.
     */
    function pruneSubscription(uint256 tokenId) external;

    // -----------
    // Views
    // -----------

    /// @notice Returns whether `tokenId`'s live liquidity is below the subscription threshold.
    function belowSubscriptionThreshold(uint256 tokenId) external view returns (bool);

    /**
     * @notice Returns whether `tokenId` is currently in range: the pool's current tick sits within
     *         the position's [tickLower, tickUpper).
     * @dev An out-of-range position holds a single currency and provides no live liquidity. This
     *      view reports the position's geometric state regardless of whether `inRangeRequired` is
     *      enabled, so off-chain consumers can always apply their own in-range filter.
     */
    function isInRange(uint256 tokenId) external view returns (bool);

    /// @notice Returns whether a position must be in range to be subscription-eligible.
    function inRangeRequired() external view returns (bool);

    /**
     * @notice Returns whether `tokenId` currently satisfies subscription eligibility: its live
     *         liquidity meets the threshold and, when `inRangeRequired` is enabled, it is in range.
     */
    function subscriptionEligible(uint256 tokenId) external view returns (bool);

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

    /**
     * @notice Returns whether a given PoolId corresponds to an initialized Uniswap v4 pool.
     * @dev Read live from StateView; a pool is valid once it has a non-zero sqrtPriceX96.
     */
    function validPool(PoolId id) external view returns (bool);

    /// @notice Returns the list of all addresses that have active subscriptions.
    function getSubscribed() external view returns (address[] memory);

    /**
     * @notice Returns an owner's currently votable subscribed tokenIds: those still owned by
     *         `owner` and satisfying `subscriptionEligible`. Evaluated live against the call's
     *         block, so a pinned-block read returns exactly the set eligible for voting power at
     *         that block. The Snapshot strategy consumes this directly.
     */
    function getSubscriptions(address owner) external view returns (uint256[] memory);

    /// @notice Returns an owner's full stored subscription set, unfiltered. For ops and prune bots.
    function getSubscriptionsRaw(address owner) external view returns (uint256[] memory);

    /// @notice Returns whether `tokenId` is currently in the subscription index.
    function isTokenSubscribed(uint256 tokenId) external view returns (bool);

    // -----------
    // Administration
    // -----------

    /// @notice Toggles whether a position must be in range to be subscription-eligible.
    /// @dev Gated to DEFAULT_ADMIN_ROLE.
    function setInRangeRequired(bool required) external;

    /// @notice Recovers ERC20 tokens sent to the contract in error. Gated to SUPPORT_ROLE.
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external;
}

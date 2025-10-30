// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPositionRegistry {
    /// @notice Checkpoint structure for fee growth data
    struct FeeGrowthCheckpoint {
        int128 feeGrowth0;
        int128 feeGrowth1;
    }

    /// @notice Checkpoint metadata for better searchability offchain
    struct CheckpointMetadata {
        uint48 firstCheckpoint;
        uint48 lastCheckpoint;
        uint48 totalCheckpoints;
    }

    /// @notice Struct to represent a tracked LP position
    struct Position {
        address owner;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        /// @notice History of positions' liquidity + feeGrowth checkpoints
        /// @dev Since Trace208 array is unbounded it can grow beyond EVM memory limits
        /// do not load into EVM memory; consume events offchain instead and fall back to loading slots if needed
        Checkpoints.Trace208 liquidityModifications;
        mapping(uint48 => FeeGrowthCheckpoint) feeGrowthCheckpoints;
    }

    /// @notice Struct to represent positions with more granular multipool data for external consumption
    struct PositionDetails {
        address owner;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        PoolKey poolKey;
    }

    /// @notice Emitted when a position is added or its liquidity is modified
    event PositionUpdated(
        uint256 indexed tokenId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when a user successfully claims their reward
    event RewardsClaimed(address indexed owner, uint256 amount);

    /// @notice Emitted when a router's trust status is updated.
    event RouterRegistryUpdated(address indexed router, bool listed);

    /// @notice Emitted when the TEL token position is updated for a pool.
    event PoolInitialized(PoolKey indexed poolKey);

    /// @notice Emitted when the weight configuration is updated
    event WeightsConfigured(uint256 minPassiveLifetime, uint256 jitWeight, uint256 activeWeight, uint256 passiveWeight);

    /// @notice Emitted at each liquidity modification for offchain consumption
    event Checkpoint(
        uint256 indexed tokenId,
        PoolId indexed poolId,
        uint256 indexed checkpointIndex,
        int128 feeGrowthInside0X128,
        int128 feeGrowthInside1X128
    );

    /// @notice Emitted when a token is subscribed
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when a subscription is removed
    event Unsubscribed(uint256 indexed tokenId, address indexed owner);

    error Untracked(uint256 tokenId);
    error InvalidPool(PoolId poolId);
    error LiquidityBelowThreshold(uint128 currentLiquidity);
    error MaxSubscriptions();
    error MaxSubscribed();
    error ArityMismatch();
    error AmountMismatch();
    error NoClaimableRewards();
    error OnlyAdmin();
    error AlreadyInitialized();

    /**
     * @notice Updates the stored index of TEL in a specific Uniswap V4 pool.
     * @dev Only callable by the TELxIncentiveHook which possesses `UNI_HOOK_ROLE`
     * @dev Must be initiated by an admin as `tx.origin`
     */
    function initialize(address sender, PoolKey calldata key) external;

    /**
     * @notice Adds or removes a router from the trusted routers registry.
     * @dev Only callable by an address with SUPPORT_ROLE.
     * @param router The router address to update.
     * @param listed Whether the router should be marked as trusted.
     */
    function updateRouter(address router, bool listed) external;

    /**
     * @notice Called by Uniswap hook to add or remove tracked liquidity
     * @param tokenId The identifier of the position to remove.
     * @param poolId Target pool
     * @param liquidityDelta Change in liquidity (positive = add, negative = remove)
     * @param feeGrowth0 Currency0 fees accrued since the last time fees were collected from this position
     * @param feeGrowth1 Currency1 fees accrued since the last time fees were collected from this position
     */
    function addOrUpdatePosition(
        uint256 tokenId,
        PoolId poolId,
        int128 liquidityDelta,
        int128 feeGrowth0,
        int128 feeGrowth1
    ) external;

    /**
     * @notice Registers a position's ownership using the NFT tokenId.
     * @dev Must be invoked during hooks by an address with SUBSCRIBER_ROLE, such as TELxSubscriber
     * @dev LP position ownership has been guaranteed but may need to be updated if appropriate
     * @dev LPs must subscribe to become eligible for TELx incentives
     */
    function handleSubscribe(uint256 tokenId) external;

    /**
     * @notice Deregisters a subscription, requiring re-subscription to re-join the program
     * @dev Invoked during v4 unsubscription hooks by TELxSubscriber
     * @dev Removes `tokenId` from `subscription` ledger and from the `subscribed` array
     */
    function handleUnsubscribe(uint256 tokenId) external;

    /**
     * @notice Permanently deregisters a subscription and untracks its position
     * @dev Invoked during v4 burn hooks by TELxSubscriber
     * @dev Removes `tokenId` from `subscription` ledger and from the `subscribed` array
     * and marks the position as untracked to be permanently ignored
     */
    function handleBurn(uint256 tokenId, address owner) external;

    /**
     * @notice Computes currency0 & currency1 amounts for given liquidity at current tick price
     * @dev Exposes Uniswap V3/V4 concentrated liquidity math publicly for TELx frontend use
     */
    function getAmountsForLiquidity(PoolId poolId, uint128 liquidity, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96);

    /// @notice Returns position metadata for a given tokenId
    function getPosition(uint256 tokenId)
        external
        view
        returns (address owner, PoolId poolId, int24 tickLower, int24 tickUpper);

    /// @notice Returns position with more granular multipool data for external consumption
    function getPositionDetails(uint256 tokenId) external view returns (PositionDetails memory);

    /// @notice Returns position's last recorded liquidity
    function getLiquidityLast(uint256 tokenId) external view returns (uint128);

    /**
     * @notice Returns whether a router is in the trusted routers list.
     * @dev Used to determine if a router can be queried for the actual msg.sender.
     */
    function isActiveRouter(address router) external view returns (bool);

    /**
     * @notice Returns whether a given PoolId is known by this contract
     * @dev A PoolId is considered valid if it has been initialized with a currency pair.
     * @param id The unique identifier for the Uniswap V4 pool.
     * @return True if the pool has a non-zero currency0 or currency1 address.
     */
    function validPool(PoolId id) external view returns (bool);

    /// @notice Returns the list of all addresses that have active subscriptions
    function getSubscribed() external view returns (address[] memory);

    /// @notice Returns tokenIds for an owner that have been subscribed
    function getSubscriptions(address owner) external view returns (uint256[] memory);
    /**
     * @notice Adds batch rewards for many users in a specific block round
     * @param lps LP addresses
     * @param amounts Reward values per address
     * @param totalAmount Sum of all `amounts`
     */
    function addRewards(address[] calldata lps, uint256[] calldata amounts, uint256 totalAmount) external;

    /**
     * @notice Allows users to claim their earned rewards
     */
    function claim() external;

    /**
     * @notice Gets unclaimed reward balance for a user
     */
    function getUnclaimedRewards(address user) external view returns (uint256);

    /// @notice Configures JIT | Active | Passive lifetimes and weights for offchain consumption
    function configureWeights(
        uint256 minPassiveLifetime,
        uint256 jitWeight,
        uint256 activeWeight,
        uint256 passiveWeight
    ) external;

    /**
     * @notice Admin function to recover ERC20 tokens sent to contract in error
     */
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external;
}

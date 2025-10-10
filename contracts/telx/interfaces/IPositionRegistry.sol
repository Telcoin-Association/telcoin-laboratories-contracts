// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPositionRegistry {
    /// @notice Checkpoint structure for fee growth data
    struct FeeGrowthCheckpoint {
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
    }

    /// @notice Checkpoint metadata for better searchability offchain
    struct CheckpointMetadata {
        uint32 firstCheckpoint;
        uint32 lastCheckpoint;
        uint32 totalCheckpoints;
    }

    /// @notice Struct to represent a tracked LP position
    struct Position {
        address owner;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        /// @notice History of positions' liquidity checkpoints: `tokenId => {block, telDenominatedFees}`
        /// @dev Since Trace224 array is unbounded it can grow beyond EVM memory limits
        /// do not load into EVM memory; consume offchain instead and fall back to loading slots if needed
        Checkpoints.Trace224 liquidityModifications;
        mapping(uint32 => FeeGrowthCheckpoint) feeGrowthCheckpoints;
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

    /// @notice Emitted at each liquidity modification for offchain consumption
    event Checkpoint(
        uint256 indexed tokenId,
        PoolId indexed poolId,
        uint256 indexed checkpointIndex,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    );

    /// @notice Emitted when a token is subscribed
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when a subscription is removed
    event Unsubscribed(
        uint256 indexed tokenId,
        address indexed owner
    );

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
     */
    function addOrUpdatePosition(
        uint256 tokenId,
        PoolId poolId,
        int128 liquidityDelta
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
    function handleBurn(uint256 tokenId) external;

    /**
     * @notice Computes currency0 & currency1 amounts for given liquidity at current tick price
     * @dev Exposes Uniswap V3/V4 concentrated liquidity math publicly for TELx frontend use
     */
    function getAmountsForLiquidity(
        PoolId poolId,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96);

    /// @notice Returns position metadata for a given tokenId
    function getPosition(uint256 tokenId) external view returns (
        address owner,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    );

    /// @notice Returns position's last recorded liquidity
    function getLiquidityLast(uint256 tokenId) external view returns (uint128);

     /**
     * @notice Returns the voting weight (in TEL) for a position at the current block's `sqrtPriceX96`
     * @dev Because voting weight is TEL-denominated, it fluctuates with price changes & impermanent loss
     * Uses TEL denomination rather than liquidity units for backwards compatibility w/ Snapshot's 
     * `erc20-balance-of-with-delegation` schema & preexisting integrations like VotingWeightCalculator
     * @param tokenId The position identifier
     */
    function computeVotingWeight(
        uint256 tokenId
    ) external view returns (uint256);

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

    /// @dev Returns whether `tokenId` is currently subscribed
    function isTokenSubscribed(uint256 tokenId) external view returns (bool);

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
    /**
     * @notice Admin function to recover ERC20 tokens sent to contract in error
     */
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external;
}

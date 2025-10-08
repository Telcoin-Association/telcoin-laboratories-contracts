// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

interface IPositionRegistry {
    /// @notice Checkpoint structure for fee growth data
    struct FeeGrowthCheckpoint {
        uint128 feeGrowthInside0X128;
        uint128 feeGrowthInside1X128;
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
        uint128 liquidity; //todo can be deleted
        /// @notice History of positions' liquidity checkpoints: `tokenId => {block, telDenominatedFees}`
        /// @dev Since Trace224 array is unbounded it can grow beyond EVM memory limits
        /// do not load into EVM memory; consume offchain instead and fall back to loading slots if needed
        Checkpoints.Trace224 liquidityModifications;
        mapping(uint32 => FeeGrowthCheckpoint) feeGrowthCheckpoints;
    }

    /// @notice Emitted when a position is added or its liquidity is increased
    event PositionUpdated(
        uint256 indexed tokenId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when a position's liquidity reaches zero and is removed
    event PositionRemoved(
        uint256 indexed tokenId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper
    );

    /// @notice Emitted when reward tokens are added to a user
    event RewardsAdded(address indexed owner, uint256 amount);

    /// @notice Emitted when a user successfully claims their reward
    event RewardsClaimed(address indexed owner, uint256 amount);

    /// @notice Emitted when a router's trust status is updated.
    event RouterRegistryUpdated(address indexed router, bool listed);

    /// @notice Emitted when the TEL token position is updated for a pool.
    event PoolAdded(PoolKey indexed poolKey);

    /// @notice Emitted when a token is subscribed for the first time
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    function initialize(address sender, PoolKey calldata key) external;

    function getSubscribedTokenIdsByOwner(
        address owner
    ) external view returns (uint256[] memory);

    function addOrUpdatePosition(
        uint256 tokenId,
        PoolId poolId,
        int128 liquidityDelta
    ) external;

    function handleSubscribe(uint256 tokenId) external;
    function handleUnsubscribe(uint256 tokenId) external;
    function handleBurn(uint256 tokenId) external;

    function computeVotingWeight(
        uint256 tokenId
    ) external view returns (uint256);

    function isActiveRouter(address router) external view returns (bool);

    function validPool(PoolId id) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IPositionRegistry {
    /// @notice Struct to represent a tracked LP position
    struct Position {
        address provider;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Emitted when a position is added or its liquidity is increased
    event PositionUpdated(
        uint256 indexed tokenId,
        address indexed provider,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when a position's liquidity reaches zero and is removed
    event PositionRemoved(
        uint256 indexed tokenId,
        address indexed provider,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper
    );

    /// @notice Emitted when reward tokens are added to a user
    event RewardsAdded(address indexed provider, uint256 amount);

    /// @notice Emitted when a user successfully claims their reward
    event RewardsClaimed(address indexed provider, uint256 amount);

    /// @notice Emitted when the TEL token position is updated for a pool.
    event TelPositionUpdated(PoolId indexed poolId, uint8 location);

    /// @notice Emitted when a token is subscribed for the first time
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    function getTokenIdsByProvider(
        address provider
    ) external view returns (uint256[] memory);

    function addOrUpdatePosition(
        uint256 tokenId,
        PoolId poolId,
        int128 liquidityDelta
    ) external;

    function handleSubscribe(uint256 tokenId) external;

    function computeVotingWeight(
        uint256 tokenId
    ) external view returns (uint256);

    function validPool(PoolId id) external view returns (bool);
}

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

    function getAllActivePositions() external view returns (Position[] memory);

    function addOrUpdatePosition(
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external;

    function activeRouters(address router) external view returns (bool);

    function validPool(PoolId id) external view returns (bool);
}

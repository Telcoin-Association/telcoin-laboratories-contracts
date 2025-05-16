// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";

// TESTING ONLY
contract MockPositionRegistry is IPositionRegistry {
    function addOrUpdatePosition(
        address,
        PoolId,
        int24,
        int24,
        int128
    ) external pure override {}

    function getAllActivePositions()
        external
        view
        returns (Position[] memory)
    {}
}

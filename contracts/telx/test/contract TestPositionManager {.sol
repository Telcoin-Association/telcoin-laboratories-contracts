// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";

// TESTING ONLY
contract TestPositionManager is IPositionManager {
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory, PositionInfo) {}

    function ownerOf(uint256) external view returns (address owner) {
        return address(this);
    }

    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128 liquidity) {}
}

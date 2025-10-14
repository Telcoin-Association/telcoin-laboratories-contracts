// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @dev This is based off of node_modules/@uniswap/v4-periphery/src/interfaces/IPositionManager.sol
interface IPositionManager {
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory, PositionInfo);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128 liquidity);
}

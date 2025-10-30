// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockTELxIncentiveHook} from "./MockTELxIncentiveHook.sol";

// TESTING ONLY
contract TestPoolManager {
    uint160 public storedSqrtPriceX96;
    int24 public storedTick;
    uint24 public storedProtocolFee;
    uint24 public storedLPFee;

    constructor() {
        storedSqrtPriceX96 = 1 << 96; // Default sqrtPriceX96 = 1.0
        storedTick = 0;
        storedProtocolFee = 0;
        storedLPFee = 3000; // 0.3%
    }

    /// @notice Manually set slot0 variables for testing
    function setSlot0(
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 protocolFee,
        uint24 lpFee
    ) external {
        storedSqrtPriceX96 = sqrtPriceX96;
        storedTick = tick;
        storedProtocolFee = protocolFee;
        storedLPFee = lpFee;
    }

    function callAfterSwap(
        address hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        MockTELxIncentiveHook(hook).afterSwap(
            sender,
            key,
            params,
            delta,
            hookData
        );
    }

    function callBeforeAddLiquidity(
        address hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external {
        MockTELxIncentiveHook(hook).beforeAddLiquidity(
            sender,
            key,
            params,
            hookData
        );
    }

    function callBeforeRemoveLiquidity(
        address hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external {
        MockTELxIncentiveHook(hook).beforeRemoveLiquidity(
            sender,
            key,
            params,
            hookData
        );
    }

    /// @notice Simulates `extsload` behavior to return encoded slot0 values
    /// Format from StateLibrary:
    /// bits  0..159   = sqrtPriceX96 (uint160)
    /// bits 160..183 = tick (int24, signed)
    /// bits 184..207 = protocolFee (uint24)
    /// bits 208..231 = lpFee (uint24)
    function extsload(bytes32) external view returns (bytes32 data) {
        data = bytes32(uint256(storedSqrtPriceX96));

        // Encode signed int24 tick into the proper bits (160..183)
        int256 shiftedTick = int256(storedTick) << 160;
        data |= bytes32(uint256(uint256(shiftedTick)));

        data |= bytes32(uint256(storedProtocolFee) << 184);
        data |= bytes32(uint256(storedLPFee) << 208);
    }

    /// Dummy fallback to fulfill interface; not used
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

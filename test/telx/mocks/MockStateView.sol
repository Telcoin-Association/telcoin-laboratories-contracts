// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MockStateView
/// @notice Minimal stand-in for the Uniswap v4 StateView lens exposing the reads the thin
///         PositionRegistry depends on: `getSlot0` (pool initialization check, current tick for
///         the in-range check, and price math) and `getLiquidity` (the subscription threshold).
///         Values are set per-pool by tests.
/// @dev Cast to `StateView` by the registry; only `getSlot0` and `getLiquidity` are dispatched.
contract MockStateView {
    mapping(PoolId => uint160) private _sqrtPriceX96;
    mapping(PoolId => int24) private _tick;
    mapping(PoolId => uint128) private _liquidity;

    /// @notice Sets a pool's current price and tick. A non-zero price marks the pool initialized.
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick) external {
        _sqrtPriceX96[poolId] = sqrtPriceX96;
        _tick[poolId] = tick;
    }

    /// @notice Sets a pool's total in-range liquidity, the denominator of the threshold check.
    function setLiquidity(PoolId poolId, uint128 liquidity) external {
        _liquidity[poolId] = liquidity;
    }

    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return (_sqrtPriceX96[poolId], _tick[poolId], 0, 0);
    }

    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return _liquidity[poolId];
    }
}

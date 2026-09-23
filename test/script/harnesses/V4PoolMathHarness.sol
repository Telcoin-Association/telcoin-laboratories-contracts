// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4PoolMath} from "../../../script/shared/V4PoolMath.sol";

/// @title V4PoolMathHarness
/// @notice External wrapper around the `V4PoolMath` internal library functions.
/// @dev    `vm.expectRevert` needs the revert to happen one call frame below the cheatcode. A
///         library's `internal` functions are inlined into the caller, so a revert inside one
///         surfaces at the test's own depth and the cheatcode rejects it with "call didn't revert
///         at a lower depth than cheatcode call depth". Routing the call through this contract
///         restores the frame, which is the only reason it exists: the happy paths are asserted
///         against the library directly.
contract V4PoolMathHarness {
    function minLiquidityForNarrowestPosition(uint160 sqrtPriceX96, int24 tickSpacing, uint256 value1)
        external
        pure
        returns (uint128)
    {
        return V4PoolMath.minLiquidityForNarrowestPosition(sqrtPriceX96, tickSpacing, value1);
    }

    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        return V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);
    }

    function alignTick(int24 tick, int24 tickSpacing, bool roundUp) external pure returns (int24) {
        return V4PoolMath.alignTick(tick, tickSpacing, roundUp);
    }

    function fullRangeTicks(int24 tickSpacing) external pure returns (int24, int24) {
        return V4PoolMath.fullRangeTicks(tickSpacing);
    }

    function percentRangeTicks(uint160 sqrtPriceX96, uint16 widthBps, int24 tickSpacing)
        external
        pure
        returns (int24, int24)
    {
        return V4PoolMath.percentRangeTicks(sqrtPriceX96, widthBps, tickSpacing);
    }
}

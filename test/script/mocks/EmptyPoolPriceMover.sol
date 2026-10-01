// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title EmptyPoolPriceMover
/// @notice Moves an EMPTY Uniswap v4 pool's price to any target for zero input, the way anyone
///         can between a pool's creation and its first mint.
/// @dev A swap through zero liquidity consumes nothing: `SwapMath.computeSwapStep` computes an
///      input of zero for any step with no liquidity, so the loop walks straight to the price
///      limit and the resulting delta is zero on both sides. Nothing needs settling, so the
///      unlock completes with the pool sitting at whatever `sqrtPriceLimitX96` was given. The
///      callback asserts the delta really was zero, because a non-zero delta would mean the pool
///      had liquidity after all and the test premise is wrong.
contract EmptyPoolPriceMover is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function moveTo(PoolKey memory key, uint160 targetSqrtPriceX96) external {
        poolManager.unlock(abi.encode(key, targetSqrtPriceX96));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, uint160 target) = abi.decode(data, (PoolKey, uint160));

        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        require(current != 0, "pool not initialized");
        require(current != target, "already at target");

        BalanceDelta delta = poolManager.swap(
            key, SwapParams({zeroForOne: target < current, amountSpecified: -1, sqrtPriceLimitX96: target}), ""
        );
        require(delta.amount0() == 0 && delta.amount1() == 0, "pool was not empty");
        return "";
    }
}

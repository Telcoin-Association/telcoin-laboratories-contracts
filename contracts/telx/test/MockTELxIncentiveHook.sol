// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract MockTELxIncentiveHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    event SwapOccurredWithTick(
        PoolId indexed poolId,
        address indexed trader,
        int256 amount0,
        int256 amount1,
        int24 currentTick
    );

    IPositionRegistry public immutable registry;

    constructor(
        IPoolManager _poolManager,
        IPositionRegistry _registry
    ) BaseHook(_poolManager) {
        registry = _registry;
    }

    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        uint256 tokenId = uint256(uint160(bytes20(params.salt)));

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta)
        );

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        uint256 tokenId = uint256(uint160(bytes20(params.salt)));

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta)
        );

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (registry.validPool(key.toId())) {
            (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());

            emit SwapOccurredWithTick(
                key.toId(),
                sender,
                delta.amount0(),
                delta.amount1(),
                tick
            );
        }

        return (BaseHook.afterSwap.selector, 0);
    }
}

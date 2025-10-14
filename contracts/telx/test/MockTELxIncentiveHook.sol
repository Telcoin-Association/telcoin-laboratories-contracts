// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TELxIncentiveHook } from "../core/TELxIncentiveHook.sol";

contract MockTELxIncentiveHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

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
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
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

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    ) internal virtual override returns (bytes4) {
        registry.initialize(sender, key);

        return BaseHook.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta),
            feesAccrued.amount0(),
            feesAccrued.amount1()
        );

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta),
            feesAccrued.amount0(),
            feesAccrued.amount1()
        );

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    function _resolveUser(address sender) internal view returns (address) {
        if (registry.isActiveRouter(sender)) {
            try IMsgSender(sender).msgSender() returns (address user) {
                return user;
            } catch {
                revert("Trusted router must implement msgSender()");
            }
        }
        return sender;
    }
}

contract TELxIncentiveHookDeployable is TELxIncentiveHook {
    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        IPositionRegistry _registry
    ) TELxIncentiveHook(_poolManager, _positionManager, _registry) {}

    function validateHookAddress(BaseHook _this) internal pure override {}
}
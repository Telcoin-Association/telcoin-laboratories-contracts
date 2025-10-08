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

/**
 * @title TELx Incentive Hook
 * @author Robriks 📯️📯️📯️.eth
 * @notice Uniswap v4 hook that tracks LP activity and emits swap events for off-chain reward logic.
 * @dev This contract works in tandem with a PositionRegistry and an off-chain rewards script.
 */
contract TELxIncentiveHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Emitted during every swap, used for off-chain range validation
    event SwapOccurredWithTick(
        PoolId indexed poolId,
        address indexed trader,
        int256 amount0,
        int256 amount1,
        int24 currentTick
    );

    /// @notice Registry used to store and track liquidity positions
    IPositionRegistry public immutable registry;
    address public immutable positionManager;

    /**
     * @notice Constructs the incentive hook contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     * @param _positionManager Address of the position manager used to track LP data
     * @param _registry Address of the PositionRegistry used to track LP metadata
     */
    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        IPositionRegistry _registry
    ) BaseHook(_poolManager) {
        registry = _registry;
        positionManager = _positionManager;
    }

    /**
     * @notice Defines which Uniswap V4 hooks this contract implements
     * @dev Only beforeAddLiquidity, beforeRemoveLiquidity, and afterSwap are enabled
     */
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
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice Called before initializing a new pool
     * @dev Passes the delta to the registry to record or update the LP’s position
     * @param key The pool key (used to derive PoolId)
     */
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    ) internal virtual override returns (bytes4) {
        registry.initialize(sender, key);

        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Called before liquidity is added to a pool
     * @dev Passes the delta to the registry to record or update the LP’s position
     * @param sender Address of the LP adding liquidity
     * @param key The pool key (used to derive PoolId)
     * @param params Liquidity modification parameters (including tick range and delta)
     */
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        require(
            sender == positionManager,
            "TELxIncentiveHook: Caller is not Position Manager"
        );

        uint256 tokenId = uint256(params.salt);

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta)
        );

        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Called before liquidity is removed from a pool
     * @dev Updates or deletes position if liquidity reaches zero
     * @param sender Address of the LP removing liquidity
     * @param key The pool key
     * @param params Liquidity modification parameters (including tick range and delta)
     */
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        require(
            sender == positionManager,
            "TELxIncentiveHook: Caller is not Position Manager"
        );

        uint256 tokenId = uint256(params.salt);

        registry.addOrUpdatePosition(
            tokenId,
            key.toId(),
            int128(params.liquidityDelta)
        );

        return BaseHook.beforeRemoveLiquidity.selector;
    }
}

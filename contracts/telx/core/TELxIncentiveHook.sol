// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";

/**
 * @title TELx Incentive Hook
 * @author Robriks 📯️📯️📯️.eth
 * @notice Uniswap v4 hook that tracks LP activity and emits swap events for off-chain reward logic.
 * @dev This contract works in tandem with a PositionRegistry and an off-chain rewards script.
 */
contract TELxIncentiveHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

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

    modifier onlyPositionManager(address sender) {
        require(
            sender == positionManager,
            "TELxIncentiveHook: Caller is not Position Manager"
        );
        _;
    }

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
     * @dev Only beforeInitialize, afterAddLiquidity and afterRemoveLiquidity are enabled
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
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
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
    ) internal virtual override onlyPoolManager() returns (bytes4) {
        registry.initialize(sender, key);

        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Called after liquidity is added to a pool
     * @dev Passes the delta to the registry to record or update the LP’s position
     * @param sender Address of the LP adding liquidity
     * @param key The pool key (used to derive PoolId)
     * @param params Liquidity modification parameters (including tick range and delta)
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override onlyPositionManager(sender) returns (bytes4, BalanceDelta) {
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

    /**
     * @notice Called after liquidity is removed from a pool
     * @dev Updates or deletes position if liquidity reaches zero
     * @param sender Address of the LP removing liquidity
     * @param key The pool key
     * @param params Liquidity modification parameters (including tick range and delta)
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override onlyPositionManager(sender) returns (bytes4, BalanceDelta) {

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
}

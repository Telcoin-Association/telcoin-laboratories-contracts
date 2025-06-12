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
 * @author Amir M. Shirif
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

    /**
     * @notice Constructs the incentive hook contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     * @param _registry Address of the position registry used to track LP data
     */
    constructor(
        IPoolManager _poolManager,
        IPositionRegistry _registry
    ) BaseHook(_poolManager) {
        registry = _registry;
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
        registry.addOrUpdatePosition(
            _resolveUser(sender),
            key.toId(),
            params.tickLower,
            params.tickUpper,
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
        registry.addOrUpdatePosition(
            _resolveUser(sender),
            key.toId(),
            params.tickLower,
            params.tickUpper,
            int128(params.liquidityDelta)
        );

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Called after a swap executes in the pool
     * @dev Captures tick for off-chain tracking — used to determine if LPs were in-range at time of swap
     * @param sender Address that initiated the swap
     * @param key Pool key
     * @param delta Amounts of token0/token1 exchanged during the swap
     * @return Selector for Uniswap V4 hook compliance, no BalanceDelta used by this hook
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (registry.validPool(key.toId())) {
            // Extract current tick directly from pool storage using StateLibrary
            (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());

            // Emit swap event with tick so off-chain logic can check LP range activity
            emit SwapOccurredWithTick(
                key.toId(),
                _resolveUser(sender),
                delta.amount0(),
                delta.amount1(),
                tick
            );
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Resolves the actual user address from the swap initiator
     * @dev If the sender is a trusted router (tracked in PositionRegistry), attempts to call `msgSender()` on the router to get the original user (EOA or smart account).
     *      Reverts if the router is trusted but does not implement the `msgSender()` function.
     *      If the sender is not a trusted router, it is assumed to be the actual user and returned directly.
     * @param sender Address passed to the hook by the PoolManager (typically a router or user)
     * @return user Resolved user address — either the EOA from a router or the direct sender
     */
    function _resolveUser(address sender) internal view returns (address) {
        if (registry.activeRouters(sender)) {
            try IMsgSender(sender).msgSender() returns (address user) {
                return user;
            } catch {
                revert("Trusted router must implement msgSender()");
            }
        }
        return sender;
    }
}

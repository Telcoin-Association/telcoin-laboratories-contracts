// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {V4PoolMath} from "../shared/V4PoolMath.sol";
import {TELxPoolScriptBase} from "./base/TELxPoolScriptBase.sol";

/**
 * @title CreateV4Pool
 * @notice Initializes one standardized TELx Uniswap v4 pool at a price derived from the amounts we
 *         intend to seed it with, and nothing else.
 * @dev    This is the two-step path. The default path is `SeedV4Liquidity.createAndSeed`, which
 *         initializes and mints in one transaction so the pool is never observable empty. An empty
 *         v4 pool's price can be moved to any value for zero input, because a swap through zero
 *         liquidity consumes nothing, so a pool created here and seeded later is a pool whose
 *         opening price is whatever the last passer-by left it at. Use this script only when the
 *         pool genuinely has to exist before it can be seeded, and seed it through
 *         `SeedV4Liquidity.run`, which refuses a live price that has drifted from the intended one.
 *
 *         Pass the SAME amounts here that will later be passed to `SeedV4Liquidity`. The pool's
 *         opening price is `amount1 / amount0` in raw units, so using different figures in the two
 *         steps opens the pool away from where the liquidity lands.
 *
 *         Amounts come from `script/telx/pools.json`, which is filled in once for all seven pools
 *         and reviewed as a set. Preview every pool on the connected chain, broadcasting nothing:
 *
 *           forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
 *             --rpc-url $POLYGON_RPC_URL --sig "planAll()"
 *
 *         Then create one:
 *
 *           forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
 *             --rpc-url $POLYGON_RPC_URL --broadcast --ledger \
 *             --sig "run(string)" "POLYGON_EUSD_TEL"
 *
 *         The explicit-amount overloads, `plan(string,uint256,uint256)` and
 *         `run(string,uint256,uint256)`, bypass the file for one-off exploration.
 *
 *         Amounts are whole tokens, not raw units: `100000` eUSD and `20000000` TEL. Scaling by
 *         each side's decimals is the script's job, because that is the step the TEL v2 to v3
 *         decimal change (2 to 18) makes easy to get wrong by a factor of 1e16.
 */
contract CreateV4Pool is TELxPoolScriptBase {
    error PriceDeviation(string poolName, int24 liveTick, int24 intendedTick, int24 maxTickDeviation);

    // -----------
    // Preview
    // -----------

    /// @notice Previews every catalog pool on the connected chain from `pools.json`. Pools whose
    ///         amounts are still unset are reported rather than skipped silently, so the output is
    ///         also a checklist of what remains to be decided.
    function planAll() external view {
        string[] memory names = _poolsOnThisChain();
        for (uint256 i; i < names.length; ++i) {
            PoolParams memory params = _poolParams(names[i]);
            if (params.amount0Human == 0 || params.amount1Human == 0) {
                console2.log("=== %s: amounts not set in pools.json ===", names[i]);
                continue;
            }
            _plan(names[i], params);
            console2.log("");
        }
    }

    /// @notice Previews one pool using the amounts in `pools.json`.
    function plan(string memory poolName) external view {
        PoolParams memory params = _poolParams(poolName);
        _requireAmountsSet(poolName, params);
        _plan(poolName, params);
    }

    /// @notice Dry run with explicit amounts and the file's default tolerance.
    function plan(string memory poolName, uint256 amount0Human, uint256 amount1Human) external view {
        _plan(poolName, _explicitParams(amount0Human, amount1Human));
    }

    /**
     * @dev Resolves and prints every number the real run would use, and broadcasts nothing. The
     *      operator sees the poolId, the opening price in raw, tick and human form, and whether
     *      the pool already exists and at what price, before spending gas or committing to a
     *      price.
     */
    function _plan(string memory poolName, PoolParams memory params) internal view {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);

        console2.log("=== CreateV4Pool plan ===");
        _logChain(config);
        _logPool(poolName, s, key);

        (uint256 amount0, uint256 amount1) = _rawAmounts(poolName, s, params.amount0Human, params.amount1Human);
        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        console2.log("Seed amounts:");
        _logAmount("amount0", amount0, s.decimals0, s.symbol0);
        _logAmount("amount1", amount1, s.decimals1, s.symbol1);
        console2.log("Intended opening price:");
        _logPrice(sqrtPriceX96, s);

        uint160 live = _currentSqrtPriceX96(config, key.toId());
        if (live == 0) {
            console2.log("Pool is NOT yet initialized; run() will create it.");
            console2.log("Consider SeedV4Liquidity.createAndSeed instead, which creates and seeds atomically.");
        } else {
            console2.log("Pool is ALREADY initialized. Live price:");
            _logPrice(live, s);
            _logDeviation(live, sqrtPriceX96, params.maxTickDeviation);
            console2.log("  pool liquidity:", uint256(_poolLiquidity(config, key.toId())));
        }
    }

    // -----------
    // Run
    // -----------

    /// @notice Production entrypoint using the amounts in `pools.json`.
    function run(string memory poolName) external returns (PoolId poolId, uint160 sqrtPriceX96) {
        PoolParams memory params = _poolParams(poolName);
        _requireAmountsSet(poolName, params);
        return runWithSigner(poolName, params, _resolveSigner());
    }

    /// @notice Production entrypoint with explicit amounts and the file's default tolerance.
    function run(string memory poolName, uint256 amount0Human, uint256 amount1Human)
        external
        returns (PoolId poolId, uint160 sqrtPriceX96)
    {
        return runWithSigner(poolName, _explicitParams(amount0Human, amount1Human), _resolveSigner());
    }

    /// @notice Explicit-signer, explicit-amount form for fork tests.
    function runWithSigner(string memory poolName, uint256 amount0Human, uint256 amount1Human, address signer)
        external
        returns (PoolId poolId, uint160 sqrtPriceX96)
    {
        return runWithSigner(poolName, _explicitParams(amount0Human, amount1Human), signer);
    }

    /**
     * @notice Explicit-signer entrypoint. Production `run()` delegates here and fork tests call it
     *         directly with a controlled signer, per the repo's deploy-script convention.
     * @param poolName A `CHAIN_SYMBOL0_SYMBOL1` name from the TELx catalog.
     * @param params Whole-token amounts, which derive the price, and the tolerance that decides
     *        whether an already-initialized pool counts as being at that price.
     * @param signer Address to broadcast from.
     * @return poolId The pool's id.
     * @return sqrtPriceX96 The pool's price after the run: the intended one if it was created here,
     *         the live one if it already existed within tolerance.
     */
    function runWithSigner(string memory poolName, PoolParams memory params, address signer)
        public
        returns (PoolId poolId, uint160 sqrtPriceX96)
    {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);
        poolId = key.toId();

        (uint256 amount0, uint256 amount1) = _rawAmounts(poolName, s, params.amount0Human, params.amount1Human);
        sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        _logChain(config);
        _logPool(poolName, s, key);

        // An existing pool is left alone, but only if it sits where we meant to open it. The price
        // we computed is not the price it has, and an empty pool can have been moved anywhere for
        // free; reporting a drifted price as success would hand the seed that follows to whoever
        // moved it.
        uint160 live = _currentSqrtPriceX96(config, poolId);
        if (live != 0) {
            console2.log("Pool already initialized; leaving it untouched. Live price:");
            _logPrice(live, s);
            _requireWithinTolerance(poolName, live, sqrtPriceX96, params.maxTickDeviation);
            return (poolId, live);
        }

        vm.startBroadcast(signer);
        // `PoolManager.initialize` directly, not the PositionManager's `initializePool` wrapper:
        // the wrapper swallows an already-initialized pool into a sentinel return, and a pool that
        // came into existence between the check above and the broadcast is a race we want to
        // fail on, at whatever price the other party chose.
        int24 tick = IPoolManager(config.poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        require(tick == TickMath.getTickAtSqrtPrice(sqrtPriceX96), "Initialized at an unexpected tick");

        console2.log("Pool initialized.");
        _logPrice(sqrtPriceX96, s);

        _postConditions(config, poolId, sqrtPriceX96);
    }

    // -----------
    // Internals
    // -----------

    /// @dev Explicit amounts with the tolerances from the file's defaults block. `widthBps` is not
    ///      used by this script and is left at zero.
    function _explicitParams(uint256 amount0Human, uint256 amount1Human) internal view returns (PoolParams memory p) {
        p.amount0Human = amount0Human;
        p.amount1Human = amount1Human;
        (p.maxTickDeviation, p.slippageBps) = _defaultTolerances();
    }

    function _requireWithinTolerance(string memory poolName, uint160 live, uint160 intended, int24 maxTickDeviation)
        internal
        pure
    {
        int24 liveTick = TickMath.getTickAtSqrtPrice(live);
        int24 intendedTick = TickMath.getTickAtSqrtPrice(intended);
        if (_tickDistance(liveTick, intendedTick) > maxTickDeviation) {
            revert PriceDeviation(poolName, liveTick, intendedTick, maxTickDeviation);
        }
    }

    function _logDeviation(uint160 live, uint160 intended, int24 maxTickDeviation) internal pure {
        int24 liveTick = TickMath.getTickAtSqrtPrice(live);
        int24 intendedTick = TickMath.getTickAtSqrtPrice(intended);
        int24 distance = _tickDistance(liveTick, intendedTick);
        console2.log("  live vs intended tick distance:", int256(distance));
        console2.log("  tolerance:", int256(maxTickDeviation));
        console2.log(distance > maxTickDeviation ? "  OUTSIDE tolerance: run() will revert" : "  within tolerance");
    }

    function _tickDistance(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    /// @dev Reads the pool back through StateView to confirm the chain agrees with what we think
    ///      we just did, rather than trusting the return value of the call we made.
    function _postConditions(ChainConfig memory config, PoolId poolId, uint160 expectedSqrtPriceX96) internal view {
        uint160 live = _currentSqrtPriceX96(config, poolId);
        require(live == expectedSqrtPriceX96, "Post-check: live price does not match the intended price");
    }
}

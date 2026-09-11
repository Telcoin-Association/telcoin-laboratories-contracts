// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {V4PoolMath} from "../shared/V4PoolMath.sol";
import {TELxPoolScriptBase} from "./TELxPoolScriptBase.sol";

/**
 * @title CreateV4Pool
 * @notice Initializes one standardized TELx Uniswap v4 pool at a price derived from the amounts we
 *         intend to seed it with.
 * @dev    Creation is separated from seeding on purpose. Initializing a v4 pool moves no tokens, so
 *         the seven pools can be created as soon as governance approves them, while seeding has to
 *         wait until the treasury holds upgraded TEL. Running them as one script would couple the
 *         two schedules for no benefit.
 *
 *         Pass the SAME amounts here that will later be passed to `SeedV4Liquidity`. The pool's
 *         opening price is `amount1 / amount0` in raw units, so using different figures in the two
 *         steps opens the pool away from where the liquidity lands and hands the difference to the
 *         first arbitrageur.
 *
 *         Usage - preview first, it broadcasts nothing:
 *
 *           forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
 *             --rpc-url $POLYGON_RPC_URL \
 *             --sig "plan(string,uint256,uint256)" \
 *             "POLYGON_EUSD_TEL" 100000 20000000
 *
 *         Then create:
 *
 *           forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
 *             --rpc-url $POLYGON_RPC_URL --broadcast \
 *             --sig "run(string,uint256,uint256)" \
 *             "POLYGON_EUSD_TEL" 100000 20000000
 *
 *         Amounts are whole tokens, not raw units: `100000` eUSD and `20000000` TEL. Scaling by
 *         each side's decimals is the script's job, because that is the step the TEL v2 to v3
 *         decimal change (2 to 18) makes easy to get wrong by a factor of 1e16.
 */
contract CreateV4Pool is TELxPoolScriptBase {
    /// @notice Returned by `initializePool` when the pool already exists, instead of reverting.
    int24 internal constant ALREADY_INITIALIZED = type(int24).max;

    /**
     * @notice Dry run. Resolves and prints every number the real run would use, and broadcasts
     *         nothing.
     * @dev The main ergonomic affordance of this suite: the operator sees the poolId, the opening
     *      price, the tick and whether the pool already exists before spending gas or committing to
     *      a price.
     */
    function plan(string memory poolName, uint256 amount0Human, uint256 amount1Human) public view {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);

        console2.log("=== CreateV4Pool plan ===");
        console2.log("Chain:      ", config.name);
        _logPool(poolName, s, key);

        (uint256 amount0, uint256 amount1) = _rawAmounts(s, amount0Human, amount1Human);
        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        console2.log("Seed amounts (raw):");
        console2.log("  amount0:", amount0);
        console2.log("  amount1:", amount1);
        console2.log("Opening price:");
        _logPrice(sqrtPriceX96);

        uint160 live = _currentSqrtPriceX96(config, key.toId());
        if (live == 0) {
            console2.log("Pool is NOT yet initialized; run() will create it.");
        } else {
            console2.log("Pool is ALREADY initialized; run() will leave it untouched.");
            console2.log("Live price:");
            _logPrice(live);
        }
    }

    /// @notice Production entrypoint. Resolves the signer from env and delegates.
    function run(string memory poolName, uint256 amount0Human, uint256 amount1Human)
        external
        returns (PoolId poolId, uint160 sqrtPriceX96)
    {
        return runWithSigner(poolName, amount0Human, amount1Human, _resolveSigner());
    }

    /**
     * @notice Explicit-signer entrypoint. Production `run()` delegates here and fork tests call it
     *         directly with a controlled signer, per the repo's deploy-script convention.
     * @param poolName A `CHAIN_SYMBOL0_SYMBOL1` name from the TELx catalog.
     * @param amount0Human Whole tokens of currency0 to be seeded, used to derive the price.
     * @param amount1Human Whole tokens of currency1 to be seeded, used to derive the price.
     * @param signer Address to broadcast from.
     */
    function runWithSigner(string memory poolName, uint256 amount0Human, uint256 amount1Human, address signer)
        public
        returns (PoolId poolId, uint160 sqrtPriceX96)
    {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);
        poolId = key.toId();

        (uint256 amount0, uint256 amount1) = _rawAmounts(s, amount0Human, amount1Human);
        sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        _logPool(poolName, s, key);

        // Initializing an existing pool would reset nothing but would waste a transaction, and
        // more importantly the price we computed is not the price it already has. Report the live
        // one instead so the caller seeds against reality.
        uint160 live = _currentSqrtPriceX96(config, poolId);
        if (live != 0) {
            console2.log("Pool already initialized; leaving it untouched.");
            _logPrice(live);
            return (poolId, live);
        }

        vm.startBroadcast(signer);
        // `initializePool` (PoolInitializer_v4) rather than `PoolManager.initialize`: it returns
        // type(int24).max instead of reverting if the pool already exists, so a rerun of this
        // script is a no-op rather than a failed broadcast.
        int24 tick = IPositionManager(config.positionManager).initializePool(key, sqrtPriceX96);
        vm.stopBroadcast();

        // A pool that existed at broadcast time despite the check above is a race, not a success.
        require(tick != ALREADY_INITIALIZED, "Pool was initialized by someone else mid-run");
        require(tick == TickMath.getTickAtSqrtPrice(sqrtPriceX96), "Initialized at an unexpected tick");

        console2.log("Pool initialized.");
        _logPrice(sqrtPriceX96);

        _postConditions(config, poolId, sqrtPriceX96);
    }

    // -----------
    // Internals
    // -----------

    /// @dev Scales whole-token amounts by each side's decimals.
    function _rawAmounts(TELxPools.PoolSpec memory s, uint256 amount0Human, uint256 amount1Human)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = V4PoolMath.toRawAmount(amount0Human, s.decimals0);
        amount1 = V4PoolMath.toRawAmount(amount1Human, s.decimals1);
    }

    /// @dev Reads the pool back through StateView to confirm the chain agrees with what we think
    ///      we just did, rather than trusting the return value of the call we made.
    function _postConditions(ChainConfig memory config, PoolId poolId, uint160 expectedSqrtPriceX96) internal view {
        uint160 live = _currentSqrtPriceX96(config, poolId);
        require(live == expectedSqrtPriceX96, "Post-check: live price does not match the intended price");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CrossChainAddresses} from "../shared/CrossChainAddresses.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {V4PoolMath} from "../shared/V4PoolMath.sol";
import {TELxPoolScriptBase} from "./base/TELxPoolScriptBase.sol";

/**
 * @title SeedV4Liquidity
 * @notice Creates a standardized TELx Uniswap v4 pool and mints its initial position in one
 *         transaction, or mints into a pool that already exists at the intended price.
 * @dev    `createAndSeed` is the default path. It bundles `initializePool` and the mint into a
 *         single `PositionManager.multicall`, so the pool is never observable in the empty state.
 *         That matters because an empty v4 pool's price can be moved to any value for zero input:
 *         a swap through zero liquidity consumes nothing and lands on its price limit. A pool
 *         created in one transaction and seeded in a later one is therefore seeded at whatever
 *         price the last passer-by chose, and the difference between that and the intended price
 *         is theirs to take from the seed. Creating and seeding together removes the window
 *         rather than trying to detect someone in it.
 *
 *         `run` is the existing-pool path, for a pool that had to be created ahead of time. It
 *         reads the live price and refuses to mint unless that price sits within
 *         `maxTickDeviation` ticks of the price the configured amounts imply, so a pool that has
 *         been moved is caught in the preview rather than paid for in the mint.
 *
 *         Both paths set the on-chain slippage maximums to the computed mint cost plus
 *         `slippageBps`, never to the whole budget. A price that moves between simulation and
 *         inclusion, by more than that margin in either direction, makes the PositionManager
 *         revert with `MaximumAmountExceeded`. This holds for a move that leaves the band too: a
 *         single-sided mint always costs more of that side than the two-sided one did.
 *
 *         Parameters come from `script/telx/pools.json`. Preview every pool on the connected
 *         chain, broadcasting nothing:
 *
 *           forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
 *             --rpc-url $POLYGON_RPC_URL --sig "planAll()"
 *
 *         Then create and seed one:
 *
 *           forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
 *             --rpc-url $POLYGON_RPC_URL --broadcast --ledger \
 *             --sig "createAndSeed(string)" "POLYGON_EUSD_TEL"
 *
 *         Or seed a pool that already exists:
 *
 *           forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
 *             --rpc-url $POLYGON_RPC_URL --broadcast --ledger \
 *             --sig "run(string)" "POLYGON_EUSD_TEL"
 *
 *         The position NFT goes to the governance Safe unless a recipient is passed explicitly.
 *         Seeding the same tick range twice is refused unless `SEED_ALLOW_EXISTING_RANGE=true`;
 *         a concentrated band plus a full-range backstop are two different ranges and need no
 *         override.
 *
 *         `widthBps` is the half-width of the band in basis points: 1000 is +/-10%, and 0 means
 *         full range. Amounts are whole tokens and are a budget, not a target: Uniswap takes the
 *         binding side of the pair, so one currency is deposited in full and the other partially.
 *         The plan output shows exactly what will move.
 */
contract SeedV4Liquidity is TELxPoolScriptBase {
    /// @notice `widthBps == 0` selects the full range rather than a band of zero width.
    uint16 internal constant FULL_RANGE = 0;

    /// @dev How long the Permit2 allowance and the mint deadline stay valid. Long enough to
    ///      survive a slow hardware-wallet confirmation, short enough that a stale approval is not
    ///      left standing.
    uint256 internal constant VALIDITY_WINDOW = 30 minutes;

    /// @dev ERC-721 `Transfer(address,address,uint256)`, which the PositionManager emits on mint.
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    error PoolNotInitialized(string poolName);
    error PoolAlreadyInitialized(string poolName);
    error PriceDeviation(string poolName, int24 liveTick, int24 intendedTick, int24 maxTickDeviation);
    error RangeAlreadySeeded(string poolName, int24 tickLower, int24 tickUpper);
    error NothingToMint();
    error MintNotObserved();

    /// @param signer Address to broadcast from; pays for the seed and receives any native remainder.
    /// @param recipient Owner of the minted position NFT.
    /// @param allowExistingRange Mint even if a position already spans exactly this tick range.
    struct SeedOptions {
        address signer;
        address recipient;
        bool allowExistingRange;
    }

    struct SeedPlan {
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        bool projected;
        int24 liveTick;
        int24 intendedTick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Budget;
        uint256 amount1Budget;
        uint256 amount0Cost;
        uint256 amount1Cost;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    // -----------
    // Preview
    // -----------

    /// @notice Previews every catalog pool on the connected chain from `pools.json`. Pools whose
    ///         amounts are still unset are reported rather than skipped silently.
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

    /// @notice Previews one pool using the parameters in `pools.json`.
    function plan(string memory poolName) external view {
        PoolParams memory params = _poolParams(poolName);
        _requireAmountsSet(poolName, params);
        _plan(poolName, params);
    }

    /// @notice Dry run with explicit parameters and the file's default tolerances.
    function plan(string memory poolName, uint256 amount0Human, uint256 amount1Human, uint16 widthBps) external view {
        _plan(poolName, _explicitParams(amount0Human, amount1Human, widthBps));
    }

    /**
     * @dev Resolves and prints the ticks, liquidity, the amounts that would actually move and the
     *      maximums the chain will enforce, and broadcasts nothing. Works before the pool exists,
     *      projecting the price `createAndSeed` would open it at, so the whole sequence can be
     *      rehearsed without writing to any chain.
     */
    function _plan(string memory poolName, PoolParams memory params) internal view {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);

        console2.log("=== SeedV4Liquidity plan ===");
        _logChain(config);

        SeedPlan memory p = _buildPlan(config, s, poolName, params, true);

        _logPool(poolName, s, p.key);

        if (p.projected) {
            console2.log("Pool not yet created. createAndSeed(string) will open it at:");
            _logPrice(p.sqrtPriceX96, s);
        } else {
            console2.log("Pool exists. run(string) will seed at the live price:");
            _logPrice(p.sqrtPriceX96, s);
            console2.log("  intended tick from amounts:", int256(p.intendedTick));
            int24 distance = _tickDistance(p.liveTick, p.intendedTick);
            console2.log("  live vs intended distance: ", int256(distance));
            console2.log("  tolerance:                 ", int256(params.maxTickDeviation));
            console2.log(distance > params.maxTickDeviation ? "  OUTSIDE tolerance: run() will revert" : "  within tolerance");
            console2.log("  pool liquidity:", uint256(_poolLiquidity(config, p.poolId)));
            if (_rangeHasLiquidity(config, p.poolId, p.tickLower, p.tickUpper)) {
                console2.log("  a position ALREADY spans this range: run() refuses without SEED_ALLOW_EXISTING_RANGE=true");
            }
        }

        console2.log(params.widthBps == FULL_RANGE ? "Range: FULL" : "Range: concentrated");
        if (params.widthBps != FULL_RANGE) console2.log("  widthBps:", uint256(params.widthBps));
        _logRange(p.tickLower, p.tickUpper, s.tickSpacing);

        console2.log("Liquidity:", uint256(p.liquidity));
        console2.log("Budget (from pools.json or arguments):");
        _logAmount("amount0", p.amount0Budget, s.decimals0, s.symbol0);
        _logAmount("amount1", p.amount1Budget, s.decimals1, s.symbol1);
        console2.log("Will deposit at this price:");
        _logAmount("amount0", p.amount0Cost, s.decimals0, s.symbol0);
        _logAmount("amount1", p.amount1Cost, s.decimals1, s.symbol1);
        console2.log("On-chain maximums (cost plus %s bps; the mint reverts above these):", uint256(params.slippageBps));
        _logAmount("amount0Max", p.amount0Max, s.decimals0, s.symbol0);
        _logAmount("amount1Max", p.amount1Max, s.decimals1, s.symbol1);

        console2.log("Position recipient:", _defaultRecipient());
        _logBalances(s, _trySigner(), p.amount0Max, p.amount1Max);
    }

    // -----------
    // Create and seed (default path)
    // -----------

    /// @notice Creates the pool and mints the configured position in one transaction. The pool
    ///         must not exist yet; use `run` for one that does.
    function createAndSeed(string memory poolName) external returns (uint256 tokenId) {
        return createAndSeed(poolName, _defaultRecipient());
    }

    /// @notice As `createAndSeed(string)`, with an explicit position recipient.
    function createAndSeed(string memory poolName, address recipient) public returns (uint256 tokenId) {
        PoolParams memory params = _poolParams(poolName);
        _requireAmountsSet(poolName, params);
        return createAndSeedWithOptions(poolName, params, _defaultOptions(recipient));
    }

    /**
     * @notice Explicit-options entrypoint. Production `createAndSeed` delegates here and fork tests
     *         call it directly with a controlled signer, per the repo's deploy-script convention.
     * @return tokenId The minted position's NFT id, read from the mint's Transfer event.
     */
    function createAndSeedWithOptions(string memory poolName, PoolParams memory params, SeedOptions memory opts)
        public
        returns (uint256 tokenId)
    {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);

        // A pool that already exists has a price of its own, and this path does not read it.
        if (_currentSqrtPriceX96(config, TELxPools.poolKey(s).toId()) != 0) revert PoolAlreadyInitialized(poolName);

        SeedPlan memory p = _buildPlan(config, s, poolName, params, true);
        if (p.liquidity == 0) revert NothingToMint();

        _logChain(config);
        _logPool(poolName, s, p.key);
        console2.log("Creating at:");
        _logPrice(p.sqrtPriceX96, s);
        _logRange(p.tickLower, p.tickUpper, s.tickSpacing);

        IPositionManager positionManager = IPositionManager(config.positionManager);

        // `initializePool` and the mint as one multicall: both are delegatecalls into the
        // PositionManager, and the call value carries through to the native settle. If someone
        // initializes the same pool first, at a price that differs from ours by more than the
        // slippage margin, the mint's maximums fail and the whole multicall reverts with it.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (p.key, p.sqrtPriceX96));
        calls[1] = abi.encodeCall(
            IPositionManager.modifyLiquidities, (_encodeMint(s, p, opts), block.timestamp + VALIDITY_WINDOW)
        );

        Held memory before = _held(config, p);

        vm.recordLogs();
        vm.startBroadcast(opts.signer);
        _approve(config, s, p);
        positionManager.multicall{value: _nativeValue(s, p)}(calls);
        vm.stopBroadcast();

        tokenId = _mintedTokenId(config, opts.recipient);
        _postConditions(config, tokenId, opts.recipient, p, before);
        require(
            _currentSqrtPriceX96(config, p.poolId) == p.sqrtPriceX96, "Post-check: pool did not open at the intended price"
        );

        console2.log("Pool created and position minted.");
        console2.log("  tokenId:  ", tokenId);
        console2.log("  liquidity:", uint256(p.liquidity));
        console2.log("  owner:    ", opts.recipient);
    }

    // -----------
    // Seed an existing pool
    // -----------

    /// @notice Mints the configured position into a pool that already exists at the intended price.
    function run(string memory poolName) external returns (uint256 tokenId) {
        return run(poolName, _defaultRecipient());
    }

    /// @notice As `run(string)`, with an explicit position recipient.
    function run(string memory poolName, address recipient) public returns (uint256 tokenId) {
        PoolParams memory params = _poolParams(poolName);
        _requireAmountsSet(poolName, params);
        return runWithOptions(poolName, params, _defaultOptions(recipient));
    }

    /// @notice Explicit parameters with the file's default tolerances; the position goes to the
    ///         governance Safe. A full-range backstop on top of the configured band is this form
    ///         with `widthBps` = 0.
    function run(string memory poolName, uint256 amount0Human, uint256 amount1Human, uint16 widthBps)
        external
        returns (uint256 tokenId)
    {
        return runWithOptions(
            poolName, _explicitParams(amount0Human, amount1Human, widthBps), _defaultOptions(_defaultRecipient())
        );
    }

    /**
     * @notice Explicit-options entrypoint. Production `run` delegates here and fork tests call it
     *         directly with a controlled signer, per the repo's deploy-script convention.
     * @return tokenId The minted position's NFT id, read from the mint's Transfer event.
     */
    function runWithOptions(string memory poolName, PoolParams memory params, SeedOptions memory opts)
        public
        returns (uint256 tokenId)
    {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);

        SeedPlan memory p = _buildPlan(config, s, poolName, params, false);
        if (p.liquidity == 0) revert NothingToMint();

        // The live price is what the mint happens at, so it has to be the price the reviewed
        // amounts describe. A pool that drifted is refused here, before any approval is signed.
        if (_tickDistance(p.liveTick, p.intendedTick) > params.maxTickDeviation) {
            revert PriceDeviation(poolName, p.liveTick, p.intendedTick, params.maxTickDeviation);
        }
        if (!opts.allowExistingRange && _rangeHasLiquidity(config, p.poolId, p.tickLower, p.tickUpper)) {
            revert RangeAlreadySeeded(poolName, p.tickLower, p.tickUpper);
        }

        _logChain(config);
        _logPool(poolName, s, p.key);
        console2.log("Seeding at the live price:");
        _logPrice(p.sqrtPriceX96, s);
        _logRange(p.tickLower, p.tickUpper, s.tickSpacing);

        IPositionManager positionManager = IPositionManager(config.positionManager);

        Held memory before = _held(config, p);

        vm.recordLogs();
        vm.startBroadcast(opts.signer);
        _approve(config, s, p);
        positionManager.modifyLiquidities{value: _nativeValue(s, p)}(
            _encodeMint(s, p, opts), block.timestamp + VALIDITY_WINDOW
        );
        vm.stopBroadcast();

        tokenId = _mintedTokenId(config, opts.recipient);
        _postConditions(config, tokenId, opts.recipient, p, before);

        console2.log("Position minted.");
        console2.log("  tokenId:  ", tokenId);
        console2.log("  liquidity:", uint256(p.liquidity));
        console2.log("  owner:    ", opts.recipient);
    }

    // -----------
    // Plan construction
    // -----------

    /**
     * @param allowProjected When the pool does not exist yet, derive the price from the amounts
     *        instead of reverting. The preview and the create-and-seed path set this, since both
     *        genuinely mean "the price these amounts imply"; a seed into an existing pool must
     *        never invent a price.
     */
    function _buildPlan(
        ChainConfig memory config,
        TELxPools.PoolSpec memory s,
        string memory poolName,
        PoolParams memory params,
        bool allowProjected
    ) internal view returns (SeedPlan memory p) {
        p.key = TELxPools.poolKey(s);
        p.poolId = p.key.toId();

        (p.amount0Budget, p.amount1Budget) = _rawAmounts(poolName, s, params.amount0Human, params.amount1Human);

        // The price the reviewed amounts describe. For a new pool it is the opening price; for an
        // existing one it is what the live price is held against.
        uint160 intended = V4PoolMath.sqrtPriceX96FromAmounts(p.amount0Budget, p.amount1Budget);
        p.intendedTick = TickMath.getTickAtSqrtPrice(intended);

        uint160 live = _currentSqrtPriceX96(config, p.poolId);
        if (live == 0) {
            if (!allowProjected) revert PoolNotInitialized(poolName);
            p.projected = true;
            p.sqrtPriceX96 = intended;
            p.liveTick = p.intendedTick;
        } else {
            p.sqrtPriceX96 = live;
            p.liveTick = TickMath.getTickAtSqrtPrice(live);
        }

        (p.tickLower, p.tickUpper) = params.widthBps == FULL_RANGE
            ? V4PoolMath.fullRangeTicks(s.tickSpacing)
            : V4PoolMath.percentRangeTicks(p.sqrtPriceX96, params.widthBps, s.tickSpacing);

        // Derive the sqrt-price bounds from the SAME ticks the position will be minted at. Any
        // other pairing computes liquidity for a range the position does not span.
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.sqrtPricesAtTicks(p.tickLower, p.tickUpper);

        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.sqrtPriceX96, sqrtLower, sqrtUpper, p.amount0Budget, p.amount1Budget
        );
        (p.amount0Cost, p.amount1Cost) = _mintCost(p.sqrtPriceX96, sqrtLower, sqrtUpper, p.liquidity);
        p.amount0Max = _withSlippage(p.amount0Cost, params.slippageBps);
        p.amount1Max = _withSlippage(p.amount1Cost, params.slippageBps);
    }

    /**
     * @dev What the mint will actually charge, rounded the way the PoolManager rounds it.
     *      `LiquidityAmounts.getAmountsForLiquidity` answers "what is this position worth" and
     *      rounds down; adding liquidity asks "what does it cost" and rounds up, and the two
     *      differ by a wei or two. The on-chain maximums are set from this figure, so it has to be
     *      the charged one: a maximum a wei under the cost is a guaranteed revert.
     */
    function _mintCost(uint160 sqrtPriceX96, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 < sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _withSlippage(uint256 cost, uint16 slippageBps) internal pure returns (uint256) {
        return cost + (cost * slippageBps) / V4PoolMath.BPS;
    }

    function _tickDistance(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    /// @dev Explicit amounts with the tolerances from the file's defaults block.
    function _explicitParams(uint256 amount0Human, uint256 amount1Human, uint16 widthBps)
        internal
        view
        returns (PoolParams memory p)
    {
        p.amount0Human = amount0Human;
        p.amount1Human = amount1Human;
        p.widthBps = widthBps;
        (p.maxTickDeviation, p.slippageBps) = _defaultTolerances();
    }

    /// @dev The treasury owns the seed positions. Every catalog pool's seed is TELx capital, and
    ///      the governance Safe is where TELx capital lives; a position sitting in the deployer
    ///      key would be one hardware wallet away from unrecoverable.
    function _defaultRecipient() internal pure returns (address) {
        return CrossChainAddresses.GOVERNANCE_SAFE;
    }

    function _defaultOptions(address recipient) internal view returns (SeedOptions memory) {
        return SeedOptions({
            signer: _resolveSigner(),
            recipient: recipient,
            allowExistingRange: vm.envOr("SEED_ALLOW_EXISTING_RANGE", false)
        });
    }

    // -----------
    // Approvals
    // -----------

    /**
     * @dev Uniswap v4 pulls ERC-20s through Permit2, which needs two steps per token: an ordinary
     *      ERC-20 approval to Permit2, then a Permit2 allowance for the PositionManager.
     *
     *      Both are for exactly the on-chain maximum with a real expiry, not `type(uint160).max`
     *      and `type(uint48).max`. The repo's convention is exact-amount approvals, and it matters
     *      more here than in a test: this runs against mainnet from a treasury-funded signer, so a
     *      standing unlimited allowance to Permit2 would outlive the deploy.
     *
     *      Native ETH needs neither step; it is sent as call value instead.
     */
    function _approve(ChainConfig memory config, TELxPools.PoolSpec memory s, SeedPlan memory p) internal {
        uint48 expiration = uint48(block.timestamp + VALIDITY_WINDOW);

        if (!TELxPools.isNativeCurrency0(s)) {
            _approveOne(config, s.currency0, p.amount0Max, expiration);
        }
        _approveOne(config, s.currency1, p.amount1Max, expiration);
    }

    function _approveOne(ChainConfig memory config, address token, uint256 amount, uint48 expiration) internal {
        IERC20(token).approve(config.permit2, amount);
        IAllowanceTransfer(config.permit2).approve(token, config.positionManager, uint160(amount), expiration);
    }

    /**
     * @dev Native ETH is settled as call value. The value sent is the on-chain maximum rather than
     *      the computed cost: the two differ only by the slippage margin, and the SWEEP action in
     *      `_encodeMint` returns everything the settle did not consume to the signer in the same
     *      transaction, so the margin is never actually at risk.
     */
    function _nativeValue(TELxPools.PoolSpec memory s, SeedPlan memory p) internal pure returns (uint256) {
        return TELxPools.isNativeCurrency0(s) ? p.amount0Max : 0;
    }

    // -----------
    // Action encoding
    // -----------

    /**
     * @dev Encodes MINT_POSITION followed by SETTLE_PAIR, plus SWEEP when currency0 is native ETH.
     *
     *      SETTLE_PAIR pays what the mint owes on both currencies. SWEEP is only needed on the
     *      native leg, where the value sent is the maximum and the settle consumes the cost; the
     *      difference would otherwise stay in the PositionManager. It goes back to the signer,
     *      who paid it. ERC-20 legs need no sweep because nothing is pre-sent; Permit2 pulls
     *      exactly what is owed.
     *
     *      The maximums are the computed cost plus the slippage margin. They are what the
     *      PositionManager enforces, so they are the one place a price that moved between
     *      simulation and inclusion is caught on chain.
     */
    function _encodeMint(TELxPools.PoolSpec memory s, SeedPlan memory p, SeedOptions memory opts)
        internal
        pure
        returns (bytes memory)
    {
        bool native = TELxPools.isNativeCurrency0(s);

        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(
            p.key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            uint128(p.amount0Max),
            uint128(p.amount1Max),
            opts.recipient,
            bytes("")
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        if (native) {
            params[2] = abi.encode(Currency.wrap(TELxPools.NATIVE), opts.signer);
        }

        return abi.encode(actions, params);
    }

    // -----------
    // Post-conditions
    // -----------

    /// @dev The id of the position the broadcast minted, taken from the PositionManager's own
    ///      `Transfer` from the zero address to the recipient rather than from a counter read
    ///      beforehand. Under `--broadcast` the logs are the simulation's, so the id reported here
    ///      is the id the transaction will mint if nothing else mints first; the receipt in
    ///      `broadcast/` is the authority once it lands.
    function _mintedTokenId(ChainConfig memory config, address recipient) internal returns (uint256 tokenId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != config.positionManager || log.topics.length != 4) continue;
            if (log.topics[0] != TRANSFER_TOPIC) continue;
            if (address(uint160(uint256(log.topics[1]))) != address(0)) continue;
            if (address(uint160(uint256(log.topics[2]))) != recipient) continue;
            return uint256(log.topics[3]);
        }
        revert MintNotObserved();
    }

    /// @dev What the PositionManager holds of the two currencies, taken before and compared after,
    ///      so a seed that leaves anything behind is caught without assuming the contract held
    ///      nothing to begin with.
    struct Held {
        uint256 currency0;
        uint256 currency1;
    }

    function _held(ChainConfig memory config, SeedPlan memory p) internal view returns (Held memory h) {
        h.currency0 = _balance(Currency.unwrap(p.key.currency0), config.positionManager);
        h.currency1 = _balance(Currency.unwrap(p.key.currency1), config.positionManager);
    }

    /// @dev Confirms on chain that the position exists, belongs to the recipient, holds the
    ///      liquidity we intended and left nothing behind, rather than trusting that the batched
    ///      call did what we encoded.
    function _postConditions(
        ChainConfig memory config,
        uint256 tokenId,
        address recipient,
        SeedPlan memory p,
        Held memory before
    ) internal view {
        IPositionManager positionManager = IPositionManager(config.positionManager);
        require(positionManager.getPositionLiquidity(tokenId) == p.liquidity, "Post-check: liquidity mismatch");

        (PoolKey memory mintedKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        require(PoolId.unwrap(mintedKey.toId()) == PoolId.unwrap(p.poolId), "Post-check: minted into the wrong pool");
        // The PositionManager is itself the position ERC-721.
        require(
            IERC721(address(positionManager)).ownerOf(tokenId) == recipient, "Post-check: unexpected position owner"
        );
        // Nothing of ours may be left in the PositionManager: the native margin is swept back and
        // Permit2 pulls exactly the cost.
        Held memory held = _held(config, p);
        require(held.currency0 == before.currency0, "Post-check: currency0 stranded in the PositionManager");
        require(held.currency1 == before.currency1, "Post-check: currency1 stranded in the PositionManager");
    }
}

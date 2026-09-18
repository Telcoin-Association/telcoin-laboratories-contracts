// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CreateV4Pool} from "../../script/telx/CreateV4Pool.s.sol";
import {SeedV4Liquidity} from "../../script/telx/SeedV4Liquidity.s.sol";
import {TELxPoolScriptBase} from "../../script/telx/base/TELxPoolScriptBase.sol";
import {CrossChainAddresses} from "../../script/shared/CrossChainAddresses.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {V4PoolMath} from "../../script/shared/V4PoolMath.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {SeedV4LiquidityHarness} from "./harnesses/SeedV4LiquidityHarness.sol";
import {EmptyPoolPriceMover} from "./mocks/EmptyPoolPriceMover.sol";
import {FlashPruneAttacker} from "./mocks/FlashPruneAttacker.sol";
import {ForkOrSkip} from "../util/ForkOrSkip.sol";

/// @title TELxPoolLifecycleForkTest
/// @notice End-to-end coverage of the TELx pool scripts against live Uniswap v4 deployments:
///         create and seed a pool in one transaction, or create then seed, then subscribe the
///         resulting position to a freshly deployed thin PositionRegistry.
/// @dev    The whole point of the suite is that these steps are the migration, and each one has a
///         failure mode the others hide. Creating at the wrong price is invisible until someone
///         arbitrages it; seeding with mismatched tick and sqrt-price bounds is invisible until the
///         deposited amounts are compared to the budget; and a hookless pool not being
///         subscribable is invisible until an LP tries.
///
///         The adversarial cases are the ones that matter most. An empty v4 pool's price can be
///         moved anywhere for free, so a pool created in one transaction and seeded in another is
///         seeded at whatever price it was left at. The tests below move the price the way an
///         attacker would and assert the script refuses, at both of its guards: the tolerance
///         check before anything is signed, and the on-chain maximums the PositionManager
///         enforces if the price moves after signing.
///
///         Differs from `ChainAddresses.fork.t.sol`, which only validates the address constants,
///         and from the unit suites, which use mocks. Here everything except our own contracts is
///         the real deployed article.
///
///         TEL v3 has zero supply on every chain today, so balances are granted with `deal`. That
///         is the honest setup rather than a shortcut: the pools genuinely cannot be seeded until
///         the upgrade portal opens, and this is what the seeding will do when it can.
abstract contract TELxPoolLifecycleForkTest is Test {
    CreateV4Pool internal createScript;
    SeedV4LiquidityHarness internal seedScript;
    EmptyPoolPriceMover internal mover;

    PositionRegistry internal registry;
    TELxSubscriber internal subscriber;

    address internal signer = makeAddr("deployer");
    address internal admin = makeAddr("admin");
    address internal support = makeAddr("support");

    uint16 internal constant BAND = 1000; // +/-10%
    uint16 internal constant FULL = 0;

    /// @dev Set by each concrete chain suite before `_setUpChain` runs.
    string internal rpcEnvVar;
    string internal poolName;
    uint256 internal amount0Human;
    uint256 internal amount1Human;

    function _setUpChain() internal {
        ForkOrSkip.select(rpcEnvVar);

        createScript = new CreateV4Pool();
        seedScript = new SeedV4LiquidityHarness();
        mover = new EmptyPoolPriceMover(IPoolManager(StateView(_stateView()).poolManager()));

        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);

        registry = new PositionRegistry(IPositionManager(_positionManager()), StateView(_stateView()), admin);
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), _positionManager(), support);

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        // the allowlist is what makes a pool a TELx pool; the Safe batch does this on mainnet
        registry.registerPool(TELxPools.poolKey(s));
        vm.stopPrank();

        _fund(s);
    }

    /// @dev Grants the signer the tokens the seeds will spend. Native ETH is dealt directly;
    ///      ERC-20s are dealt into their balance slot.
    function _fund(TELxPools.PoolSpec memory s) internal {
        uint256 raw0 = V4PoolMath.toRawAmount(amount0Human, s.decimals0) * 4;
        uint256 raw1 = V4PoolMath.toRawAmount(amount1Human, s.decimals1) * 4;

        if (TELxPools.isNativeCurrency0(s)) {
            vm.deal(signer, raw0);
        } else {
            deal(s.currency0, signer, raw0, true);
        }
        deal(s.currency1, signer, raw1, true);
    }

    function _positionManager() internal view virtual returns (address);
    function _stateView() internal view virtual returns (address);

    // -----------
    // Create and seed (the default path)
    // -----------

    /// @notice The migration's default path: one transaction creates the pool at the price the
    ///         amounts imply and mints the position into it, so the pool never exists empty.
    function test_createAndSeed_opensAndMintsAtomically() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        PoolId poolId = TELxPools.poolKey(s).toId();
        uint160 expected = _intendedSqrtPrice(s);

        (uint160 before,,,) = StateView(_stateView()).getSlot0(poolId);
        assertEq(before, 0, "precondition: pool must not exist");

        uint256 tokenId = seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(signer));

        (uint160 live,,,) = StateView(_stateView()).getSlot0(poolId);
        assertEq(live, expected, "pool opened at the intended price");
        assertGt(IPositionManager(_positionManager()).getPositionLiquidity(tokenId), 0, "no liquidity minted");
        assertEq(IERC721(_positionManager()).ownerOf(tokenId), signer, "position owner");
        _assertRangeMatchesMath(tokenId, live, BAND, s.tickSpacing);
    }

    /// @notice The position goes to the recipient, which on mainnet is the governance Safe.
    function test_createAndSeed_mintsToRecipient() public {
        address treasury = CrossChainAddresses.GOVERNANCE_SAFE;
        uint256 tokenId = seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(treasury));
        assertEq(IERC721(_positionManager()).ownerOf(tokenId), treasury, "position should belong to the recipient");
    }

    /// @notice A pool that already exists has a price of its own that this path does not read,
    ///         so it must refuse rather than fall through to a mint at an unchecked price.
    function test_createAndSeed_revertsWhenPoolExists() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        TELxPoolScriptBase.PoolParams memory params = _params(BAND);
        vm.expectRevert(abi.encodeWithSelector(SeedV4Liquidity.PoolAlreadyInitialized.selector, poolName));
        seedScript.createAndSeedWithOptions(poolName, params, _opts(signer));
    }

    /// @notice The front-run: between our simulation and inclusion someone initializes the same
    ///         pool at a different price. `initializePool` swallows that into a sentinel, so the
    ///         mint runs, and it is the mint's maximums that have to fail the whole multicall.
    function test_createAndSeed_frontRunInitializeAtOtherPriceReverts() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        SeedV4Liquidity.SeedPlan memory p = seedScript.buildPlan(poolName, _params(BAND), true);
        bytes memory mint = seedScript.encodeMint(poolName, p, _opts(signer));

        // attacker initializes 5% away from our intended price
        uint160 attackerPrice = uint160(uint256(p.sqrtPriceX96) * 10_247 / 10_000); // sqrt(1.05)
        IPoolManager(StateView(_stateView()).poolManager()).initialize(p.key, attackerPrice);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (p.key, p.sqrtPriceX96));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (mint, block.timestamp + 30 minutes));

        _approveForMint(s, p);
        uint256 value = seedScript.nativeValue(poolName, p);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        vm.prank(signer);
        IPositionManager(_positionManager()).multicall{value: value}(calls);
    }

    // -----------
    // Create (two-step path)
    // -----------

    /// @notice A pool that does not exist yet is created at exactly the price implied by the
    ///         amounts, and the chain agrees with the tick we expected.
    function test_createPool_opensAtThePriceImpliedByAmounts() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);
        uint160 expected = _intendedSqrtPrice(s);

        (PoolId poolId, uint160 sqrtPriceX96) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        (uint160 live,,,) = StateView(_stateView()).getSlot0(poolId);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()), "poolId");
        assertEq(sqrtPriceX96, expected, "returned price");
        assertEq(live, expected, "live price");
        assertEq(TickMath.getTickAtSqrtPrice(live), TickMath.getTickAtSqrtPrice(expected), "tick");
    }

    /// @notice Rerunning with the same amounts is a no-op that reports the live price.
    function test_createPool_rerunAtSamePriceIsNoOp() public {
        (, uint160 first) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        (, uint160 second) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        assertEq(second, first, "rerun must report the existing price");
    }

    /// @notice Rerunning with amounts that imply a different price must fail rather than report
    ///         the existing price as if it were the intended one.
    function test_createPool_rerunAtOtherPriceReverts() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        vm.expectPartialRevert(CreateV4Pool.PriceDeviation.selector);
        createScript.runWithSigner(poolName, amount0Human * 2, amount1Human, signer);
    }

    /// @notice An empty pool that has been moved since creation is reported as drifted, even
    ///         though the amounts have not changed.
    function test_createPool_reportsDriftOfAnEmptyPool() public {
        (, uint160 opened) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _movePriceByTicks(opened, 200);
        vm.expectPartialRevert(CreateV4Pool.PriceDeviation.selector);
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
    }

    /// @notice Naming a pool that belongs to another chain must fail on the name, which is the
    ///         guard against a mismatched --rpc-url when running seven deploys in a row.
    function test_createPool_rejectsWrongChainPool() public {
        string memory foreign = _foreignPoolName();
        vm.expectRevert();
        createScript.runWithSigner(foreign, amount0Human, amount1Human, signer);
    }

    // -----------
    // Seed an existing pool
    // -----------

    /// @notice Full-range seeding mints a real position, charges exactly the planned cost and
    ///         never pulls more than the budget.
    function test_seed_fullRange() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _assertSeed(FULL);
    }

    /// @notice The concentrated shape the proposal names as the primary one.
    function test_seed_concentratedBand() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _assertSeed(BAND);
    }

    /// @notice A concentrated position must span strictly fewer ticks than the full range, which is
    ///         the property that makes it capital efficient in the first place.
    function test_seed_concentratedIsNarrowerThanFullRange() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        uint256 fullId = seedScript.runWithOptions(poolName, _params(FULL), _opts(signer));
        uint256 bandId = seedScript.runWithOptions(poolName, _params(BAND), _opts(signer));

        assertGt(_positionSpan(fullId), _positionSpan(bandId), "full range should span more ticks than a +/-10% band");
    }

    /// @notice A band plus a full-range backstop are two intended mints into one pool and must not
    ///         trip the double-seed guard, while the same range twice must.
    function test_seed_sameRangeTwiceIsRefused_differentRangesAreNot() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        seedScript.runWithOptions(poolName, _params(BAND), _opts(signer));

        // the backstop
        seedScript.runWithOptions(poolName, _params(FULL), _opts(signer));

        // the accidental rerun
        TELxPoolScriptBase.PoolParams memory band = _params(BAND);
        vm.expectPartialRevert(SeedV4Liquidity.RangeAlreadySeeded.selector);
        seedScript.runWithOptions(poolName, band, _opts(signer));

        // and the deliberate one
        SeedV4Liquidity.SeedOptions memory opts = _opts(signer);
        opts.allowExistingRange = true;
        seedScript.runWithOptions(poolName, band, opts);
    }

    /// @notice Seeding a pool that was never created must fail loudly rather than mint into a
    ///         zero-priced pool.
    function test_seed_revertsWhenPoolNotInitialized() public {
        TELxPoolScriptBase.PoolParams memory params = _params(BAND);
        vm.expectRevert(abi.encodeWithSelector(SeedV4Liquidity.PoolNotInitialized.selector, poolName));
        seedScript.runWithOptions(poolName, params, _opts(signer));
    }

    /// @notice The price-manipulation attack on the two-step path. The pool is created empty, an
    ///         attacker moves its price for free, and the seed must refuse before signing anything.
    function test_seed_refusesWhenEmptyPoolWasMoved() public {
        (, uint160 opened) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _movePriceByTicks(opened, 200);

        TELxPoolScriptBase.PoolParams memory params = _params(BAND);
        vm.expectPartialRevert(SeedV4Liquidity.PriceDeviation.selector);
        seedScript.runWithOptions(poolName, params, _opts(signer));
    }

    /// @notice A move inside the tolerance is accepted, and the mint then happens at the live
    ///         price rather than the intended one.
    function test_seed_acceptsMoveWithinTolerance() public {
        (, uint160 opened) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _movePriceByTicks(opened, 20);

        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        uint256 tokenId = seedScript.runWithOptions(poolName, _params(BAND), _opts(signer));

        (uint160 live,,,) = StateView(_stateView()).getSlot0(TELxPools.poolKey(s).toId());
        _assertRangeMatchesMath(tokenId, live, BAND, s.tickSpacing);
    }

    /// @notice The on-chain guard. A plan is built at one price, the price moves after the plan
    ///         is signed, and the PositionManager must refuse the mint on its maximums. This is
    ///         the only defence once the transaction has left the operator's hands.
    function test_seed_onChainMaximumsRevertWhenPriceMovesAfterSigning() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        (, uint160 opened) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        SeedV4Liquidity.SeedPlan memory p = seedScript.buildPlan(poolName, _params(BAND), false);
        bytes memory mint = seedScript.encodeMint(poolName, p, _opts(signer));
        _approveForMint(s, p);

        // 100 ticks is about 1%, well past the 50 bps margin and well inside the band
        _movePriceByTicks(opened, 100);

        uint256 value = seedScript.nativeValue(poolName, p);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        vm.prank(signer);
        IPositionManager(_positionManager()).modifyLiquidities{value: value}(mint, block.timestamp + 30 minutes);
    }

    /// @notice A move that takes the price out of the band entirely turns the mint single-sided,
    ///         which costs more of that side than the two-sided mint did, so the same maximum
    ///         catches it.
    function test_seed_onChainMaximumsRevertWhenPriceLeavesTheBand() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        (, uint160 opened) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        SeedV4Liquidity.SeedPlan memory p = seedScript.buildPlan(poolName, _params(BAND), false);
        bytes memory mint = seedScript.encodeMint(poolName, p, _opts(signer));
        _approveForMint(s, p);

        _movePriceByTicks(opened, -2000); // roughly -18%, past the -10% edge

        uint256 value = seedScript.nativeValue(poolName, p);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        vm.prank(signer);
        IPositionManager(_positionManager()).modifyLiquidities{value: value}(mint, block.timestamp + 30 minutes);
    }

    /// @notice The `pools.json` path refuses the shipped file, whose amounts are all unset, before
    ///         it gets anywhere near a signer or a price.
    function test_run_refusesUnsetAmountsInPoolsJson() public {
        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolAmountsNotSet.selector, poolName));
        seedScript.run(poolName);

        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolAmountsNotSet.selector, poolName));
        seedScript.createAndSeed(poolName);

        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolAmountsNotSet.selector, poolName));
        createScript.run(poolName);
    }

    /// @notice The previews run before the pool exists, on both scripts, and print without
    ///         reverting. Their output is the operator's only look at the numbers before signing,
    ///         so a preview that reverts is a preview nobody sees.
    function test_plan_projectedPathRenders() public view {
        seedScript.plan(poolName, amount0Human, amount1Human, BAND);
        createScript.plan(poolName, amount0Human, amount1Human);
    }

    /// @notice And after the pool exists with liquidity in it, including the existing-range notice.
    function test_plan_livePathRendersWithExistingLiquidity() public {
        seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(signer));
        seedScript.plan(poolName, amount0Human, amount1Human, BAND);
        seedScript.plan(poolName, amount0Human, amount1Human, FULL);
        createScript.plan(poolName, amount0Human, amount1Human);
    }

    // -----------
    // Subscribe
    // -----------

    /// @notice The migration's actual acceptance criterion: a position in a hookless TELx pool can
    ///         be subscribed through the v4 native subscriber flow and shows up as votable in the
    ///         thin registry. This is what the old hook-gated registry could not do.
    function test_seededPositionIsSubscribable() public {
        uint256 tokenId = seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(signer));

        vm.prank(signer);
        IPositionManager(_positionManager()).subscribe(tokenId, address(subscriber), "");

        assertTrue(registry.isTokenSubscribed(tokenId), "not recorded as subscribed");
        assertTrue(registry.isInRange(tokenId), "freshly seeded position should be in range");
        assertTrue(registry.subscriptionEligible(tokenId), "should be eligible");

        uint256[] memory votable = registry.getSubscriptions(signer);
        assertEq(votable.length, 1, "expected one votable position");
        assertEq(votable[0], tokenId, "wrong tokenId");
    }

    // -----------
    // Adversarial: registry
    // -----------

    /// @notice The flash-liquidity mass-prune attack, against the real PoolManager. An attacker
    ///         inside their own `unlock` callback, where they could add and remove any amount of
    ///         liquidity and move price freely before settling, calls `pruneSubscription` on a
    ///         subscribed position. The registry must refuse before reading anything.
    function test_pruneSubscription_refusedInsideUnlock() public {
        uint256 tokenId = _createSeedSubscribe();

        FlashPruneAttacker attacker = new FlashPruneAttacker(
            IPoolManager(StateView(_stateView()).poolManager()), IPositionRegistry(address(registry))
        );
        attacker.attack(tokenId);

        assertFalse(attacker.pruneSucceeded(), "prune must not succeed inside unlock");
        assertEq(
            bytes4(attacker.lastRevert()),
            IPositionRegistry.PoolManagerUnlocked.selector,
            "refused with PoolManagerUnlocked"
        );
        assertTrue(registry.isTokenSubscribed(tokenId), "subscription intact");
    }

    /// @notice Outside an unlock, a healthy position in an allowlisted pool cannot be pruned by
    ///         anyone, whatever the pool's aggregate liquidity or price is doing.
    function test_pruneSubscription_healthyPositionNotPrunableByThirdParty() public {
        uint256 tokenId = _createSeedSubscribe();

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, tokenId));
        vm.prank(makeAddr("thirdParty"));
        registry.pruneSubscription(tokenId);
    }

    /// @notice A position in a pool TELx has not allowlisted cannot subscribe, however real and
    ///         well-funded that pool is. This is what stops a private pool of attacker-issued tokens
    ///         from filling the global subscriber cap for the cost of gas.
    function test_subscribe_refusedForUnlistedPool() public {
        uint256 tokenId = seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(signer));

        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        vm.prank(admin);
        registry.deregisterPool(TELxPools.poolKey(s).toId());

        vm.expectRevert();
        vm.prank(signer);
        IPositionManager(_positionManager()).subscribe(tokenId, address(subscriber), "");
    }

    // -----------
    // Helpers
    // -----------

    function _params(uint16 widthBps) internal view returns (TELxPoolScriptBase.PoolParams memory) {
        return seedScript.explicitParams(amount0Human, amount1Human, widthBps);
    }

    function _opts(address recipient) internal view returns (SeedV4Liquidity.SeedOptions memory) {
        return SeedV4Liquidity.SeedOptions({signer: signer, recipient: recipient, allowExistingRange: false});
    }

    function _intendedSqrtPrice(TELxPools.PoolSpec memory s) internal view returns (uint160) {
        return V4PoolMath.sqrtPriceX96FromAmounts(
            V4PoolMath.toRawAmount(amount0Human, s.decimals0), V4PoolMath.toRawAmount(amount1Human, s.decimals1)
        );
    }

    function _createSeedSubscribe() internal returns (uint256 tokenId) {
        tokenId = seedScript.createAndSeedWithOptions(poolName, _params(BAND), _opts(signer));
        vm.prank(signer);
        IPositionManager(_positionManager()).subscribe(tokenId, address(subscriber), "");
        assertTrue(registry.isTokenSubscribed(tokenId), "precondition: subscribed");
    }

    /// @dev Moves the empty pool's price by `ticks` from `from`, the way anyone can before the
    ///      first mint.
    function _movePriceByTicks(uint160 from, int24 ticks) internal {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        int24 target = TickMath.getTickAtSqrtPrice(from) + ticks;
        mover.moveTo(TELxPools.poolKey(s), TickMath.getSqrtPriceAtTick(target));
    }

    /// @dev The approvals the script would make for this plan, so a test can send the script's
    ///      exact mint calldata itself.
    function _approveForMint(TELxPools.PoolSpec memory s, SeedV4Liquidity.SeedPlan memory p) internal {
        TELxPoolScriptBase.ChainConfig memory config = seedScript.chainConfig();
        uint48 expiration = uint48(block.timestamp + 30 minutes);
        vm.startPrank(signer);
        if (!TELxPools.isNativeCurrency0(s)) {
            IERC20(s.currency0).approve(config.permit2, p.amount0Max);
            IAllowanceTransfer(config.permit2)
                .approve(s.currency0, config.positionManager, uint160(p.amount0Max), expiration);
        }
        IERC20(s.currency1).approve(config.permit2, p.amount1Max);
        IAllowanceTransfer(config.permit2)
            .approve(s.currency1, config.positionManager, uint160(p.amount1Max), expiration);
        vm.stopPrank();
    }

    function _assertSeed(uint16 widthBps) internal {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        SeedV4Liquidity.SeedPlan memory p = seedScript.buildPlan(poolName, _params(widthBps), false);

        uint256 before0 = _balance(s.currency0, signer);
        uint256 before1 = _balance(s.currency1, signer);
        uint256 held0 = _balance(s.currency0, _positionManager());
        uint256 held1 = _balance(s.currency1, _positionManager());

        uint256 tokenId = seedScript.runWithOptions(poolName, _params(widthBps), _opts(signer));

        assertEq(IPositionManager(_positionManager()).getPositionLiquidity(tokenId), p.liquidity, "liquidity");
        assertEq(IERC721(_positionManager()).ownerOf(tokenId), signer, "position owner");
        _assertRangeMatchesMath(tokenId, p.sqrtPriceX96, widthBps, s.tickSpacing);

        // The plan's cost is what moves, to the wei, and it never exceeds the budget. On an ERC-20
        // leg Permit2 pulls exactly the cost. On the native leg the call value is the maximum and
        // SWEEP returns the margin, but under vm.startBroadcast in a test the returned value is
        // not credited back to the signer the way it is in a real broadcast, so that leg is only
        // bounded: never below the cost, never above the maximum. That the margin left the
        // PositionManager is asserted separately below.
        uint256 spent0 = before0 - _balance(s.currency0, signer);
        if (TELxPools.isNativeCurrency0(s)) {
            assertGe(spent0, p.amount0Cost, "native spent below the planned cost");
            assertLe(spent0, p.amount0Max, "native spent above the on-chain maximum");
        } else {
            assertEq(spent0, p.amount0Cost, "currency0 spent should equal the planned cost");
        }
        assertEq(
            before1 - _balance(s.currency1, signer), p.amount1Cost, "currency1 spent should equal the planned cost"
        );
        assertLe(p.amount0Cost, V4PoolMath.toRawAmount(amount0Human, s.decimals0), "cost exceeds the currency0 budget");
        assertLe(p.amount1Cost, V4PoolMath.toRawAmount(amount1Human, s.decimals1), "cost exceeds the currency1 budget");

        // The native leg sends the on-chain maximum as call value and SWEEP returns the margin in
        // the same transaction. The property that proves SWEEP ran is that the PositionManager
        // holds no more of either currency than it did before.
        assertEq(_balance(s.currency0, _positionManager()), held0, "currency0 stranded in the PositionManager");
        assertEq(_balance(s.currency1, _positionManager()), held1, "currency1 stranded in the PositionManager");

        // No standing ERC-20 allowance to Permit2 survives the run: the slippage margin that was
        // approved but not pulled is revoked in the same broadcast.
        address permit2 = seedScript.chainConfig().permit2;
        if (!TELxPools.isNativeCurrency0(s)) {
            assertEq(IERC20(s.currency0).allowance(signer, permit2), 0, "currency0 allowance to Permit2 left standing");
        }
        assertEq(IERC20(s.currency1).allowance(signer, permit2), 0, "currency1 allowance to Permit2 left standing");
    }

    /// @dev The minted range must be exactly what `V4PoolMath` says for this price and width.
    function _assertRangeMatchesMath(uint256 tokenId, uint160 sqrtPriceX96, uint16 widthBps, int24 spacing)
        internal
        view
    {
        (int24 expectedLower, int24 expectedUpper) = widthBps == FULL
            ? V4PoolMath.fullRangeTicks(spacing)
            : V4PoolMath.percentRangeTicks(sqrtPriceX96, widthBps, spacing);
        (,, int24 lower, int24 upper) = registry.getPosition(tokenId);
        assertEq(lower, expectedLower, "tickLower");
        assertEq(upper, expectedUpper, "tickUpper");
    }

    function _balance(address currency, address who) internal view returns (uint256) {
        return currency == TELxPools.NATIVE ? who.balance : IERC20(currency).balanceOf(who);
    }

    function _positionSpan(uint256 tokenId) internal view returns (uint256) {
        (,, int24 lower, int24 upper) = registry.getPosition(tokenId);
        return uint256(int256(upper) - int256(lower));
    }

    function _foreignPoolName() internal view virtual returns (string memory);
}

/// @title PolygonTELxPoolLifecycleForkTest
/// @notice Runs the lifecycle against Polygon's eUSD/TEL pool, the ERC-20 on both sides case.
contract PolygonTELxPoolLifecycleForkTest is TELxPoolLifecycleForkTest {
    function setUp() public {
        rpcEnvVar = "POLYGON_RPC_URL";
        poolName = "POLYGON_EUSD_TEL";
        amount0Human = 100_000; // eUSD
        amount1Human = 20_000_000; // TEL v3
        _setUpChain();
    }

    function _positionManager() internal pure override returns (address) {
        return 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;
    }

    function _stateView() internal pure override returns (address) {
        return 0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a;
    }

    function _foreignPoolName() internal pure override returns (string memory) {
        return "BASE_EUSD_TEL";
    }
}

/// @title BaseTELxPoolLifecycleForkTest
/// @notice Runs the lifecycle against Base's ETH/TEL pool, exercising the native-currency0 branch:
///         no Permit2 on the ETH leg, value sent with the call, and a SWEEP to return the margin.
contract BaseTELxPoolLifecycleForkTest is TELxPoolLifecycleForkTest {
    function setUp() public {
        rpcEnvVar = "BASE_RPC_URL";
        poolName = "BASE_ETH_TEL";
        amount0Human = 10; // ETH
        amount1Human = 5_660_380; // TEL v3
        _setUpChain();
    }

    function _positionManager() internal pure override returns (address) {
        return 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    }

    function _stateView() internal pure override returns (address) {
        return 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    }

    function _foreignPoolName() internal pure override returns (string memory) {
        return "POLYGON_EUSD_TEL";
    }
}

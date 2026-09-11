// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreateV4Pool} from "../../script/telx/CreateV4Pool.s.sol";
import {SeedV4Liquidity} from "../../script/telx/SeedV4Liquidity.s.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {V4PoolMath} from "../../script/shared/V4PoolMath.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";

/// @title TELxPoolLifecycleForkTest
/// @notice End-to-end coverage of the TELx pool scripts against live Uniswap v4 deployments:
///         create a pool at a derived price, seed it full range and concentrated, then subscribe
///         the resulting position to a freshly deployed thin PositionRegistry.
/// @dev    The whole point of the suite is that these three steps are the migration, and each one
///         has a failure mode the others hide. Creating at the wrong price is invisible until
///         someone arbitrages it; seeding with mismatched tick and sqrt-price bounds is invisible
///         until the deposited amounts are compared to the authorized ones; and a hookless pool not
///         being subscribable is invisible until an LP tries.
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
    SeedV4Liquidity internal seedScript;

    PositionRegistry internal registry;
    TELxSubscriber internal subscriber;

    address internal signer = makeAddr("deployer");
    address internal admin = makeAddr("admin");
    address internal support = makeAddr("support");

    /// @dev Set by each concrete chain suite before `_setUpChain` runs.
    string internal rpcEnvVar;
    string internal poolName;
    uint256 internal amount0Human;
    uint256 internal amount1Human;

    function _setUpChain() internal {
        string memory rpc = vm.envOr(rpcEnvVar, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        createScript = new CreateV4Pool();
        seedScript = new SeedV4Liquidity();

        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);

        registry = new PositionRegistry(
            IPositionManager(_positionManager()), StateView(_stateView()), admin
        );
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), _positionManager(), support);

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();

        _fund(s);
    }

    /// @dev Grants the signer the tokens the seed will spend. Native ETH is dealt directly;
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
    // Create
    // -----------

    /// @notice A pool that does not exist yet is created at exactly the price implied by the
    ///         amounts, and the chain agrees with the tick we expected.
    function test_createPool_opensAtThePriceImpliedByAmounts() public {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);
        PoolKey memory key = TELxPools.poolKey(s);

        uint160 expected = V4PoolMath.sqrtPriceX96FromAmounts(
            V4PoolMath.toRawAmount(amount0Human, s.decimals0), V4PoolMath.toRawAmount(amount1Human, s.decimals1)
        );

        (PoolId poolId, uint160 sqrtPriceX96) =
            createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        (uint160 live,,,) = StateView(_stateView()).getSlot0(poolId);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()), "poolId");
        assertEq(sqrtPriceX96, expected, "returned price");
        assertEq(live, expected, "live price");
        assertEq(
            TickMath.getTickAtSqrtPrice(live), TickMath.getTickAtSqrtPrice(expected), "tick"
        );
    }

    /// @notice Rerunning creation is a no-op that reports the live price rather than reverting or
    ///         re-pricing. `PoolInitializer_v4.initializePool` returns type(int24).max instead of
    ///         reverting, which is exactly why the script uses it over `PoolManager.initialize`.
    function test_createPool_isIdempotent() public {
        (, uint160 first) = createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);

        // second run at a deliberately different price must not move the pool
        (, uint160 second) = createScript.runWithSigner(poolName, amount0Human * 2, amount1Human, signer);

        assertEq(second, first, "rerun must report the existing price, not a new one");
    }

    /// @notice Naming a pool that belongs to another chain must fail on the name, which is the
    ///         guard against a mismatched --rpc-url when running seven deploys in a row.
    function test_createPool_rejectsWrongChainPool() public {
        string memory foreign = _foreignPoolName();
        vm.expectRevert();
        createScript.runWithSigner(foreign, amount0Human, amount1Human, signer);
    }

    // -----------
    // Seed
    // -----------

    /// @notice Full-range seeding mints a real position and never pulls more than authorized.
    function test_seed_fullRange() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _assertSeed(0);
    }

    /// @notice The concentrated shape the proposal names as the primary one.
    function test_seed_concentratedBand() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        _assertSeed(1000); // +/-10%
    }

    /// @notice A concentrated position must span strictly fewer ticks than the full range, which is
    ///         the property that makes it capital efficient in the first place.
    function test_seed_concentratedIsNarrowerThanFullRange() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);

        uint256 fullId = seedScript.runWithSigner(poolName, amount0Human, amount1Human, 0, signer);
        uint256 bandId = seedScript.runWithSigner(poolName, amount0Human, amount1Human, 1000, signer);

        (, uint256 fullInfo) = _positionTicks(fullId);
        (, uint256 bandInfo) = _positionTicks(bandId);
        assertGt(fullInfo, bandInfo, "full range should span more ticks than a +/-10% band");
        assertGt(uint256(s.decimals1), 0, "sanity");
    }

    /// @notice Seeding a pool that was never created must fail loudly rather than mint into a
    ///         zero-priced pool.
    function test_seed_revertsWhenPoolNotInitialized() public {
        vm.expectRevert();
        seedScript.runWithSigner(poolName, amount0Human, amount1Human, 0, signer);
    }

    // -----------
    // Subscribe
    // -----------

    /// @notice The migration's actual acceptance criterion: a position in a hookless TELx pool can
    ///         be subscribed through the v4 native subscriber flow and shows up as votable in the
    ///         thin registry. This is what the old hook-gated registry could not do.
    function test_seededPositionIsSubscribable() public {
        createScript.runWithSigner(poolName, amount0Human, amount1Human, signer);
        uint256 tokenId = seedScript.runWithSigner(poolName, amount0Human, amount1Human, 1000, signer);

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
    // Helpers
    // -----------

    function _assertSeed(uint16 widthBps) internal {
        TELxPools.PoolSpec memory s = TELxPools.spec(poolName);

        uint256 before0 = _balance(s.currency0, signer);
        uint256 before1 = _balance(s.currency1, signer);

        uint256 tokenId = seedScript.runWithSigner(poolName, amount0Human, amount1Human, widthBps, signer);

        assertGt(IPositionManager(_positionManager()).getPositionLiquidity(tokenId), 0, "no liquidity minted");
        assertEq(IERC721(_positionManager()).ownerOf(tokenId), signer, "position owner");

        uint256 spent0 = before0 - _balance(s.currency0, signer);
        uint256 spent1 = before1 - _balance(s.currency1, signer);

        // Never spend more than the operator authorized. Native ETH also pays gas, which is not
        // charged against the signer under vm.startBroadcast in a test, so the comparison holds.
        uint256 authorized0 = V4PoolMath.toRawAmount(amount0Human, s.decimals0);
        uint256 authorized1 = V4PoolMath.toRawAmount(amount1Human, s.decimals1);
        assertLe(spent0, authorized0, "pulled more currency0 than authorized");
        assertLe(spent1, authorized1, "pulled more currency1 than authorized");

        // The native leg sends the full authorized ceiling as call value, because minting rounds
        // the owed amount up and sending the computed amount leaves `settle` a wei short. SWEEP
        // returns the remainder in the same transaction. The property that proves SWEEP ran is
        // that the PositionManager keeps nothing: without it, the difference between the ceiling
        // and the settled amount would sit there permanently. Asserted for both currencies since
        // a stranded ERC-20 would be just as wrong.
        //
        // Deliberately not asserted via the signer's balance delta: under `vm.startBroadcast` in a
        // test, native value accounting does not follow the signer the way it does in a real
        // broadcast, so that measurement would be testing Foundry rather than the script.
        assertEq(_positionManager().balance, 0, "native value stranded in the PositionManager");
        assertEq(
            IERC20(s.currency1).balanceOf(_positionManager()), 0, "currency1 stranded in the PositionManager"
        );
    }

    function _balance(address currency, address who) internal view returns (uint256) {
        return currency == TELxPools.NATIVE ? who.balance : IERC20(currency).balanceOf(who);
    }

    /// @dev Returns the position's tick span, used to compare range widths.
    function _positionTicks(uint256 tokenId) internal view returns (PoolKey memory key, uint256 span) {
        int24 tickLower;
        int24 tickUpper;
        (key,) = IPositionManager(_positionManager()).getPoolAndPositionInfo(tokenId);
        (, tickLower, tickUpper) = _decodeTicks(tokenId);
        span = uint256(int256(tickUpper) - int256(tickLower));
    }

    function _decodeTicks(uint256 tokenId) internal view returns (PoolKey memory key, int24 tickLower, int24 tickUpper) {
        (address owner, PoolId poolId, int24 lower, int24 upper) = registry.getPosition(tokenId);
        owner;
        poolId;
        tickLower = lower;
        tickUpper = upper;
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
///         no Permit2 on the ETH leg, value sent with the call, and a SWEEP to return the dust.
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

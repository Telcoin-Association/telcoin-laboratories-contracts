// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TelxTestConstants} from "./TelxTestConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PositionRegistryTest
/// @notice Deterministic, non-fork unit tests for the thin (post-V4-hook-removal) PositionRegistry.
///         The registry's only external dependencies are the Uniswap v4 PositionManager and
///         StateView; both are replaced here with `MockPositionManager` / `MockStateView` so every
///         branch - subscription lifecycle, threshold gate, prune paths, live view shims, caps -
///         is exercised without RPC. Production ABI compatibility against real v4 contracts is
///         covered separately by `PositionRegistry.polygon.t.sol`.
contract PositionRegistryTest is Test {
    PositionRegistry internal registry;
    MockPositionManager internal pm;
    MockStateView internal sv;

    address internal admin = makeAddr("admin");
    address internal support = makeAddr("support");
    address internal subscriber = makeAddr("subscriber");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    PoolKey internal poolKey;
    PoolId internal poolId;

    // Local aliases for shared TELx test fixtures (see test/telx/TelxTestConstants.sol).
    int24 internal constant TICK_SPACING = TelxTestConstants.TICK_SPACING;
    int24 internal constant TICK_LOWER = TelxTestConstants.TICK_LOWER;
    int24 internal constant TICK_UPPER = TelxTestConstants.TICK_UPPER;
    uint128 internal constant DEFAULT_LIQUIDITY = TelxTestConstants.DEFAULT_LIQUIDITY;
    uint128 internal constant POOL_LIQUIDITY = TelxTestConstants.POOL_LIQUIDITY;
    uint160 internal constant SQRT_PRICE_1_1 = TelxTestConstants.SQRT_PRICE_1_1;

    /// @dev Storage slot of the `subscribed` address[] (length lives directly in this slot).
    ///      AccessControl occupies slot 0; `subscribed` is the first variable PositionRegistry
    ///      declares. Guarded at runtime by `_forceSubscribedLength`.
    uint256 internal constant SUBSCRIBED_LENGTH_SLOT = 1;

    function setUp() public {
        pm = new MockPositionManager();
        sv = new MockStateView();
        registry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), subscriber);
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();

        poolKey = _poolKey(3000);
        poolId = poolKey.toId();
        // current tick 0 sits inside every test position's default [-600, 600) range
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 0);
        sv.setLiquidity(poolId, POOL_LIQUIDITY);
    }

    // -----------
    // Constructor
    // -----------

    function test_constructor_setsDependenciesAndAdmin() public view {
        assertEq(address(registry.positionManager()), address(pm), "positionManager");
        assertEq(address(registry.stateView()), address(sv), "stateView");
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "admin");
        assertTrue(registry.inRangeRequired(), "in-range required by default");
    }

    function test_caps() public view {
        assertEq(registry.MAX_SUBSCRIPTIONS(), 1_000, "MAX_SUBSCRIPTIONS");
        assertEq(registry.MAX_SUBSCRIBED(), 50_000, "MAX_SUBSCRIBED");
    }

    function test_roleConstants() public view {
        assertEq(registry.SUBSCRIBER_ROLE(), keccak256("SUBSCRIBER_ROLE"), "SUBSCRIBER_ROLE");
        assertEq(registry.SUPPORT_ROLE(), keccak256("SUPPORT_ROLE"), "SUPPORT_ROLE");
    }

    // -----------
    // setInRangeRequired
    // -----------

    function test_setInRangeRequired_togglesAndEmits() public {
        assertTrue(registry.inRangeRequired(), "enabled by default");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPositionRegistry.InRangeRequiredSet(false);
        vm.prank(admin);
        registry.setInRangeRequired(false);
        assertFalse(registry.inRangeRequired(), "disabled after toggle");

        vm.prank(admin);
        registry.setInRangeRequired(true);
        assertTrue(registry.inRangeRequired(), "re-enabled after toggle");
    }

    function testRevert_setInRangeRequired_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        registry.setInRangeRequired(false);
    }

    // -----------
    // handleSubscribe
    // -----------

    function test_handleSubscribe_firstSubscription() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPositionRegistry.Subscribed(1, alice);
        vm.prank(subscriber);
        registry.handleSubscribe(1);

        assertTrue(registry.isTokenSubscribed(1), "isTokenSubscribed");
        assertTrue(registry.isSubscribed(alice), "isSubscribed");
        uint256[] memory subs = registry.getSubscriptions(alice);
        assertEq(subs.length, 1, "subscriptions length");
        assertEq(subs[0], 1, "subscription tokenId");
        address[] memory all = registry.getSubscribed();
        assertEq(all.length, 1, "subscribed length");
        assertEq(all[0], alice, "subscribed owner");
    }

    function test_handleSubscribe_secondSubscriptionSameOwner() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);

        assertEq(registry.getSubscriptions(alice).length, 2, "two subscriptions");
        // the global subscribed set holds the owner exactly once
        assertEq(registry.getSubscribed().length, 1, "single subscribed entry");
    }

    function test_handleSubscribe_multipleOwners() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, bob, DEFAULT_LIQUIDITY);

        assertEq(registry.getSubscribed().length, 2, "two subscribed owners");
        assertTrue(registry.isSubscribed(alice) && registry.isSubscribed(bob), "both subscribed");
    }

    function test_handleSubscribe_smallPoolAcceptsTinyPosition() public {
        // a pool at or below 10,000 total liquidity accepts any non-zero position
        sv.setLiquidity(poolId, 5_000);
        _setPosition(1, alice, 1);

        vm.prank(subscriber);
        registry.handleSubscribe(1);
        assertTrue(registry.isTokenSubscribed(1), "tiny position subscribed in small pool");
    }

    function testRevert_handleSubscribe_onlySubscriberRole() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.SUBSCRIBER_ROLE()
            )
        );
        vm.prank(alice);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_invalidPool() public {
        // a pool whose slot0 was never set has sqrtPriceX96 == 0 -> not a valid pool
        PoolKey memory uninitialized = _poolKey(500);
        pm.setPosition(1, uninitialized, TICK_LOWER, TICK_UPPER, DEFAULT_LIQUIDITY, alice);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.InvalidPool.selector, uninitialized.toId()));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_belowThreshold() public {
        // threshold is POOL_LIQUIDITY / 10_000 = 100; a 50-liquidity position is below it
        _setPosition(1, alice, 50);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.LiquidityBelowThreshold.selector, uint128(50)));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_outOfRange() public {
        // pool tick 1000 sits above the position's [-600, 600) range
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 1000);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.OutOfRange.selector, uint256(1)));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function test_handleSubscribe_outOfRangeAllowedWhenFlagOff() public {
        // the admin disables the in-range requirement
        vm.prank(admin);
        registry.setInRangeRequired(false);

        // pool tick 1000 is outside the position's range, but the gate is off
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 1000);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleSubscribe(1);
        assertTrue(registry.isTokenSubscribed(1), "out-of-range position subscribed once the flag is off");
    }

    function testRevert_handleSubscribe_maxSubscribed() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        _forceSubscribedLength(50_000);

        vm.expectRevert(IPositionRegistry.MaxSubscribed.selector);
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    // -----------
    // handleUnsubscribe
    // -----------

    function test_handleUnsubscribe_removesSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPositionRegistry.Unsubscribed(1, alice);
        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        assertFalse(registry.isTokenSubscribed(1), "no longer token-subscribed");
        assertFalse(registry.isSubscribed(alice), "no longer subscribed");
        assertEq(registry.getSubscriptions(alice).length, 0, "subscriptions cleared");
        assertEq(registry.getSubscribed().length, 0, "subscribed set cleared");
    }

    function test_handleUnsubscribe_keepsOwnerWithRemainingSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        assertEq(registry.getSubscriptions(alice).length, 1, "one subscription remains");
        assertTrue(registry.isSubscribed(alice), "owner still subscribed");
    }

    function test_handleUnsubscribe_notSubscribedIsNoop() public {
        // a stray notification for an unsubscribed token must never revert
        vm.prank(subscriber);
        registry.handleUnsubscribe(999);
        assertFalse(registry.isTokenSubscribed(999), "still unsubscribed");
    }

    function testRevert_handleUnsubscribe_onlySubscriberRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.SUBSCRIBER_ROLE()
            )
        );
        vm.prank(alice);
        registry.handleUnsubscribe(1);
    }

    // -----------
    // handleBurn
    // -----------

    function test_handleBurn_removesSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPositionRegistry.Unsubscribed(1, alice);
        vm.prank(subscriber);
        registry.handleBurn(1, alice);

        assertFalse(registry.isTokenSubscribed(1), "subscription removed on burn");
        assertEq(registry.getSubscribed().length, 0, "subscribed set cleared");
    }

    function test_handleBurn_notSubscribedIsNoop() public {
        vm.prank(subscriber);
        registry.handleBurn(999, alice);
        assertFalse(registry.isTokenSubscribed(999), "still unsubscribed");
    }

    function testRevert_handleBurn_onlySubscriberRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.SUBSCRIBER_ROLE()
            )
        );
        vm.prank(alice);
        registry.handleBurn(1, alice);
    }

    // -----------
    // pruneSubscription
    // -----------

    function testRevert_pruneSubscription_notSubscribed() public {
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotSubscribed.selector, uint256(1)));
        registry.pruneSubscription(1);
    }

    function testRevert_pruneSubscription_healthySubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, uint256(1)));
        registry.pruneSubscription(1);
    }

    function test_pruneSubscription_transferredPosition() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // simulate a transfer: the live owner no longer matches the subscriber of record
        pm.setOwner(1, bob);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPositionRegistry.Unsubscribed(1, alice);
        registry.pruneSubscription(1);

        assertFalse(registry.isTokenSubscribed(1), "stale entry pruned");
    }

    function test_pruneSubscription_burnedPosition() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // simulate a burn: ownerOf now reverts, so the live owner resolves to address(0)
        pm.burn(1);

        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "burned entry pruned");
    }

    function test_pruneSubscription_belowThreshold() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // owner unchanged, but liquidity drained below the threshold (100)
        pm.setLiquidity(1, 50);

        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "drained entry pruned");
    }

    function test_pruneSubscription_outOfRange() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // owner and liquidity unchanged, but the pool tick drifted out of the position's range
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);

        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "out-of-range entry pruned");
    }

    function test_pruneSubscription_isPermissionless() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.setLiquidity(1, 0);

        // any address, with no role, may prune
        vm.prank(carol);
        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "pruned by arbitrary caller");
    }

    // -----------
    // _removeSubscription swap-and-pop coverage
    // -----------

    function test_removeSubscription_swapNonLastElement() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);
        _subscribe(3, alice, DEFAULT_LIQUIDITY);

        // remove index 0; the last element (tokenId 3) is swapped into its slot
        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        uint256[] memory subs = registry.getSubscriptionsRaw(alice);
        assertEq(subs.length, 2, "two remain");
        assertEq(subs[0], 3, "last swapped into slot 0");
        assertEq(subs[1], 2, "slot 1 unchanged");

        // the swapped token's index was updated: removing it must still work
        vm.prank(subscriber);
        registry.handleUnsubscribe(3);
        assertEq(registry.getSubscriptionsRaw(alice)[0], 2, "tokenId 2 remains after second removal");
    }

    function test_removeSubscription_lastElementNoSwap() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);

        // remove the last element: the swap branch is skipped
        vm.prank(subscriber);
        registry.handleUnsubscribe(2);

        uint256[] memory subs = registry.getSubscriptionsRaw(alice);
        assertEq(subs.length, 1, "one remains");
        assertEq(subs[0], 1, "first element untouched");
    }

    function test_removeSubscription_swapInGlobalSubscribedSet() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, bob, DEFAULT_LIQUIDITY);
        _subscribe(3, carol, DEFAULT_LIQUIDITY);

        // remove alice (index 0); carol is swapped into her slot in the global set
        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        address[] memory all = registry.getSubscribed();
        assertEq(all.length, 2, "two owners remain");
        assertEq(all[0], carol, "carol swapped into slot 0");
        assertEq(all[1], bob, "bob unchanged");

        // carol's subscribedIndex was updated: removing her must still work
        vm.prank(subscriber);
        registry.handleUnsubscribe(3);
        address[] memory afterCarol = registry.getSubscribed();
        assertEq(afterCarol.length, 1, "one owner remains");
        assertEq(afterCarol[0], bob, "bob remains");
    }

    // -----------
    // belowSubscriptionThreshold / _meetsSubscriptionThreshold
    // -----------

    function test_belowSubscriptionThreshold_aboveAndBelow() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY); // 10_000 >= 100
        assertFalse(registry.belowSubscriptionThreshold(1), "healthy position is above threshold");

        pm.setLiquidity(1, 50); // below 100
        assertTrue(registry.belowSubscriptionThreshold(1), "drained position is below threshold");
    }

    function test_belowSubscriptionThreshold_zeroLiquidity() public {
        _setPosition(1, alice, 0);
        assertTrue(registry.belowSubscriptionThreshold(1), "zero liquidity is below threshold");
    }

    function test_belowSubscriptionThreshold_smallPool() public {
        sv.setLiquidity(poolId, 10_000); // boundary: <= 10_000 accepts any non-zero position
        _setPosition(1, alice, 1);
        assertFalse(registry.belowSubscriptionThreshold(1), "small pool accepts any non-zero position");
    }

    // -----------
    // isInRange
    // -----------

    function test_isInRange_withinBounds() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 0); // tick 0 inside [-600, 600)
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertTrue(registry.isInRange(1), "tick within bounds is in range");
    }

    function test_isInRange_atLowerBoundIsInRange() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_LOWER); // tickLower is inclusive
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertTrue(registry.isInRange(1), "tickLower is inclusive");
    }

    function test_isInRange_atUpperBoundIsOutOfRange() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER); // tickUpper is exclusive
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertFalse(registry.isInRange(1), "tickUpper is exclusive");
    }

    function test_isInRange_belowRange() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_LOWER - 1);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertFalse(registry.isInRange(1), "tick below range is out of range");
    }

    function test_isInRange_aboveRange() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertFalse(registry.isInRange(1), "tick above range is out of range");
    }

    // -----------
    // subscriptionEligible
    // -----------

    function test_subscriptionEligible_belowThreshold() public {
        _setPosition(1, alice, 50); // below the 100 threshold
        assertFalse(registry.subscriptionEligible(1), "below threshold is ineligible");
    }

    function test_subscriptionEligible_outOfRangeWhenFlagOn() public {
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertFalse(registry.subscriptionEligible(1), "out of range is ineligible while the flag is on");
    }

    function test_subscriptionEligible_outOfRangeAllowedWhenFlagOff() public {
        vm.prank(admin);
        registry.setInRangeRequired(false);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertTrue(registry.subscriptionEligible(1), "out of range is eligible once the flag is off");
    }

    function test_subscriptionEligible_healthy() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertTrue(registry.subscriptionEligible(1), "in-range, above-threshold position is eligible");
    }

    // -----------
    // validPool
    // -----------

    function test_validPool_trueForInitializedPool() public view {
        assertTrue(registry.validPool(poolId), "initialized pool is valid");
    }

    function test_validPool_falseForUninitializedPool() public view {
        assertFalse(registry.validPool(_poolKey(500).toId()), "uninitialized pool is invalid");
    }

    // -----------
    // View shims
    // -----------

    function test_getPosition_returnsLiveData() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        (address owner, PoolId id, int24 tickLower, int24 tickUpper) = registry.getPosition(1);
        assertEq(owner, alice, "owner");
        assertEq(PoolId.unwrap(id), PoolId.unwrap(poolId), "poolId");
        assertEq(tickLower, TICK_LOWER, "tickLower");
        assertEq(tickUpper, TICK_UPPER, "tickUpper");
    }

    function test_getPosition_burnedReturnsZeroOwner() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        pm.burn(1);
        (address owner,,,) = registry.getPosition(1);
        assertEq(owner, address(0), "burned position resolves owner to zero");
    }

    function test_getPositionDetails_returnsLiveData() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(1);
        assertEq(d.owner, alice, "owner");
        assertEq(PoolId.unwrap(d.poolId), PoolId.unwrap(poolId), "poolId");
        assertEq(d.tickLower, TICK_LOWER, "tickLower");
        assertEq(d.tickUpper, TICK_UPPER, "tickUpper");
        assertEq(d.liquidity, DEFAULT_LIQUIDITY, "liquidity");
        assertEq(Currency.unwrap(d.poolKey.currency0), Currency.unwrap(poolKey.currency0), "poolKey currency0");
    }

    function test_getPositionDetails_unregisteredReturnsZeros() public view {
        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(999_999);
        assertEq(d.owner, address(0), "unregistered owner is zero");
        assertEq(d.liquidity, 0, "unregistered liquidity is zero");
    }

    function test_getLiquidityLast_returnsLiveLiquidity() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertEq(registry.getLiquidityLast(1), DEFAULT_LIQUIDITY, "live liquidity");
    }

    function test_getLiquidityLast_unregisteredIsZero() public view {
        assertEq(registry.getLiquidityLast(999_999), 0, "unregistered liquidity is zero");
    }

    function test_getSubscriptions_emptyForUnknownOwner() public view {
        assertEq(registry.getSubscriptions(address(0xdead)).length, 0, "empty");
    }

    function test_getSubscriptions_filtersIneligibleAndForeignPositions() public {
        // three positions subscribed under alice
        _subscribe(1, alice, DEFAULT_LIQUIDITY); // stays healthy
        _subscribe(2, alice, DEFAULT_LIQUIDITY); // drained below threshold
        _subscribe(3, alice, DEFAULT_LIQUIDITY); // transferred away

        pm.setLiquidity(2, 50); // below the 100 threshold -> ineligible
        pm.setOwner(3, bob); // no longer owned by alice

        // the raw set still holds every stored entry
        assertEq(registry.getSubscriptionsRaw(alice).length, 3, "raw set holds all three");

        // getSubscriptions returns only the still-owned, still-eligible position
        uint256[] memory votable = registry.getSubscriptions(alice);
        assertEq(votable.length, 1, "only one votable position");
        assertEq(votable[0], 1, "the healthy position is votable");
    }

    function test_getSubscribed_emptyOnFreshRegistry() public view {
        assertEq(registry.getSubscribed().length, 0, "empty");
    }

    function test_getAmountsForLiquidity_returnsPriceAndAmounts() public view {
        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) =
            registry.getAmountsForLiquidity(poolId, DEFAULT_LIQUIDITY, TICK_LOWER, TICK_UPPER);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "sqrtPriceX96 read from state");
        // a non-zero-width range straddling spot requires both currencies
        assertGt(amount0, 0, "amount0");
        assertGt(amount1, 0, "amount1");
    }

    // -----------
    // erc20Rescue
    // -----------

    function test_erc20Rescue_transfersTokens() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1_000e18);

        vm.prank(support);
        registry.erc20Rescue(IERC20(address(token)), bob, 400e18);

        assertEq(token.balanceOf(bob), 400e18, "destination balance");
        assertEq(token.balanceOf(address(registry)), 600e18, "registry balance");
    }

    function testRevert_erc20Rescue_onlySupportRole() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.SUPPORT_ROLE()
            )
        );
        vm.prank(alice);
        registry.erc20Rescue(IERC20(address(token)), alice, 1e18);
    }

    // -----------
    // MAX_SUBSCRIPTIONS cap + query gas check
    // -----------

    /// @notice Fills one LP to `MAX_SUBSCRIPTIONS` (1,000) and confirms the registry's linear-in-N
    ///         reads still resolve. The migration raised the cap from 100 to 1,000; this is the gas
    ///         check requested for that decision. `getSubscriptionsRaw` is the plain stored read;
    ///         `getSubscriptions` additionally filters every entry for eligibility. Subscribe and
    ///         unsubscribe stay O(1). Both reads are consumed off-chain via `eth_call`, which has
    ///         no practical gas limit, and a real voter holds only a handful of positions.
    function test_maxSubscriptions_capAndQueryGas() public {
        uint256 cap = registry.MAX_SUBSCRIPTIONS();
        for (uint256 i = 1; i <= cap; ++i) {
            _setPosition(i, alice, DEFAULT_LIQUIDITY);
            vm.prank(subscriber);
            registry.handleSubscribe(i);
        }

        uint256 gasBefore = gasleft();
        uint256[] memory raw = registry.getSubscriptionsRaw(alice);
        uint256 rawGas = gasBefore - gasleft();
        assertEq(raw.length, cap, "owner filled to the cap");
        emit log_named_uint("getSubscriptionsRaw() gas at 1,000 entries", rawGas);

        gasBefore = gasleft();
        uint256[] memory votable = registry.getSubscriptions(alice);
        uint256 votableGas = gasBefore - gasleft();
        assertEq(votable.length, cap, "all 1,000 positions votable");
        emit log_named_uint("getSubscriptions() filtered gas at 1,000 entries", votableGas);

        // a removal is O(1) regardless of how full the array is
        gasBefore = gasleft();
        vm.prank(subscriber);
        registry.handleUnsubscribe(500);
        uint256 unsubscribeGas = gasBefore - gasleft();
        emit log_named_uint("handleUnsubscribe() gas at 1,000 entries", unsubscribeGas);

        // refill the freed slot, then confirm the cap rejects the next subscription
        _setPosition(cap + 1, alice, DEFAULT_LIQUIDITY);
        vm.prank(subscriber);
        registry.handleSubscribe(cap + 1);
        assertEq(registry.getSubscriptionsRaw(alice).length, cap, "back at the cap");

        _setPosition(cap + 2, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(IPositionRegistry.MaxSubscriptions.selector);
        vm.prank(subscriber);
        registry.handleSubscribe(cap + 2);
    }

    // -----------
    // Helpers
    // -----------

    function _poolKey(uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xA11CE0)),
            currency1: Currency.wrap(address(0xB0B0B0)),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _setPosition(uint256 tokenId, address owner, uint128 liquidity) internal {
        pm.setPosition(tokenId, poolKey, TICK_LOWER, TICK_UPPER, liquidity, owner);
    }

    function _subscribe(uint256 tokenId, address owner, uint128 liquidity) internal {
        _setPosition(tokenId, owner, liquidity);
        vm.prank(subscriber);
        registry.handleSubscribe(tokenId);
    }

    /// @dev Forces `subscribed.length` via vm.store so the MAX_SUBSCRIBED guard can be hit without
    ///      50,000 distinct signers. Verifies the slot first: a layout change makes this fail
    ///      loudly instead of silently corrupting unrelated storage.
    function _forceSubscribedLength(uint256 length) internal {
        bytes32 slot = bytes32(SUBSCRIBED_LENGTH_SLOT);
        vm.store(address(registry), slot, bytes32(uint256(3)));
        require(
            registry.getSubscribed().length == 3,
            "storage layout drift: `subscribed` not at SUBSCRIBED_LENGTH_SLOT; re-run forge inspect"
        );
        vm.store(address(registry), slot, bytes32(length));
    }
}

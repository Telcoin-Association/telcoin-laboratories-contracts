// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
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
/// @notice Deterministic, non-fork unit tests for the thin PositionRegistry.
///         The registry's external dependencies - the Uniswap v4 PositionManager, StateView and
///         the PoolManager lock slot - are replaced with `MockPositionManager`, `MockStateView`
///         and `MockPoolManager` so every branch is exercised without RPC: subscription lifecycle,
///         the pool allowlist, the absolute minimum-liquidity gate, position-local prune, the
///         unlock guard, admin eviction, pagination, live view shims and both caps. Production
///         ABI compatibility against real v4 contracts is covered by `PositionRegistry.polygon.t.sol`.
///
///         The adversarial cases are the point: each one models a concrete attack against the
///         previous design (flash-liquidity mass prune, gas-only cap fill via a private pool,
///         duplicate subscribe) and asserts the hardened registry refuses it.
contract PositionRegistryTest is Test {
    PositionRegistry internal registry;
    MockPositionManager internal pm;
    MockStateView internal sv;
    MockPoolManager internal poolManager;

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
        poolManager = new MockPoolManager();
        pm = new MockPositionManager();
        sv = new MockStateView(address(poolManager));
        registry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);

        poolKey = _poolKey(3000);
        poolId = poolKey.toId();

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), subscriber);
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        registry.registerPool(poolKey);
        vm.stopPrank();

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
        assertEq(address(registry.poolManager()), address(poolManager), "poolManager read from stateView");
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
    // Pool allowlist
    // -----------

    function test_registerPool_allowsAndEmits() public {
        PoolKey memory other = _poolKey(500);
        PoolId otherId = other.toId();
        assertFalse(registry.poolAllowed(otherId), "not allowed before");

        vm.expectEmit(true, false, false, true);
        emit IPositionRegistry.PoolRegistered(otherId, other);
        vm.prank(admin);
        registry.registerPool(other);

        assertTrue(registry.poolAllowed(otherId), "allowed after");
    }

    function testRevert_registerPool_twice() public {
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.AlreadyRegistered.selector, poolId));
        vm.prank(admin);
        registry.registerPool(poolKey);
    }

    function testRevert_registerPool_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        registry.registerPool(_poolKey(500));
    }

    function test_deregisterPool_disallowsAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit IPositionRegistry.PoolDeregistered(poolId);
        vm.prank(admin);
        registry.deregisterPool(poolId);

        assertFalse(registry.poolAllowed(poolId), "disallowed");
    }

    function testRevert_deregisterPool_notAllowed() public {
        PoolId otherId = _poolKey(500).toId();
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.PoolNotAllowed.selector, otherId));
        vm.prank(admin);
        registry.deregisterPool(otherId);
    }

    /// @notice Deregistering a pool does not evict its subscriptions, but it does stop them voting:
    ///         eligibility is read live and the allowlist is its first leg.
    function test_deregisterPool_existingSubscriptionsStopBeingEligible() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        assertEq(registry.getSubscriptions(alice).length, 1, "votable before");

        vm.prank(admin);
        registry.deregisterPool(poolId);

        assertTrue(registry.isTokenSubscribed(1), "still indexed");
        assertEq(registry.getSubscriptions(alice).length, 0, "no longer votable");
        assertFalse(registry.subscriptionEligible(1), "ineligible");
    }

    // -----------
    // Minimum liquidity
    // -----------

    function test_setMinLiquidity_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit IPositionRegistry.MinLiquiditySet(poolId, 500);
        vm.prank(admin);
        registry.setMinLiquidity(poolId, 500);
        assertEq(registry.minLiquidity(poolId), 500, "min set");
    }

    function testRevert_setMinLiquidity_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        registry.setMinLiquidity(poolId, 500);
    }

    /// @notice The minimum is absolute, so a third party changing the pool's aggregate liquidity
    ///         cannot move a position across it. The pool total is set to something absurd and
    ///         the position's eligibility does not change.
    function test_minLiquidity_isAbsoluteNotRelative() public {
        vm.prank(admin);
        registry.setMinLiquidity(poolId, 100);
        _setPosition(1, alice, 100);
        assertFalse(registry.belowSubscriptionThreshold(1), "at the minimum");

        sv.setLiquidity(poolId, type(uint128).max);
        assertFalse(registry.belowSubscriptionThreshold(1), "pool total is irrelevant");

        pm.setLiquidity(1, 99);
        assertTrue(registry.belowSubscriptionThreshold(1), "below the minimum");
    }

    // -----------
    // In-range flag
    // -----------

    function test_setInRangeRequired_togglesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit IPositionRegistry.InRangeRequiredSet(false);
        vm.prank(admin);
        registry.setInRangeRequired(false);
        assertFalse(registry.inRangeRequired(), "disabled");

        vm.prank(admin);
        registry.setInRangeRequired(true);
        assertTrue(registry.inRangeRequired(), "re-enabled");
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

        vm.expectEmit(true, true, false, false);
        emit IPositionRegistry.Subscribed(1, alice);
        vm.prank(subscriber);
        registry.handleSubscribe(1);

        assertTrue(registry.isTokenSubscribed(1), "token subscribed");
        assertTrue(registry.isSubscribed(alice), "owner subscribed");
        assertEq(registry.getSubscriptionsRaw(alice).length, 1, "one subscription");
        assertEq(registry.getSubscribed().length, 1, "one owner in global set");
    }

    function test_handleSubscribe_secondSubscriptionSameOwner() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);
        assertEq(registry.getSubscriptionsRaw(alice).length, 2, "two subscriptions");
        assertEq(registry.getSubscribed().length, 1, "still one owner");
    }

    function test_handleSubscribe_multipleOwners() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, bob, DEFAULT_LIQUIDITY);
        assertEq(registry.getSubscribed().length, 2, "two owners");
    }

    /// @notice With no minimum set, any non-zero position qualifies regardless of pool size. The
    ///         old relative gate would have rejected a dust position in a deep pool.
    function test_handleSubscribe_dustAcceptedWithNoMinimum() public {
        sv.setLiquidity(poolId, type(uint128).max);
        _subscribe(1, alice, 1);
        assertTrue(registry.isTokenSubscribed(1), "dust subscribed");
    }

    /// @notice A repeated notification for an indexed token is a no-op. The failure it prevents is a
    ///         duplicate array entry that would vote twice, hold a cap slot forever and desync the
    ///         swap-and-pop index.
    function test_handleSubscribe_repeatIsNoop() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleSubscribe(1);

        assertEq(registry.getSubscriptionsRaw(alice).length, 1, "no duplicate entry");
        assertEq(registry.getSubscribed().length, 1, "no duplicate owner");
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

    /// @notice A pool that is initialized but not on the allowlist is refused. This is the guard
    ///         against a gas-only cap fill through a private pool of attacker-issued tokens.
    function testRevert_handleSubscribe_poolNotAllowed() public {
        PoolKey memory privatePool = _poolKey(500);
        PoolId privateId = privatePool.toId();
        sv.setSlot0(privateId, SQRT_PRICE_1_1, 0);
        pm.setPosition(1, privatePool, TICK_LOWER, TICK_UPPER, DEFAULT_LIQUIDITY, alice);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.PoolNotAllowed.selector, privateId));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_poolNotInitialized() public {
        PoolKey memory fresh = _poolKey(500);
        PoolId freshId = fresh.toId();
        vm.prank(admin);
        registry.registerPool(fresh);
        pm.setPosition(1, fresh, TICK_LOWER, TICK_UPPER, DEFAULT_LIQUIDITY, alice);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.PoolNotInitialized.selector, freshId));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_zeroLiquidity() public {
        _setPosition(1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.LiquidityBelowThreshold.selector, uint128(0)));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_belowMinimum() public {
        vm.prank(admin);
        registry.setMinLiquidity(poolId, 1_000);
        _setPosition(1, alice, 999);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.LiquidityBelowThreshold.selector, uint128(999)));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_handleSubscribe_outOfRange() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.OutOfRange.selector, uint256(1)));
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function test_handleSubscribe_outOfRangeAllowedWhenFlagOff() public {
        vm.prank(admin);
        registry.setInRangeRequired(false);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER);

        vm.prank(subscriber);
        registry.handleSubscribe(1);
        assertTrue(registry.isTokenSubscribed(1), "subscribed while out of range");
    }

    function testRevert_handleSubscribe_maxSubscribed() public {
        _forceSubscribedLength(50_000);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(IPositionRegistry.MaxSubscribed.selector);
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    /// @notice An owner who is already in the global set is not blocked by the cap; only a new
    ///         owner's first subscription is.
    function test_handleSubscribe_existingOwnerBypassesGlobalCap() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _forceSubscribedLength(50_000);
        _setPosition(2, alice, DEFAULT_LIQUIDITY);
        vm.prank(subscriber);
        registry.handleSubscribe(2);
        assertEq(registry.getSubscriptionsRaw(alice).length, 2, "existing owner may add");
    }

    // -----------
    // Unlock guard
    // -----------

    /// @notice Inside a `PoolManager.unlock` the caller controls all pool state, so every
    ///         state-changing path that judges a position refuses to run there. This is the
    ///         structural defense against flash-liquidity and flash-price manipulation.
    function testRevert_handleSubscribe_whilePoolManagerUnlocked() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        poolManager.setUnlocked(true);
        vm.expectRevert(IPositionRegistry.PoolManagerUnlocked.selector);
        vm.prank(subscriber);
        registry.handleSubscribe(1);
    }

    function testRevert_pruneSubscription_whilePoolManagerUnlocked() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.setLiquidity(1, 0); // genuinely prunable, so only the guard can be what rejects it
        poolManager.setUnlocked(true);
        vm.expectRevert(IPositionRegistry.PoolManagerUnlocked.selector);
        registry.pruneSubscription(1);
    }

    /// @notice The notification paths v4 fires from inside its own unlock (burn, and transfer's
    ///         unsubscribe) must keep working there; they are role-gated to the subscriber and read
    ///         no pool state, so the guard is deliberately absent.
    function test_handleUnsubscribeAndBurn_workWhilePoolManagerUnlocked() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);
        poolManager.setUnlocked(true);

        vm.prank(subscriber);
        registry.handleUnsubscribe(1);
        vm.prank(subscriber);
        registry.handleBurn(2, alice);

        assertFalse(registry.isTokenSubscribed(1), "unsubscribed inside unlock");
        assertFalse(registry.isTokenSubscribed(2), "burned inside unlock");
    }

    // -----------
    // handleUnsubscribe
    // -----------

    function test_handleUnsubscribe_removesSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.expectEmit(true, true, false, false);
        emit IPositionRegistry.Unsubscribed(1, alice);
        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        assertFalse(registry.isTokenSubscribed(1), "token unsubscribed");
        assertFalse(registry.isSubscribed(alice), "owner removed from global set");
        assertEq(registry.getSubscribed().length, 0, "global set empty");
    }

    function test_handleUnsubscribe_keepsOwnerWithRemainingSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        assertTrue(registry.isSubscribed(alice), "owner still subscribed");
        assertEq(registry.getSubscriptionsRaw(alice).length, 1, "one remaining");
    }

    function test_handleUnsubscribe_notSubscribedIsNoop() public {
        vm.prank(subscriber);
        registry.handleUnsubscribe(99);
        assertFalse(registry.isTokenSubscribed(99), "still not subscribed");
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

        vm.expectEmit(true, true, false, false);
        emit IPositionRegistry.Unsubscribed(1, alice);
        vm.prank(subscriber);
        registry.handleBurn(1, alice);

        assertFalse(registry.isTokenSubscribed(1), "removed on burn");
    }

    function test_handleBurn_notSubscribedIsNoop() public {
        vm.prank(subscriber);
        registry.handleBurn(99, alice);
        assertFalse(registry.isTokenSubscribed(99), "still not subscribed");
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
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotSubscribed.selector, uint256(99)));
        registry.pruneSubscription(99);
    }

    function testRevert_pruneSubscription_healthySubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, uint256(1)));
        registry.pruneSubscription(1);
    }

    function test_pruneSubscription_transferredPosition() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.setOwner(1, bob);

        vm.expectEmit(true, true, false, false);
        emit IPositionRegistry.Unsubscribed(1, alice);
        registry.pruneSubscription(1);

        assertFalse(registry.isTokenSubscribed(1), "pruned after transfer");
        assertFalse(registry.isSubscribed(alice), "alice removed from global set");
    }

    function test_pruneSubscription_burnedPosition() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.burn(1);
        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "pruned after burn");
    }

    function test_pruneSubscription_drainedPosition() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.setLiquidity(1, 0);
        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "pruned after drain");
    }

    /// @notice The flash-liquidity attack, minus the flash. A third party inflates the pool's
    ///         aggregate liquidity so that a healthy position becomes a vanishing fraction of it;
    ///         under the old relative gate that alone made the position prunable. Now the pool
    ///         total is not a prune input at all, so the position stays.
    function testRevert_pruneSubscription_poolLiquidityIsNotAPruneInput() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        sv.setLiquidity(poolId, type(uint128).max);

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, uint256(1)));
        registry.pruneSubscription(1);
        assertTrue(registry.isTokenSubscribed(1), "healthy position survives a whale");
    }

    /// @notice Price is not a prune input either. A position pushed out of range stops voting
    ///         (the live filter sees it) but keeps its slot, so a price move cannot evict anyone.
    function testRevert_pruneSubscription_priceIsNotAPruneInput() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);

        assertEq(registry.getSubscriptions(alice).length, 0, "out of range does not vote");
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, uint256(1)));
        registry.pruneSubscription(1);
        assertTrue(registry.isTokenSubscribed(1), "but keeps its slot");
    }

    /// @notice A position that dips below an admin-set minimum is ineligible but not prunable:
    ///         the minimum is a voting gate, and only zero liquidity frees a slot.
    function testRevert_pruneSubscription_belowMinimumIsNotPrunable() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        vm.prank(admin);
        registry.setMinLiquidity(poolId, DEFAULT_LIQUIDITY + 1);

        assertFalse(registry.subscriptionEligible(1), "below minimum is ineligible");
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.NotPrunable.selector, uint256(1)));
        registry.pruneSubscription(1);
    }

    function test_pruneSubscription_isPermissionless() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        pm.setLiquidity(1, 0);
        vm.prank(carol);
        registry.pruneSubscription(1);
        assertFalse(registry.isTokenSubscribed(1), "anyone may prune a drained position");
    }

    // -----------
    // forceUnsubscribe
    // -----------

    function test_forceUnsubscribe_removesHealthySubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.expectEmit(true, true, false, false);
        emit IPositionRegistry.Unsubscribed(1, alice);
        vm.prank(admin);
        registry.forceUnsubscribe(1);

        assertFalse(registry.isTokenSubscribed(1), "evicted");
        assertFalse(registry.isSubscribed(alice), "owner removed");
    }

    function test_forceUnsubscribe_notSubscribedIsNoop() public {
        vm.prank(admin);
        registry.forceUnsubscribe(99);
        assertFalse(registry.isTokenSubscribed(99), "still not subscribed");
    }

    function testRevert_forceUnsubscribe_onlyAdmin() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, support, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(support);
        registry.forceUnsubscribe(1);
    }

    // -----------
    // _removeSubscription swap-and-pop
    // -----------

    function test_removeSubscription_swapNonLastElement() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);
        _subscribe(3, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        uint256[] memory remaining = registry.getSubscriptionsRaw(alice);
        assertEq(remaining.length, 2, "two remain");
        assertEq(remaining[0], 3, "last swapped into removed slot");
        assertEq(remaining[1], 2, "second unchanged");

        // the swapped token's index must be correct, or its own later removal corrupts the array
        vm.prank(subscriber);
        registry.handleUnsubscribe(3);
        remaining = registry.getSubscriptionsRaw(alice);
        assertEq(remaining.length, 1, "one remains");
        assertEq(remaining[0], 2, "token 2 intact");
    }

    function test_removeSubscription_lastElementNoSwap() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleUnsubscribe(2);

        uint256[] memory remaining = registry.getSubscriptionsRaw(alice);
        assertEq(remaining.length, 1, "one remains");
        assertEq(remaining[0], 1, "first unchanged");
    }

    function test_removeSubscription_swapInGlobalSubscribedSet() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, bob, DEFAULT_LIQUIDITY);
        _subscribe(3, carol, DEFAULT_LIQUIDITY);

        vm.prank(subscriber);
        registry.handleUnsubscribe(1);

        address[] memory owners = registry.getSubscribed();
        assertEq(owners.length, 2, "two owners remain");
        assertEq(owners[0], carol, "carol swapped into alice's slot");
        assertEq(owners[1], bob, "bob unchanged");

        vm.prank(subscriber);
        registry.handleUnsubscribe(3);
        owners = registry.getSubscribed();
        assertEq(owners.length, 1, "one owner remains");
        assertEq(owners[0], bob, "bob intact");
    }

    // -----------
    // belowSubscriptionThreshold
    // -----------

    function test_belowSubscriptionThreshold_zeroLiquidity() public {
        _setPosition(1, alice, 0);
        assertTrue(registry.belowSubscriptionThreshold(1), "zero is below");
    }

    function test_belowSubscriptionThreshold_anyNonZeroWithNoMinimum() public {
        _setPosition(1, alice, 1);
        assertFalse(registry.belowSubscriptionThreshold(1), "one wei of liquidity qualifies");
    }

    // -----------
    // isInRange
    // -----------

    function test_isInRange_withinBounds() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 0);
        assertTrue(registry.isInRange(1), "tick 0 in [-600, 600)");
    }

    function test_isInRange_atLowerBoundIsInRange() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_LOWER);
        assertTrue(registry.isInRange(1), "lower bound inclusive");
    }

    function test_isInRange_atUpperBoundIsOutOfRange() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER);
        assertFalse(registry.isInRange(1), "upper bound exclusive");
    }

    function test_isInRange_belowRange() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_LOWER - 1);
        assertFalse(registry.isInRange(1), "below");
    }

    function test_isInRange_aboveRange() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);
        assertFalse(registry.isInRange(1), "above");
    }

    // -----------
    // subscriptionEligible
    // -----------

    function test_subscriptionEligible_healthy() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertTrue(registry.subscriptionEligible(1), "healthy");
    }

    function test_subscriptionEligible_poolNotAllowed() public {
        PoolKey memory other = _poolKey(500);
        sv.setSlot0(other.toId(), SQRT_PRICE_1_1, 0);
        pm.setPosition(1, other, TICK_LOWER, TICK_UPPER, DEFAULT_LIQUIDITY, alice);
        assertFalse(registry.subscriptionEligible(1), "unlisted pool");
    }

    function test_subscriptionEligible_zeroLiquidity() public {
        _setPosition(1, alice, 0);
        assertFalse(registry.subscriptionEligible(1), "zero liquidity");
    }

    function test_subscriptionEligible_belowMinimum() public {
        vm.prank(admin);
        registry.setMinLiquidity(poolId, DEFAULT_LIQUIDITY + 1);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertFalse(registry.subscriptionEligible(1), "below minimum");
    }

    function test_subscriptionEligible_outOfRangeWhenFlagOn() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER);
        assertFalse(registry.subscriptionEligible(1), "out of range");
    }

    function test_subscriptionEligible_outOfRangeAllowedWhenFlagOff() public {
        vm.prank(admin);
        registry.setInRangeRequired(false);
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER);
        assertTrue(registry.subscriptionEligible(1), "flag off");
    }

    // -----------
    // validPool
    // -----------

    function test_validPool_allowedAndInitialized() public view {
        assertTrue(registry.validPool(poolId), "allowed + initialized");
    }

    function test_validPool_allowedButUninitialized() public {
        PoolKey memory fresh = _poolKey(500);
        vm.prank(admin);
        registry.registerPool(fresh);
        assertFalse(registry.validPool(fresh.toId()), "allowed but no price");
    }

    function test_validPool_initializedButNotAllowed() public {
        PoolKey memory other = _poolKey(500);
        sv.setSlot0(other.toId(), SQRT_PRICE_1_1, 0);
        assertFalse(registry.validPool(other.toId()), "initialized but unlisted");
    }

    // -----------
    // View shims
    // -----------

    function test_getPosition_returnsLiveData() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        (address owner, PoolId pid, int24 lower, int24 upper) = registry.getPosition(1);
        assertEq(owner, alice, "owner");
        assertEq(PoolId.unwrap(pid), PoolId.unwrap(poolId), "poolId");
        assertEq(lower, TICK_LOWER, "tickLower");
        assertEq(upper, TICK_UPPER, "tickUpper");
    }

    function test_getPosition_burnedReturnsZeroOwner() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        pm.burn(1);
        (address owner,,,) = registry.getPosition(1);
        assertEq(owner, address(0), "burned reads as zero owner");
    }

    function test_getPositionDetails_returnsLiveData() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(1);
        assertEq(d.owner, alice, "owner");
        assertEq(PoolId.unwrap(d.poolId), PoolId.unwrap(poolId), "poolId");
        assertEq(d.tickLower, TICK_LOWER, "tickLower");
        assertEq(d.tickUpper, TICK_UPPER, "tickUpper");
        assertEq(d.liquidity, DEFAULT_LIQUIDITY, "liquidity");
        assertEq(Currency.unwrap(d.poolKey.currency0), Currency.unwrap(poolKey.currency0), "poolKey");
    }

    function test_getPositionDetails_unregisteredReturnsZeros() public view {
        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(99);
        assertEq(d.owner, address(0), "no owner");
        assertEq(d.liquidity, 0, "no liquidity");
    }

    function test_getLiquidityLast_returnsLiveLiquidity() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        assertEq(registry.getLiquidityLast(1), DEFAULT_LIQUIDITY, "live liquidity");
        pm.setLiquidity(1, 5);
        assertEq(registry.getLiquidityLast(1), 5, "tracks changes");
    }

    function test_getLiquidityLast_unregisteredIsZero() public view {
        assertEq(registry.getLiquidityLast(99), 0, "zero");
    }

    function test_getSubscriptions_emptyForUnknownOwner() public view {
        assertEq(registry.getSubscriptions(alice).length, 0, "empty");
    }

    function test_getSubscriptions_filtersIneligibleAndForeignPositions() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY); // stays healthy
        _subscribe(2, alice, DEFAULT_LIQUIDITY); // drained
        _subscribe(3, alice, DEFAULT_LIQUIDITY); // transferred away
        pm.setLiquidity(2, 0);
        pm.setOwner(3, bob);

        uint256[] memory votable = registry.getSubscriptions(alice);
        assertEq(votable.length, 1, "only the healthy one");
        assertEq(votable[0], 1, "token 1");
        assertEq(registry.getSubscriptionsRaw(alice).length, 3, "raw still holds all three");
    }

    // -----------
    // Pagination
    // -----------

    function test_getSubscriptions_paginated_walksTheWholeSet() public {
        for (uint256 i = 1; i <= 7; ++i) {
            _subscribe(i, alice, DEFAULT_LIQUIDITY);
        }
        pm.setLiquidity(4, 0); // one ineligible entry in the middle

        uint256 seen;
        uint256 offset;
        uint256 total;
        do {
            (uint256[] memory page, uint256 t) = registry.getSubscriptions(alice, offset, 3);
            total = t;
            seen += page.length;
            offset += 3;
        } while (offset < total);

        assertEq(total, 7, "total is the stored count");
        assertEq(seen, 6, "six votable across pages");
    }

    function test_getSubscriptions_paginated_offsetPastEnd() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        (uint256[] memory page, uint256 total) = registry.getSubscriptions(alice, 5, 3);
        assertEq(page.length, 0, "empty page");
        assertEq(total, 1, "total still reported");
    }

    function test_getSubscriptions_paginated_limitOverflowClamps() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        _subscribe(2, alice, DEFAULT_LIQUIDITY);
        (uint256[] memory page, uint256 total) = registry.getSubscriptions(alice, 1, type(uint256).max);
        assertEq(page.length, 1, "clamped to the array end");
        assertEq(total, 2, "total");
        assertEq(page[0], 2, "second entry");
    }

    function test_getSubscriptions_paginated_matchesUnpaginated() public {
        for (uint256 i = 1; i <= 5; ++i) {
            _subscribe(i, alice, DEFAULT_LIQUIDITY);
        }
        (uint256[] memory page,) = registry.getSubscriptions(alice, 0, 5);
        uint256[] memory all = registry.getSubscriptions(alice);
        assertEq(page.length, all.length, "same length");
        for (uint256 i; i < all.length; ++i) {
            assertEq(page[i], all[i], "same order");
        }
    }

    function test_getSubscribed_emptyOnFreshRegistry() public view {
        assertEq(registry.getSubscribed().length, 0, "empty");
    }

    function test_getAmountsForLiquidity_returnsPriceAndAmounts() public view {
        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) =
            registry.getAmountsForLiquidity(poolId, DEFAULT_LIQUIDITY, TICK_LOWER, TICK_UPPER);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "price passthrough");
        assertGt(amount0, 0, "amount0");
        assertGt(amount1, 0, "amount1");
        assertEq(amount0, amount1, "symmetric range at 1:1");
    }

    // -----------
    // erc20Rescue
    // -----------

    function test_erc20Rescue_transfersTokens() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1_000);

        vm.prank(support);
        registry.erc20Rescue(IERC20(address(token)), bob, 1_000);

        assertEq(token.balanceOf(bob), 1_000, "rescued");
        assertEq(token.balanceOf(address(registry)), 0, "drained");
    }

    function testRevert_erc20Rescue_onlySupportRole() public {
        MockERC20 token = new MockERC20();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, registry.SUPPORT_ROLE()
            )
        );
        vm.prank(admin);
        registry.erc20Rescue(IERC20(address(token)), bob, 1);
    }

    // -----------
    // MAX_SUBSCRIPTIONS cap + query gas check
    // -----------

    /// @notice Fills one LP to `MAX_SUBSCRIPTIONS` (1,000) and records what the linear-in-N reads
    ///         cost, then confirms the cap rejects the next subscription and that pagination bounds
    ///         the per-call cost. Subscribe and unsubscribe stay O(1). These figures are against
    ///         mocks; real Uniswap contracts with cold storage cost more.
    function test_maxSubscriptions_capAndQueryGas() public {
        uint256 cap = registry.MAX_SUBSCRIPTIONS();
        for (uint256 i = 1; i <= cap; ++i) {
            _setPosition(i, alice, DEFAULT_LIQUIDITY);
            vm.prank(subscriber);
            registry.handleSubscribe(i);
        }

        uint256 gasBefore = gasleft();
        uint256[] memory raw = registry.getSubscriptionsRaw(alice);
        emit log_named_uint("getSubscriptionsRaw() gas at 1,000 entries", gasBefore - gasleft());
        assertEq(raw.length, cap, "owner filled to the cap");

        gasBefore = gasleft();
        uint256[] memory votable = registry.getSubscriptions(alice);
        emit log_named_uint("getSubscriptions() filtered gas at 1,000 entries", gasBefore - gasleft());
        assertEq(votable.length, cap, "all 1,000 positions votable");

        gasBefore = gasleft();
        (uint256[] memory page,) = registry.getSubscriptions(alice, 0, 100);
        emit log_named_uint("getSubscriptions(offset,limit) gas for a 100-entry page", gasBefore - gasleft());
        assertEq(page.length, 100, "one page");

        gasBefore = gasleft();
        vm.prank(subscriber);
        registry.handleUnsubscribe(500);
        emit log_named_uint("handleUnsubscribe() gas at 1,000 entries", gasBefore - gasleft());

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
        uint256 current = registry.getSubscribed().length;
        vm.store(address(registry), slot, bytes32(current + 3));
        require(
            registry.getSubscribed().length == current + 3,
            "storage layout drift: `subscribed` not at SUBSCRIBED_LENGTH_SLOT; re-run forge inspect"
        );
        vm.store(address(registry), slot, bytes32(length));
    }
}

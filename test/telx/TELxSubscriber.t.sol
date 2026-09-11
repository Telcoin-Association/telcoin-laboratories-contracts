// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "contracts/telx/abstract/PositionManagerAuth.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {TelxTestConstants} from "./TelxTestConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TELxSubscriberTest
/// @notice Deterministic, non-fork unit tests for TELxSubscriber - the Uniswap v4 PositionManager
///         subscriber that mirrors LP subscription state into PositionRegistry. Covers all four
///         notify* callbacks (including the new threshold-enforcing `notifyModifyLiquidity`), the
///         owner-swappable registry pointer, and access control. The PositionManager and StateView
///         are mocked so every branch is exercised without RPC.
contract TELxSubscriberTest is Test {
    TELxSubscriber internal subscriber;
    PositionRegistry internal registry;
    MockPositionManager internal pm;
    MockStateView internal sv;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    PoolKey internal poolKey;
    PoolId internal poolId;

    // Local aliases for shared TELx test fixtures (see test/telx/TelxTestConstants.sol).
    int24 internal constant TICK_SPACING = TelxTestConstants.TICK_SPACING;
    int24 internal constant TICK_LOWER = TelxTestConstants.TICK_LOWER;
    int24 internal constant TICK_UPPER = TelxTestConstants.TICK_UPPER;
    uint128 internal constant DEFAULT_LIQUIDITY = TelxTestConstants.DEFAULT_LIQUIDITY;
    uint128 internal constant POOL_LIQUIDITY = TelxTestConstants.POOL_LIQUIDITY;
    uint160 internal constant SQRT_PRICE_1_1 = TelxTestConstants.SQRT_PRICE_1_1;

    function setUp() public {
        pm = new MockPositionManager();
        sv = new MockStateView();
        registry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), address(pm), owner);

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE0)),
            currency1: Currency.wrap(address(0xB0B0B0)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        // current tick 0 sits inside every test position's default [-600, 600) range
        sv.setSlot0(poolId, SQRT_PRICE_1_1, 0);
        sv.setLiquidity(poolId, POOL_LIQUIDITY);
    }

    // -----------
    // Constructor
    // -----------

    function test_constructor_setsState() public view {
        assertEq(address(subscriber.registry()), address(registry), "registry");
        assertEq(subscriber.positionManager(), address(pm), "positionManager");
        assertEq(subscriber.owner(), owner, "owner");
    }

    function testRevert_constructor_zeroRegistry() public {
        vm.expectRevert(TELxSubscriber.ZeroAddress.selector);
        new TELxSubscriber(IPositionRegistry(address(0)), address(pm), owner);
    }

    // -----------
    // setRegistry
    // -----------

    function test_setRegistry_updatesPointer() public {
        PositionRegistry newRegistry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);

        vm.expectEmit(true, true, true, true, address(subscriber));
        emit TELxSubscriber.RegistryUpdated(IPositionRegistry(address(registry)), IPositionRegistry(address(newRegistry)));
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(newRegistry)));

        assertEq(address(subscriber.registry()), address(newRegistry), "registry repointed");
    }

    function test_setRegistry_routesCallbacksToNewRegistry() public {
        // a freshly deployed registry the subscriber is repointed at
        PositionRegistry newRegistry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);
        vm.startPrank(admin);
        newRegistry.grantRole(newRegistry.SUBSCRIBER_ROLE(), address(subscriber));
        vm.stopPrank();
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(newRegistry)));

        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        vm.prank(address(pm));
        subscriber.notifySubscribe(1, "");

        assertTrue(newRegistry.isTokenSubscribed(1), "new registry received the subscription");
        assertFalse(registry.isTokenSubscribed(1), "old registry untouched");
    }

    function testRevert_setRegistry_zeroAddress() public {
        vm.expectRevert(TELxSubscriber.ZeroAddress.selector);
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(0)));
    }

    function testRevert_setRegistry_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        subscriber.setRegistry(IPositionRegistry(address(registry)));
    }

    // -----------
    // notifySubscribe
    // -----------

    function test_notifySubscribe_recordsSubscription() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);

        vm.prank(address(pm));
        subscriber.notifySubscribe(1, "");

        assertTrue(registry.isTokenSubscribed(1), "subscription recorded");
    }

    function testRevert_notifySubscribe_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifySubscribe(1, "");
    }

    // -----------
    // notifyUnsubscribe
    // -----------

    function test_notifyUnsubscribe_removesSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.prank(address(pm));
        subscriber.notifyUnsubscribe(1);

        assertFalse(registry.isTokenSubscribed(1), "subscription removed");
    }

    function testRevert_notifyUnsubscribe_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifyUnsubscribe(1);
    }

    // -----------
    // notifyModifyLiquidity (threshold enforcement)
    // -----------

    function test_notifyModifyLiquidity_unsubscribesWhenDrainedBelowThreshold() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // drain the position below the 100-liquidity threshold
        pm.setLiquidity(1, 50);

        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(1, -9_950, BalanceDelta.wrap(0));

        assertFalse(registry.isTokenSubscribed(1), "drained position unsubscribed");
    }

    function test_notifyModifyLiquidity_keepsSubscriptionWhenStillEligible() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // still above threshold and in range after the modification
        pm.setLiquidity(1, 5_000);

        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(1, -5_000, BalanceDelta.wrap(0));

        assertTrue(registry.isTokenSubscribed(1), "healthy position stays subscribed");
    }

    function test_notifyModifyLiquidity_unsubscribesWhenOutOfRange() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);
        // liquidity stays healthy, but the position is no longer in range
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);

        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(1, 0, BalanceDelta.wrap(0));

        assertFalse(registry.isTokenSubscribed(1), "out-of-range position unsubscribed");
    }

    function test_notifyModifyLiquidity_noopWhenNotSubscribed() public {
        // an unsubscribed token short-circuits before any threshold read
        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(999, 1_000, BalanceDelta.wrap(0));

        assertFalse(registry.isTokenSubscribed(999), "still unsubscribed");
    }

    function testRevert_notifyModifyLiquidity_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifyModifyLiquidity(1, 0, BalanceDelta.wrap(0));
    }

    // -----------
    // notifyBurn
    // -----------

    function test_notifyBurn_removesSubscription() public {
        _subscribe(1, alice, DEFAULT_LIQUIDITY);

        vm.prank(address(pm));
        subscriber.notifyBurn(1, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));

        assertFalse(registry.isTokenSubscribed(1), "subscription removed on burn");
    }

    function testRevert_notifyBurn_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifyBurn(1, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));
    }

    // -----------
    // Ownership
    // -----------

    function test_ownership_twoStepTransfer() public {
        vm.prank(owner);
        subscriber.transferOwnership(alice);
        // ownership does not move until the pending owner accepts
        assertEq(subscriber.owner(), owner, "owner unchanged before acceptance");

        vm.prank(alice);
        subscriber.acceptOwnership();
        assertEq(subscriber.owner(), alice, "owner moved after acceptance");
    }

    // -----------
    // Helpers
    // -----------

    function _setPosition(uint256 tokenId, address positionOwner, uint128 liquidity) internal {
        pm.setPosition(tokenId, poolKey, TICK_LOWER, TICK_UPPER, liquidity, positionOwner);
    }

    function _subscribe(uint256 tokenId, address positionOwner, uint128 liquidity) internal {
        _setPosition(tokenId, positionOwner, liquidity);
        vm.prank(address(pm));
        subscriber.notifySubscribe(tokenId, "");
    }
}

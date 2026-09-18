// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "contracts/telx/abstract/PositionManagerAuth.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {RevertingRegistry} from "./mocks/RevertingRegistry.sol";
import {TelxTestConstants} from "./TelxTestConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TELxSubscriberTest
/// @notice Deterministic, non-fork unit tests for TELxSubscriber - the Uniswap v4 PositionManager
///         subscriber that mirrors LP subscription state into PositionRegistry. Covers all four
///         notify* callbacks, the owner-swappable registry pointer and its wiring checks, the
///         disabled renounce, and access control. The PositionManager, StateView and PoolManager
///         lock are mocked so every branch is exercised without RPC.
///
///         The property that matters most is that a broken registry can never block an LP: the
///         two notifications v4 bubbles (`notifyModifyLiquidity`, `notifyBurn`) must complete
///         whatever the registry does, so `RevertingRegistry` stands in for one that reverts on
///         every call.
contract TELxSubscriberTest is Test {
    TELxSubscriber internal subscriber;
    PositionRegistry internal registry;
    MockPositionManager internal pm;
    MockStateView internal sv;
    MockPoolManager internal poolManager;

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
        poolManager = new MockPoolManager();
        pm = new MockPositionManager();
        sv = new MockStateView(address(poolManager));
        registry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), address(pm), owner);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE0)),
            currency1: Currency.wrap(address(0xB0B0B0)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.registerPool(poolKey);
        vm.stopPrank();

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
        PositionRegistry next = _wiredRegistry();

        vm.expectEmit(true, true, false, false);
        emit TELxSubscriber.RegistryUpdated(IPositionRegistry(address(registry)), IPositionRegistry(address(next)));
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(next)));

        assertEq(address(subscriber.registry()), address(next), "pointer moved");
    }

    function test_setRegistry_routesCallbacksToNewRegistry() public {
        PositionRegistry next = _wiredRegistry();
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(next)));

        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        vm.prank(address(pm));
        subscriber.notifySubscribe(1, "");

        assertTrue(next.isTokenSubscribed(1), "recorded in the new registry");
        assertFalse(registry.isTokenSubscribed(1), "not in the old one");
    }

    function testRevert_setRegistry_zeroAddress() public {
        vm.expectRevert(TELxSubscriber.ZeroAddress.selector);
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(0)));
    }

    /// @notice A registry with no code would make every forwarded notification fail from the
    ///         moment of the switch. Refused up front.
    function testRevert_setRegistry_noCode() public {
        address empty = makeAddr("empty");
        vm.expectRevert(abi.encodeWithSelector(TELxSubscriber.RegistryHasNoCode.selector, empty));
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(empty));
    }

    /// @notice A registry that has not granted this subscriber SUBSCRIBER_ROLE would reject every
    ///         subscribe. Refused up front; the role must be granted before the switch.
    function testRevert_setRegistry_notWired() public {
        PositionRegistry unwired = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);
        vm.expectRevert(abi.encodeWithSelector(TELxSubscriber.RegistryNotWired.selector, address(unwired)));
        vm.prank(owner);
        subscriber.setRegistry(IPositionRegistry(address(unwired)));
    }

    function testRevert_setRegistry_onlyOwner() public {
        PositionRegistry next = _wiredRegistry();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        subscriber.setRegistry(IPositionRegistry(address(next)));
    }

    // -----------
    // notifySubscribe
    // -----------

    function test_notifySubscribe_recordsSubscription() public {
        _setPosition(1, alice, DEFAULT_LIQUIDITY);
        vm.prank(address(pm));
        subscriber.notifySubscribe(1, "");
        assertTrue(registry.isTokenSubscribed(1), "subscribed");
    }

    /// @notice Subscribe is deliberately not wrapped: a rejected opt-in must fail loudly so v4 and
    ///         the registry never disagree about a fresh subscription.
    function testRevert_notifySubscribe_bubblesRegistryRevert() public {
        _setPosition(1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.LiquidityBelowThreshold.selector, uint128(0)));
        vm.prank(address(pm));
        subscriber.notifySubscribe(1, "");
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
        _subscribe(1, alice);
        vm.prank(address(pm));
        subscriber.notifyUnsubscribe(1);
        assertFalse(registry.isTokenSubscribed(1), "unsubscribed");
    }

    function testRevert_notifyUnsubscribe_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifyUnsubscribe(1);
    }

    // -----------
    // notifyModifyLiquidity
    // -----------

    /// @notice A no-op by design. Fires inside the LP's own unlock, so any pool-state read here is
    ///         one the transaction controls; the registry judges eligibility live at read time
    ///         instead. Nothing about the subscription changes, whatever the position looks like.
    function test_notifyModifyLiquidity_isNoop() public {
        _subscribe(1, alice);

        // drained, out of range, and inside an unlock: none of it matters here
        pm.setLiquidity(1, 0);
        sv.setSlot0(poolId, SQRT_PRICE_1_1, TICK_UPPER + 1);
        poolManager.setUnlocked(true);

        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(1, -int256(uint256(DEFAULT_LIQUIDITY)), BalanceDelta.wrap(0));

        assertTrue(registry.isTokenSubscribed(1), "still indexed");
        assertEq(registry.getSubscriptions(alice).length, 0, "but the live filter sees the drain");
    }

    /// @notice The strongest form of the guarantee: with a registry that reverts on every call,
    ///         the LP's liquidity modification still completes, because there is no call to make.
    function test_notifyModifyLiquidity_cannotBeBlockedByRegistry() public {
        _repointToRevertingRegistry();
        vm.prank(address(pm));
        subscriber.notifyModifyLiquidity(1, 1, BalanceDelta.wrap(0));
    }

    function testRevert_notifyModifyLiquidity_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(stranger);
        subscriber.notifyModifyLiquidity(1, 1, BalanceDelta.wrap(0));
    }

    // -----------
    // notifyBurn
    // -----------

    function test_notifyBurn_removesSubscription() public {
        _subscribe(1, alice);
        vm.prank(address(pm));
        subscriber.notifyBurn(1, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));
        assertFalse(registry.isTokenSubscribed(1), "removed on burn");
    }

    /// @notice v4 bubbles a burn notification revert into the LP's transaction. With the registry
    ///         reverting, the burn must still complete; the drop is signalled by event instead.
    function test_notifyBurn_swallowsRegistryRevert() public {
        _repointToRevertingRegistry();

        vm.expectEmit(true, true, false, false);
        emit TELxSubscriber.NotificationDropped(1, ISubscriber.notifyBurn.selector);
        vm.prank(address(pm));
        subscriber.notifyBurn(1, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));
    }

    /// @notice Same guarantee when the failure is a revoked role rather than a broken contract.
    function test_notifyBurn_swallowsRevokedRole() public {
        _subscribe(1, alice);
        vm.prank(admin);
        registry.revokeRole(keccak256("SUBSCRIBER_ROLE"), address(subscriber));

        vm.expectEmit(true, true, false, false);
        emit TELxSubscriber.NotificationDropped(1, ISubscriber.notifyBurn.selector);
        vm.prank(address(pm));
        subscriber.notifyBurn(1, alice, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));

        assertTrue(registry.isTokenSubscribed(1), "registry untouched, but the burn went through");
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
        assertEq(subscriber.owner(), owner, "still the old owner");
        assertEq(subscriber.pendingOwner(), alice, "alice pending");

        vm.prank(alice);
        subscriber.acceptOwnership();
        assertEq(subscriber.owner(), alice, "alice owns");
    }

    /// @notice An ownerless subscriber could never be repointed, which would freeze every LP
    ///         subscription on whatever registry it last held. Disabled outright.
    function testRevert_renounceOwnership_disabled() public {
        vm.expectRevert(TELxSubscriber.CannotRenounce.selector);
        vm.prank(owner);
        subscriber.renounceOwnership();
        assertEq(subscriber.owner(), owner, "still owned");
    }

    function testRevert_renounceOwnership_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        subscriber.renounceOwnership();
    }

    // -----------
    // Helpers
    // -----------

    function _setPosition(uint256 tokenId, address who, uint128 liquidity) internal {
        pm.setPosition(tokenId, poolKey, TICK_LOWER, TICK_UPPER, liquidity, who);
    }

    function _subscribe(uint256 tokenId, address who) internal {
        _setPosition(tokenId, who, DEFAULT_LIQUIDITY);
        vm.prank(address(pm));
        subscriber.notifySubscribe(tokenId, "");
    }

    /// @dev A second registry with the subscriber already granted its role and the pool allowlisted.
    function _wiredRegistry() internal returns (PositionRegistry next) {
        next = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);
        vm.startPrank(admin);
        next.grantRole(next.SUBSCRIBER_ROLE(), address(subscriber));
        next.registerPool(poolKey);
        vm.stopPrank();
    }

    /// @dev Swaps the registry pointer for one that reverts on every call, bypassing setRegistry's
    ///      own wiring checks via storage so the notification paths can be tested against the
    ///      worst case a misconfiguration could produce.
    function _repointToRevertingRegistry() internal {
        RevertingRegistry bad = new RevertingRegistry();
        // `registry` is the first declared state variable; Ownable/Ownable2Step take slots 0-1.
        vm.store(address(subscriber), bytes32(uint256(2)), bytes32(uint256(uint160(address(bad)))));
        require(address(subscriber.registry()) == address(bad), "storage layout drift: `registry` not at slot 2");
    }
}

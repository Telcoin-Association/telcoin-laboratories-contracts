// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "../../contracts/telx/abstract/PositionManagerAuth.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestConstants} from "../util/TestConstants.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title TELxSubscriber Polygon Fork Tests
 * @notice Verifies a TELxSubscriber deployed against live Uniswap v4 infrastructure on Polygon is
 *         wired correctly and enforces access control. The subscriber itself makes no calls into
 *         v4 - it only forwards to the registry and gates on the PositionManager address - so
 *         behavioral coverage lives in the deterministic `TELxSubscriber.t.sol` unit suite.
 *
 * @dev The previous production subscriber is being redeployed as part of this migration, so this
 *      file deploys fresh rather than reading a production address.
 *
 *      Required env vars: POLYGON_RPC_URL
 */
contract TELxSubscriberPolygonTest is Test {
    // Local aliases for shared Polygon constants (see test/util/PolygonConstants.sol).
    address constant V4_POOL_MANAGER = PolygonConstants.V4_POOL_MANAGER;
    address constant V4_POSITION_MANAGER = PolygonConstants.V4_POSITION_MANAGER;

    address admin = makeAddr("admin");
    address owner = makeAddr("owner");

    PositionRegistry registry;
    TELxSubscriber subscriber;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), TestConstants.PRODUCTION_STATE_POLYGON_FORK_BLOCK);

        StateView stateView = new StateView(IPoolManager(V4_POOL_MANAGER));
        registry = new PositionRegistry(IPositionManager(V4_POSITION_MANAGER), stateView, admin);
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), V4_POSITION_MANAGER, owner);

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        vm.stopPrank();
    }

    function test_deployment_wiredToLiveV4() public view {
        assertEq(address(subscriber.registry()), address(registry), "registry");
        assertEq(subscriber.positionManager(), V4_POSITION_MANAGER, "positionManager");
        assertEq(subscriber.owner(), owner, "owner");
    }

    function test_notifyCallbacks_revertFromUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);

        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        subscriber.notifySubscribe(1, "");

        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        subscriber.notifyUnsubscribe(1);

        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        subscriber.notifyModifyLiquidity(1, 0, BalanceDelta.wrap(0));

        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        subscriber.notifyBurn(1, address(0), PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));

        vm.stopPrank();
    }

    function test_setRegistry_revertsFromNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        subscriber.setRegistry(IPositionRegistry(address(registry)));
    }
}

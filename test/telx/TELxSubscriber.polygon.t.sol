// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title TELxSubscriber Polygon Production Fork Tests
 * @notice Read-only verification that the production subscriber on Polygon is correctly configured
 *         and access control is correctly enforced.
 *
 * @dev Complements the Sepolia fresh-deploy tests at test/telx/TELxSubscriber.t.sol.
 *
 *      Required env vars: POLYGON_RPC_URL
 *      Fork block: 65000000+ (post-Dencun)
 */
contract TELxSubscriberPolygonTest is Test {
    address constant PRODUCTION_SUBSCRIBER = PolygonConstants.TELX_PRODUCTION_SUBSCRIBER;
    address constant PRODUCTION_REGISTRY = PolygonConstants.TELX_PRODUCTION_REGISTRY;
    address constant V4_POSITION_MANAGER = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;

    uint256 constant FORK_BLOCK = 85_800_000;

    TELxSubscriber subscriber;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);
        subscriber = TELxSubscriber(PRODUCTION_SUBSCRIBER);
    }

    function test_productionSubscriber_isContract() public view {
        uint256 size;
        address target = PRODUCTION_SUBSCRIBER;
        assembly {
            size := extcodesize(target)
        }
        assertTrue(size > 0, "Production subscriber should have code");
    }

    function test_registry_setCorrectly() public view {
        assertEq(address(subscriber.registry()), PRODUCTION_REGISTRY, "Subscriber registry mismatch");
    }

    function test_positionManager_setCorrectly() public view {
        assertEq(subscriber.positionManager(), V4_POSITION_MANAGER, "Subscriber positionManager mismatch");
    }

    function test_notifySubscribe_revertsFromUnauthorized() public {
        // Call from an unauthorized address — should revert
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        subscriber.notifySubscribe(1, "");
    }

    function test_notifyUnsubscribe_revertsFromUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        subscriber.notifyUnsubscribe(1);
    }

    function test_notifyModifyLiquidity_revertsFromUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        ISubscriber(address(subscriber)).notifyModifyLiquidity(1, int256(0), BalanceDelta.wrap(0));
    }

    function test_notifyBurn_revertsFromUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        ISubscriber(address(subscriber)).notifyBurn(
            1, address(0), PositionInfo.wrap(0), uint256(0), BalanceDelta.wrap(0)
        );
    }
}

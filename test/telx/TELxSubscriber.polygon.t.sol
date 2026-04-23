// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";

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
    address constant PRODUCTION_SUBSCRIBER = 0x3Bf9bAdC67573e7b4756547A2dC0C77368A2062b;
    address constant PRODUCTION_REGISTRY = 0x2c33fC9c09CfAC5431e754b8fe708B1dA3F5B954;
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
        // Call via raw calldata to avoid type construction complexity
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        (bool ok,) = address(subscriber).call(
            abi.encodeWithSignature("notifyModifyLiquidity(uint256,int256,int256)", 1, int256(0), int256(0))
        );
        assertFalse(ok, "notifyModifyLiquidity should revert from unauthorized caller");
    }

    function test_notifyBurn_revertsFromUnauthorized() public {
        // Call via raw calldata — the full signature involves PositionInfo and BalanceDelta types
        // that require Uniswap V4 imports; we just verify the auth check rejects unauthorized callers
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        (bool ok,) = address(subscriber).call(
            abi.encodeWithSignature(
                "notifyBurn(uint256,address,uint256,uint256,int256)",
                1,
                address(0),
                uint256(0),
                uint256(0),
                int256(0)
            )
        );
        assertFalse(ok, "notifyBurn should revert from unauthorized caller");
    }
}

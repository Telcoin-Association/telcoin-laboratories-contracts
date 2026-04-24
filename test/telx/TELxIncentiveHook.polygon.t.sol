// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxIncentiveHook} from "../../contracts/telx/core/TELxIncentiveHook.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title TELxIncentiveHook Polygon Production Fork Tests
 * @notice Read-only verification that the production hook on Polygon is correctly configured.
 *
 * @dev Complements the Sepolia fresh-deploy tests at test/telx/TELxIncentiveHook.t.sol.
 *
 *      Required env vars: POLYGON_RPC_URL
 *      Fork block: 65000000+ (post-Dencun)
 */
contract TELxIncentiveHookPolygonTest is Test {
    address constant PRODUCTION_HOOK = PolygonConstants.TELX_PRODUCTION_HOOK;
    address constant PRODUCTION_REGISTRY = PolygonConstants.TELX_PRODUCTION_REGISTRY;
    address constant V4_POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address constant V4_POSITION_MANAGER = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;

    uint256 constant FORK_BLOCK = 85_800_000;

    TELxIncentiveHook hook;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);
        hook = TELxIncentiveHook(PRODUCTION_HOOK);
    }

    function test_productionHook_isContract() public view {
        uint256 size;
        address target = PRODUCTION_HOOK;
        assembly {
            size := extcodesize(target)
        }
        assertTrue(size > 0, "Production hook should have code");
    }

    function test_registry_setCorrectly() public view {
        assertEq(address(hook.registry()), PRODUCTION_REGISTRY, "Hook registry mismatch");
    }

    function test_poolManager_setCorrectly() public view {
        assertEq(address(hook.poolManager()), V4_POOL_MANAGER, "Hook poolManager mismatch");
    }

    function test_positionManager_setCorrectly() public view {
        assertEq(hook.positionManager(), V4_POSITION_MANAGER, "Hook positionManager mismatch");
    }

    function test_hookPermissions_matchProduction() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        // Verify the core liquidity hook permissions are enabled (these are load-bearing)
        assertTrue(perms.afterAddLiquidity, "afterAddLiquidity should be true");
        assertTrue(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be true");

        // Production hook has beforeInitialize enabled (differs from the Sepolia test expectation)
        // This is a production-configuration detail the Polygon fork test captures
        assertTrue(perms.beforeInitialize, "production hook has beforeInitialize enabled");

        // Swap hooks should remain disabled — adding them would impose gas cost on every swap
        assertFalse(perms.beforeSwap, "beforeSwap should be false");
        assertFalse(perms.afterSwap, "afterSwap should be false");

        // Return-delta hooks should all be disabled
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }
}

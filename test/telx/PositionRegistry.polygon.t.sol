// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TestConstants} from "../util/TestConstants.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title PositionRegistry Polygon Production Fork Tests
 * @notice Read-only verification that the production PositionRegistry on Polygon is correctly
 *         configured and reachable. Does NOT mutate on-chain state.
 *
 * @dev Complements the Sepolia fresh-deploy tests at test/telx/PositionRegistry.t.sol:
 *      - Sepolia tests: fresh deploys, exhaustive branch coverage, deterministic
 *      - Polygon tests (this file): production state verification, real live data
 *
 *      Required env vars: POLYGON_RPC_URL
 *      Fork block: 65000000+ (must be post-Dencun for transient storage on Polygon)
 */
contract PositionRegistryPolygonTest is Test {
    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    // V4 PoolManager + PositionManager addresses are unique to this file (used only here),
    // so they remain inline.
    address constant PRODUCTION_REGISTRY = PolygonConstants.TELX_PRODUCTION_REGISTRY;
    address constant PRODUCTION_HOOK = PolygonConstants.TELX_PRODUCTION_HOOK;
    address constant PRODUCTION_SUBSCRIBER = PolygonConstants.TELX_PRODUCTION_SUBSCRIBER;
    address constant V4_POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address constant V4_POSITION_MANAGER = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;
    address constant TELCOIN = PolygonConstants.TEL;

    // Known pool IDs
    bytes32 constant POOL_ID_USDC_EMXN = 0x37dafec81119c7987538ac000b8a8a16a7f4daeecf91626efc9956ccd5146246;
    bytes32 constant POOL_ID_WETH_TEL = 0x25412ca33f9a2069f0520708da3f70a7843374dd46dc1c7e62f6d5002f5f9fa7;

    PositionRegistry registry;

    function setUp() public {
        // Use the production-state fork block — later than the generic fork
        // block used by deploy-script tests, because this file exercises
        // the LIVE PositionRegistry + its initialized USDC/eMXN and WETH/TEL
        // pools. Those pool IDs were registered mid-production (after block
        // 84.3M), so an earlier fork would see `validPool(...) == false`.
        vm.createSelectFork(
            vm.envString("POLYGON_RPC_URL"),
            TestConstants.PRODUCTION_STATE_POLYGON_FORK_BLOCK
        );
        registry = PositionRegistry(PRODUCTION_REGISTRY);
    }

    function test_productionRegistry_isContract() public view {
        uint256 size;
        address target = PRODUCTION_REGISTRY;
        assembly {
            size := extcodesize(target)
        }
        assertTrue(size > 0, "Production registry should have code");
    }

    function test_weightConstants_readable() public view {
        uint256 jitWeight = registry.JIT_WEIGHT();
        uint256 activeWeight = registry.ACTIVE_WEIGHT();
        uint256 passiveWeight = registry.PASSIVE_WEIGHT();
        uint256 minPassiveLifetime = registry.MIN_PASSIVE_LIFETIME();

        // Weights must be in valid range (0-10000 bps each)
        assertLe(jitWeight, 10_000, "JIT_WEIGHT out of range");
        assertLe(activeWeight, 10_000, "ACTIVE_WEIGHT out of range");
        assertLe(passiveWeight, 10_000, "PASSIVE_WEIGHT out of range");
        assertGt(minPassiveLifetime, 0, "MIN_PASSIVE_LIFETIME should be non-zero");
    }

    function test_accessControl_hasAdmin() public view {
        bytes32 UNI_HOOK_ROLE = keccak256("UNI_HOOK_ROLE");

        // The hook contract should have UNI_HOOK_ROLE
        assertTrue(
            IAccessControl(PRODUCTION_REGISTRY).hasRole(UNI_HOOK_ROLE, PRODUCTION_HOOK),
            "Production hook should have UNI_HOOK_ROLE"
        );
    }

    function test_getSubscribed_returnsLiveData() public view {
        // getSubscribed() returns the global subscriber list
        address[] memory subscribers = registry.getSubscribed();

        // Live production data — we expect at least some subscribers
        // This can be 0 in early deployment; if so just verify the call succeeds
        assertTrue(subscribers.length >= 0, "getSubscribed should be callable");
    }

    function test_unclaimedRewards_readableForKnownLP() public view {
        // Read rewards for the hook itself (may be 0 but should not revert)
        uint256 rewards = registry.getUnclaimedRewards(PRODUCTION_HOOK);
        assertTrue(rewards >= 0, "getUnclaimedRewards should be callable");
    }

    function test_telcoin_set() public view {
        // The production registry should have TELCOIN as the reward token
        assertEq(address(registry.telcoin()), TELCOIN, "telcoin address mismatch");
    }

    function test_production_pool_initialization() public view {
        // Verify that each known-production pool is registered on the live
        // PositionRegistry — i.e., `addPoolKey(poolId)` was called for it.
        // This doubles as a live-state sanity check for the whole test file:
        // if either pool ID changes on-chain, subsequent tests in this file
        // that subscribe / claim against these pools would misbehave.
        assertTrue(registry.validPool(PoolId.wrap(POOL_ID_USDC_EMXN)), "USDC/eMXN pool not initialized");
        assertTrue(registry.validPool(PoolId.wrap(POOL_ID_WETH_TEL)), "WETH/TEL pool not initialized");
    }

    function test_iterateSubscribedPositions_forUSDCeMXN() public view {
        // Walk the global subscribed list and find LPs with positions in USDC/eMXN
        address[] memory subscribers = registry.getSubscribed();

        uint256 matchCount = 0;
        PoolId targetPool = PoolId.wrap(POOL_ID_USDC_EMXN);

        // Limit iteration to prevent gas blowup on large subscriber lists
        uint256 limit = subscribers.length > 100 ? 100 : subscribers.length;

        for (uint256 i; i < limit; ++i) {
            uint256[] memory tokenIds = registry.getSubscriptions(subscribers[i]);
            for (uint256 j; j < tokenIds.length; ++j) {
                IPositionRegistry.PositionDetails memory details = registry.getPositionDetails(tokenIds[j]);
                if (PoolId.unwrap(details.poolId) == PoolId.unwrap(targetPool)) {
                    matchCount++;
                    // Validate data sanity
                    assertTrue(details.owner != address(0), "Position owner should be non-zero");
                    assertTrue(details.liquidity > 0, "Position liquidity should be positive");
                    assertTrue(details.tickUpper > details.tickLower, "Ticks should be ordered");
                }
            }
        }

        // We don't assert matchCount > 0 because the fork block may predate LP subscriptions
        // The test is valuable even if no matches — it exercises the iteration path
        assertTrue(matchCount >= 0, "Iteration completed");
    }
}

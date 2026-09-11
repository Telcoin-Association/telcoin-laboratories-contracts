// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TestConstants} from "../util/TestConstants.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title PositionRegistry Polygon Fork Tests
 * @notice Verifies the thin (post-V4-hook-removal) PositionRegistry against real Uniswap v4
 *         infrastructure on Polygon. A fresh registry is deployed on the fork pointed at the live
 *         v4 PositionManager and a fresh StateView lens over the live PoolManager, then its view
 *         shims are exercised against real on-chain position and pool state.
 *
 * @dev Complements the deterministic mock-based unit tests in `PositionRegistry.t.sol`:
 *      - Unit tests: exhaustive branch coverage against mocks, no RPC.
 *      - Polygon tests (this file): ABI compatibility against real v4 contracts and live data.
 *
 *      The previous production PositionRegistry deployment is being redeployed as part of this
 *      migration, so this file deploys fresh rather than reading a production address.
 *
 *      Required env vars: POLYGON_RPC_URL
 */
contract PositionRegistryPolygonTest is Test {
    // Local aliases for shared Polygon constants (see test/util/PolygonConstants.sol).
    address constant V4_POOL_MANAGER = PolygonConstants.V4_POOL_MANAGER;
    address constant V4_POSITION_MANAGER = PolygonConstants.V4_POSITION_MANAGER;
    bytes32 constant POOL_ID_USDC_EMXN = PolygonConstants.TELX_POOL_ID_USDC_EMXN;
    bytes32 constant POOL_ID_WETH_TEL = PolygonConstants.TELX_POOL_ID_WETH_TEL;

    PositionRegistry registry;
    StateView stateView;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), TestConstants.PRODUCTION_STATE_POLYGON_FORK_BLOCK);

        // a fresh StateView lens over the live PoolManager reads real pool state
        stateView = new StateView(IPoolManager(V4_POOL_MANAGER));
        registry = new PositionRegistry(IPositionManager(V4_POSITION_MANAGER), stateView, address(this));
    }

    function test_deployment_wiredToLiveV4() public view {
        assertEq(address(registry.positionManager()), V4_POSITION_MANAGER, "positionManager");
        assertEq(address(registry.stateView()), address(stateView), "stateView");
    }

    function test_validPool_reflectsLivePoolState() public view {
        assertTrue(registry.validPool(PoolId.wrap(POOL_ID_WETH_TEL)), "WETH/TEL pool is initialized");
        assertTrue(registry.validPool(PoolId.wrap(POOL_ID_USDC_EMXN)), "USDC/eMXN pool is initialized");
        assertFalse(registry.validPool(PoolId.wrap(keccak256("not-a-pool"))), "unknown pool is invalid");
    }

    function test_viewShims_decodeRealPositionData() public view {
        uint256 tokenId = IPositionManager(V4_POSITION_MANAGER).nextTokenId() - 1;
        uint128 liquidity = IPositionManager(V4_POSITION_MANAGER).getPositionLiquidity(tokenId);

        // getLiquidityLast delegates straight to the live PositionManager
        assertEq(registry.getLiquidityLast(tokenId), liquidity, "getLiquidityLast matches PositionManager");

        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(tokenId);
        assertEq(d.liquidity, liquidity, "PositionDetails liquidity");

        // getPosition and getPositionDetails must decode the same live data identically
        (address owner, PoolId poolId, int24 tickLower, int24 tickUpper) = registry.getPosition(tokenId);
        assertEq(owner, d.owner, "owner agrees across shims");
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(d.poolId), "poolId agrees across shims");
        assertEq(tickLower, d.tickLower, "tickLower agrees across shims");
        assertEq(tickUpper, d.tickUpper, "tickUpper agrees across shims");
    }

    function test_eligibilityViews_readLiveState() public view {
        uint256 tokenId = IPositionManager(V4_POSITION_MANAGER).nextTokenId() - 1;
        uint128 liquidity = IPositionManager(V4_POSITION_MANAGER).getPositionLiquidity(tokenId);

        // belowSubscriptionThreshold must resolve against the real StateView.getLiquidity ABI
        bool below = registry.belowSubscriptionThreshold(tokenId);
        if (liquidity == 0) {
            assertTrue(below, "a zero-liquidity position is always below threshold");
        }

        // isInRange must agree with an independent tick comparison over the same live data
        IPositionRegistry.PositionDetails memory d = registry.getPositionDetails(tokenId);
        (, int24 currentTick,,) = stateView.getSlot0(d.poolId);
        bool expectedInRange = d.tickLower <= currentTick && currentTick < d.tickUpper;
        assertEq(registry.isInRange(tokenId), expectedInRange, "isInRange matches live tick comparison");
    }

    function test_getAmountsForLiquidity_onLivePool() public view {
        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) =
            registry.getAmountsForLiquidity(PoolId.wrap(POOL_ID_WETH_TEL), 1e12, -60, 60);
        assertGt(sqrtPriceX96, 0, "live pool price");
        assertTrue(amount0 > 0 || amount1 > 0, "non-zero liquidity requires tokens");
    }
}

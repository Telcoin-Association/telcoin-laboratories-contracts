// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { PositionRegistry } from "contracts/telx/core/PositionRegistry.sol";
import { IPositionRegistry } from "contracts/telx/interfaces/IPositionRegistry.sol";
import { TELxIncentiveHook } from "contracts/telx/core/TELxIncentiveHook.sol";
import { IPositionManager } from "contracts/telx/interfaces/IPositionManager.sol";
import { TELxIncentiveHookDeployable } from "contracts/telx/test/MockTELxIncentiveHook.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PositionManager } from "@uniswap/v4-periphery/src/PositionManager.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PositionRegistryTest is Test {
    using PoolIdLibrary for bytes32;

    string SEPOLIA_RPC_URL = vm.envString("SEPOLIA_RPC_URL");
    uint256 sepoliaFork;

    IERC20 public tel;
    PoolManager public poolManager;
    PositionManager public positionManager;
    PositionRegistry public positionRegistry;
    TELxIncentiveHook public telXIncentiveHook;

    PoolKey public poolKey;

    address public holder = 0x5d5d4d04B70BFe49ad7Aac8C4454536070dAf180;
    address public admin = address(0xc0ffee);
    address public support = address(0xdeadbeef);
    address public usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // sepolia USDC
    // address encoding the enabled afterAddLiquidity, beforeRemoveLiquidity, and afterSwap hooks
    address public hookAddress = 0x0000000000000000000000000000000000000a40;

    function setUp() public {
        // sepolia fork setup
        sepoliaFork = vm.createFork(SEPOLIA_RPC_URL);
        vm.selectFork(sepoliaFork);
        tel = IERC20(0x92bc9f0D42A3194Df2C5AB55c3bbDD82e6Fb2F92); // tel clone on sepolia
        poolManager = PoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        positionManager = PositionManager(payable(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4));
        
        // create pool registry and hook on permissions-encoded address
        vm.startPrank(admin);
        positionRegistry = new PositionRegistry(tel, IPoolManager(address(poolManager)), IPositionManager(address(positionManager)));
        positionRegistry.grantRole(positionRegistry.SUPPORT_ROLE(), support);
        TELxIncentiveHook tempHook = new TELxIncentiveHookDeployable(
            IPoolManager(address(poolManager)),
            address(positionManager),
            IPositionRegistry(address(positionRegistry))
        );
        vm.etch(hookAddress, address(tempHook).code);
        telXIncentiveHook = TELxIncentiveHook(hookAddress);
        positionRegistry.grantRole(positionRegistry.UNI_HOOK_ROLE(), address(telXIncentiveHook));
        vm.stopPrank();

        // where token1 is 2decimal TEL @ $0.006 and token0 is 6decimal USDC @ $1, sqrtPriceX96 = sqrt(0.015873) * 2^96
        uint160 sqrtPriceX96 = 9.9827e27; // 0.126 * 2^96
        // create TEL-USDC pool
        poolKey = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(address(tel)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        vm.expectEmit(true, true, true, true);
        emit IPoolManager.Initialize(poolKey.toId(), poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks, sqrtPriceX96, tick);
        assertEq(poolManager.initialize(poolKey, sqrtPriceX96), tick);

        // position registry must be informed of the TEL position
        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.TelPositionUpdated(poolKey.toId(), uint8(2));
        vm.prank(support);
        positionRegistry.updateTelPosition(poolKey.toId(), uint8(2));

        assertTrue(positionRegistry.validPool(poolKey.toId()));
    }

    function test_setUp() public view {
        assertEq(address(telXIncentiveHook.registry()), address(positionRegistry));
        Hooks.Permissions memory permissions = telXIncentiveHook.getHookPermissions();
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.afterSwap);

        assertEq(address(positionRegistry.telcoin()), address(tel));
        assertTrue(positionRegistry.hasRole(positionRegistry.UNI_HOOK_ROLE(), address(telXIncentiveHook)));
        assertTrue(positionRegistry.hasRole(positionRegistry.SUPPORT_ROLE(), support));
    }

    function testRevert_updateTelPosition() public {
        PoolKey memory zeroKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x0000000000000000000000000000000000000000),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });
        vm.expectRevert();
        vm.prank(holder);
        positionRegistry.updateTelPosition(zeroKey.toId(), uint8(0));
        assertFalse(positionRegistry.validPool(zeroKey.toId()));
    }

    function test_activeRouters() public {
        // v4 universal router on sepolia
        address router = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
        assertFalse(positionRegistry.activeRouters(router));
        assertFalse(positionRegistry.activeRouters(address(0x0)));

        vm.prank(support);
        positionRegistry.updateRegistry(router, true);

        assertTrue(positionRegistry.activeRouters(router));
    }

    function test_addOrUpdatePosition() public {
        uint256 tokenId = 1; // placeholder `ModifyLiquidityParams.salt`
        PoolId poolId = poolKey.toId();
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 1_000;
        uint128 amount0Max = 1_000_000;
        uint128 amount1Max = 1_000_000;
        uint256 deadline = block.timestamp + 10 minutes;

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, holder, '');
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.startPrank(holder);
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        IERC20(usdc).approve(address(permit2), amount0Max);
        tel.approve(address(permit2), amount1Max);
        permit2.call(abi.encodeWithSignature("approve(address,address,uint160,uint48)", usdc, address(positionManager), amount0Max, type(uint48).max));

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(tokenId, holder, poolId, tickLower, tickUpper, liquidity);
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();

        // (int24 lower, int24 upper, uint128 liq) = positionRegistry.getPosition(tokenId);
        // assertEq(lower, tickLower);
        // assertEq(upper, tickUpper);
        // assertEq(liq, liquidity);
    }

    // helper function to return a PoolId as bytes32 type
    function toIdBytes32(PoolId poolId) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId));
    }
}

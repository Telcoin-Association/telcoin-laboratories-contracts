// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {TELxIncentiveHook} from "contracts/telx/core/TELxIncentiveHook.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {IPositionManager} from "contracts/telx/interfaces/IPositionManager.sol";
import {TELxIncentiveHookDeployable} from "contracts/telx/test/MockTELxIncentiveHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PositionRegistryTest is
    PositionRegistry(IERC20(address(0)), IPoolManager(address(0)), IPositionManager(address(0))),
    Test
{
    using PoolIdLibrary for bytes32;

    string SEPOLIA_RPC_URL = vm.envString("SEPOLIA_RPC_URL");
    uint256 sepoliaFork;

    IERC20 public tel;
    PoolManager public poolMngr;
    PositionManager public positionMngr;
    PositionRegistry public positionRegistry;
    TELxIncentiveHook public telXIncentiveHook;
    TELxSubscriber public telXSubscriber;

    PoolKey public poolKey;

    IERC20 public usdc = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238); // sepolia USDC
    address public holder = 0x5d5d4d04B70BFe49ad7Aac8C4454536070dAf180;
    address public admin = address(0xc0ffee);
    address public support = address(0xdeadbeef);
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // address encoding the enabled afterAddLiquidity, beforeRemoveLiquidity, and afterSwap hooks
    address public hookAddress = 0x0000000000000000000000000000000000000a40;

    int24 tickSpacing = 60;

    function setUp() public {
        // sepolia fork setup
        sepoliaFork = vm.createFork(SEPOLIA_RPC_URL);
        vm.selectFork(sepoliaFork);
        tel = IERC20(0x92bc9f0D42A3194Df2C5AB55c3bbDD82e6Fb2F92); // tel clone on sepolia
        poolMngr = PoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        positionMngr = PositionManager(payable(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4));

        // create pool registry and hook on permissions-encoded address
        vm.startPrank(admin);
        positionRegistry =
            new PositionRegistry(tel, IPoolManager(address(poolMngr)), IPositionManager(address(positionMngr)));
        positionRegistry.grantRole(positionRegistry.SUPPORT_ROLE(), support);
        TELxIncentiveHook tempHook = new TELxIncentiveHookDeployable(
            IPoolManager(address(poolMngr)), address(positionMngr), IPositionRegistry(address(positionRegistry))
        );
        vm.etch(hookAddress, address(tempHook).code);
        telXIncentiveHook = TELxIncentiveHook(hookAddress);
        positionRegistry.grantRole(positionRegistry.UNI_HOOK_ROLE(), address(telXIncentiveHook));

        // setup subscriber with its role in position registry
        telXSubscriber = new TELxSubscriber(IPositionRegistry(address(positionRegistry)), address(positionMngr));
        positionRegistry.grantRole(positionRegistry.SUBSCRIBER_ROLE(), address(telXSubscriber));
        vm.stopPrank();

        // where token1 is 2decimal TEL @ $0.006 and token0 is 6decimal USDC @ $1, sqrtPriceX96 = sqrt(0.015873) * 2^96
        uint160 sqrtPriceX96 = 9.9827e27; // 0.126 * 2^96
        // create TEL-USDC pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(tel)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        vm.expectEmit(true, true, true, true);
        emit IPoolManager.Initialize(
            poolKey.toId(),
            poolKey.currency0,
            poolKey.currency1,
            poolKey.fee,
            poolKey.tickSpacing,
            poolKey.hooks,
            sqrtPriceX96,
            tick
        );
        assertEq(poolMngr.initialize(poolKey, sqrtPriceX96), tick);

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

    function test_mintPosition(int24 range, uint128 liquidity) public {
        // bound the range to prevent overflow/underflow
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        int24 maxRange = TickMath.MAX_TICK - currentTick;
        int24 minRange = currentTick - TickMath.MIN_TICK;
        int256 upperBound = minRange < maxRange ? minRange : maxRange;
        range = int24(bound(range, tickSpacing, upperBound));

        // bound the liquidity to avoid exceeding holder's onchain balance
        liquidity = uint128(bound(liquidity, 1, type(uint24).max));

        // slippage is beyond scope of this test
        uint128 amount0Max = type(uint128).max;
        uint128 amount1Max = type(uint128).max;

        // capture state before minting
        uint256 expectedTokenId = positionMngr.nextTokenId();
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);

        mintPosition(holder, currentTick, range, liquidity, amount0Max, amount1Max);

        // verify the added liquidity is reflected in the pool
        assertEq(positionMngr.nextTokenId(), expectedTokenId + 1);
        uint128 returnedLiquidity = positionMngr.getPositionLiquidity(expectedTokenId);
        assertEq(returnedLiquidity, liquidity);
        // ensure expected transfers have been made
        assertLt(usdc.balanceOf(holder), usdcBefore);
        assertLt(tel.balanceOf(holder), telBefore);

        // position has been added to unsubscribed token ID storage mapping
        assertTrue(positionRegistry.getUnsubscribedTokenIdsByProvider(holder).length == 1);
        // LP's token ID is not yet subscribed
        uint256[] memory tokenIds = positionRegistry.getTokenIdsByProvider(holder);
        assertTrue(tokenIds.length == 0);
    }

    function test_subscribe() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        int24 range = 120;
        uint128 liquidity = 1_000_000;
        uint128 amount0Max = 1_000_000;
        uint128 amount1Max = 1_000_000;

        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, amount0Max, amount1Max);

        // expect PositionUpdated event, which is emitted at subscribe time, not mint time
        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(tokenId, holder, poolKey.toId(), tickLower, tickUpper, liquidity);
        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // token ID position has been graduated from `positionRegistry` unsubscribed storage
        assertTrue(positionRegistry.getUnsubscribedTokenIdsByProvider(holder).length == 0);
        // to being correctly registered in its subscribed storage
        uint256[] memory tokenIds = positionRegistry.getTokenIdsByProvider(holder);
        assertTrue(tokenIds.length == 1);
        assertEq(tokenIds[0], tokenId);
        // assert position values are as expected
        PositionRegistry.Position memory position = positionRegistry.getPosition(tokenId);
        assertEq(position.provider, holder);
        assertEq(position.liquidity, liquidity);
        assertEq(position.tickLower, tickLower);
        assertEq(position.tickUpper, tickUpper);
        bytes32 id = PoolId.unwrap(position.poolId);
        assertEq(id, keccak256(abi.encode(poolKey)));

        // ensure voting weight is computed correctly
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 96);
        uint256 expectedWeight = amount1 + FullMath.mulDiv(amount0, priceX96, 2 ** 96);
        uint256 votingWeight = positionRegistry.computeVotingWeight(tokenId);
        assertEq(votingWeight, expectedWeight);
    }

    function mintPosition(
        address lp,
        int24 currentTick,
        int24 range,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (int24 tickLower, int24 tickUpper) {
        tickLower = (currentTick - range) / tickSpacing * tickSpacing;
        tickUpper = (currentTick + range) / tickSpacing * tickSpacing;

        vm.startPrank(lp);
        approveTokens(usdc, amount0Max);
        approveTokens(tel, amount1Max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // MINT_POSITION
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, lp, "");
        // SETTLE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    // function increaseLiquidity(int24 range, uint128 additionalLiquidity, uint128 amount0Max, uint128 amount1Max, uint256 deadline) internal {
    //     (int24 currentTick,,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
    //     int24 tickLower = (currentTick - range) / tickSpacing * tickSpacing;
    //     int24 tickUpper = (currentTick + range) / tickSpacing * tickSpacing;

    //     vm.startPrank(holder);
    //     approveTokens(usdc, amount0Max);
    //     approveTokens(tel, amount1Max);

    //     positionMngr.modifyLiquidities(
    //         abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY)),
    //         abi.encode(poolKey, tickLower, tickUpper, tokenId, additionalLiquidity, amount0Max, amount1Max, holder, ''),
    //         deadline
    //     );
    //     vm.stopPrank();
    // }

    // function decreaseLiquidity(int24 range, uint128 liquidityToRemove, uint128 amount0Max, uint128 amount1Max, uint256 deadline) internal {
    //     (int24 currentTick,,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
    //     int24 tickLower = (currentTick - range) / tickSpacing * tickSpacing;
    //     int24 tickUpper = (currentTick + range) / tickSpacing * tickSpacing;

    //     vm.startPrank(holder);
    //     approveTokens(usdc, amount0Max);
    //     approveTokens(tel, amount1Max);

    //     positionMngr.modifyLiquidities(
    //         abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY)),
    //         abi.encode(poolKey, tickLower, tickUpper, tokenId, liquidityToRemove, amount0Max, amount1Max, holder, ''),
    //         deadline
    //     );
    //     vm.stopPrank();
    // }

    // approves permit2 address and positionMngr to spend `amount` of `token`
    function approveTokens(IERC20 token, uint128 amount) internal {
        token.approve(permit2, amount);
        (bool r,) = permit2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)", token, address(positionMngr), amount, type(uint48).max
            )
        );
        require(r, "Token approval failed");
    }
}

/**
 * function test_increaseLiquidity()
 *     - **Objective:** Test the ability to increase liquidity for an existing position.
 *     - **Checkpoints:**
 *         - Confirm the increased liquidity in the pool.
 *         - Verify the positionRegistry reflects the updated position.
 *         - Check if the `beforeAddLiquidity` hook behaves as expected.
 *
 *         // IPositionRegistry.Position memory noPosition = positionRegistry.getPosition(tokenId);
 *         // assertEq(noPosition.provider, address(0));
 *         // assertEq(noPosition.liquidity, 0);
 *         // assertEq(noPosition.tickLower, 0);
 *         // assertEq(noPosition.tickUpper, 0);
 *
 *     function test_decreaseLiquidity()
 *     - **Objective:** Test reduction of liquidity from an existing position.
 *     - **Checkpoints:**
 *         - Ensure liquidity decrease is accurately reflected.
 *         - Check that the positionRegistry updates the position correctly.
 *         - Validate the `beforeRemoveLiquidity` hook's behavior.
 *
 *     function test_swap()
 *     - **Objective:** Simulate swaps and ensure the hook behaves correctly during and after swaps.
 *     - **Checkpoints:**
 *         - Verify swap execution and resulting balances.
 *         - Confirm the `afterSwap` hook's impact.
 *         - Ensure the swap affects the pool state as expected.
 *
 *     function test_burnPosition()
 *     - **Objective:** Ensure a position can be fully withdrawn and removed.
 *     - **Checkpoints:**
 *         - Confirm the position is removed from the pool.
 *         - Check if the position is deregistered from `positionRegistry`.
 *         - Ensure all balances are settled correctly.
 */

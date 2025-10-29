// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {TELxIncentiveHook} from "contracts/telx/core/TELxIncentiveHook.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {TELxIncentiveHookDeployable} from "contracts/telx/test/MockTELxIncentiveHook.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager, PositionInfo} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";

contract PositionRegistryTest is
    PositionRegistry(IERC20(address(0)), IPoolManager(address(0)), IPositionManager(address(0)), StateView(address(0)), address(0)),
    Test
{
    using PoolIdLibrary for bytes32;

    string SEPOLIA_RPC_URL = vm.envString("SEPOLIA_RPC_URL");
    uint256 sepoliaFork;

    IERC20 public tel;
    PoolManager public poolMngr;
    PositionManager public positionMngr;
    UniversalRouter public router;
    StateView public st8View;
    PositionRegistry public positionRegistry;
    TELxIncentiveHook public telXIncentiveHook;
    TELxSubscriber public telXSubscriber;

    PoolKey public poolKey;

    IERC20 public usdc = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238); // sepolia USDC
    address public holder = 0x5d5d4d04B70BFe49ad7Aac8C4454536070dAf180;
    address public admin = address(0xc0ffee);
    address public support = address(0xdeadbeef);
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // address encoding the enabled beforeInitialize, afterAddLiquidity, and beforeRemoveLiquidity hooks
    address public hookAddress = 0x0000000000000000000000000000000000002500;
    
    int24 tickSpacing = 60;
    uint256 constant V4_SWAP = 0x10;

    function setUp() public {
        // sepolia fork setup
        sepoliaFork = vm.createFork(SEPOLIA_RPC_URL);
        vm.selectFork(sepoliaFork);
        tel = IERC20(0x92bc9f0D42A3194Df2C5AB55c3bbDD82e6Fb2F92); // tel clone on sepolia
        poolMngr = PoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        // for debugging: new PoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        positionMngr = PositionManager(payable(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4));
        // for debugging: new PositionManager(IPoolManager(address(poolMngr)), IAllowanceTransfer(permit2), type(uint128).max, IPositionDescriptor(0x12570561f184C7Bf46C7EcA7D937db49861C7e61), IWETH9(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14));
        router = UniversalRouter(0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b);
        st8View = StateView(0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C);

        // create pool registry and hook on permissions-encoded address
        vm.startPrank(admin);
        positionRegistry =
            new PositionRegistry(tel, IPoolManager(address(poolMngr)), IPositionManager(address(positionMngr)), StateView(address(st8View)), admin);
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

        // position registry should correctly be informed of the currency position
        vm.expectEmit(address(positionRegistry));
        emit IPositionRegistry.PoolInitialized(poolKey);
        vm.expectEmit(address(poolMngr));
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
        vm.prank(admin);
        int24 returnedTick = poolMngr.initialize(poolKey, sqrtPriceX96);
        assertEq(returnedTick, tick);

        assertTrue(positionRegistry.validPool(poolKey.toId()));
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing, IHooks hooks) = positionRegistry.initializedPoolKeys(poolKey.toId());
        assertEq(Currency.unwrap(currency0), Currency.unwrap(poolKey.currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(poolKey.currency1));
        assertEq(fee, poolKey.fee);
        assertEq(spacing, poolKey.tickSpacing);
        assertEq(address(hooks), address(poolKey.hooks));
    }

    function test_setUp() public view {
        assertEq(address(telXIncentiveHook.registry()), address(positionRegistry));
        Hooks.Permissions memory permissions = telXIncentiveHook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterAddLiquidity);
        assertTrue(permissions.afterRemoveLiquidity);

        assertEq(address(positionRegistry.telcoin()), address(tel));
        assertTrue(positionRegistry.hasRole(positionRegistry.UNI_HOOK_ROLE(), address(telXIncentiveHook)));
        assertTrue(positionRegistry.hasRole(positionRegistry.SUPPORT_ROLE(), support));
    }

    function test_initialize() public {
        PoolKey memory dummyKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x1000000000000000000000000000000000000000),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        // only admin can call initialize
        vm.expectRevert();
        vm.prank(holder);
        poolMngr.initialize(dummyKey, uint160(1e27));
        assertFalse(positionRegistry.validPool(dummyKey.toId()));

        // success case
        vm.prank(admin);
        poolMngr.initialize(dummyKey, uint160(1e27));
    }

    function testRevert_alreadyInitialized() public {        
        assertTrue(positionRegistry.validPool(poolKey.toId()));

        // revert for already initialized pools
        vm.expectRevert();
        vm.prank(admin);
        poolMngr.initialize(poolKey, uint160(1e27));
        
        // initialized pool unchanged
        assertTrue(positionRegistry.validPool(poolKey.toId()));
    }

    function test_activeRouters() public {
        assertFalse(positionRegistry.isActiveRouter(address(router)));
        assertFalse(positionRegistry.isActiveRouter(address(0x0)));

        vm.prank(support);
        positionRegistry.updateRouter(address(router), true);

        assertTrue(positionRegistry.isActiveRouter(address(router)));
    }

    function test_mintPosition(int24 range, uint128 liquidity) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        // capture state before minting
        uint256 expectedTokenId = positionMngr.nextTokenId();
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);

        // slippage is beyond scope of this test so amount0Max and amount1Max are set to `type(uint128).max`
        mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        // verify the added liquidity is reflected in the pool
        assertEq(positionMngr.nextTokenId(), expectedTokenId + 1);
        uint128 returnedLiquidity = positionMngr.getPositionLiquidity(expectedTokenId);
        assertEq(returnedLiquidity, liquidity);
        // ensure expected transfers have been made
        assertLt(usdc.balanceOf(holder), usdcBefore);
        assertLt(tel.balanceOf(holder), telBefore);

        // position has been picked up
        assertEq(positionRegistry.getLiquidityLast(expectedTokenId), returnedLiquidity);
        // LP's token ID is not yet subscribed
        uint256[] memory tokenIds = positionRegistry.getSubscriptions(holder);
        assertTrue(tokenIds.length == 0);
    }

    function test_subscribe(int24 range, uint128 liquidity) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        uint256 tokenId = positionMngr.nextTokenId();
        // slippage is beyond scope of this test so amount0Max and amount1Max are set to `type(uint128).max`
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        // expect PositionUpdated event, which is emitted at subscribe time, not mint time
        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.Subscribed(tokenId, holder);
        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // to being correctly registered in its subscribed storage
        uint256[] memory tokenIds = positionRegistry.getSubscriptions(holder);
        assertTrue(tokenIds.length == 1);
        assertEq(tokenIds[0], tokenId);
        address[] memory subscribed = positionRegistry.getSubscribed();
        assertEq(subscribed.length, 1);
        assertEq(subscribed[0], holder);
        // assert position values are as expected
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) = positionRegistry.getPosition(tokenId);
        assertEq(owner, holder);
        assertEq(tickLower, returnedTickLower);
        assertEq(tickUpper, returnedTickUpper);
        assertEq(PoolId.unwrap(poolId), keccak256(abi.encode(poolKey)));
        uint128 liquidityLast = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityLast, liquidity);
    }

    function test_increaseLiquidity(int24 range, uint128 liquidity, uint128 additionalLiquidity) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);
        // bound sum of liquidity and additionalLiquidity to avoid exceeding holder's onchain balance (3k USDC)
        if (uint256(liquidity) + uint256(additionalLiquidity) > type(uint24).max) {
            additionalLiquidity = type(uint24).max - liquidity;
        }

        // mint initial position
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, 1000, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // capture state before updating liquidity position
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);
        uint128 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(tokenId, holder, poolKey.toId(), tickLower, tickUpper, liquidityBefore + additionalLiquidity);
        increaseLiquidity(holder, tokenId, additionalLiquidity, type(uint128).max, type(uint128).max);

        // confirm the increased liquidity in the pool
        uint256 returnedLiquidity = positionMngr.getPositionLiquidity(tokenId);
        assertEq(returnedLiquidity, liquidityBefore + additionalLiquidity);
        // ensure expected transfers have been made (includes `additionalLiquidity == 0`)
        assertLe(usdc.balanceOf(holder), usdcBefore);
        assertLe(tel.balanceOf(holder), telBefore);

        // verify the positionRegistry reflects the updated position
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) = positionRegistry.getPosition(tokenId);
        assertEq(owner, holder);
        assertEq(tickLower, returnedTickLower);
        assertEq(tickUpper, returnedTickUpper);
        assertEq(PoolId.unwrap(poolId), keccak256(abi.encode(poolKey)));
        uint128 liquidityLast = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityLast, returnedLiquidity);
    }

    function test_decreaseLiquidity(int24 range, uint128 liquidity, uint128 liquidityToRemove) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);
        // bound liquidityToRemove to be no more than the initial liquidity
        liquidityToRemove = uint128(bound(liquidityToRemove, 0, liquidity));

        // mint initial position
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // capture state before updating liquidity position
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);
        uint128 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(tokenId, holder, poolKey.toId(), tickLower, tickUpper, liquidityBefore - liquidityToRemove);
        decreaseLiquidity(holder, tokenId, liquidityToRemove, 0, 0);

        // confirm the decreased liquidity is accurately reflected in the pool
        uint256 returnedLiquidity = positionMngr.getPositionLiquidity(tokenId);
        assertEq(returnedLiquidity, liquidityBefore - liquidityToRemove);
        // ensure expected transfers to lp have been made (includes `liquidityToRemove == 0`)
        assertGe(usdc.balanceOf(holder), usdcBefore);
        assertGe(tel.balanceOf(holder), telBefore);

        // verify the positionRegistry reflects the updated position
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) = positionRegistry.getPosition(tokenId);
        assertEq(owner, holder);
        assertEq(tickLower, returnedTickLower);
        assertEq(tickUpper, returnedTickUpper);
        assertEq(PoolId.unwrap(poolId), keccak256(abi.encode(poolKey)));
        uint128 liquidityLast = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityLast, returnedLiquidity);
    }

    // note that BURN_POSITION uses decreaseLiquidity and ERC20::_burn so unsubscription flow is not invoked
    function test_burnPosition(int24 range, uint128 liquidity) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        // capture state before burning liquidity position
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);

        // mint initial position
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.Unsubscribed(tokenId, holder);
        burnPosition(holder, tokenId, 0, 0);

        // confirm the decreased liquidity is accurately reflected in the pool
        uint256 noLiquidity = positionMngr.getPositionLiquidity(tokenId);
        assertEq(noLiquidity, 0);
        // ensure expected transfers to restore lp balance have been made
        assertApproxEqAbs(usdc.balanceOf(holder), usdcBefore, 1, "balance deviation above v4 rounding precision");
        assertApproxEqAbs(tel.balanceOf(holder), telBefore, 1, "balance deviation above v4 rounding precision");

        // verify the positionRegistry reflects the burned position
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);
        assertEq(positionRegistry.getLiquidityLast(tokenId), 0);
        assertEq(returnedTickLower, tickLower);
        assertEq(returnedTickUpper, tickUpper);
        assertEq(PoolId.unwrap(poolId), keccak256(abi.encode(poolKey)));

        // sanity check unsubscribed and subscribed storage mappings
        assertTrue(positionRegistry.getSubscriptions(holder).length == 0);
    }

    // note that position transfers use `PositionManager::transferFrom`, triggering unsubscription flow unlike burns
    function test_transferPosition(int24 range, uint128 liquidity) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        // mint initial position
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        uint256 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.prank(holder);
        (bool r,) = address(positionMngr).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, support, tokenId));
        require(r);

        // liquidity should be unchanged despite owner change
        uint256 liquidityAfter = positionMngr.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, liquidityBefore);

        // after transfer position should remain unchanged
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) = positionRegistry.getPosition(tokenId);
        assertEq(owner, holder);
        assertEq(positionRegistry.getLiquidityLast(tokenId), liquidityAfter);
        assertEq(tickLower, returnedTickLower);
        assertEq(tickUpper, returnedTickUpper);
        assertEq(PoolId.unwrap(poolId), keccak256(abi.encode(poolKey)));

        // transfer should remove existing position from subscription
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
        assertEq(positionRegistry.getSubscribed().length, 0);
        // transferred positions should not be subscribed for new owner
        assertTrue(positionRegistry.getSubscriptions(support).length == 0);

        vm.prank(support);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        // after subscribing the position should be reregistered
        assertTrue(positionRegistry.getSubscriptions(support).length == 1);
        assertTrue(positionRegistry.getSubscribed().length == 1);
        assertEq(positionRegistry.subscribed(0), support);
    }

    function test_swap(int24 range, uint128 liquidity, uint128 amountIn, bool zeroForOne) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        // mint initial position so there is liquidity in the pool
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) = mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);
        
        // identify amountIn bound based on not exceeding available liquidity
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 liquidityBound = calculateLiquidityBound(liquidity, sqrtPriceX96, tickLower, tickUpper, zeroForOne);

        // identify amountIn bound based on not exceeding lesser of liquidityBound or holder balance
        Currency inputCurrency;
        (inputCurrency, amountIn) = boundAmountInByBalance(holder, amountIn, liquidityBound, zeroForOne);

        // subscribe position and approve router (required for swaps)
        vm.startPrank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        Permit2(permit2).approve(Currency.unwrap(inputCurrency), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // add v4 universal router to position registry
        vm.prank(support);
        positionRegistry.updateRouter(address(router), true);

        uint256 initialInputBal = inputCurrency.balanceOf(holder);
        (, Currency outputCurrency) = inputAndOutputCurrencies(zeroForOne);
        uint256 initialOutputBal = outputCurrency.balanceOf(holder);

        uint256 amountOut = swapTokensExactInSingle(holder, amountIn, 0, zeroForOne);
        
        // verify swap execution and resulting balances
        assertEq(inputCurrency.balanceOf(holder), initialInputBal - amountIn);
        assertEq(outputCurrency.balanceOf(holder), initialOutputBal + amountOut);
    }

    /**
     * UTILS
     */

    // performs approvals to permit2 and positionMngr so it can be skipped later
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
        approveTokensForMint(usdc, amount0Max);
        approveTokensForMint(tel, amount1Max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // MINT_POSITION
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, lp, "");
        // SETTLE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function burnPosition(
        address lp,
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // BURN_POSITION
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, "");
        // TAKE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);
        vm.startPrank(lp);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    // assumes approvals are already set
    function increaseLiquidity(address lp, uint256 tokenId, uint128 additionalLiquidity, uint128 amount0Max, uint128 amount1Max) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // INCREASE_LIQUIDITY
        params[0] = abi.encode(tokenId, additionalLiquidity, amount0Max, amount1Max, "");
        // SETTLE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        
        vm.startPrank(lp);
        positionMngr.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 1 minutes
        );
        vm.stopPrank();
    }

    // assumes approvals are already set
    function decreaseLiquidity(address lp, uint256 tokenId, uint128 liquidityToRemove, uint128 amount0Min, uint128 amount1Min) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // DECREASE_LIQUIDITY
        params[0] = abi.encode(tokenId, liquidityToRemove, amount0Min, amount1Min, "");
        // TAKE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);

        vm.startPrank(lp);
        positionMngr.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 1 minutes
        );
        vm.stopPrank();
    }

    // pre-mint LP approvals to permit2 address and positionMngr to spend `amount` of `token`
    function approveTokensForMint(IERC20 token, uint128 amount) internal {
        token.approve(permit2, amount);
        Permit2(permit2).approve(address(token), address(positionMngr), type(uint160).max, type(uint48).max);
    }

    // assumes previous approval to permit2::approve for router address on behalf of swapper 
    function swapTokensExactInSingle(
        address swapper,
        uint128 amountIn,
        uint128 minAmountOut,
        bool zeroForOne
    ) public returns (uint256 amountOut) {
        (Currency inputCurrency, Currency outputCurrency) = inputAndOutputCurrencies(zeroForOne);

        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        // SWAP_EXACT_IN_SINGLE
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: ""
            })
        );
        // SETTLE_ALL
        params[1] = abi.encode(inputCurrency, amountIn);
        // TAKE_ALL
        params[2] = abi.encode(outputCurrency, minAmountOut);

        // combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 initialBal = outputCurrency.balanceOf(swapper);

        vm.startPrank(swapper);
        router.execute(commands, inputs, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 finalBal = outputCurrency.balanceOf(swapper);

        return finalBal - initialBal;
    }

    function inputAndOutputCurrencies(bool zeroForOne) internal view returns (Currency inputCurrency, Currency outputCurrency) {
        if (zeroForOne) {
            inputCurrency = poolKey.currency0;
            outputCurrency = poolKey.currency1;
        } else {
            inputCurrency = poolKey.currency1;
            outputCurrency = poolKey.currency0;
        }
    }

    function boundRange(int24 currentTick, int24 range) internal view returns (int24) {
        int24 maxRange = TickMath.MAX_TICK - currentTick;
        int24 minRange = currentTick - TickMath.MIN_TICK;
        int256 upperBound = minRange < maxRange ? minRange : maxRange;
        return int24(bound(range, tickSpacing, upperBound));
    }

    function boundLiquidity(uint128 liquidity) internal pure returns (uint128) {
        // bound the liquidity to avoid exceeding holder's onchain balance (3k USDC)
        return uint128(bound(liquidity, 1, type(uint24).max));
    }

    // calculates the max swappable amount based on available liquidity
    function calculateLiquidityBound(uint128 liquidity, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, bool zeroForOne) internal pure returns (uint256) {        
        // calculate the price which exceeds the position's range
        uint160 sqrtPriceLimitX96 = zeroForOne 
            ? TickMath.getSqrtPriceAtTick(tickLower) // downward bound
            : TickMath.getSqrtPriceAtTick(tickUpper); // upward bound
        
        // calculate max swappable amount based on liquidity
        uint256 liquidityBoundAmountIn;
        if (zeroForOne) {
            // swapping token0 for token1, price decreases
            liquidityBoundAmountIn = SqrtPriceMath.getAmount0Delta(
                sqrtPriceLimitX96,
                sqrtPriceX96,
                liquidity,
                true // roundUp for input amount
            );
        } else {
            // swapping token1 for token0, price increases
            liquidityBoundAmountIn = SqrtPriceMath.getAmount1Delta(
                sqrtPriceX96,
                sqrtPriceLimitX96,
                liquidity,
                true // roundUp for input amount
            );
        }

        return liquidityBoundAmountIn;
    }

    function boundAmountInByBalance(address lp, uint128 amountIn, uint256 liquidityBound, bool zeroForOne) internal view returns (Currency, uint128) {
        // identify amountIn bound based on not exceeding holder balance
        (Currency inputCurrency, ) = inputAndOutputCurrencies(zeroForOne);
        uint256 swappableBalance = inputCurrency.balanceOf(lp);
        uint256 finalBound = swappableBalance < liquidityBound ? swappableBalance : liquidityBound;
        
        // bound amountIn to be nonzero and no more than the lesser of the two bounds
        amountIn = uint128(bound(amountIn, 1, finalBound));

        return (inputCurrency, amountIn);
    }
}

// interface used to interact with the Uniswap V4 Universal Router without requiring extra dependencies
interface UniversalRouter {
    function execute(
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline
    ) external payable;
}

interface Permit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
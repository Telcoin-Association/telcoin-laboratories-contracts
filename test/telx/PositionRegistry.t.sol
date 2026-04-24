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
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";

/// @title PositionRegistryTest
/// @notice Sepolia-fork unit tests for PositionRegistry — fresh deploys with full branch coverage.
///         Tests the LP subscription registry: pool config, weight rules, MAX_SUBSCRIBED /
///         MAX_SUBSCRIPTIONS guards, and reward attribution math. Inherits PositionRegistry
///         directly (with sentinel-zero constructor args) so internal helpers are testable.
///         Companion file: PositionRegistry.polygon.t.sol (read-only production state checks).
contract PositionRegistryTest is
    PositionRegistry(
        IERC20(address(0)), IPoolManager(address(0)), IPositionManager(address(0)), StateView(address(0)), address(0)
    ),
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
        positionRegistry = new PositionRegistry(
            tel,
            IPoolManager(address(poolMngr)),
            IPositionManager(address(positionMngr)),
            StateView(address(st8View)),
            admin
        );
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
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing, IHooks hooks) =
            positionRegistry.initializedPoolKeys(poolKey.toId());
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
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

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
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) =
            positionRegistry.getPosition(tokenId);
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
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, 1000, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // capture state before updating liquidity position
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);
        uint128 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(
            tokenId, holder, poolKey.toId(), tickLower, tickUpper, liquidityBefore + additionalLiquidity
        );
        increaseLiquidity(holder, tokenId, additionalLiquidity, type(uint128).max, type(uint128).max);

        // confirm the increased liquidity in the pool
        uint256 returnedLiquidity = positionMngr.getPositionLiquidity(tokenId);
        assertEq(returnedLiquidity, liquidityBefore + additionalLiquidity);
        // ensure expected transfers have been made (includes `additionalLiquidity == 0`)
        assertLe(usdc.balanceOf(holder), usdcBefore);
        assertLe(tel.balanceOf(holder), telBefore);

        // verify the positionRegistry reflects the updated position
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) =
            positionRegistry.getPosition(tokenId);
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
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // capture state before updating liquidity position
        uint256 usdcBefore = usdc.balanceOf(holder);
        uint256 telBefore = tel.balanceOf(holder);
        uint128 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.PositionUpdated(
            tokenId, holder, poolKey.toId(), tickLower, tickUpper, liquidityBefore - liquidityToRemove
        );
        decreaseLiquidity(holder, tokenId, liquidityToRemove, 0, 0);

        // confirm the decreased liquidity is accurately reflected in the pool
        uint256 returnedLiquidity = positionMngr.getPositionLiquidity(tokenId);
        assertEq(returnedLiquidity, liquidityBefore - liquidityToRemove);
        // ensure expected transfers to lp have been made (includes `liquidityToRemove == 0`)
        assertGe(usdc.balanceOf(holder), usdcBefore);
        assertGe(tel.balanceOf(holder), telBefore);

        // verify the positionRegistry reflects the updated position
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) =
            positionRegistry.getPosition(tokenId);
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
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

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
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) =
            positionRegistry.getPosition(tokenId);
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
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

        vm.prank(holder); // LP must be the one to call subscribe
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        uint256 liquidityBefore = positionMngr.getPositionLiquidity(tokenId);

        vm.prank(holder);
        (bool r,) = address(positionMngr).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, support, tokenId)
        );
        require(r);

        // liquidity should be unchanged despite owner change
        uint256 liquidityAfter = positionMngr.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, liquidityBefore);

        // after transfer position should remain unchanged
        (address owner, PoolId poolId, int24 returnedTickLower, int24 returnedTickUpper) =
            positionRegistry.getPosition(tokenId);
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
        assertEq(positionRegistry.getSubscribed()[0], support);
    }

    function test_swap(int24 range, uint128 liquidity, uint128 amountIn, bool zeroForOne) public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        range = boundRange(currentTick, range);
        liquidity = boundLiquidity(liquidity);

        // mint initial position so there is liquidity in the pool
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

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

    // -----------
    // ADD REWARDS
    // -----------

    function test_addRewards_happyPath() public {
        address[] memory lps = new address[](2);
        lps[0] = holder;
        lps[1] = support;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e18;
        amounts[1] = 500e18;
        uint256 totalAmount = 1000e18;

        // Fund the support role with TEL and approve positionRegistry
        deal(address(tel), support, totalAmount);
        vm.prank(support);
        tel.approve(address(positionRegistry), totalAmount);

        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, totalAmount);

        assertEq(positionRegistry.getUnclaimedRewards(holder), 500e18);
        assertEq(positionRegistry.getUnclaimedRewards(support), 500e18);
    }

    function test_addRewards_cumulative() public {
        address[] memory lps = new address[](1);
        lps[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        deal(address(tel), support, 200e18);
        vm.startPrank(support);
        tel.approve(address(positionRegistry), 200e18);

        positionRegistry.addRewards(lps, amounts, 100e18);
        assertEq(positionRegistry.getUnclaimedRewards(holder), 100e18);

        positionRegistry.addRewards(lps, amounts, 100e18);
        assertEq(positionRegistry.getUnclaimedRewards(holder), 200e18);
        vm.stopPrank();
    }

    function testRevert_addRewards_arityMismatch() public {
        address[] memory lps = new address[](2);
        lps[0] = holder;
        lps[1] = support;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.expectRevert(IPositionRegistry.ArityMismatch.selector);
        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, 1000e18);
    }

    function testRevert_addRewards_amountMismatch() public {
        address[] memory lps = new address[](2);
        lps[0] = holder;
        lps[1] = support;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e18;
        amounts[1] = 600e18; // total 1100, but we pass 1000

        deal(address(tel), support, 1000e18);
        vm.prank(support);
        tel.approve(address(positionRegistry), 1000e18);

        vm.expectRevert(IPositionRegistry.AmountMismatch.selector);
        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, 1000e18);
    }

    function testRevert_addRewards_onlySupportRole() public {
        address[] memory lps = new address[](1);
        lps[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.expectRevert();
        vm.prank(holder);
        positionRegistry.addRewards(lps, amounts, 100e18);
    }

    // -----
    // CLAIM
    // -----

    function test_claim_happyPath() public {
        // Add rewards first
        address[] memory lps = new address[](1);
        lps[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        deal(address(tel), support, 500e18);
        vm.prank(support);
        tel.approve(address(positionRegistry), 500e18);
        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, 500e18);

        uint256 holderBalBefore = tel.balanceOf(holder);

        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.RewardsClaimed(holder, 500e18);

        vm.prank(holder);
        positionRegistry.claim();

        assertEq(tel.balanceOf(holder), holderBalBefore + 500e18);
        assertEq(positionRegistry.getUnclaimedRewards(holder), 0);
    }

    function testRevert_claim_noRewards() public {
        vm.expectRevert(IPositionRegistry.NoClaimableRewards.selector);
        vm.prank(holder);
        positionRegistry.claim();
    }

    function test_claim_cannotDoubleClaim() public {
        address[] memory lps = new address[](1);
        lps[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        deal(address(tel), support, 500e18);
        vm.prank(support);
        tel.approve(address(positionRegistry), 500e18);
        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, 500e18);

        vm.prank(holder);
        positionRegistry.claim();

        vm.expectRevert(IPositionRegistry.NoClaimableRewards.selector);
        vm.prank(holder);
        positionRegistry.claim();
    }

    // ---------------------
    // GET UNCLAIMED REWARDS
    // ---------------------

    function test_getUnclaimedRewards_initiallyZero() public view {
        assertEq(positionRegistry.getUnclaimedRewards(holder), 0);
    }

    function test_getUnclaimedRewards_afterAddRewards() public {
        address[] memory lps = new address[](1);
        lps[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 123e18;

        deal(address(tel), support, 123e18);
        vm.prank(support);
        tel.approve(address(positionRegistry), 123e18);
        vm.prank(support);
        positionRegistry.addRewards(lps, amounts, 123e18);

        assertEq(positionRegistry.getUnclaimedRewards(holder), 123e18);
    }

    // -----------------
    // CONFIGURE WEIGHTS
    // -----------------

    function test_configureWeights_happyPath() public {
        vm.expectEmit(true, true, true, true);
        emit IPositionRegistry.WeightsConfigured(86_400, 1000, 3000, 6000);

        vm.prank(support);
        positionRegistry.configureWeights(86_400, 1000, 3000, 6000);

        assertEq(positionRegistry.MIN_PASSIVE_LIFETIME(), 86_400);
        assertEq(positionRegistry.JIT_WEIGHT(), 1000);
        assertEq(positionRegistry.ACTIVE_WEIGHT(), 3000);
        assertEq(positionRegistry.PASSIVE_WEIGHT(), 6000);
    }

    function test_configureWeights_allPassive() public {
        vm.prank(support);
        positionRegistry.configureWeights(100_000, 0, 0, 10_000);

        assertEq(positionRegistry.JIT_WEIGHT(), 0);
        assertEq(positionRegistry.ACTIVE_WEIGHT(), 0);
        assertEq(positionRegistry.PASSIVE_WEIGHT(), 10_000);
    }

    function testRevert_configureWeights_weightsTooHigh() public {
        vm.expectRevert("PositionRegistry: Weights must be between 0 and 10000 bps");
        vm.prank(support);
        positionRegistry.configureWeights(100, 10_001, 0, 0);
    }

    function testRevert_configureWeights_weightsDontTotal100() public {
        vm.expectRevert("PositionRegistry: Weights must total 100%");
        vm.prank(support);
        positionRegistry.configureWeights(100, 1000, 2000, 3000); // total 6000 != 10000
    }

    function testRevert_configureWeights_onlySupportRole() public {
        vm.expectRevert();
        vm.prank(holder);
        positionRegistry.configureWeights(100, 0, 2500, 7500);
    }

    // ------------
    // ERC20 RESCUE
    // ------------

    function test_erc20Rescue_happyPath() public {
        deal(address(tel), address(positionRegistry), 1000e18);
        uint256 holderTelBefore = tel.balanceOf(holder);

        vm.prank(support);
        positionRegistry.erc20Rescue(tel, holder, 500e18);

        assertEq(tel.balanceOf(holder), holderTelBefore + 500e18);
        assertEq(tel.balanceOf(address(positionRegistry)), 500e18);
    }

    function test_erc20Rescue_fullBalance() public {
        deal(address(usdc), address(positionRegistry), 5000e6);
        uint256 holderUsdcBefore = usdc.balanceOf(holder);

        vm.prank(support);
        positionRegistry.erc20Rescue(usdc, holder, 5000e6);

        assertEq(usdc.balanceOf(holder), holderUsdcBefore + 5000e6);
        assertEq(usdc.balanceOf(address(positionRegistry)), 0);
    }

    function testRevert_erc20Rescue_onlySupportRole() public {
        deal(address(tel), address(positionRegistry), 1000e18);

        vm.expectRevert();
        vm.prank(holder);
        positionRegistry.erc20Rescue(tel, holder, 500e18);
    }

    // ------------------------------
    // SUBSCRIPTION THRESHOLD REMOVAL
    // ------------------------------

    function test_subscriptionThresholdRemoval() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // Mint a large position to create a baseline of liquidity
        mintPosition(holder, currentTick, 60, type(uint24).max, type(uint128).max, type(uint128).max);

        // Now mint a tiny position from another user
        address tinyLp = address(0xbeef);
        vm.startPrank(holder);
        tel.transfer(tinyLp, tel.balanceOf(holder) / 2);
        usdc.transfer(tinyLp, usdc.balanceOf(holder) / 2);
        vm.stopPrank();

        uint256 tinyTokenId = positionMngr.nextTokenId();
        mintPosition(tinyLp, currentTick, 60, 1, type(uint128).max, type(uint128).max);

        // The tiny position might not meet the subscription threshold if pool is large enough
        // Try to subscribe - may revert with LiquidityBelowThreshold if pool is big enough
        // This is a behavior test: if the pool has enough total liquidity, tiny positions get rejected
        uint128 tinyLiquidity = positionRegistry.getLiquidityLast(tinyTokenId);
        uint128 totalLiquidity = st8View.getLiquidity(poolKey.toId());

        if (totalLiquidity > 10_000 && tinyLiquidity < totalLiquidity / 10_000) {
            // PositionManager wraps subscriber reverts, so use generic expectRevert
            vm.expectRevert();
            vm.prank(tinyLp);
            positionMngr.subscribe(tinyTokenId, address(telXSubscriber), "");
        }
    }

    // --------------
    // NEGATIVE TESTS
    // --------------

    function test_invalidPool_validPool() public view {
        // The setUp pool should be valid
        assertTrue(positionRegistry.validPool(poolKey.toId()));

        // A random poolId should not be valid
        PoolId randomId = PoolId.wrap(keccak256("random"));
        assertFalse(positionRegistry.validPool(randomId));
    }

    function test_getPositionDetails() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        (int24 tickLower, int24 tickUpper) =
            mintPosition(holder, currentTick, 120, 5000, type(uint128).max, type(uint128).max);

        IPositionRegistry.PositionDetails memory details = positionRegistry.getPositionDetails(tokenId);
        assertEq(details.owner, holder);
        assertEq(details.tickLower, tickLower);
        assertEq(details.tickUpper, tickUpper);
        assertEq(details.liquidity, 5000);
    }

    function test_getLiquidityLast_unregistered() public view {
        // Non-existent tokenId should return 0
        assertEq(positionRegistry.getLiquidityLast(999_999), 0);
    }

    function test_getSubscriptions_empty() public view {
        uint256[] memory subs = positionRegistry.getSubscriptions(address(0xdead));
        assertEq(subs.length, 0);
    }

    function test_getSubscribed_empty() public view {
        // Fresh registry with no subscriptions yet (apart from setUp)
        // Actually setUp does not subscribe anything, so subscribed should be empty
        address[] memory subscribedArr = positionRegistry.getSubscribed();
        assertEq(subscribedArr.length, 0);
    }

    function test_updateRouter_addAndRemove() public {
        address routerAddr = address(0x1234);

        vm.prank(support);
        positionRegistry.updateRouter(routerAddr, true);
        assertTrue(positionRegistry.isActiveRouter(routerAddr));

        vm.prank(support);
        positionRegistry.updateRouter(routerAddr, false);
        assertFalse(positionRegistry.isActiveRouter(routerAddr));
    }

    function testRevert_updateRouter_onlySupportRole() public {
        vm.expectRevert();
        vm.prank(holder);
        positionRegistry.updateRouter(address(0x1234), true);
    }

    function test_accessControl_roles() public view {
        // Verify role constants
        assertEq(positionRegistry.UNI_HOOK_ROLE(), keccak256("UNI_HOOK_ROLE"));
        assertEq(positionRegistry.SUPPORT_ROLE(), keccak256("SUPPORT_ROLE"));
        assertEq(positionRegistry.SUBSCRIBER_ROLE(), keccak256("SUBSCRIBER_ROLE"));
    }

    function test_initialWeights() public view {
        assertEq(positionRegistry.MIN_PASSIVE_LIFETIME(), 43_200);
        assertEq(positionRegistry.JIT_WEIGHT(), 0);
        assertEq(positionRegistry.ACTIVE_WEIGHT(), 2_500);
        assertEq(positionRegistry.PASSIVE_WEIGHT(), 10_000);
        assertEq(positionRegistry.JIT_LIFETIME(), 1);
    }

    /**
     * @notice Stress benchmark for the contract's `MAX_SUBSCRIBED` / `MAX_SUBSCRIPTIONS`
     *         hard caps. This is NOT a unit test — it attempts to fill the contract to
     *         its ceiling (50,000 subscribers × 100 subscriptions each = 5,000,000
     *         mint+subscribe operations) which cannot complete within any realistic
     *         gas budget.
     *
     *         Prefixed `bench_` so `forge test` does not auto-run it. To execute the
     *         benchmark manually (expect it to exhaust gas after several minutes):
     *             forge test --match-test bench_MAX_SUBSCRIBED_MAX_SUBSCRIPTIONS -vvv
     *
     *         See README "Benchmarks" section for context.
     */
    function bench_MAX_SUBSCRIBED_MAX_SUBSCRIPTIONS() public {
        uint256 maxSubscribed = 50_000;
        uint256 maxSubscriptions = 100;

        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        int24 range = int24(60);
        uint128 liquidity = uint128(10_000);
        int24 tickLower = (currentTick - range) / tickSpacing * tickSpacing;
        int24 tickUpper = (currentTick + range) / tickSpacing * tickSpacing;

        (uint256 amount0, uint256 amount1,) =
            positionRegistry.getAmountsForLiquidity(poolKey.toId(), liquidity, tickLower, tickUpper);
        // fund all mock users with enough tokens to mint positions
        for (uint160 i = 1; i <= maxSubscribed; i++) {
            address user = address(i);

            vm.startPrank(holder);
            tel.transfer(user, amount0 * maxSubscriptions);
            usdc.transfer(user, amount1 * maxSubscriptions);
            vm.stopPrank();
        }

        uint256 startTokenId = positionMngr.nextTokenId();

        // create 'maxSubscribed' users and subscribe 'maxSubscriptions' token IDs for them all
        for (uint160 i = 1; i <= maxSubscribed; i++) {
            address user = address(i);

            for (uint256 j; j < maxSubscriptions; j++) {
                uint256 iteration = maxSubscriptions * j;
                uint256 tokenId = startTokenId + j + iteration;
                mintPosition(user, currentTick, range, liquidity, type(uint128).max, type(uint128).max);

                vm.prank(user);
                positionMngr.subscribe(tokenId, address(telXSubscriber), "");
            }
        }

        // reverts when contract cannot handle any more
        address[] memory subscribed = positionRegistry.getSubscribed();
        assertEq(subscribed.length, maxSubscribed);
        uint256[] memory subscriptions = positionRegistry.getSubscriptions(address(uint160(maxSubscribed)));
        assertEq(subscriptions.length, maxSubscriptions);
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

    function burnPosition(address lp, uint256 tokenId, uint128 amount0Min, uint128 amount1Min) internal {
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
    function increaseLiquidity(
        address lp,
        uint256 tokenId,
        uint128 additionalLiquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // INCREASE_LIQUIDITY
        params[0] = abi.encode(tokenId, additionalLiquidity, amount0Max, amount1Max, "");
        // SETTLE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.startPrank(lp);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    // assumes approvals are already set
    function decreaseLiquidity(
        address lp,
        uint256 tokenId,
        uint128 liquidityToRemove,
        uint128 amount0Min,
        uint128 amount1Min
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // DECREASE_LIQUIDITY
        params[0] = abi.encode(tokenId, liquidityToRemove, amount0Min, amount1Min, "");
        // TAKE_PAIR
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);

        vm.startPrank(lp);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    // pre-mint LP approvals to permit2 address and positionMngr to spend `amount` of `token`
    function approveTokensForMint(IERC20 token, uint128 amount) internal {
        token.approve(permit2, amount);
        Permit2(permit2).approve(address(token), address(positionMngr), type(uint160).max, type(uint48).max);
    }

    // assumes previous approval to permit2::approve for router address on behalf of swapper
    function swapTokensExactInSingle(address swapper, uint128 amountIn, uint128 minAmountOut, bool zeroForOne)
        public
        returns (uint256 amountOut)
    {
        (Currency inputCurrency, Currency outputCurrency) = inputAndOutputCurrencies(zeroForOne);

        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
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

    function inputAndOutputCurrencies(bool zeroForOne)
        internal
        view
        returns (Currency inputCurrency, Currency outputCurrency)
    {
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
    function calculateLiquidityBound(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        bool zeroForOne
    ) internal pure returns (uint256) {
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

    function boundAmountInByBalance(address lp, uint128 amountIn, uint256 liquidityBound, bool zeroForOne)
        internal
        view
        returns (Currency, uint128)
    {
        // identify amountIn bound based on not exceeding holder balance
        (Currency inputCurrency,) = inputAndOutputCurrencies(zeroForOne);
        uint256 swappableBalance = inputCurrency.balanceOf(lp);
        uint256 finalBound = swappableBalance < liquidityBound ? swappableBalance : liquidityBound;

        // bound amountIn to be nonzero and no more than the lesser of the two bounds
        amountIn = uint128(bound(amountIn, 1, finalBound));

        return (inputCurrency, amountIn);
    }

    // ------------------------------------------
    // COVERAGE: addOrUpdatePosition branch paths
    // ------------------------------------------

    /// @dev Hits the early return in addOrUpdatePosition when poolId is invalid
    function test_addOrUpdatePosition_invalidPoolSkips() public {
        PoolId invalidPoolId = PoolId.wrap(keccak256("nonexistent"));
        // calling addOrUpdatePosition with an invalid pool should silently return
        vm.prank(address(telXIncentiveHook));
        positionRegistry.addOrUpdatePosition(999, invalidPoolId, 100, 0, 0);

        // position should remain unset
        (address owner,,,) = positionRegistry.getPosition(999);
        assertEq(owner, address(0));
    }

    /// @dev Hits the UNTRACKED early return in addOrUpdatePosition
    function test_addOrUpdatePosition_untrackedSkips() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint and subscribe a position, then burn it to mark it UNTRACKED
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        burnPosition(holder, tokenId, 0, 0);

        // confirm it's UNTRACKED
        (address owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);

        // now calling addOrUpdatePosition on the UNTRACKED position should silently return
        vm.prank(address(telXIncentiveHook));
        positionRegistry.addOrUpdatePosition(tokenId, poolKey.toId(), 100, 0, 0);

        // owner should still be UNTRACKED
        (owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);
    }

    /// @dev Hits the known position branch with positive liquidityDelta (increase on known non-subscribed position)
    function test_addOrUpdatePosition_knownPositionIncreaseLiquidity() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint a position (becomes known but not subscribed)
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        uint128 liquidityBefore = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityBefore, 5000);

        // increase liquidity on the known position
        increaseLiquidity(holder, tokenId, 3000, type(uint128).max, type(uint128).max);

        uint128 liquidityAfter = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityAfter, 8000);
    }

    /// @dev Hits the known position branch with zero liquidityDelta (fee collection)
    function test_addOrUpdatePosition_knownPositionZeroDelta() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint a position (becomes known)
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        uint128 liquidityBefore = positionRegistry.getLiquidityLast(tokenId);

        // decrease by 0 triggers fee collection path (liquidityDelta == 0 is permitted)
        decreaseLiquidity(holder, tokenId, 0, 0, 0);

        uint128 liquidityAfter = positionRegistry.getLiquidityLast(tokenId);
        assertEq(liquidityAfter, liquidityBefore);
    }

    // -----------------------------------------------
    // COVERAGE: _removeSubscription swap-and-pop path
    // -----------------------------------------------

    /// @dev Tests removing a non-last subscription, triggering the swap-and-pop branch
    function test_removeSubscription_swapAndPop() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint and subscribe 3 positions for the same owner
        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");

        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        uint256 tokenId3 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 180, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId3, address(telXSubscriber), "");

        // verify 3 subscriptions
        uint256[] memory subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 3);

        // unsubscribe the FIRST position (index 0), triggering swap-and-pop with last element
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId1);

        // verify only 2 subscriptions remain and the first was replaced by the last
        subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 2);
        // tokenId3 should have been swapped into index 0
        assertEq(subs[0], tokenId3);
        assertEq(subs[1], tokenId2);

        // owner should still be subscribed since they have remaining subscriptions
        assertTrue(positionRegistry.isSubscribed(holder));
    }

    /// @dev Tests removing the middle subscription to verify swap-and-pop correctness
    function test_removeSubscription_removeMiddle() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint and subscribe 3 positions
        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");

        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        uint256 tokenId3 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 180, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId3, address(telXSubscriber), "");

        // unsubscribe the MIDDLE position (index 1)
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId2);

        uint256[] memory subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 2);
        assertEq(subs[0], tokenId1);
        // tokenId3 should have been swapped into index 1
        assertEq(subs[1], tokenId3);
    }

    // ---------------------------------------------------------
    // COVERAGE: subscribed array swap-and-pop (multiple owners)
    // ---------------------------------------------------------

    /// @dev Tests removing a non-last owner from the subscribed array (swap-and-pop on global array)
    function test_subscribedArray_swapAndPop() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // create 3 users, each with one subscription
        address user1 = holder;
        address user2 = address(0xbeef);
        address user3 = address(0xcafe);

        // fund user2 and user3
        vm.startPrank(holder);
        tel.transfer(user2, tel.balanceOf(holder) / 3);
        usdc.transfer(user2, usdc.balanceOf(holder) / 3);
        tel.transfer(user3, tel.balanceOf(holder) / 2);
        usdc.transfer(user3, usdc.balanceOf(holder) / 2);
        vm.stopPrank();

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(user1, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(user1);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");

        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(user2, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(user2);
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        uint256 tokenId3 = positionMngr.nextTokenId();
        mintPosition(user3, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(user3);
        positionMngr.subscribe(tokenId3, address(telXSubscriber), "");

        // verify 3 users in subscribed array
        address[] memory subscribedArr = positionRegistry.getSubscribed();
        assertEq(subscribedArr.length, 3);

        // unsubscribe the FIRST user's only position -> removes user1 from subscribed array
        // this triggers swap-and-pop on the subscribed array (user3 takes user1's slot)
        vm.prank(user1);
        positionMngr.unsubscribe(tokenId1);

        subscribedArr = positionRegistry.getSubscribed();
        assertEq(subscribedArr.length, 2);
        // user3 should have been swapped into index 0
        assertEq(subscribedArr[0], user3);
        assertEq(subscribedArr[1], user2);

        assertFalse(positionRegistry.isSubscribed(user1));
        assertTrue(positionRegistry.isSubscribed(user2));
        assertTrue(positionRegistry.isSubscribed(user3));
    }

    // ---------------------------------
    // COVERAGE: isSubscribed false path
    // ---------------------------------

    /// @dev Verifies isSubscribed returns false for a user with no subscriptions
    function test_isSubscribed_falsePath() public view {
        assertFalse(positionRegistry.isSubscribed(address(0xdead)));
        assertFalse(positionRegistry.isSubscribed(address(0)));
        assertFalse(positionRegistry.isSubscribed(holder));
    }

    // ---------------------------------
    // COVERAGE: isTokenSubscribed paths
    // ---------------------------------

    /// @dev Verifies isTokenSubscribed returns true after subscribing and false after unsubscribing
    function test_isTokenSubscribed_paths() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        // before subscribing
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // after subscribing
        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        vm.prank(holder);
        positionMngr.unsubscribe(tokenId);

        // after unsubscribing
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
    }

    // ------------------------------------
    // COVERAGE: handleSubscribe edge cases
    // ------------------------------------

    /// @dev Tests handleSubscribe when pos.owner is stale (position was transferred outside of hook flow)
    function test_handleSubscribe_staleOwnerUpdate() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        // subscribe and then transfer (which unsubscribes)
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        vm.prank(holder);
        (bool r,) = address(positionMngr).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, support, tokenId)
        );
        require(r);

        // At this point, the registry's pos.owner still reflects `holder` from the last liquidity update
        // but the actual NFT owner is `support`. Subscribing from `support` should update pos.owner
        vm.prank(support);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        (address registeredOwner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(registeredOwner, support);
        assertTrue(positionRegistry.isSubscribed(support));
    }

    // --------------------------------
    // COVERAGE: handleBurn direct path
    // --------------------------------

    /// @dev Tests handleBurn marks position UNTRACKED and removes subscription
    function test_handleBurn_marksUntracked() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));
        assertTrue(positionRegistry.isSubscribed(holder));

        // burn triggers handleBurn via TELxSubscriber.notifyBurn
        burnPosition(holder, tokenId, 0, 0);

        // position should be UNTRACKED
        (address owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertFalse(positionRegistry.isSubscribed(holder));
    }

    // ---------------------------------------
    // COVERAGE: handleUnsubscribe direct path
    // ---------------------------------------

    /// @dev Tests handleUnsubscribe removes the token subscription
    function test_handleUnsubscribe_removesSubscription() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));
        assertTrue(positionRegistry.isSubscribed(holder));

        // trigger unsubscribe
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId);

        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertFalse(positionRegistry.isSubscribed(holder));
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
    }

    // -----------------------------------------------------------
    // COVERAGE: _resolveUser trusted router path (via initialize)
    // -----------------------------------------------------------

    /// @dev Tests the _resolveUser path when msg.sender is a trusted router implementing IMsgSender
    function test_resolveUser_trustedRouterPath() public {
        // deploy a mock router that implements IMsgSender returning admin
        MockRouter mockRouter = new MockRouter(admin);

        // register the mock router as trusted
        vm.prank(support);
        positionRegistry.updateRouter(address(mockRouter), true);

        // create a new pool key with a different currency pair to avoid AlreadyInitialized
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x2000000000000000000000000000000000000000),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        // call initialize directly with the mock router as sender
        // the hook role calls initialize(sender, key) where sender = mockRouter
        // _resolveUser should call mockRouter.msgSender() which returns admin
        vm.prank(address(telXIncentiveHook));
        positionRegistry.initialize(address(mockRouter), newKey);

        // verify the pool was initialized successfully (admin was resolved via router)
        assertTrue(positionRegistry.validPool(newKey.toId()));
    }

    /// @dev Tests the _resolveUser revert path when trusted router doesn't implement IMsgSender
    function test_resolveUser_trustedRouterNoMsgSender_reverts() public {
        // deploy a contract that doesn't implement IMsgSender
        MockRouterNoMsgSender badRouter = new MockRouterNoMsgSender();

        // register it as trusted
        vm.prank(support);
        positionRegistry.updateRouter(address(badRouter), true);

        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x3000000000000000000000000000000000000000),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        // should revert because the trusted router doesn't implement msgSender()
        vm.expectRevert("Trusted router must implement msgSender()");
        vm.prank(address(telXIncentiveHook));
        positionRegistry.initialize(address(badRouter), newKey);
    }

    /// @dev Tests that _resolveUser passes through sender directly when not a trusted router
    function test_resolveUser_nonRouterPassthrough() public {
        // admin is not a registered router, so _resolveUser should return admin directly
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x4000000000000000000000000000000000000000),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        vm.prank(address(telXIncentiveHook));
        positionRegistry.initialize(admin, newKey);

        assertTrue(positionRegistry.validPool(newKey.toId()));
    }

    // -----------------------------------------
    // COVERAGE: validPool explicit false return
    // -----------------------------------------

    /// @dev Hits the explicit `return false` in validPool when both currencies are address(0)
    function test_validPool_returnsFalse_bothCurrenciesZero() public view {
        // An uninitialized pool has both currency0 and currency1 as address(0)
        PoolId unknownPool = PoolId.wrap(keccak256("completely_unknown"));
        assertFalse(positionRegistry.validPool(unknownPool));
    }

    // --------------------------------------------
    // COVERAGE: configureWeights additional branch
    // --------------------------------------------

    /// @dev Hits the branch where activeWeight exceeds 10000 bps
    function testRevert_configureWeights_activeWeightTooHigh() public {
        vm.expectRevert("PositionRegistry: Weights must be between 0 and 10000 bps");
        vm.prank(support);
        positionRegistry.configureWeights(100, 0, 10_001, 0);
    }

    /// @dev Hits the branch where passiveWeight exceeds 10000 bps
    function testRevert_configureWeights_passiveWeightTooHigh() public {
        vm.expectRevert("PositionRegistry: Weights must be between 0 and 10000 bps");
        vm.prank(support);
        positionRegistry.configureWeights(100, 0, 0, 10_001);
    }

    // ----------------------------------------------------------------
    // COVERAGE: subscription threshold - zero liquidity and small pool
    // ----------------------------------------------------------------

    /// @dev Tests that decreasing all liquidity on a subscribed position removes its subscription
    function test_subscriptionThreshold_zeroLiquidityRemoval() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        // remove all liquidity - should trigger subscription threshold check with 0 liquidity
        decreaseLiquidity(holder, tokenId, 5000, 0, 0);

        // position should have been unsubscribed due to zero liquidity
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertEq(positionRegistry.getLiquidityLast(tokenId), 0);
    }

    // ---------------------------------------------------
    // COVERAGE: unsubscribe last element (no swap needed)
    // ---------------------------------------------------

    /// @dev Tests removing the last subscription (no swap-and-pop needed, just pop)
    function test_removeSubscription_lastElement() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");

        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        // remove the LAST element (no swap needed)
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId2);

        uint256[] memory subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 1);
        assertEq(subs[0], tokenId1);
    }

    // -------------------------------------------------------------------------
    // COVERAGE: multiple operations in quick succession (checkpoint overwrites)
    // -------------------------------------------------------------------------

    /// @dev Tests multiple liquidity modifications triggering checkpoint behavior
    function test_multipleModifications_checkpointBehavior() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        // do multiple increases to build checkpoint history
        increaseLiquidity(holder, tokenId, 1000, type(uint128).max, type(uint128).max);
        vm.roll(block.number + 1);
        increaseLiquidity(holder, tokenId, 2000, type(uint128).max, type(uint128).max);

        assertEq(positionRegistry.getLiquidityLast(tokenId), 8000);
    }

    // -------------------------------------------------------
    // COVERAGE: addOrUpdatePosition known position catch path
    // -------------------------------------------------------
    // (ownerOf reverts for non-subscribed known position)

    /// @dev Tests the known-position catch block where the token is burned but NOT subscribed
    ///      This hits the `!isTokenSubscribed[tokenId]` branch that calls _setUntracked
    function test_addOrUpdatePosition_knownPositionBurnNotSubscribed() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint a position but do NOT subscribe it
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);

        // verify known but not subscribed
        (address owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, holder);
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));

        // burn the position (triggers afterRemoveLiquidity hook -> addOrUpdatePosition -> catch block)
        burnPosition(holder, tokenId, 0, 0);

        // position should be UNTRACKED since it was not subscribed
        (owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);
    }

    /// @dev Tests the known-position catch block where the token IS subscribed
    ///      This hits the path where `isTokenSubscribed[tokenId]` is true, so _setUntracked is NOT called
    function test_addOrUpdatePosition_knownPositionBurnSubscribed() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        // mint and subscribe a position
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        // burn the position - for subscribed tokens, afterRemoveLiquidity should NOT set UNTRACKED
        // because handleBurn subsequently does it
        burnPosition(holder, tokenId, 0, 0);

        // after full burn flow (afterRemoveLiquidity + notifyBurn -> handleBurn), position is UNTRACKED
        (address owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, UNTRACKED);
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
    }

    // ---------------------------------
    // COVERAGE: handleSubscribe reverts
    // ---------------------------------

    /// @dev Tests that subscribing a position in an invalid pool reverts
    function test_handleSubscribe_invalidPool_reverts() public {
        // We need to create a position that exists in the registry with an invalid poolId
        // This is hard to trigger naturally since positions are created via hooks on valid pools
        // Instead, test that subscribing an untracked position reverts
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");
        burnPosition(holder, tokenId, 0, 0);

        // position is now UNTRACKED, trying to subscribe should revert with Untracked
        // This would need re-minting the same tokenId which isn't possible, so we test
        // that handleSubscribe on an UNTRACKED position reverts
        // PositionManager wraps subscriber reverts so we use generic expectRevert
        // Note: this can't be directly tested through positionMngr since the token is burned
        // Instead we call handleSubscribe directly through the subscriber role
        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.Untracked.selector, tokenId));
        vm.prank(address(telXSubscriber));
        positionRegistry.handleSubscribe(tokenId);
    }

    // -------------------------------------------------------------
    // COVERAGE: initialize revert - OnlyAdmin from non-admin sender
    // -------------------------------------------------------------

    /// @dev Tests that initialize reverts when sender is not admin (direct call)
    function test_initialize_onlyAdmin_reverts() public {
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(0x0000000000000000000000000000000000000000),
            currency1: Currency.wrap(0x5000000000000000000000000000000000000000),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        // holder is not admin
        vm.expectRevert(IPositionRegistry.OnlyAdmin.selector);
        vm.prank(address(telXIncentiveHook));
        positionRegistry.initialize(holder, newKey);
    }

    // ---------------------------------------------------------------
    // COVERAGE: multiple subscriptions then full unsubscribe sequence
    // ---------------------------------------------------------------

    /// @dev Unsubscribe all positions one by one, verifying subscribed array cleanup
    function test_fullUnsubscribeSequence() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");

        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 5000, type(uint128).max, type(uint128).max);
        vm.prank(holder);
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        assertEq(positionRegistry.getSubscriptions(holder).length, 2);
        assertEq(positionRegistry.getSubscribed().length, 1);
        assertTrue(positionRegistry.isSubscribed(holder));

        // unsubscribe first
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId1);
        assertEq(positionRegistry.getSubscriptions(holder).length, 1);
        assertTrue(positionRegistry.isSubscribed(holder));

        // unsubscribe last - should remove owner from subscribed array
        vm.prank(holder);
        positionMngr.unsubscribe(tokenId2);
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
        assertEq(positionRegistry.getSubscribed().length, 0);
        assertFalse(positionRegistry.isSubscribed(holder));
    }

    // ------------------------------------------------------
    // COVERAGE: getPositionDetails for unregistered position
    // ------------------------------------------------------

    /// @dev Tests getPositionDetails returns zero values for an unregistered position
    function test_getPositionDetails_unregistered() public view {
        IPositionRegistry.PositionDetails memory details = positionRegistry.getPositionDetails(999_999);
        assertEq(details.owner, address(0));
        assertEq(details.liquidity, 0);
    }

    // -----------------------------------------------------
    // COVERAGE: getAmountsForLiquidity (public view helper)
    // -----------------------------------------------------

    /// @dev getAmountsForLiquidity is a public read helper consumed by the
    ///      benchmark + off-chain tooling. It is not otherwise exercised.
    function test_getAmountsForLiquidity_returnsLiveSlot0Price() public view {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        int24 tickLower = (currentTick - 60) / tickSpacing * tickSpacing;
        int24 tickUpper = (currentTick + 60) / tickSpacing * tickSpacing;

        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) =
            positionRegistry.getAmountsForLiquidity(poolKey.toId(), 10_000, tickLower, tickUpper);

        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 should be read from state");
        // For a non-zero-width range centered near spot, both sides need tokens.
        assertTrue(amount0 > 0 || amount1 > 0, "non-zero liquidity requires tokens");
    }

    // --------------------------------------------------------------
    // COVERAGE: addOrUpdatePosition catch branch (new position whose
    // --------------------------------------------------------------
    // tokenId does not exist in PositionManager)

    /// @dev When the hook forwards a tokenId that PositionManager.ownerOf()
    ///      reverts on, addOrUpdatePosition must fall into its catch branch
    ///      and mark the position UNTRACKED.
    function test_addOrUpdatePosition_unknownTokenId_marksUntracked() public {
        // Use the max possible tokenId — guaranteed unused by PositionManager
        // regardless of how many tokens it has minted. Previously we used
        // `nextTokenId() + 10_000`, which would silently break if the live
        // PositionManager ever caught up to that offset.
        uint256 phantomTokenId = type(uint256).max;
        // Sanity: PositionManager does not know this tokenId.
        (bool ok,) =
            address(positionMngr).staticcall(abi.encodeWithSignature("ownerOf(uint256)", phantomTokenId));
        assertFalse(ok, "phantom tokenId must revert on ownerOf");

        vm.prank(address(telXIncentiveHook));
        positionRegistry.addOrUpdatePosition(phantomTokenId, poolKey.toId(), int128(100), 0, 0);

        (address owner,,,) = positionRegistry.getPosition(phantomTokenId);
        assertEq(owner, address(type(uint160).max), "position should be UNTRACKED");
    }

    // --------------------------------------------------------------
    // COVERAGE: handleSubscribe revert paths (lines 318 / 331 / 334)
    // --------------------------------------------------------------

    /// @dev An unknown tokenId has pos.owner == address(0) (not UNTRACKED) and
    ///      pos.poolId == bytes32(0). That trips the InvalidPool branch.
    function test_handleSubscribe_invalidPoolBranch_reverts() public {
        // Any unregistered tokenId works; use max to make "never-minted" obvious.
        uint256 unknownTokenId = type(uint256).max;
        PoolId invalidId = PoolId.wrap(bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IPositionRegistry.InvalidPool.selector, invalidId));
        vm.prank(address(telXSubscriber));
        positionRegistry.handleSubscribe(unknownTokenId);
    }

    /// @dev Force `subscriptions[holder].length == MAX_SUBSCRIPTIONS` via vm.store
    ///      so the next subscribe from `holder` trips the MaxSubscriptions guard.
    ///      Naturally filling 100 subscriptions would require 100 mintPosition+subscribe
    ///      cycles per run — wasteful and slow.
    function test_handleSubscribe_maxSubscriptions_reverts() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 10_000, type(uint128).max, type(uint128).max);

        bytes32 lenSlot = _subscriptionsLengthSlot(holder);
        _assertSubscriptionsSlotStillAt(holder, lenSlot);
        vm.store(address(positionRegistry), lenSlot, bytes32(uint256(100)));

        vm.expectRevert(IPositionRegistry.MaxSubscriptions.selector);
        vm.prank(address(telXSubscriber));
        positionRegistry.handleSubscribe(tokenId);
    }

    /// @dev Force `subscribed.length == MAX_SUBSCRIBED` via vm.store so a fresh
    ///      subscriber trips the MaxSubscribed guard. Naturally filling the
    ///      subscribed array would require 50,000 unique signers; that is what
    ///      `bench_MAX_SUBSCRIBED_MAX_SUBSCRIPTIONS` is for, not a unit test.
    function test_handleSubscribe_maxSubscribed_reverts() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 60, 10_000, type(uint128).max, type(uint128).max);

        bytes32 slot = _subscribedArrayLengthSlot();
        _assertSubscribedSlotStillAt(slot);
        vm.store(address(positionRegistry), slot, bytes32(uint256(50_000)));

        vm.expectRevert(IPositionRegistry.MaxSubscribed.selector);
        vm.prank(address(telXSubscriber));
        positionRegistry.handleSubscribe(tokenId);
    }

    // ----------------------
    // Storage-layout helpers
    // ----------------------
    //
    // These tests mutate `positionRegistry`'s internal storage via vm.store.
    // The slots are taken from `forge inspect contracts/telx/core/
    // PositionRegistry.sol:PositionRegistry storageLayout` at the time this
    // was written. If someone adds, removes, or reorders a state variable on
    // PositionRegistry, those slots shift — and vm.store would silently
    // corrupt unrelated state instead of writing the array length we intend.
    //
    // The `_assertXSlotStillAt` helpers guard against that: they write a
    // small sentinel length to the slot, confirm via the contract's public
    // getter that we see the same length back, then restore the original
    // value. If the storage layout has drifted, these fail LOUDLY with a
    // message that points to the fix.

    /// @dev Storage slot holding `subscribed.length`. Matches forge-inspect output.
    function _subscribedArrayLengthSlot() internal pure returns (bytes32) {
        return bytes32(uint256(10));
    }

    /// @dev Storage slot holding `subscriptions[owner].length`. Matches forge-inspect output.
    function _subscriptionsLengthSlot(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, uint256(12)));
    }

    function _assertSubscribedSlotStillAt(bytes32 slot) internal {
        bytes32 original = vm.load(address(positionRegistry), slot);
        vm.store(address(positionRegistry), slot, bytes32(uint256(3)));
        require(
            positionRegistry.getSubscribed().length == 3,
            "storage layout drift: `subscribed` no longer at expected slot; re-run forge inspect and update _subscribedArrayLengthSlot"
        );
        vm.store(address(positionRegistry), slot, original);
    }

    function _assertSubscriptionsSlotStillAt(address owner, bytes32 slot) internal {
        bytes32 original = vm.load(address(positionRegistry), slot);
        vm.store(address(positionRegistry), slot, bytes32(uint256(5)));
        require(
            positionRegistry.getSubscriptions(owner).length == 5,
            "storage layout drift: `subscriptions` no longer at expected slot; re-run forge inspect and update _subscriptionsLengthSlot"
        );
        vm.store(address(positionRegistry), slot, original);
    }
}

// interface used to interact with the Uniswap V4 Universal Router without requiring extra dependencies
interface UniversalRouter {
    function execute(bytes memory commands, bytes[] memory inputs, uint256 deadline) external payable;
}

interface Permit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Mock router that implements IMsgSender for testing _resolveUser trusted router path
contract MockRouter {
    address private _sender;

    constructor(address sender_) {
        _sender = sender_;
    }

    function msgSender() external view returns (address) {
        return _sender;
    }
}

/// @dev Mock router that does NOT implement IMsgSender for testing _resolveUser revert path
contract MockRouterNoMsgSender {
    // intentionally empty - no msgSender function
}

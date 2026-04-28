// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {TELxIncentiveHook} from "contracts/telx/core/TELxIncentiveHook.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {TELxIncentiveHookDeployable} from "contracts/telx/test/MockTELxIncentiveHook.sol";
import {PositionManagerAuth} from "contracts/telx/abstract/PositionManagerAuth.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager, PositionInfo} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "../util/interfaces/IPermit2.sol";

/// @title TELxSubscriberTest
/// @notice Sepolia-fork unit tests for TELxSubscriber — the Uniswap v4 PositionManager subscriber
///         that mirrors LP subscription state into PositionRegistry. Covers all four notify*
///         callbacks (subscribe, unsubscribe, modifyLiquidity, burn) plus the position-transfer
///         re-subscription flow. Companion: TELxSubscriber.polygon.t.sol (auth-only checks).
contract TELxSubscriberTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager public poolMngr;
    PositionManager public positionMngr;
    StateView public st8View;
    PositionRegistry public positionRegistry;
    TELxIncentiveHook public telXIncentiveHook;
    TELxSubscriber public telXSubscriber;

    IERC20 public tel;
    IERC20 public usdc;
    PoolKey public poolKey;

    address public admin = address(0xc0ffee);
    address public support = address(0xdeadbeef);
    address public holder = 0x5d5d4d04B70BFe49ad7Aac8C4454536070dAf180;
    address public secondUser = makeAddr("secondUser");
    address permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public hookAddress = 0x0000000000000000000000000000000000002500;

    int24 tickSpacing = 60;

    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        tel = IERC20(0x92bc9f0D42A3194Df2C5AB55c3bbDD82e6Fb2F92);
        usdc = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        poolMngr = PoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        positionMngr = PositionManager(payable(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4));
        st8View = StateView(0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C);

        vm.startPrank(admin);
        positionRegistry = new PositionRegistry(
            tel,
            IPoolManager(address(poolMngr)),
            IPositionManager(address(positionMngr)),
            st8View,
            admin
        );
        positionRegistry.grantRole(positionRegistry.SUPPORT_ROLE(), support);

        TELxIncentiveHook tempHook = new TELxIncentiveHookDeployable(
            IPoolManager(address(poolMngr)),
            address(positionMngr),
            IPositionRegistry(address(positionRegistry))
        );
        vm.etch(hookAddress, address(tempHook).code);
        telXIncentiveHook = TELxIncentiveHook(hookAddress);
        positionRegistry.grantRole(positionRegistry.UNI_HOOK_ROLE(), address(telXIncentiveHook));

        telXSubscriber = new TELxSubscriber(
            IPositionRegistry(address(positionRegistry)),
            address(positionMngr)
        );
        positionRegistry.grantRole(positionRegistry.SUBSCRIBER_ROLE(), address(telXSubscriber));
        vm.stopPrank();

        // Initialize pool
        uint160 sqrtPriceX96 = 9.9827e27;
        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(tel)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        vm.prank(admin);
        poolMngr.initialize(poolKey, sqrtPriceX96);
    }

    // ------------------------
    // CONSTRUCTOR & IMMUTABLES
    // ------------------------

    function test_constructorImmutables() public view {
        assertEq(address(telXSubscriber.registry()), address(positionRegistry));
        assertEq(telXSubscriber.positionManager(), address(positionMngr));
    }

    // ----------------
    // NOTIFY SUBSCRIBE
    // ----------------

    function test_notifySubscribe_happyPath() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        // Subscribe via positionManager (which calls notifySubscribe on subscriber)
        vm.expectEmit(true, true, true, true, address(positionRegistry));
        emit IPositionRegistry.Subscribed(tokenId, holder);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // Verify subscription state
        uint256[] memory subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 1);
        assertEq(subs[0], tokenId);
        assertTrue(positionRegistry.isTokenSubscribed(tokenId));
        assertTrue(positionRegistry.isSubscribed(holder));
    }

    function test_notifySubscribe_multiplePositions() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);
        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 180, 10_000, type(uint128).max, type(uint128).max);

        vm.startPrank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");
        vm.stopPrank();

        uint256[] memory subs = positionRegistry.getSubscriptions(holder);
        assertEq(subs.length, 2);

        // Only one entry in subscribed array for the same owner
        address[] memory subscribedArr = positionRegistry.getSubscribed();
        assertEq(subscribedArr.length, 1);
        assertEq(subscribedArr[0], holder);
    }

    // ------------------
    // NOTIFY UNSUBSCRIBE
    // ------------------

    function test_notifyUnsubscribe_happyPath() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        // Unsubscribe
        vm.expectEmit(true, true, true, true, address(positionRegistry));
        emit IPositionRegistry.Unsubscribed(tokenId, holder);

        vm.prank(holder);
        positionMngr.unsubscribe(tokenId);

        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
        assertFalse(positionRegistry.isSubscribed(holder));
        assertEq(positionRegistry.getSubscribed().length, 0);
    }

    function test_notifyUnsubscribe_partialUnsubscription() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);
        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 180, 10_000, type(uint128).max, type(uint128).max);

        vm.startPrank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");

        // Unsubscribe only one
        positionMngr.unsubscribe(tokenId1);
        vm.stopPrank();

        assertFalse(positionRegistry.isTokenSubscribed(tokenId1));
        assertTrue(positionRegistry.isTokenSubscribed(tokenId2));
        assertEq(positionRegistry.getSubscriptions(holder).length, 1);
        // Owner should still be in subscribed array since they have remaining subscriptions
        assertTrue(positionRegistry.isSubscribed(holder));
    }

    // -------------------------------
    // NOTIFY MODIFY LIQUIDITY (NO-OP)
    // -------------------------------

    function test_notifyModifyLiquidity_isNoOp() public {
        // notifyModifyLiquidity is a no-op in the subscriber.
        // We verify it doesn't revert when called via the positionManager flow.
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        uint256[] memory subsBefore = positionRegistry.getSubscriptions(holder);

        // Increase liquidity while subscribed -- this triggers notifyModifyLiquidity on subscriber
        increaseLiquidity(holder, tokenId, 5000, type(uint128).max, type(uint128).max);

        // Subscription state unchanged (no-op)
        uint256[] memory subsAfter = positionRegistry.getSubscriptions(holder);
        assertEq(subsBefore.length, subsAfter.length);
    }

    // -----------
    // NOTIFY BURN
    // -----------

    function test_notifyBurn() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        // Burn the position -- triggers notifyBurn on subscriber
        vm.expectEmit(true, true, true, true, address(positionRegistry));
        emit IPositionRegistry.Unsubscribed(tokenId, holder);

        burnPosition(holder, tokenId, 0, 0);

        // Position should be unsubscribed and marked as UNTRACKED
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
        (address owner,,,) = positionRegistry.getPosition(tokenId);
        assertEq(owner, address(type(uint160).max), "should be UNTRACKED after burn");
    }

    function test_notifyBurn_withMultipleSubscriptions() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());

        uint256 tokenId1 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);
        uint256 tokenId2 = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 180, 10_000, type(uint128).max, type(uint128).max);

        vm.startPrank(holder);
        positionMngr.subscribe(tokenId1, address(telXSubscriber), "");
        positionMngr.subscribe(tokenId2, address(telXSubscriber), "");
        vm.stopPrank();

        // Burn the first position
        burnPosition(holder, tokenId1, 0, 0);

        // Second subscription should remain
        assertFalse(positionRegistry.isTokenSubscribed(tokenId1));
        assertTrue(positionRegistry.isTokenSubscribed(tokenId2));
        assertEq(positionRegistry.getSubscriptions(holder).length, 1);
        assertTrue(positionRegistry.isSubscribed(holder));
    }

    // ---------------
    // NOTIFY TRANSFER
    // ---------------

    function test_notifyTransfer_unsubscribesOnTransfer() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));

        // Transfer triggers unsubscribe via notifyUnsubscribe
        vm.prank(holder);
        IERC721(address(positionMngr)).transferFrom(holder, support, tokenId);

        // Position should be unsubscribed after transfer
        assertFalse(positionRegistry.isTokenSubscribed(tokenId));
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
        assertFalse(positionRegistry.isSubscribed(holder));
    }

    function test_notifyTransfer_newOwnerCanResubscribe() public {
        (, int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolMngr)), poolKey.toId());
        uint256 tokenId = positionMngr.nextTokenId();
        mintPosition(holder, currentTick, 120, 10_000, type(uint128).max, type(uint128).max);

        vm.prank(holder);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        // Transfer
        vm.prank(holder);
        IERC721(address(positionMngr)).transferFrom(holder, support, tokenId);

        // New owner resubscribes
        vm.prank(support);
        positionMngr.subscribe(tokenId, address(telXSubscriber), "");

        assertTrue(positionRegistry.isTokenSubscribed(tokenId));
        assertEq(positionRegistry.getSubscriptions(support).length, 1);
        assertTrue(positionRegistry.isSubscribed(support));
        // Old owner should have no subscriptions
        assertEq(positionRegistry.getSubscriptions(holder).length, 0);
    }

    // --------------
    // ACCESS CONTROL
    // --------------

    function testRevert_notifySubscribe_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(holder);
        telXSubscriber.notifySubscribe(1, "");
    }

    function testRevert_notifyUnsubscribe_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(holder);
        telXSubscriber.notifyUnsubscribe(1);
    }

    function testRevert_notifyModifyLiquidity_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(holder);
        telXSubscriber.notifyModifyLiquidity(1, 0, BalanceDelta.wrap(0));
    }

    function testRevert_notifyBurn_onlyPositionManager() public {
        vm.expectRevert(PositionManagerAuth.OnlyPositionManager.selector);
        vm.prank(holder);
        telXSubscriber.notifyBurn(1, holder, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));
    }

    // -----
    // UTILS
    // -----

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
        usdc.approve(permit2Addr, amount0Max);
        IPermit2(permit2Addr).approve(address(usdc), address(positionMngr), type(uint160).max, type(uint48).max);
        tel.approve(permit2Addr, amount1Max);
        IPermit2(permit2Addr).approve(address(tel), address(positionMngr), type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, lp, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function increaseLiquidity(
        address lp,
        uint256 tokenId,
        uint128 additionalLiquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, additionalLiquidity, amount0Max, amount1Max, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.startPrank(lp);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function burnPosition(address lp, uint256 tokenId, uint128 amount0Min, uint128 amount1Min) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);
        vm.startPrank(lp);
        positionMngr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 minutes);
        vm.stopPrank();
    }
}

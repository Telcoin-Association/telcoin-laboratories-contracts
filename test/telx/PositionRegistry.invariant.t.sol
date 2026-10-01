// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {PositionRegistryHandler} from "./handlers/PositionRegistryHandler.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title PositionRegistryInvariantTest
/// @notice The index bookkeeping under random interleavings of every write path.
/// @dev    The branch tests prove each function does the right thing from a known state; this
///         proves the swap-and-pop index, the global owner set and the two caps stay consistent
///         through orderings nobody wrote a test for: a transfer whose notification was swallowed
///         followed by a resubscribe, a prune between a drain and a refill, an eviction of the
///         last entry of the last owner, and so on.
contract PositionRegistryInvariantTest is Test {
    PositionRegistry internal registry;
    PositionRegistryHandler internal handler;
    MockPositionManager internal pm;
    MockStateView internal sv;
    MockPoolManager internal poolManager;

    address internal admin = makeAddr("admin");
    address internal subscriber = makeAddr("subscriber");
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        poolManager = new MockPoolManager();
        pm = new MockPositionManager();
        sv = new MockStateView(address(poolManager));
        registry = new PositionRegistry(IPositionManager(address(pm)), StateView(address(sv)), admin);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE0)),
            currency1: Currency.wrap(address(0xB0B0B0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        vm.startPrank(admin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), subscriber);
        registry.registerPool(poolKey);
        vm.stopPrank();
        sv.setSlot0(poolId, 79228162514264337593543950336, 0);

        handler = new PositionRegistryHandler(registry, pm, sv, poolManager, admin, subscriber, poolKey);
        targetContract(address(handler));
    }

    /// @notice Every token the index holds is at the recorded index of the recorded owner's list,
    ///         and every list entry is a token the index holds under that owner.
    function invariant_indexIsConsistent() public view {
        uint256 tokens = handler.tokenCount();
        uint256 owners = handler.ownerCount();

        uint256 listed;
        for (uint256 o; o < owners; ++o) {
            address owner = handler.owners(o);
            uint256[] memory list = registry.getSubscriptionsRaw(owner);
            for (uint256 i; i < list.length; ++i) {
                uint256 tokenId = list[i];
                assertTrue(registry.isTokenSubscribed(tokenId), "listed token not flagged subscribed");
                // no token appears in two lists or twice in one
                for (uint256 j; j < i; ++j) {
                    assertTrue(list[j] != tokenId, "duplicate entry");
                }
                ++listed;
            }
            assertEq(registry.isSubscribed(owner), list.length > 0, "isSubscribed disagrees with the list");
        }

        uint256 flagged;
        for (uint256 t = 1; t <= tokens; ++t) {
            if (registry.isTokenSubscribed(t)) ++flagged;
        }
        assertEq(flagged, listed, "flagged tokens not all listed exactly once");
    }

    /// @notice The global owner set is exactly the owners with a non-empty list, with no
    ///         duplicates, and never above the cap.
    function invariant_subscribedSetMatchesLists() public view {
        address[] memory set = registry.getSubscribed();
        assertLe(set.length, registry.MAX_SUBSCRIBED(), "global cap");

        uint256 nonEmpty;
        for (uint256 o; o < handler.ownerCount(); ++o) {
            address owner = handler.owners(o);
            bool inSet;
            for (uint256 i; i < set.length; ++i) {
                if (set[i] == owner) {
                    assertFalse(inSet, "owner listed twice");
                    inSet = true;
                }
            }
            bool hasEntries = registry.getSubscriptionsRaw(owner).length > 0;
            assertEq(inSet, hasEntries, "set membership disagrees with the list");
            if (hasEntries) ++nonEmpty;
        }
        assertEq(set.length, nonEmpty, "set holds an owner with no entries");
    }

    /// @notice Nothing the index holds was opted in behind v4's back. Every indexed token is one
    ///         v4 has subscribed to our subscriber, or one whose v4 unsubscribe was swallowed by
    ///         the gas-limited notification (which the handler models and records).
    function invariant_indexNeverAheadOfUniswapExceptSwallowed() public view {
        for (uint256 t = 1; t <= handler.tokenCount(); ++t) {
            if (!registry.isTokenSubscribed(t)) continue;
            if (handler.v4Subscribed(t)) continue;
            assertTrue(handler.swallowed(t), "indexed without a v4 subscription and no swallowed notification");
        }
    }

    /// @notice The votable view never returns a token the index does not hold, and never one whose
    ///         live owner differs from the list it came from.
    function invariant_votableIsASubsetOfTheIndex() public view {
        for (uint256 o; o < handler.ownerCount(); ++o) {
            address owner = handler.owners(o);
            uint256[] memory votable = registry.getSubscriptions(owner);
            for (uint256 i; i < votable.length; ++i) {
                assertTrue(registry.isTokenSubscribed(votable[i]), "votable token not indexed");
                (address live,,,) = registry.getPosition(votable[i]);
                assertEq(live, owner, "votable token owned by someone else");
                assertTrue(registry.subscriptionEligible(votable[i]), "votable token not eligible");
            }
        }
    }
}

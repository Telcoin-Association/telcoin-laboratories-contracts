// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";
import {MockStateView} from "../mocks/MockStateView.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PositionRegistryHandler
/// @notice Drives every write path of the registry in random interleavings for the invariant
///         suite: subscribe, unsubscribe, burn, transfer, drain, refill, prune, force-evict,
///         resubscribe, allowlist and floor changes, and the unlock guard flipping. Keeps a shadow
///         of what v4 would report so the invariants can be checked against it.
/// @dev    Every action is total: a call that the registry is expected to refuse is caught, so the
///         fuzzer keeps exploring rather than discarding the run. What must never happen is a
///         revert the registry does not expect, which the handler lets through.
contract PositionRegistryHandler is Test {
    PositionRegistry public registry;
    MockPositionManager public pm;
    MockStateView public sv;
    MockPoolManager public poolManager;

    address public admin;
    address public subscriber;
    PoolKey public poolKey;
    PoolId public poolId;

    uint256 internal constant TOKENS = 12;
    uint256 internal constant OWNERS = 4;

    address[] public owners;
    /// @dev v4's view: which tokens are subscribed to our subscriber.
    mapping(uint256 => bool) public v4Subscribed;
    mapping(uint256 => bool) public exists;
    /// @dev Tokens whose v4 unsubscribe never reached the registry (the gas-limited notification
    ///      v4 swallows). The only way the index may hold a token v4 does not.
    mapping(uint256 => bool) public swallowed;

    uint256 public calls;

    constructor(
        PositionRegistry _registry,
        MockPositionManager _pm,
        MockStateView _sv,
        MockPoolManager _poolManager,
        address _admin,
        address _subscriber,
        PoolKey memory _poolKey
    ) {
        registry = _registry;
        pm = _pm;
        sv = _sv;
        poolManager = _poolManager;
        admin = _admin;
        subscriber = _subscriber;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        for (uint256 i; i < OWNERS; ++i) {
            owners.push(makeAddr(string.concat("owner", vm.toString(i))));
        }
    }

    // -----------
    // Actions
    // -----------

    function mint(uint256 tokenSeed, uint256 ownerSeed, uint128 liquidity) external {
        uint256 tokenId = _token(tokenSeed);
        if (exists[tokenId]) return;
        pm.setPosition(tokenId, poolKey, -600, 600, liquidity, _owner(ownerSeed));
        exists[tokenId] = true;
        ++calls;
    }

    /// @dev The v4 subscribe flow: v4 records the subscriber first, then notifies. A refused
    ///      notification reverts the whole v4 call, so the record is undone.
    function subscribe(uint256 tokenSeed) external {
        uint256 tokenId = _token(tokenSeed);
        if (!exists[tokenId] || v4Subscribed[tokenId]) return;
        pm.setSubscriber(tokenId, subscriber);
        vm.prank(subscriber);
        try registry.handleSubscribe(tokenId) {
            v4Subscribed[tokenId] = true;
            swallowed[tokenId] = false;
        } catch {
            pm.setSubscriber(tokenId, address(0));
        }
        ++calls;
    }

    /// @dev The v4 unsubscribe flow, and the notification v4 swallows on a gas-limited call. The
    ///      `swallow` flag models that: v4 forgets the subscription, the registry never hears.
    function unsubscribe(uint256 tokenSeed, bool swallow) external {
        uint256 tokenId = _token(tokenSeed);
        if (!v4Subscribed[tokenId]) return;
        v4Subscribed[tokenId] = false;
        pm.setSubscriber(tokenId, address(0));
        if (swallow) {
            swallowed[tokenId] = true;
        } else {
            vm.prank(subscriber);
            registry.handleUnsubscribe(tokenId);
        }
        ++calls;
    }

    function transfer(uint256 tokenSeed, uint256 ownerSeed, bool swallow) external {
        uint256 tokenId = _token(tokenSeed);
        if (!exists[tokenId]) return;
        // v4 unsubscribes on transfer
        if (v4Subscribed[tokenId]) {
            v4Subscribed[tokenId] = false;
            pm.setSubscriber(tokenId, address(0));
            if (swallow) {
                swallowed[tokenId] = true;
            } else {
                vm.prank(subscriber);
                registry.handleUnsubscribe(tokenId);
            }
        }
        pm.setOwner(tokenId, _owner(ownerSeed));
        ++calls;
    }

    function burn(uint256 tokenSeed) external {
        uint256 tokenId = _token(tokenSeed);
        if (!exists[tokenId]) return;
        bool wasSubscribed = v4Subscribed[tokenId];
        v4Subscribed[tokenId] = false;
        exists[tokenId] = false;
        pm.burn(tokenId);
        if (wasSubscribed) {
            vm.prank(subscriber);
            registry.handleBurn(tokenId, address(0));
        }
        ++calls;
    }

    function setLiquidity(uint256 tokenSeed, uint128 liquidity) external {
        uint256 tokenId = _token(tokenSeed);
        if (!exists[tokenId]) return;
        pm.setLiquidity(tokenId, liquidity);
        ++calls;
    }

    function prune(uint256 tokenSeed) external {
        uint256 tokenId = _token(tokenSeed);
        try registry.pruneSubscription(tokenId) {} catch {}
        ++calls;
    }

    function resubscribe(uint256 tokenSeed) external {
        uint256 tokenId = _token(tokenSeed);
        try registry.resubscribe(tokenId) {} catch {}
        ++calls;
    }

    function forceUnsubscribe(uint256 tokenSeed) external {
        uint256 tokenId = _token(tokenSeed);
        vm.prank(admin);
        registry.forceUnsubscribe(tokenId);
        ++calls;
    }

    function setFloor(uint128 floor) external {
        vm.prank(admin);
        registry.setMinLiquidity(poolId, floor % 20_000);
        ++calls;
    }

    function toggleAllowlist() external {
        vm.startPrank(admin);
        if (registry.poolAllowed(poolId)) registry.deregisterPool(poolId);
        else registry.registerPool(poolKey);
        vm.stopPrank();
        ++calls;
    }

    function toggleInRange() external {
        vm.prank(admin);
        registry.setInRangeRequired(!registry.inRangeRequired());
        ++calls;
    }

    function movePrice(int24 tick) external {
        tick = int24(bound(tick, -1200, 1200));
        sv.setSlot0(poolId, 79228162514264337593543950336, tick);
        ++calls;
    }

    /// @dev Flips the PoolManager lock. While unlocked, subscribe, prune and resubscribe must all
    ///      refuse; the invariants then check nothing moved.
    function setUnlocked(bool unlocked) external {
        poolManager.setUnlocked(unlocked);
        ++calls;
    }

    // -----------
    // Views for the invariants
    // -----------

    function ownerCount() external pure returns (uint256) {
        return OWNERS;
    }

    function tokenCount() external pure returns (uint256) {
        return TOKENS;
    }

    function _token(uint256 seed) internal pure returns (uint256) {
        return 1 + (seed % TOKENS);
    }

    function _owner(uint256 seed) internal view returns (address) {
        return owners[seed % OWNERS];
    }
}

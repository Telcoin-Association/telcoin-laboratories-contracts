// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPositionRegistry} from "../../../contracts/telx/interfaces/IPositionRegistry.sol";

/// @title FlashPruneAttacker
/// @notice Models the flash-liquidity mass-prune attack: call the registry from inside a
///         `PoolManager.unlock` callback, where the caller controls every piece of pool state the
///         registry might read. The registry must refuse to act there at all.
/// @dev Records the prune's revert data rather than letting it bubble, so the enclosing unlock
///      completes and the test can assert on exactly what the registry said. No liquidity is
///      actually added: the guard fires before any pool state is consulted, and proving it fires
///      is the point.
contract FlashPruneAttacker is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IPositionRegistry public immutable registry;

    bytes public lastRevert;
    bool public pruneSucceeded;

    constructor(IPoolManager _poolManager, IPositionRegistry _registry) {
        poolManager = _poolManager;
        registry = _registry;
    }

    function attack(uint256 tokenId) external {
        poolManager.unlock(abi.encode(tokenId));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        uint256 tokenId = abi.decode(data, (uint256));
        try registry.pruneSubscription(tokenId) {
            pruneSucceeded = true;
        } catch (bytes memory reason) {
            lastRevert = reason;
        }
        return "";
    }
}

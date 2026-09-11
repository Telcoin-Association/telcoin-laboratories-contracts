// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "../abstract/PositionManagerAuth.sol";

/**
 * @title TELxSubscriber
 * @author Robriks 📯️📯️📯️.eth
 * @notice Implements ISubscriber to relay Uniswap v4 position events into the PositionRegistry.
 * @dev https://docs.uniswap.org/contracts/v4/quickstart/subscriber
 *      The `registry` pointer is owner-swappable so a redeployed (e.g. thinned) registry can be
 *      put behind this subscriber without redeploying it, preserving every LP's existing v4
 *      subscription. `notifyModifyLiquidity` enforces the subscription liquidity threshold that
 *      the now-removed TELxIncentiveHook used to enforce.
 */
contract TELxSubscriber is ISubscriber, PositionManagerAuth, Ownable2Step {
    /// @notice Registry that mirrors subscription state for the Snapshot governance strategy.
    IPositionRegistry public registry;

    /// @notice Emitted when the owner repoints the subscriber at a new registry.
    event RegistryUpdated(IPositionRegistry indexed oldRegistry, IPositionRegistry indexed newRegistry);

    error ZeroAddress();

    constructor(IPositionRegistry _registry, address _positionManager, address _owner)
        PositionManagerAuth(_positionManager)
        Ownable(_owner)
    {
        if (address(_registry) == address(0)) revert ZeroAddress();
        registry = _registry;
    }

    /// @notice Repoints the subscriber at a new registry.
    /// @dev Restricted to the owner. Lets governance swap the registry implementation without
    ///      redeploying the subscriber, so existing v4 subscriptions keep firing callbacks here.
    function setRegistry(IPositionRegistry _registry) external onlyOwner {
        if (address(_registry) == address(0)) revert ZeroAddress();
        emit RegistryUpdated(registry, _registry);
        registry = _registry;
    }

    /// @notice Notifies the registry that an LP token is being subscribed.
    /// @dev Only callable by the PositionManager.
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager(msg.sender) {
        registry.handleSubscribe(tokenId);
    }

    /// @notice Notifies the registry during unsubscriptions and LP token transfers.
    /// @dev Deletes the registry's stored subscription, requiring LPs to resubscribe after transfers.
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager(msg.sender) {
        registry.handleUnsubscribe(tokenId);
    }

    /// @notice Enforces subscription eligibility on every liquidity modification.
    /// @dev Replaces the bookkeeping the TELxIncentiveHook performed: a subscribed position that is
    ///      no longer `subscriptionEligible` (below the liquidity threshold, or out of range while
    ///      the in-range requirement is enabled) is unsubscribed. Every branch is a cheap read, so
    ///      this can never revert a v4 liquidity modification.
    function notifyModifyLiquidity(uint256 tokenId, int256, BalanceDelta)
        external
        override
        onlyPositionManager(msg.sender)
    {
        if (registry.isTokenSubscribed(tokenId) && !registry.subscriptionEligible(tokenId)) {
            registry.handleUnsubscribe(tokenId);
        }
    }

    /// @notice Notifies the registry of a position burn.
    /// @dev Deletes the registry's stored subscription for the burned position.
    function notifyBurn(uint256 tokenId, address owner, PositionInfo, uint256, BalanceDelta)
        external
        override
        onlyPositionManager(msg.sender)
    {
        registry.handleBurn(tokenId, owner);
    }
}

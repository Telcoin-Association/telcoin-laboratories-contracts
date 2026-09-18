// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "../abstract/PositionManagerAuth.sol";

/**
 * @title TELxSubscriber
 * @author Robriks 📯️📯️📯️.eth
 * @notice Implements ISubscriber to relay Uniswap v4 position events into the PositionRegistry.
 * @dev https://docs.uniswap.org/contracts/v4/quickstart/subscriber
 *
 *      The v4 Notifier bubbles reverts from `notifyModifyLiquidity` and `notifyBurn` up into the
 *      LP's own transaction, so a registry that reverts for any reason would block every
 *      subscribed LP's increase, decrease, collect and burn. Those two forwards are therefore
 *      wrapped: a registry failure is swallowed and the LP's operation completes. The registry's
 *      index can then be stale, which `getSubscriptions` already tolerates by filtering live, and
 *      which `pruneSubscription` can clean up. `notifySubscribe` is deliberately not wrapped: a
 *      subscribe that the registry rejects should fail loudly at the LP's opt-in, not silently
 *      leave v4 subscribed and the registry empty.
 *
 *      `setRegistry` lets governance swap the registry implementation without redeploying the
 *      subscriber, preserving every LP's existing v4 subscription. It refuses a target with no code
 *      or one that has not granted this subscriber SUBSCRIBER_ROLE, and ownership can never be
 *      renounced, so the pointer can never be frozen on a dead or unwired registry.
 */
contract TELxSubscriber is ISubscriber, PositionManagerAuth, Ownable2Step {
    /// @notice Registry that mirrors subscription state for the Snapshot governance strategy.
    IPositionRegistry public registry;

    /// @notice Emitted when the owner repoints the subscriber at a new registry.
    event RegistryUpdated(IPositionRegistry indexed oldRegistry, IPositionRegistry indexed newRegistry);

    /// @notice Emitted when a forwarded notification was swallowed rather than allowed to block
    ///         the LP's transaction. A signal for ops that the registry is misconfigured.
    event NotificationDropped(uint256 indexed tokenId, bytes4 indexed selector);

    error ZeroAddress();
    error RegistryHasNoCode(address registry);
    error RegistryNotWired(address registry);
    error CannotRenounce();

    bytes32 private constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");

    constructor(IPositionRegistry _registry, address _positionManager, address _owner)
        PositionManagerAuth(_positionManager)
        Ownable(_owner)
    {
        if (address(_registry) == address(0)) revert ZeroAddress();
        registry = _registry;
    }

    // -----------
    // Administration
    // -----------

    /// @notice Repoints the subscriber at a new registry.
    /// @dev Restricted to the owner. The target must be a deployed contract that has already
    ///      granted this subscriber SUBSCRIBER_ROLE; otherwise every forwarded notification would
    ///      fail from the moment of the switch.
    function setRegistry(IPositionRegistry _registry) external onlyOwner {
        address target = address(_registry);
        if (target == address(0)) revert ZeroAddress();
        if (target.code.length == 0) revert RegistryHasNoCode(target);
        if (!IAccessControl(target).hasRole(SUBSCRIBER_ROLE, address(this))) revert RegistryNotWired(target);

        emit RegistryUpdated(registry, _registry);
        registry = _registry;
    }

    /// @notice Disabled. An ownerless subscriber could never be repointed, which would freeze every
    ///         LP subscription on whatever registry it last held.
    function renounceOwnership() public view override onlyOwner {
        revert CannotRenounce();
    }

    // -----------
    // ISubscriber
    // -----------

    /// @notice Notifies the registry that an LP token is being subscribed.
    /// @dev Only callable by the PositionManager. Not wrapped: a rejected subscribe must revert the
    ///      LP's opt-in so v4 and the registry never disagree about a fresh subscription.
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager(msg.sender) {
        registry.handleSubscribe(tokenId);
    }

    /// @notice Notifies the registry during unsubscriptions and LP token transfers.
    /// @dev v4 already wraps this notification in its own try/catch with a gas limit, so it can
    ///      never block the LP regardless of what the registry does.
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager(msg.sender) {
        registry.handleUnsubscribe(tokenId);
    }

    /// @notice Fired by v4 on every liquidity modification of a subscribed position. A no-op.
    /// @dev Three reasons this touches nothing. It runs inside the LP's own `unlock`, where pool
    ///      state is whatever the transaction has made it, so any eligibility read here would be
    ///      the one place a transient state (a price briefly out of range during a collect, say)
    ///      could drop a healthy subscription. The registry decides eligibility live at read time
    ///      anyway, so mirroring it into storage buys nothing. And with no external call on this
    ///      path, the subscriber cannot affect an LP's increase, decrease or collect under any
    ///      registry configuration whatsoever. A fully drained position stops voting immediately
    ///      (zero liquidity is ineligible) and anyone may `pruneSubscription` it afterwards.
    function notifyModifyLiquidity(uint256, int256, BalanceDelta)
        external
        view
        override
        onlyPositionManager(msg.sender)
    {}

    /// @notice Notifies the registry of a position burn.
    /// @dev Wrapped so a misconfigured registry can never prevent an LP from burning.
    function notifyBurn(uint256 tokenId, address owner, PositionInfo, uint256, BalanceDelta)
        external
        override
        onlyPositionManager(msg.sender)
    {
        try registry.handleBurn(tokenId, owner) {}
        catch {
            emit NotificationDropped(tokenId, ISubscriber.notifyBurn.selector);
        }
    }
}

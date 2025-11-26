// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionManagerAuth} from "../abstract/PositionManagerAuth.sol";

/**
 * @title TELxSubscriber
 * @author Robriks 📯️📯️📯️.eth
 * @notice Implements ISubscriber to receive Uniswap v4 position transfer events
 * @dev https://docs.uniswap.org/contracts/v4/quickstart/subscriber
 */
contract TELxSubscriber is ISubscriber, PositionManagerAuth {
    IPositionRegistry public immutable registry;

    constructor(IPositionRegistry _registry, address _positionManager) PositionManagerAuth(_positionManager) {
        registry = _registry;
    }

    /// @notice Notifies registry that an LP token is being subscribed for the first time
    /// @dev Only callable by the PositionManager to trigger internal state update in the PositionRegistry
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager(msg.sender) {
        registry.handleSubscribe(tokenId);
    }

    /// @notice Notifies registry during unsubscriptions and LP token transfers
    /// @dev Deletes registry's stored subscription, requiring LPs to resubscribe in the case of transfers
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager(msg.sender) {
        registry.handleUnsubscribe(tokenId);
    }

    /// @notice No-op as liquidity modifications are recorded for all positions
    function notifyModifyLiquidity(uint256 tokenId, int256, BalanceDelta)
        external
        override
        onlyPositionManager(msg.sender)
    {}

    /// @notice Notifies registry of position burn
    /// @dev Deletes registry's stored subscription and permanently marks its position burned
    function notifyBurn(uint256 tokenId, address owner, PositionInfo, uint256, BalanceDelta)
        external
        override
        onlyPositionManager(msg.sender)
    {
        registry.handleBurn(tokenId, owner);
    }
}

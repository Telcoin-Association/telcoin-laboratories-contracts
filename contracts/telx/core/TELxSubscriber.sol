// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/**
 * @title TELxSubscriber
 * @author Robriks 📯️📯️📯️.eth
 * @notice Implements ISubscriber to receive Uniswap v4 position transfer events
 * @dev https://docs.uniswap.org/contracts/v4/quickstart/subscriber
 */
contract TELxSubscriber is ISubscriber {    
    IPositionRegistry public immutable registry;
    address public immutable positionManager;

    error OnlyPositionManager();

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) {
            revert OnlyPositionManager();
        }
        _;
    }

    constructor(IPositionRegistry _registry, address _positionManager) {
        registry = _registry;
        positionManager = _positionManager;
    }

    /// @notice Notifies registry that an LP token is being subscribed for the first time
    /// @dev Only callable by the PositionManager to trigger internal state update in the PositionRegistry
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager {
        registry.handleSubscribe(tokenId);
    }

    /// @notice Notifies registry during unsubscriptions and LP token transfers
    /// @dev Deletes registry's stored subscription, requiring LPs to resubscribe in the case of transfers
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager {
        registry.handleUnsubscribe(tokenId);
    }

    /// @notice Notifies registry of liquidity modification
    /// @dev Updates registry's stored subscription with a fee checkpoint
    function notifyModifyLiquidity(
        uint256,
        int256,
        BalanceDelta
    ) external override onlyPositionManager {
        //todo: update fee tracking in PositionRegistry
        // registry.handleModifyLiquidity(tokenId);
    }

    /// @notice Notifies registry of position burn
    /// @dev Deletes registry's stored subscription and permanently marks its position burned
    function notifyBurn(
        uint256 tokenId,
        address,
        PositionInfo,
        uint256,
        BalanceDelta
    ) external override onlyPositionManager {
        registry.handleBurn(tokenId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";

/**
 * @title TELxSubscriber
 * @author Amir M. Shirif
 * @notice Implements ISubscriber to receive Uniswap v4 position transfer events
 * @dev https://docs.uniswap.org/contracts/v4/quickstart/subscriber
 */
contract TELxSubscriber is ISubscriber {
    IPositionRegistry public immutable registry;
    address public immutable positionManager;

    constructor(IPositionRegistry _registry, address _positionManager) {
        registry = _registry;
        positionManager = _positionManager;
    }

    /// @notice Notifies this contract that a tokenId has been transferred to a new subscriber
    /// @dev Only callable by the PositionManager; triggers internal state update in the PositionRegistry
    /// @param tokenId The NFT tokenId representing a Uniswap LP position
    function notifySubscribe(uint256 tokenId, bytes memory) external override {
        require(
            msg.sender == positionManager,
            "TELxSubscriber: Caller is not Position Manager"
        );
        registry.handleSubscribe(tokenId);
    }

    /// @notice No-op for unsubscribe events
    /// @dev Required to satisfy ISubscriber but unused in this implementation
    function notifyUnsubscribe(uint256) external pure override {}

    /// @notice No-op for liquidity modification events
    /// @dev Required to satisfy ISubscriber but unused in this implementation
    function notifyModifyLiquidity(
        uint256,
        int256,
        BalanceDelta
    ) external pure override {}

    /// @notice No-op for burn events
    /// @dev Required to satisfy ISubscriber but unused in this implementation
    function notifyBurn(
        uint256,
        address,
        PositionInfo,
        uint256,
        BalanceDelta
    ) external pure override {}
}

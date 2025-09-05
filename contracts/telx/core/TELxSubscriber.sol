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
    /// @param tokenId The NFT tokenId representing a Uniswap LP position
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager {
        registry.handleSubscribe(tokenId);
    }

    /// @notice Notifies registry during unsubscription flow, ie LP token transfers
    /// @dev Effectively renders LP tokens untransferrable
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager {
        registry.handleUnsubscribe(tokenId);
    }

    /// @notice No-op for liquidity modification events
    /// @dev Required to satisfy ISubscriber but unused in this implementation
    function notifyModifyLiquidity(
        uint256,
        int256,
        BalanceDelta
    ) external pure override onlyPositionManager {
        //todo: update liquidity and fee tracking in PositionRegistry. 
        //todo: must accommodate liquidity increases or fee collection
        //todo: must accomodate unsubscribed vs subscribed position state
        // registry.handleModifyLiquidity(tokenId);
    }

    /// @notice No-op for burn events
    /// @dev Required to satisfy ISubscriber but unused in this implementation
    function notifyBurn(
        uint256,
        address,
        PositionInfo,
        uint256,
        BalanceDelta
    ) external pure override onlyPositionManager {
        //todo: update PositionRegistry state by deleting position. tokenIDs not reused so full delete
        //todo: must accomodate unsubscribed () vs subscribed (delete) position state
        // registry.handleBurn(tokenId);
    }
}

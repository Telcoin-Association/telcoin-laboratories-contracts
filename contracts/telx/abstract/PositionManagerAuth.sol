// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract PositionManagerAuth {
    address public immutable positionManager;

    error OnlyPositionManager();

    modifier onlyPositionManager(address sender) {
        if (sender != positionManager) {
            revert OnlyPositionManager();
        }
        _;
    }

    constructor(address _positionManager) {
        positionManager = _positionManager;
    }
}

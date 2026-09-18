// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract PositionManagerAuth {
    address public immutable positionManager;

    error OnlyPositionManager();
    error NotAContract(address target);

    modifier onlyPositionManager(address sender) {
        if (sender != positionManager) {
            revert OnlyPositionManager();
        }
        _;
    }

    constructor(address _positionManager) {
        // Every notification is gated on this address, so a wrong one is a subscriber that nothing
        // can ever reach; refuse the obvious mistakes at construction.
        if (_positionManager.code.length == 0) revert NotAContract(_positionManager);
        positionManager = _positionManager;
    }
}

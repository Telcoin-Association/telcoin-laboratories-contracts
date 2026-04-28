// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";

/// @title MockSource
/// @notice Minimal ISource implementation backed by a writable balance map. Used by
///         VotingWeightCalculator tests to drive the iteration logic with controllable
///         per-voter weights without depending on any live snapshot adapter.
contract MockSource is ISource, IERC165 {
    mapping(address => uint256) private _balances;

    function setBalanceOf(address account, uint256 value) external {
        _balances[account] = value;
    }

    function balanceOf(address voter) external view override returns (uint256) {
        return _balances[voter];
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ISource).interfaceId;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStakingRewards} from "contracts/snapshot/interfaces/IStakingRewards.sol";

/// @title MockStakingRewards
/// @notice Minimal IStakingRewards stand-in with writable backing maps so tests can stage
///         per-account `balanceOf` / `earned` values plus a `totalSupply` and assert the
///         StakingRewardsAdaptor reads them back through the ISource surface as expected.
contract MockStakingRewards is IStakingRewards {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _earned;
    uint256 private _totalSupply;

    function setBalance(address account, uint256 value) external {
        _balances[account] = value;
    }

    function setEarned(address account, uint256 value) external {
        _earned[account] = value;
    }

    function setTotalSupply(uint256 value) external {
        _totalSupply = value;
    }

    function earned(address account) external view override returns (uint256) {
        return _earned[account];
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
}

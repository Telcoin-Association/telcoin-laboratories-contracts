// contracts/test/MockLockup.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract TestLockup {
    uint128 public amountToWithdraw = 100;

    function setWithdrawAmount(uint128 _amount) external {
        amountToWithdraw = _amount;
    }

    function withdrawMax(uint256, address) external view returns (uint128) {
        return amountToWithdraw;
    }
}

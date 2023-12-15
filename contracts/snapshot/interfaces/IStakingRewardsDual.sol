//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakingRewardsDual {
    function earnedA(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

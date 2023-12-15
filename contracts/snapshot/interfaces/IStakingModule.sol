//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakingModule {
    function balanceOf(
        address account,
        bytes calldata auxData
    ) external view returns (uint256);
}

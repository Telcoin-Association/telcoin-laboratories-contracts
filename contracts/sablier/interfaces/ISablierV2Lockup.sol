// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.16;

interface ISablierV2Lockup {
    function withdrawMax(
        uint256 streamId,
        address to
    ) external returns (uint128 withdrawnAmount);
}

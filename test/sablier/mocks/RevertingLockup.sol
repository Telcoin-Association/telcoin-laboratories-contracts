// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISablierV2Lockup} from "contracts/sablier/interfaces/ISablierV2Lockup.sol";

/// @title RevertingLockup
/// @notice ISablierV2Lockup stand-in whose every withdraw-side call reverts. Used by both
///         CouncilMember.t.sol and CouncilMemberFork.t.sol to verify CouncilMember handles
///         the catch path in `_retrieve` without losing accounting.
contract RevertingLockup is ISablierV2Lockup {
    function withdrawMax(uint256, address) external pure returns (uint128) {
        revert("withdraw failed");
    }

    function withdrawableAmountOf(uint256) external pure returns (uint128) {
        revert("withdrawableAmountOf failed");
    }
}

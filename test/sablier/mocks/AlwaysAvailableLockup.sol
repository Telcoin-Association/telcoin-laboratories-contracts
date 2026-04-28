// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "contracts/sablier/interfaces/ISablierV2Lockup.sol";

/// @title AlwaysAvailableLockup
/// @notice Lockup that always has tokens available, removing the same-block limitation of
///         TestSablierV2Lockup so `_retrieve()` is non-trivial during reentrancy. Used by the
///         CouncilMember reentrancy tests to keep the callback window open with real value.
contract AlwaysAvailableLockup is ISablierV2Lockup {
    IERC20 public token;
    uint256 public constant DRIP = 100;

    constructor(IERC20 token_) {
        token = token_;
    }

    function withdrawMax(uint256, address to) external returns (uint128) {
        token.transfer(to, DRIP);
        return uint128(DRIP);
    }

    function withdrawableAmountOf(uint256) external pure returns (uint128) {
        return uint128(DRIP);
    }
}

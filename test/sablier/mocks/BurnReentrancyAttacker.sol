// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CouncilMember} from "contracts/sablier/core/CouncilMember.sol";
import {ITokenReceiver} from "../interfaces/ITokenReceiver.sol";

/// @title BurnReentrancyAttacker
/// @notice Exploits the burn() reentrancy window. During the TELCOIN.safeTransfer callback
///         inside CouncilMember.burn, attempts to reenter via claim() and records what it
///         observes. The recorded observations let the test assert the reentrancy invariant
///         (state visible during the callback should be consistent post-effect, no stale slots).
contract BurnReentrancyAttacker is ITokenReceiver {
    CouncilMember public target;
    uint256 public ownedTokenId;
    bool private _entered;

    // Observations captured during the callback window
    bool public callbackFired;
    bool public reentrantClaimSucceeded;
    bool public burnedSlotAccessible;
    uint256 public burnedSlotBalance;
    uint256 public totalSupplyDuringCallback;

    constructor(CouncilMember target_, uint256 ownedTokenId_) {
        target = target_;
        ownedTokenId = ownedTokenId_;
    }

    function onTokenReceived(address, uint256) external {
        if (!_entered) {
            _entered = true;
            callbackFired = true;

            // Snapshot state visible during the reentrancy window
            totalSupplyDuringCallback = target.totalSupply();

            // Is the burned slot still in the balances array?
            try target.balances(2) returns (uint256 bal) {
                burnedSlotAccessible = true;
                burnedSlotBalance = bal;
            } catch {
                burnedSlotAccessible = false;
            }

            // Attempt a reentrant claim (triggers _retrieve internally).
            // Uses try/catch so the outer burn() still completes even if
            // a future reentrancy guard reverts this call.
            try target.claim(ownedTokenId, 0) {
                reentrantClaimSucceeded = true;
            } catch {
                reentrantClaimSucceeded = false;
            }
        }
    }
}

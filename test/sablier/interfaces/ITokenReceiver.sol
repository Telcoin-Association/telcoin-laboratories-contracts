// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenReceiver
/// @notice ERC-777-style hook interface used by the CouncilMember reentrancy tests. The
///         CallbackERC20 mock invokes `onTokenReceived` after every balance update, which lets
///         attacker contracts re-enter CouncilMember through the open callback window.
interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

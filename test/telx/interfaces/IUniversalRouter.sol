// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniversalRouter
/// @notice Minimal Uniswap v4 Universal Router interface for tests that need to drive a swap
///         through the live router without pulling the full universal-router dependency.
interface IUniversalRouter {
    function execute(bytes memory commands, bytes[] memory inputs, uint256 deadline) external payable;
}

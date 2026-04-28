// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPermit2
/// @notice Minimal Permit2 interface for test files that need to grant the Uniswap v4
///         PositionManager / Universal Router approval over an ERC-20 without pulling in
///         the full Permit2 dependency. The on-chain Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`)
///         exposes the same selector; tests interact with it via `vm.etch` or by talking to
///         the live contract on a fork.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

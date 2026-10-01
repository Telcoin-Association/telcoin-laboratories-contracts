// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ForkOrSkip
/// @notice Selects a fork from an RPC URL in the environment, or skips the calling test when the
///         variable is unset.
/// @dev    Every fork suite in this repo reads its RPC URL the same way, and the difference
///         between `vm.envString` and this is the difference between a suite that fails in an
///         environment without secrets and one that reports itself skipped. CI runs `forge test`
///         with whatever secrets it has; a fork suite that cannot run says so instead of failing
///         the build, and a fork suite that can run does. Called from `setUp`, the skip applies to
///         every test in the contract; called from a test, to that test alone.
///
///         `vm.skip(true)` ends the current call, so nothing after it in the caller executes.
library ForkOrSkip {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Forks the latest block of the chain at `envVar`, or skips.
    function select(string memory envVar) internal returns (uint256 forkId) {
        return vm.createSelectFork(_rpcOrSkip(envVar));
    }

    /// @notice Forks `blockNumber` of the chain at `envVar`, or skips.
    function select(string memory envVar, uint256 blockNumber) internal returns (uint256 forkId) {
        return vm.createSelectFork(_rpcOrSkip(envVar), blockNumber);
    }

    function _rpcOrSkip(string memory envVar) private returns (string memory rpc) {
        rpc = vm.envOr(envVar, string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
    }
}

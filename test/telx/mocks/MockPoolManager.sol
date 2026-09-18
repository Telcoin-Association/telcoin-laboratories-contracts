// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockPoolManager
/// @notice Stand-in for the Uniswap v4 PoolManager exposing only the transient lock slot the
///         PositionRegistry reads through `TransientStateLibrary.isUnlocked`. Tests flip the lock
///         to prove that state-changing registry paths refuse to run inside an unlock.
/// @dev `exttload` returns the mocked lock state for the real `Lock.IS_UNLOCKED_SLOT` and zero for
///      anything else, matching a PoolManager that is otherwise untouched.
contract MockPoolManager {
    bytes32 private constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    bool private _unlocked;

    /// @notice Simulates entering (true) or leaving (false) a `PoolManager.unlock` callback.
    function setUnlocked(bool unlocked) external {
        _unlocked = unlocked;
    }

    function exttload(bytes32 slot) external view returns (bytes32) {
        if (slot == IS_UNLOCKED_SLOT) return bytes32(uint256(_unlocked ? 1 : 0));
        return bytes32(0);
    }
}

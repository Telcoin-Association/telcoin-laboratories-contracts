// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe
/// @notice Minimal Safe (Gnosis Safe) surface needed to prove that a checked-in multisig constant
///         really is a deployed Safe rather than an EOA or an unrelated contract.
/// @dev    The vendored `@safe-utils/ISafeSmartAccount` covers transaction execution, not
///         ownership introspection, so the two accessors we need are declared here instead of
///         pulling in the full safe-smart-account tree.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

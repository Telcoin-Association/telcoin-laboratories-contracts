// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProxyAdminLike
/// @notice Minimal interface for OpenZeppelin's ProxyAdmin. Used by the CouncilMember
///         upgrade fork test to call `upgradeAndCall` against the live ProxyAdmin without
///         pulling in the full ProxyAdmin source. Names mirror upstream OZ.
interface IProxyAdminLike {
    function owner() external view returns (address);

    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes memory data
    ) external payable;
}

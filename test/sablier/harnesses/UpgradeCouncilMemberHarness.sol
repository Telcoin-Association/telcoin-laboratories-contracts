// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeCouncilMember} from "script/sablier/UpgradeCouncilMember.s.sol";

/// @title UpgradeCouncilMemberHarness
/// @notice Test harness over the UpgradeCouncilMember deploy script that exposes its
///         internal helpers (`getProxies`, `_readAddressSlot`, `runWithSigner`) so the
///         fork test can drive each step independently. Mirrors the standard
///         "expose internals via a subclass" harness pattern.
contract UpgradeCouncilMemberHarness is UpgradeCouncilMember {
    function exposed_getProxies() external pure returns (address[] memory) {
        return getProxies();
    }

    function exposed_readAddressSlot(
        address target,
        bytes32 slot
    ) external view returns (address) {
        return _readAddressSlot(target, slot);
    }

    function exposed_runWithSigner(
        address signer
    ) external returns (address newImplementation) {
        return runWithSigner(signer);
    }
}

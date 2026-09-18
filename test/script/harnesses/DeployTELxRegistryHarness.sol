// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Safe} from "@safe-utils/Safe.sol";
import {BaseDeployTELxRegistry} from "../../../script/telx/base/BaseDeployTELxRegistry.s.sol";

/// @title DeployTELxRegistryHarness
/// @notice Drives `BaseDeployTELxRegistry._deployOnChain` from a test, with the safe-utils client
///         initialized from arguments rather than from the environment.
/// @dev    The production script initializes safe-utils in `setUp` from `DEPLOYER_SAFE_ADDRESS`
///         and `SIGNER_ADDRESS_n`. A test cannot set those without `vm.setEnv`, which leaks into
///         every other test in the process, so the harness sets the same internal state directly
///         and always in simulation mode. Everything downstream of that, the batch assembly and
///         the storage-manipulated `execTransaction` against the real Safe, is the script's own
///         code.
contract DeployTELxRegistryHarness is BaseDeployTELxRegistry {
    using Safe for *;

    function initForSimulation(address safeAddress, address[] memory owners) external {
        deployerSafeAddress = safeAddress;
        safe.initialize(safeAddress);
        delete signers;
        for (uint256 i; i < owners.length; ++i) {
            signers.push(owners[i]);
        }
        signer = signers[0];
        _isSimulation = true;
        currentNonce = safe.getNonce();
        _loadChainTargets();
    }

    /// @notice Runs the per-chain batch for `chainName` against the fork the test has selected.
    function deployOn(string memory chainName) external {
        _deployOnChain(chainTarget(chainName));
    }

    function chainTarget(string memory chainName) public view returns (ChainTarget memory) {
        for (uint256 i; i < allChains.length; ++i) {
            if (keccak256(bytes(allChains[i].name)) == keccak256(bytes(chainName))) return allChains[i];
        }
        revert("unknown chain");
    }
}

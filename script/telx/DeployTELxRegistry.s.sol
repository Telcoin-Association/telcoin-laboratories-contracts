// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDeployTELxRegistry} from "./base/BaseDeployTELxRegistry.s.sol";

/**
 * @title DeployTELxRegistry
 * @notice Mainnet configuration for the TELx registry deploy. All logic lives in
 *         `BaseDeployTELxRegistry`; this only initializes the Safe client and loads the chain list.
 *
 *         Simulate first. This executes the batch against a local fork by manipulating Safe
 *         storage, so it needs no hardware wallet and proposes nothing:
 *
 *           CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
 *             script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
 *             --rpc-url $POLYGON_RPC_URL --ffi -vvvv
 *
 *         Then propose to the Safe Transaction Service, signing with the hardware wallet:
 *
 *           CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
 *             script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
 *             --rpc-url $POLYGON_RPC_URL --ffi --broadcast -vvvv
 *
 *         After the Safe executes, run `VerifyTELxRegistry` against the same chain.
 *
 *         `--rpc-url` is required even though `run()` forks each chain itself: safe-utils reads the
 *         Safe's nonce during `setUp()`, before the loop starts, and that read needs a chain where
 *         the Safe exists. `FOUNDRY_PROFILE=deploy` is required because it is the only profile with
 *         FFI and filesystem writes enabled. The governance Safe is 2-of-8, so at least two owner
 *         addresses (`SIGNER_ADDRESS_0`, `SIGNER_ADDRESS_1`) are needed for the signature check.
 */
contract DeployTELxRegistry is BaseDeployTELxRegistry {
    function setUp() public {
        _initializeSafeMultiSig();
        _loadChainTargets();
    }
}

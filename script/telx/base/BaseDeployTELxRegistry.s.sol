// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Safe} from "@safe-utils/Safe.sol";
import {SaltMath} from "forge-deploy-utils/libraries/SaltMath.sol";
import {ICreateX} from "forge-deploy-utils/interfaces/ICreateX.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionRegistry} from "../../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../../contracts/telx/interfaces/IPositionRegistry.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Salts} from "../../shared/Salts.sol";
import {TELxPools} from "../../shared/TELxPools.sol";
import {TELxRegistryScriptBase} from "./TELxRegistryScriptBase.sol";

/**
 * @title BaseDeployTELxRegistry
 * @notice Deploys the thin TELx PositionRegistry and its TELxSubscriber, as one Safe MultiSend batch
 *         per chain. The concrete `DeployTELxRegistry` script only wires up configuration.
 * @dev    Runs through safe-utils rather than an EOA because both contracts are governance
 *         infrastructure: the registry's DEFAULT_ADMIN_ROLE decides whether the in-range
 *         eligibility gate is on, and the subscriber's owner can repoint every existing LP
 *         subscription at a different registry. Neither should ever have sat behind a deployer key.
 *
 *         Deploying through CreateX in cross-chain mode means the registry and the subscriber land
 *         at the SAME address on all three chains, even though each chain passes a different
 *         PositionManager and StateView, because a CREATE3 address depends only on the factory, the
 *         deployer and the salt. That is worth preserving deliberately: the Snapshot strategy and
 *         every downstream integration then carry one address instead of three.
 *
 *         Everything for a chain goes out as a single MultiSend: both deploys, both role grants,
 *         and one `registerPool` per catalog pool on that chain. The registry can never be live
 *         with the subscriber unwired or with an empty allowlist. A half-applied batch is not
 *         possible; a rejected one leaves nothing behind.
 *
 *         The governance Safe is both the registry admin and the subscriber owner. `setRegistry`
 *         repoints every LP subscription, which is a governance decision, and governance holding
 *         both ends means it can always recover a misconfiguration. Ops holds SUPPORT_ROLE on the
 *         registry for token rescue and nothing else.
 *
 *         Because the Safe executes the batch out of band, this script cannot check the resulting
 *         on-chain state the way an EOA script would after `vm.stopBroadcast`. That is what
 *         `VerifyTELxRegistry` is for: run it once the Safe transaction has executed.
 *
 *         This script deliberately does NOT expose the `runWithSigner(address)` entrypoint the
 *         repo's other deploy scripts use. That pattern exists to work around `vm.startBroadcast`
 *         being incompatible with `vm.prank`, and safe-utils never calls `startBroadcast`: it
 *         either simulates against a fork or proposes to the Safe API. Simulation mode is the
 *         equivalent rehearsal, and the runbook uses it.
 */
abstract contract BaseDeployTELxRegistry is TELxRegistryScriptBase {
    using Safe for *;

    address[] internal _batchTargets;
    bytes[] internal _batchDatas;

    error MissingSupportSafe(string chain);
    error DeployerIsNotAdmin(address deployerSafe, address admin);
    error UnknownChain(string chain);

    // -----------
    // Entry point
    // -----------

    function run() public virtual {
        // `vm.writeJson` can create a missing file but not a missing directory. Guarantee the
        // directory up front, on a real broadcast only: simulation writes nothing, and `createDir`
        // needs filesystem write permission that only the deploy profile grants.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.createDir(string.concat(vm.projectRoot(), "/deployments"), true);
        }

        // Every chain this run will touch is checked before any proposal goes out, so a run over
        // several chains cannot propose to the first and then fail on the second's configuration.
        // A CHAIN value that names nothing is a typo, not an empty selection.
        _preflight();

        for (uint256 i; i < allChains.length; ++i) {
            ChainTarget memory target = allChains[i];
            if (!_selectChain(target)) continue;

            // The Safe's on-chain nonce only advances on execution, so re-read it per chain and let
            // safe-utils increment locally across proposals within a run.
            currentNonce = safe.getNonce() + vm.envOr("SAFE_NONCE_OFFSET", uint256(0));

            console.log("\n=== TELx registry on %s (chainId %s) ===", target.name, vm.toString(target.chainId));
            _deployOnChain(target);
        }
    }

    // -----------
    // Pre-flight
    // -----------

    /// @dev The configuration checks `_deployOnChain` would make, applied up front to every chain
    ///      the run will select, without forking. Nothing here needs chain state.
    function _preflight() internal view {
        string memory only = vm.envOr("CHAIN", string(""));
        bool matched = bytes(only).length == 0;

        for (uint256 i; i < allChains.length; ++i) {
            ChainTarget memory target = allChains[i];
            bool named = keccak256(bytes(target.name)) == keccak256(bytes(only));
            if (bytes(only).length > 0 && !named) continue;
            matched = matched || named;
            if (bytes(target.rpcUrl).length == 0) continue;

            if (target.supportSafe == address(0)) revert MissingSupportSafe(target.name);
            if (deployerSafeAddress != target.admin) revert DeployerIsNotAdmin(deployerSafeAddress, target.admin);
        }

        if (!matched) revert UnknownChain(only);
    }

    // -----------
    // Per-chain batch
    // -----------

    function _deployOnChain(ChainTarget memory target) internal {
        // Without a support multisig the batch would grant SUPPORT_ROLE to nobody. Fail instead.
        if (target.supportSafe == address(0)) revert MissingSupportSafe(target.name);

        // The CREATE3 salt is guarded with the env-supplied DEPLOYER_SAFE_ADDRESS while the role
        // grants and ownership go to the constant governance Safe. A stray .env would put the
        // contracts at a different address from the one every doc and test predicts, with the
        // grants still pointed at governance; refuse rather than propose that.
        if (deployerSafeAddress != target.admin) revert DeployerIsNotAdmin(deployerSafeAddress, target.admin);

        address registry = _addCreate3ToBatch(
            Salts.TELX_POSITION_REGISTRY,
            bytes.concat(
                type(PositionRegistry).creationCode,
                abi.encode(IPositionManager(target.positionManager), StateView(target.stateView), target.admin)
            ),
            "Deploy PositionRegistry"
        );

        address subscriber = _addCreate3ToBatch(
            Salts.TELX_SUBSCRIBER,
            bytes.concat(
                type(TELxSubscriber).creationCode,
                abi.encode(IPositionRegistry(registry), target.positionManager, target.admin)
            ),
            "Deploy TELxSubscriber"
        );

        // Role grants and pool registrations ride in the same batch. The admin is the Safe itself,
        // so it can grant and register inside the very transaction that creates the registry.
        // Each is skipped when the live registry already has it, so a rerun after a partially
        // executed batch proposes only what is missing and a rerun after a complete one proposes
        // nothing.
        _addGrantToBatch(registry, keccak256("SUBSCRIBER_ROLE"), subscriber, "SUBSCRIBER_ROLE -> TELxSubscriber");
        _addGrantToBatch(registry, keccak256("SUPPORT_ROLE"), target.supportSafe, "SUPPORT_ROLE -> support Safe");

        // Allowlist the chain's catalog pools. Registration is by PoolKey and needs no on-chain
        // state, so pools can be registered before they are created; a subscription still needs
        // the pool initialized, which the registry checks separately.
        string[] memory names = TELxPools.allNames();
        uint256 registered;
        for (uint256 i; i < names.length; ++i) {
            TELxPools.PoolSpec memory spec = TELxPools.spec(names[i]);
            if (spec.chainId != target.chainId) continue;
            if (registry.code.length > 0 && IPositionRegistry(registry).poolAllowed(TELxPools.poolKey(spec).toId())) {
                console.log("  [batch] %s already allowlisted, skipping", names[i]);
                continue;
            }
            _batchTargets.push(registry);
            _batchDatas.push(abi.encodeCall(IPositionRegistry.registerPool, (TELxPools.poolKey(spec))));
            console.log("  [batch] registerPool %s", names[i]);
            ++registered;
        }

        // The addresses are a function of the Safe and the salts alone, so they are known before
        // the proposal goes out. Record them first: a proposal that went out but whose addresses
        // were never recorded is the one failure this script must not be able to produce.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveDeploymentAddress(target.name, "PositionRegistry", registry);
            _saveDeploymentAddress(target.name, "TELxSubscriber", subscriber);
        }

        _flushBatch(string.concat("Deploy + wire TELx registry on ", target.name));

        console.log("  PositionRegistry: %s", registry);
        console.log("  TELxSubscriber:   %s", subscriber);
        console.log("  Pools registered: %s", vm.toString(registered));
    }

    // -----------
    // Batch helpers
    // -----------

    /**
     * @dev Queues a CREATE3 deployment and returns the address it will land at.
     * @dev Our pinned `forge-deploy-utils` only exposes the single-propose `_deployCreate3`, which
     *      would make each contract its own Safe transaction. Accumulating into one MultiSend
     *      instead means a chain's registry, subscriber and role grants are all-or-nothing, and
     *      signers approve one batch rather than four. Mirrors the pattern the tel-v3 repo keeps in
     *      its own base scripts.
     *
     *      Idempotent: an address that already has code is skipped, so a rerun after a partially
     *      executed batch proposes only what is missing.
     */
    function _addCreate3ToBatch(bytes32 rawSalt, bytes memory initCode, string memory label)
        internal
        returns (address expectedAddress)
    {
        bytes32 guardedSalt = SaltMath.guardSalt(deployerSafeAddress, rawSalt);
        require(SaltMath.extractGuard(guardedSalt) == deployerSafeAddress, "guarded salt incorrect");

        expectedAddress = _computeCreate3Address(guardedSalt);

        if (expectedAddress.code.length > 0) {
            console.log("  [batch] %s already deployed at %s, skipping", label, expectedAddress);
            return expectedAddress;
        }

        console.log("  [batch] %s (expected: %s)", label, expectedAddress);
        _batchTargets.push(CREATEX);
        _batchDatas.push(abi.encodeCall(ICreateX.deployCreate3, (guardedSalt, initCode)));
    }

    /// @dev Queues a role grant unless the live registry already has it. Before the registry
    ///      exists there is nothing to read, so the grant is always queued.
    function _addGrantToBatch(address registry, bytes32 role, address account, string memory label) internal {
        if (registry.code.length > 0 && IAccessControl(registry).hasRole(role, account)) {
            console.log("  [batch] %s already granted, skipping", label);
            return;
        }
        _batchTargets.push(registry);
        _batchDatas.push(abi.encodeCall(IAccessControl.grantRole, (role, account)));
        console.log("  [batch] grantRole %s", label);
    }

    function _flushBatch(string memory description) internal {
        uint256 len = _batchTargets.length;
        if (len == 0) {
            console.log("  Nothing to do on this chain.");
            return;
        }

        address[] memory targets = new address[](len);
        bytes[] memory datas = new bytes[](len);
        for (uint256 i; i < len; ++i) {
            targets[i] = _batchTargets[i];
            datas[i] = _batchDatas[i];
        }

        console.log("  Proposing %s transactions as a single MultiSend", vm.toString(len));
        _proposeTransactions(targets, datas, description);

        delete _batchTargets;
        delete _batchDatas;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Safe} from "@safe-utils/Safe.sol";
import {DeployBase} from "forge-deploy-utils/DeployBase.sol";
import {SaltMath} from "forge-deploy-utils/libraries/SaltMath.sol";
import {ICreateX} from "forge-deploy-utils/interfaces/ICreateX.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {EthereumAddresses} from "../shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../shared/PolygonAddresses.sol";
import {BaseAddresses} from "../shared/BaseAddresses.sol";
import {Salts} from "../shared/Salts.sol";

/**
 * @title DeployTELxRegistry
 * @notice Deploys the thin TELx PositionRegistry and its TELxSubscriber to Ethereum, Polygon and
 *         Base, as one Safe MultiSend batch per chain.
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
 *         Everything for a chain goes out as a single MultiSend so the registry can never be live
 *         with the subscriber unwired. A half-applied batch is not possible; a rejected one leaves
 *         nothing behind.
 *
 *         ## Running it
 *
 *         Simulate first. This executes the batch against a local fork by manipulating Safe
 *         storage, so it needs no hardware wallet and proposes nothing:
 *
 *           FOUNDRY_PROFILE=deploy forge script \
 *             script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistryMainnet --ffi -vvvv
 *
 *         Then propose to the Safe Transaction Service, signing with the hardware wallet:
 *
 *           FOUNDRY_PROFILE=deploy forge script \
 *             script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistryMainnet --ffi --broadcast -vvvv
 *
 *         `FOUNDRY_PROFILE=deploy` is required: it is the only profile with FFI and filesystem
 *         writes enabled. Set `CHAIN=polygon` to restrict the run to one chain.
 *
 *         This script deliberately does NOT expose the `runWithSigner(address)` entrypoint the
 *         repo's other deploy scripts use. That pattern exists to work around `vm.startBroadcast`
 *         being incompatible with `vm.prank`, and safe-utils never calls `startBroadcast`: it
 *         either simulates against a fork or proposes to the Safe API. Simulation mode is the
 *         equivalent rehearsal, and the runbook uses it.
 */
abstract contract BaseDeployTELxRegistry is DeployBase {
    using Safe for *;

    struct ChainTarget {
        string name;
        string rpcUrl;
        uint256 chainId;
        address positionManager;
        address stateView;
        address supportSafe;
        address admin;
    }

    ChainTarget[] internal allChains;

    address[] internal _batchTargets;
    bytes[] internal _batchDatas;

    error MissingSupportSafe(string chain);

    // -----------
    // Entry point
    // -----------

    function run() public {
        string memory only = vm.envOr("CHAIN", string(""));

        for (uint256 i; i < allChains.length; ++i) {
            ChainTarget memory target = allChains[i];
            if (bytes(only).length > 0 && keccak256(bytes(target.name)) != keccak256(bytes(only))) continue;

            // A chain with no RPC configured is skipped rather than fatal. Deploying one chain at a
            // time is the normal way to run this, and requiring every chain's URL to be present in
            // order to touch one of them would be a trap rather than a safety check.
            if (bytes(target.rpcUrl).length == 0) {
                console.log("Skipping %s: no RPC URL configured", target.name);
                continue;
            }

            vm.createSelectFork(target.rpcUrl);
            // The Safe's on-chain nonce only advances on execution, so re-read it per chain and let
            // safe-utils increment locally across proposals within a run.
            currentNonce = safe.getNonce() + vm.envOr("SAFE_NONCE_OFFSET", uint256(0));

            require(
                block.chainid == target.chainId,
                string.concat(
                    "Chain ID mismatch: expected ",
                    vm.toString(target.chainId),
                    " but connected to ",
                    vm.toString(block.chainid)
                )
            );

            console.log("\n=== TELx registry on %s (chainId %s) ===", target.name, vm.toString(target.chainId));
            _deployOnChain(target);
        }
    }

    // -----------
    // Per-chain batch
    // -----------

    function _deployOnChain(ChainTarget memory target) internal {
        // Without a support multisig the batch would grant SUPPORT_ROLE to nobody and hand the
        // subscriber to address(0), permanently freezing its registry pointer. Fail instead.
        if (target.supportSafe == address(0)) revert MissingSupportSafe(target.name);

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
                abi.encode(IPositionRegistry(registry), target.positionManager, target.supportSafe)
            ),
            "Deploy TELxSubscriber"
        );

        // Role grants ride in the same batch. The admin is the Safe itself, so it can grant inside
        // the very transaction that creates the registry.
        _batchTargets.push(registry);
        _batchDatas.push(
            abi.encodeCall(IAccessControl.grantRole, (keccak256("SUBSCRIBER_ROLE"), subscriber))
        );
        _batchTargets.push(registry);
        _batchDatas.push(
            abi.encodeCall(IAccessControl.grantRole, (keccak256("SUPPORT_ROLE"), target.supportSafe))
        );

        _flushBatch(string.concat("Deploy + wire TELx registry on ", target.name));

        console.log("  PositionRegistry: %s", registry);
        console.log("  TELxSubscriber:   %s", subscriber);

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveDeploymentAddress(target.name, "PositionRegistry", registry);
            _saveDeploymentAddress(target.name, "TELxSubscriber", subscriber);
        }
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

    // -----------
    // Address prediction
    // -----------

    /// @notice The addresses this script will deploy to, without proposing anything.
    /// @dev Exposed so the runbook and the tests can assert cross-chain address parity up front.
    function predictedAddresses() public view returns (address registry, address subscriber) {
        registry = _computeCreate3Address(SaltMath.guardSalt(deployerSafeAddress, Salts.TELX_POSITION_REGISTRY));
        subscriber = _computeCreate3Address(SaltMath.guardSalt(deployerSafeAddress, Salts.TELX_SUBSCRIBER));
    }
}

/// @title DeployTELxRegistryMainnet
/// @notice Concrete mainnet configuration. The base contract holds all the logic; this only names
///         the chains and where each one's addresses come from.
contract DeployTELxRegistryMainnet is BaseDeployTELxRegistry {
    function setUp() public {
        _initializeSafeMultiSig();

        allChains.push(
            ChainTarget({
                name: "ethereum",
                rpcUrl: vm.envOr("ETHEREUM_RPC_URL", string("")),
                chainId: EthereumAddresses.CHAIN_ID,
                positionManager: EthereumAddresses.POSITION_MANAGER,
                stateView: EthereumAddresses.STATE_VIEW,
                // Still address(0): Ethereum has no TELx support multisig yet, so this chain
                // reverts until the deployment team supplies one.
                supportSafe: EthereumAddresses.SUPPORT_SAFE,
                admin: EthereumAddresses.GOVERNANCE_SAFE
            })
        );

        allChains.push(
            ChainTarget({
                name: "polygon",
                rpcUrl: vm.envOr("POLYGON_RPC_URL", string("")),
                chainId: PolygonAddresses.CHAIN_ID,
                positionManager: PolygonAddresses.POSITION_MANAGER,
                stateView: PolygonAddresses.STATE_VIEW,
                supportSafe: PolygonAddresses.SUPPORT_SAFE,
                admin: PolygonAddresses.GOVERNANCE_SAFE
            })
        );

        allChains.push(
            ChainTarget({
                name: "base",
                rpcUrl: vm.envOr("BASE_RPC_URL", string("")),
                chainId: BaseAddresses.CHAIN_ID,
                positionManager: BaseAddresses.POSITION_MANAGER,
                stateView: BaseAddresses.STATE_VIEW,
                supportSafe: BaseAddresses.SUPPORT_SAFE,
                admin: BaseAddresses.GOVERNANCE_SAFE
            })
        );
    }
}

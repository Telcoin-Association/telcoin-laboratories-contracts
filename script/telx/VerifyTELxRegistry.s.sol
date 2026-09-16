// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {VerificationBase} from "forge-deploy-utils/VerificationBase.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {CrossChainAddresses} from "../shared/CrossChainAddresses.sol";
import {TELxRegistryScriptBase} from "./base/TELxRegistryScriptBase.sol";

/**
 * @title VerifyTELxRegistry
 * @notice Post-execution verification of the TELx registry deploy. Run it after the Safe has
 *         executed the batch that `DeployTELxRegistry` proposed.
 * @dev    A script that broadcasts from an EOA can follow its own transactions with `require`s on
 *         the resulting state. A safe-utils script cannot: it proposes a batch and stops, and the
 *         Safe executes that batch later, out of band. So the checks that would otherwise sit at
 *         the end of the deploy script live here instead, as their own step:
 *
 *           DeployTELxRegistry  ->  Safe UI executes the batch  ->  VerifyTELxRegistry
 *
 *         Every check reads live chain state and reverts on the first mismatch, so a clean run is
 *         proof the deploy produced exactly the wiring we intended, rather than a report to be read.
 *
 *         Needs no Safe credentials, no FFI and no broadcast:
 *
 *           CHAIN=polygon forge script script/telx/VerifyTELxRegistry.s.sol:VerifyTELxRegistry \
 *             --rpc-url $POLYGON_RPC_URL -vvvv
 *
 *         Addresses come from `deployments/<chain>.json`, written by the deploy at proposal time.
 *         When the file has no entry yet the predicted CREATE3 address is used instead, which lets
 *         the script double as a pre-flight check that the predicted addresses are still free.
 */
contract VerifyTELxRegistry is TELxRegistryScriptBase, VerificationBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    function setUp() public {
        // The Safe is only needed as the CREATE3 salt guard for address prediction. Reading it
        // from the shared constant rather than `_initializeSafeMultiSig()` means verification
        // needs no signer environment and no FFI, so anyone with an RPC URL can run it.
        deployerSafeAddress = CrossChainAddresses.GOVERNANCE_SAFE;
        _loadChainTargets();
    }

    function run() public {
        for (uint256 i; i < allChains.length; ++i) {
            ChainTarget memory target = allChains[i];
            if (!_selectChain(target)) continue;

            console.log("\n=== Verifying TELx registry on %s (chainId %s) ===", target.name, vm.toString(target.chainId));

            (address registry, address subscriber) = _resolveAddresses(target);
            verifyOn(target, registry, subscriber);

            console.log("[OK] %s: all checks passed", target.name);
        }
    }

    // -----------
    // Address resolution
    // -----------

    /// @dev Prefers the recorded deployment, falls back to the prediction, and insists the two agree
    ///      when both exist. A recorded address that differs from the prediction means the deploy
    ///      ran with a different Safe or salt than this tree expects, which is worth stopping on.
    function _resolveAddresses(ChainTarget memory target) internal view returns (address registry, address subscriber) {
        (address predictedRegistry, address predictedSubscriber) = predictedAddresses();

        registry = _loadDeploymentAddress(target.name, "PositionRegistry");
        subscriber = _loadDeploymentAddress(target.name, "TELxSubscriber");

        if (registry == address(0)) {
            console.log("  No recorded PositionRegistry; using predicted %s", predictedRegistry);
            registry = predictedRegistry;
        } else {
            require(registry == predictedRegistry, "Recorded PositionRegistry does not match the predicted address");
        }

        if (subscriber == address(0)) {
            console.log("  No recorded TELxSubscriber; using predicted %s", predictedSubscriber);
            subscriber = predictedSubscriber;
        } else {
            require(subscriber == predictedSubscriber, "Recorded TELxSubscriber does not match the predicted address");
        }
    }

    // -----------
    // Checks
    // -----------

    /**
     * @notice Asserts the full intended wiring of a deployed registry and subscriber pair.
     * @dev Public so the fork tests can drive it against contracts they deployed themselves, which
     *      is how the checks are kept honest before any real deploy exists to run them on.
     *
     *      Checked, in order:
     *        1. Both contracts have code.
     *        2. The registry points at this chain's PositionManager and StateView.
     *        3. The governance Safe holds DEFAULT_ADMIN_ROLE on the registry.
     *        4. The subscriber holds SUBSCRIBER_ROLE, and nothing else does that we can see.
     *        5. The support Safe holds SUPPORT_ROLE.
     *        6. The subscriber points at the registry and at this chain's PositionManager, and is
     *           owned by the support Safe.
     *        7. The in-range eligibility gate is enabled, which is the constructor default.
     *
     *      Runtime bytecode is deliberately NOT compared against `type(X).runtimeCode`: both
     *      contracts bake immutables (PositionManager, StateView, registry) into their runtime code,
     *      so the hash legitimately differs per chain and the comparison would always fail.
     */
    function verifyOn(ChainTarget memory target, address registryAddr, address subscriberAddr) public view {
        PositionRegistry registry = PositionRegistry(registryAddr);
        TELxSubscriber subscriber = TELxSubscriber(subscriberAddr);

        // 1. Deployed
        _requireCode(registryAddr, "PositionRegistry");
        _requireCode(subscriberAddr, "TELxSubscriber");

        // 2. Registry dependencies
        require(address(registry.positionManager()) == target.positionManager, "registry: wrong PositionManager");
        require(address(registry.stateView()) == target.stateView, "registry: wrong StateView");
        console.log("[OK] registry dependencies: PositionManager %s, StateView %s", target.positionManager, target.stateView);

        // 3. Governance owns the registry
        _requireRole(registryAddr, DEFAULT_ADMIN_ROLE, target.admin, "registry DEFAULT_ADMIN_ROLE -> governance Safe");

        // 4. Only the subscriber can drive the subscription lifecycle
        _requireRole(registryAddr, SUBSCRIBER_ROLE, subscriberAddr, "registry SUBSCRIBER_ROLE -> TELxSubscriber");
        require(!registry.hasRole(SUBSCRIBER_ROLE, target.admin), "registry: governance Safe must not hold SUBSCRIBER_ROLE");
        require(
            !registry.hasRole(SUBSCRIBER_ROLE, target.supportSafe), "registry: support Safe must not hold SUBSCRIBER_ROLE"
        );

        // 5. Ops can rescue tokens
        _requireRole(registryAddr, SUPPORT_ROLE, target.supportSafe, "registry SUPPORT_ROLE -> support Safe");

        // 6. Subscriber wiring
        require(address(subscriber.registry()) == registryAddr, "subscriber: wrong registry");
        require(subscriber.positionManager() == target.positionManager, "subscriber: wrong PositionManager");
        _requireOwner(subscriberAddr, target.supportSafe, "TELxSubscriber owner -> support Safe");
        require(subscriber.pendingOwner() == address(0), "subscriber: unexpected pending ownership transfer");

        // 7. Eligibility gate at its default
        require(registry.inRangeRequired(), "registry: inRangeRequired should be enabled by default");
        console.log("[OK] inRangeRequired enabled");
    }
}

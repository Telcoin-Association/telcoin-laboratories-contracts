// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {VerificationBase} from "forge-deploy-utils/VerificationBase.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {CrossChainAddresses} from "../shared/CrossChainAddresses.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
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
 *         A run that selects no chain at all is a failure, not a pass: the one thing a verification
 *         script must never do is exit green having verified nothing.
 *
 *         Needs no Safe credentials, no FFI and no broadcast:
 *
 *           CHAIN=polygon forge script script/telx/VerifyTELxRegistry.s.sol:VerifyTELxRegistry \
 *             --rpc-url $POLYGON_RPC_URL -vvvv
 *
 *         Addresses come from `deployments/<chain>.json`, written by the deploy at proposal time.
 *         When the file has no entry yet the predicted CREATE3 address is used instead, which lets
 *         the script double as a pre-flight check that the predicted addresses are still free.
 *
 *         Bytecode is checked by deploying a twin of each contract with the same constructor
 *         arguments in the forked run and comparing `extcodehash`. Both contracts bake immutables
 *         into their runtime code, so `type(X).runtimeCode` is not available, but a twin built from
 *         the same source, compiler and arguments has an identical hash. The hash covers the CBOR
 *         metadata too, so verification must run from the deploy commit with the same solc; that is
 *         the property wanted.
 */
contract VerifyTELxRegistry is TELxRegistryScriptBase, VerificationBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    error NothingVerified();

    function setUp() public {
        // The Safe is only needed as the CREATE3 salt guard for address prediction. Reading it
        // from the shared constant rather than `_initializeSafeMultiSig()` means verification
        // needs no signer environment and no FFI, so anyone with an RPC URL can run it.
        deployerSafeAddress = CrossChainAddresses.GOVERNANCE_SAFE;
        _loadChainTargets();
    }

    function run() public {
        uint256 verified;
        for (uint256 i; i < allChains.length; ++i) {
            ChainTarget memory target = allChains[i];
            if (!_selectChain(target)) continue;

            console.log(
                "\n=== Verifying TELx registry on %s (chainId %s) ===", target.name, vm.toString(target.chainId)
            );

            (address registry, address subscriber) = _resolveAddresses(target);
            verifyOn(target, registry, subscriber);
            verifyBytecode(target, registry, subscriber);

            console.log("[OK] %s: all checks passed", target.name);
            ++verified;
        }

        // A CHAIN value that matches nothing, or every configured chain lacking an RPC URL, would
        // otherwise fall straight through to a clean exit.
        if (verified == 0) revert NothingVerified();
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
     *        2. The registry points at this chain's PositionManager, StateView and PoolManager.
     *        3. The governance Safe holds DEFAULT_ADMIN_ROLE on the registry and nobody else we
     *           can see does.
     *        4. The subscriber holds SUBSCRIBER_ROLE, and nothing else does that we can see.
     *        5. The support Safe holds SUPPORT_ROLE and nothing else does that we can see.
     *        6. The subscriber points at the registry and at this chain's PositionManager, and is
     *           owned by the governance Safe with no transfer pending.
     *        7. The in-range eligibility gate is enabled, which is the constructor default.
     *        8. Every catalog pool for this chain is on the allowlist, with the liquidity floor
     *           `pools.json` implies, and that floor is not zero.
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
        require(
            address(registry.poolManager()) == address(StateView(target.stateView).poolManager()),
            "registry: wrong PoolManager"
        );
        console.log(
            "[OK] registry dependencies: PositionManager %s, StateView %s", target.positionManager, target.stateView
        );

        // 3. Governance owns the registry
        _requireRole(registryAddr, DEFAULT_ADMIN_ROLE, target.admin, "registry DEFAULT_ADMIN_ROLE -> governance Safe");
        require(!registry.hasRole(DEFAULT_ADMIN_ROLE, target.supportSafe), "registry: support Safe must not be admin");
        require(!registry.hasRole(DEFAULT_ADMIN_ROLE, subscriberAddr), "registry: subscriber must not be admin");

        // 4. Only the subscriber can drive the subscription lifecycle
        _requireRole(registryAddr, SUBSCRIBER_ROLE, subscriberAddr, "registry SUBSCRIBER_ROLE -> TELxSubscriber");
        require(
            !registry.hasRole(SUBSCRIBER_ROLE, target.admin), "registry: governance Safe must not hold SUBSCRIBER_ROLE"
        );
        require(
            !registry.hasRole(SUBSCRIBER_ROLE, target.supportSafe),
            "registry: support Safe must not hold SUBSCRIBER_ROLE"
        );

        // 5. Ops can rescue tokens, and only ops
        _requireRole(registryAddr, SUPPORT_ROLE, target.supportSafe, "registry SUPPORT_ROLE -> support Safe");
        require(!registry.hasRole(SUPPORT_ROLE, target.admin), "registry: governance Safe must not hold SUPPORT_ROLE");

        // 6. Subscriber wiring
        require(address(subscriber.registry()) == registryAddr, "subscriber: wrong registry");
        require(subscriber.positionManager() == target.positionManager, "subscriber: wrong PositionManager");
        _requireOwner(subscriberAddr, target.admin, "TELxSubscriber owner -> governance Safe");
        require(subscriber.pendingOwner() == address(0), "subscriber: unexpected pending ownership transfer");

        // 7. Eligibility gate at its default
        require(registry.inRangeRequired(), "registry: inRangeRequired should be enabled by default");
        console.log("[OK] inRangeRequired enabled");

        // 8. Allowlist covers the chain's pool set, each with its floor
        string[] memory names = TELxPools.allNames();
        uint256 expected;
        for (uint256 i; i < names.length; ++i) {
            TELxPools.PoolSpec memory spec = TELxPools.spec(names[i]);
            if (spec.chainId != target.chainId) continue;
            PoolId poolId = TELxPools.poolKey(spec).toId();
            require(registry.poolAllowed(poolId), string.concat("registry: catalog pool not allowlisted: ", names[i]));
            uint128 floor = _expectedFloor(names[i]);
            require(floor > 0, string.concat("registry: zero liquidity floor for ", names[i]));
            require(
                registry.minLiquidity(poolId) == floor,
                string.concat("registry: liquidity floor does not match pools.json for ", names[i])
            );
            ++expected;
        }
        require(expected > 0, "registry: no catalog pools for this chain");
        console.log("[OK] %s catalog pools allowlisted with floors", vm.toString(expected));
    }

    /**
     * @notice Asserts the deployed bytecode is what this tree compiles to, by comparing against a
     *         twin deployed here with the same constructor arguments.
     * @dev Not `view`: it deploys. The twin never touches state anyone else can see; it is created
     *      in the forked run purely to have a hash to compare against. Immutables (PositionManager,
     *      StateView, PoolManager, registry) are part of runtime code, so the twin must use exactly
     *      the arguments the live contract was deployed with, which is why it takes `registryAddr`
     *      for the subscriber rather than deploying a fresh registry.
     */
    function verifyBytecode(ChainTarget memory target, address registryAddr, address subscriberAddr) public {
        PositionRegistry twinRegistry =
            new PositionRegistry(IPositionManager(target.positionManager), StateView(target.stateView), target.admin);
        require(
            registryAddr.codehash == address(twinRegistry).codehash,
            "PositionRegistry: deployed bytecode does not match this tree"
        );
        console.log("[OK] PositionRegistry bytecode matches");

        TELxSubscriber twinSubscriber =
            new TELxSubscriber(IPositionRegistry(registryAddr), target.positionManager, target.admin);
        require(
            subscriberAddr.codehash == address(twinSubscriber).codehash,
            "TELxSubscriber: deployed bytecode does not match this tree"
        );
        console.log("[OK] TELxSubscriber bytecode matches");
    }
}

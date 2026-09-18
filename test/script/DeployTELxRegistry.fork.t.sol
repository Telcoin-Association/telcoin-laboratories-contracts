// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {BaseDeployTELxRegistry} from "../../script/telx/base/BaseDeployTELxRegistry.s.sol";
import {VerifyTELxRegistry} from "../../script/telx/VerifyTELxRegistry.s.sol";
import {TELxRegistryScriptBase} from "../../script/telx/base/TELxRegistryScriptBase.sol";
import {CrossChainAddresses} from "../../script/shared/CrossChainAddresses.sol";
import {PolygonAddresses} from "../../script/shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../script/shared/BaseAddresses.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {DeployTELxRegistryHarness} from "./harnesses/DeployTELxRegistryHarness.sol";
import {ISafe} from "./interfaces/ISafe.sol";

/// @title DeployTELxRegistryForkTest
/// @notice Executes the registry deploy batch the way the Safe will: through the safe-utils
///         simulation against the real governance Safe, the real CreateX factory and the real
///         MultiSend on a fork of each chain, then hands the result to `VerifyTELxRegistry`.
/// @dev    The salt test pins the predicted addresses and the verify test pins the checks, but
///         neither proves the batch the script assembles actually executes and produces state the
///         checks accept. This does. It is also the regression for the batch shape: two CREATE3
///         deploys, two grants, one `registerPool` per catalog pool, in one MultiSend, and nothing
///         at all on a rerun.
abstract contract DeployTELxRegistryForkTest is Test {
    DeployTELxRegistryHarness internal deployer;
    address[] internal owners;

    bytes32 internal constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    address internal constant GOVERNANCE_SAFE = CrossChainAddresses.GOVERNANCE_SAFE;

    /// @dev Set by each concrete chain suite before `_setUpChain` runs.
    string internal rpcEnvVar;
    string internal chainName;
    uint256 internal chainId;
    address internal supportSafe;
    uint256 internal catalogPools;

    function _setUpChain() internal {
        string memory rpc = vm.envOr(rpcEnvVar, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address[] memory all = ISafe(GOVERNANCE_SAFE).getOwners();
        owners.push(all[0]);
        owners.push(all[1]);

        deployer = new DeployTELxRegistryHarness();
        deployer.initForSimulation(GOVERNANCE_SAFE, owners);
    }

    /// @notice The batch executes as the Safe and lands both contracts at the predicted
    ///         addresses, fully wired, and the verify script accepts the result.
    function test_batchExecutesAndVerifies() public {
        (address registryAddr, address subscriberAddr) = deployer.predictedAddresses();
        assertEq(registryAddr.code.length, 0, "precondition: registry address free");
        assertEq(subscriberAddr.code.length, 0, "precondition: subscriber address free");

        deployer.deployOn(chainName);

        assertGt(registryAddr.code.length, 0, "registry not deployed");
        assertGt(subscriberAddr.code.length, 0, "subscriber not deployed");

        PositionRegistry registry = PositionRegistry(registryAddr);
        TELxSubscriber subscriber = TELxSubscriber(subscriberAddr);

        assertTrue(registry.hasRole(0x00, GOVERNANCE_SAFE), "governance admin");
        assertTrue(registry.hasRole(SUBSCRIBER_ROLE, subscriberAddr), "subscriber role");
        assertTrue(registry.hasRole(SUPPORT_ROLE, supportSafe), "support role");
        assertEq(subscriber.owner(), GOVERNANCE_SAFE, "subscriber owner");
        assertEq(address(subscriber.registry()), registryAddr, "subscriber registry");

        string[] memory names = TELxPools.allNames();
        uint256 registered;
        for (uint256 i; i < names.length; ++i) {
            TELxPools.PoolSpec memory spec = TELxPools.spec(names[i]);
            if (spec.chainId != chainId) continue;
            assertTrue(registry.poolAllowed(TELxPools.poolKey(spec).toId()), names[i]);
            ++registered;
        }
        assertEq(registered, catalogPools, "catalog pool count for this chain");

        // the post-execution gate accepts exactly this state
        VerifyTELxRegistry verifier = new VerifyTELxRegistry();
        TELxRegistryScriptBase.ChainTarget memory target = deployer.chainTarget(chainName);
        verifier.verifyOn(target, registryAddr, subscriberAddr);
        verifier.verifyBytecode(target, registryAddr, subscriberAddr);
    }

    /// @notice A rerun against a chain where the batch already executed finds every step done and
    ///         proposes nothing. If it proposed anything, the simulation would execute it as the
    ///         Safe and the nonce would advance.
    function test_rerunProposesNothing() public {
        deployer.deployOn(chainName);

        uint256 nonceBefore = _safeNonce();
        deployer.deployOn(chainName);
        assertEq(_safeNonce(), nonceBefore, "rerun should not execute a Safe transaction");
    }

    /// @notice The CREATE3 salt is guarded with the deployer Safe while the grants go to
    ///         governance. Any other deployer must be refused before a batch is assembled.
    function test_refusesDeployerThatIsNotGovernance() public {
        address[] memory supportOwners = ISafe(supportSafe).getOwners();
        address[] memory two = new address[](2);
        two[0] = supportOwners[0];
        two[1] = supportOwners[1];

        DeployTELxRegistryHarness wrong = new DeployTELxRegistryHarness();
        wrong.initForSimulation(supportSafe, two);

        vm.expectRevert(
            abi.encodeWithSelector(BaseDeployTELxRegistry.DeployerIsNotAdmin.selector, supportSafe, GOVERNANCE_SAFE)
        );
        wrong.deployOn(chainName);
    }

    function _safeNonce() internal view returns (uint256) {
        (bool ok, bytes memory data) = GOVERNANCE_SAFE.staticcall(abi.encodeWithSignature("nonce()"));
        require(ok, "nonce read failed");
        return abi.decode(data, (uint256));
    }
}

/// @title PolygonDeployTELxRegistryForkTest
contract PolygonDeployTELxRegistryForkTest is DeployTELxRegistryForkTest {
    function setUp() public {
        rpcEnvVar = "POLYGON_RPC_URL";
        chainName = "polygon";
        chainId = PolygonAddresses.CHAIN_ID;
        supportSafe = PolygonAddresses.SUPPORT_SAFE;
        catalogPools = 3;
        _setUpChain();
    }
}

/// @title BaseDeployTELxRegistryForkTest
/// @notice The same batch on Base. `forge script` simulation of this batch fails in some
///         environments (see the runbook); this suite drives the identical safe-utils simulation
///         path from a test, where prank-on-fork is the behaviour every fork test relies on.
contract BaseDeployTELxRegistryForkTest is DeployTELxRegistryForkTest {
    function setUp() public {
        rpcEnvVar = "BASE_RPC_URL";
        chainName = "base";
        chainId = BaseAddresses.CHAIN_ID;
        supportSafe = BaseAddresses.SUPPORT_SAFE;
        catalogPools = 2;
        _setUpChain();
    }
}

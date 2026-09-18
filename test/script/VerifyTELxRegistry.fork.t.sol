// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {PolygonAddresses} from "../../script/shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../script/shared/BaseAddresses.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {VerifyTELxRegistry} from "../../script/telx/VerifyTELxRegistry.s.sol";
import {TELxRegistryScriptBase} from "../../script/telx/base/TELxRegistryScriptBase.sol";
import {ForkOrSkip} from "../util/ForkOrSkip.sol";

/// @title VerifyTELxRegistryForkTest
/// @notice Proves the post-deploy verification script accepts a correctly wired registry and
///         rejects each way it could be miswired, with the specific reason each time.
/// @dev    The verify script exists because the Safe executes the deploy batch out of band, so the
///         deploy script itself cannot check the result. That makes the verify script the only
///         thing standing between "the Safe executed something" and "the registry is wired the way
///         we intended", and a verify script that passes on a bad deploy is worse than none. So the
///         negative cases are the point of this file: each one deploys a pair that is wrong in
///         exactly one way and asserts the script notices, by the reason string that names that
///         defect. A bare `expectRevert` would let the wrong check fire first and still pass.
///
///         Forks Polygon so the PositionManager and StateView the checks compare against are the
///         real ones; the registry and subscriber are deployed fresh here rather than read from
///         `deployments/`, since no real deploy exists yet.
contract VerifyTELxRegistryForkTest is Test {
    VerifyTELxRegistry internal verifier;
    TELxRegistryScriptBase.ChainTarget internal target;

    address internal governance = PolygonAddresses.GOVERNANCE_SAFE;
    address internal support = PolygonAddresses.SUPPORT_SAFE;
    address internal positionManager = PolygonAddresses.POSITION_MANAGER;
    address internal stateView = PolygonAddresses.STATE_VIEW;

    // Hoisted so a single-shot `vm.prank` is consumed by the role mutation and not by the
    // `registry.X_ROLE()` staticcall that would otherwise precede it in the same expression.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    function setUp() public {
        ForkOrSkip.select("POLYGON_RPC_URL");

        verifier = new VerifyTELxRegistry();
        target = TELxRegistryScriptBase.ChainTarget({
            name: "polygon",
            rpcUrl: "",
            chainId: PolygonAddresses.CHAIN_ID,
            positionManager: positionManager,
            stateView: stateView,
            supportSafe: support,
            admin: governance
        });
    }

    // -----------
    // Fixture
    // -----------

    /// @dev Deploys and wires a pair exactly as the Safe batch would: both contracts, both role
    ///      grants, every catalog pool for the chain registered, governance owning the subscriber.
    function _deployWired() internal returns (PositionRegistry registry, TELxSubscriber subscriber) {
        return _deployWith(positionManager, stateView, governance, governance);
    }

    function _deployWith(address pm, address sv, address admin, address subscriberOwner)
        internal
        returns (PositionRegistry registry, TELxSubscriber subscriber)
    {
        registry = new PositionRegistry(IPositionManager(pm), StateView(sv), admin);
        subscriber = new TELxSubscriber(IPositionRegistry(address(registry)), pm, subscriberOwner);
        vm.startPrank(admin);
        registry.grantRole(SUBSCRIBER_ROLE, address(subscriber));
        registry.grantRole(SUPPORT_ROLE, support);
        _registerCatalogPools(registry);
        vm.stopPrank();
    }

    function _registerCatalogPools(PositionRegistry registry) internal {
        string[] memory names = TELxPools.allNames();
        for (uint256 i; i < names.length; ++i) {
            TELxPools.PoolSpec memory spec = TELxPools.spec(names[i]);
            if (spec.chainId != PolygonAddresses.CHAIN_ID) continue;
            registry.registerPool(TELxPools.poolKey(spec));
        }
    }

    // -----------
    // Happy path
    // -----------

    function test_verifyOn_acceptsCorrectWiring() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyBytecode_acceptsThisTreesBuild() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        verifier.verifyBytecode(target, address(registry), address(subscriber));
    }

    // -----------
    // Each way the deploy could be wrong
    // -----------

    function test_verifyOn_rejectsUndeployedRegistry() public {
        vm.expectRevert(bytes("PositionRegistry: no code"));
        verifier.verifyOn(target, makeAddr("nothingHere"), makeAddr("nothingHereEither"));
    }

    function test_verifyOn_rejectsUndeployedSubscriber() public {
        (PositionRegistry registry,) = _deployWired();
        vm.expectRevert(bytes("TELxSubscriber: no code"));
        verifier.verifyOn(target, address(registry), makeAddr("nothingHere"));
    }

    /// @notice Wrong Uniswap infrastructure in the constructor is the cross-chain copy-paste error:
    ///         Base's PositionManager on a Polygon deploy.
    function test_verifyOn_rejectsWrongPositionManager() public {
        (PositionRegistry registry, TELxSubscriber subscriber) =
            _deployWith(BaseAddresses.POSITION_MANAGER, stateView, governance, governance);
        vm.expectRevert(bytes("registry: wrong PositionManager"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice A second, fully functional StateView over the same PoolManager is still the wrong
    ///         one: the registry must point at the canonical lens every integration reads.
    function test_verifyOn_rejectsWrongStateView() public {
        StateView otherLens = new StateView(StateView(stateView).poolManager());
        (PositionRegistry registry, TELxSubscriber subscriber) =
            _deployWith(positionManager, address(otherLens), governance, governance);
        vm.expectRevert(bytes("registry: wrong StateView"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice The registry constructor reads `poolManager()` off the StateView it is given, so a
    ///         StateView address with no code cannot even be deployed against. That is the
    ///         constructor-time guard for a mistyped lens address.
    function testRevert_constructor_rejectsCodelessStateView() public {
        vm.expectRevert();
        new PositionRegistry(IPositionManager(positionManager), StateView(makeAddr("noLens")), governance);
    }

    function test_verifyOn_rejectsWrongRegistryAdmin() public {
        address wrongAdmin = makeAddr("wrongAdmin");
        (PositionRegistry registry, TELxSubscriber subscriber) =
            _deployWith(positionManager, stateView, wrongAdmin, governance);
        vm.expectRevert(bytes("registry DEFAULT_ADMIN_ROLE -> governance Safe: role not granted"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsSupportSafeAsAdmin() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.grantRole(DEFAULT_ADMIN_ROLE, support);
        vm.expectRevert(bytes("registry: support Safe must not be admin"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsMissingSubscriberRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.revokeRole(SUBSCRIBER_ROLE, address(subscriber));
        vm.expectRevert(bytes("registry SUBSCRIBER_ROLE -> TELxSubscriber: role not granted"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice The governance Safe holding SUBSCRIBER_ROLE would let it inject subscriptions
    ///         directly. Nothing in the deploy grants that, so its presence means something else did.
    function test_verifyOn_rejectsGovernanceHoldingSubscriberRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, governance);
        vm.expectRevert(bytes("registry: governance Safe must not hold SUBSCRIBER_ROLE"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsSupportHoldingSubscriberRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, support);
        vm.expectRevert(bytes("registry: support Safe must not hold SUBSCRIBER_ROLE"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsMissingSupportRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.revokeRole(SUPPORT_ROLE, support);
        vm.expectRevert(bytes("registry SUPPORT_ROLE -> support Safe: role not granted"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsGovernanceHoldingSupportRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.grantRole(SUPPORT_ROLE, governance);
        vm.expectRevert(bytes("registry: governance Safe must not hold SUPPORT_ROLE"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice A subscriber built against a different registry than the one being verified is
    ///         the failure a copy-paste of the wrong address in the batch would produce.
    function test_verifyOn_rejectsSubscriberPointingElsewhere() public {
        (PositionRegistry registry,) = _deployWired();
        PositionRegistry other =
            new PositionRegistry(IPositionManager(positionManager), StateView(stateView), governance);
        TELxSubscriber strayed = new TELxSubscriber(IPositionRegistry(address(other)), positionManager, governance);
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, address(strayed));
        vm.expectRevert(bytes("subscriber: wrong registry"));
        verifier.verifyOn(target, address(registry), address(strayed));
    }

    function test_verifyOn_rejectsSubscriberWrongPositionManager() public {
        (PositionRegistry registry,) = _deployWired();
        TELxSubscriber wrongPm =
            new TELxSubscriber(IPositionRegistry(address(registry)), BaseAddresses.POSITION_MANAGER, governance);
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, address(wrongPm));
        vm.expectRevert(bytes("subscriber: wrong PositionManager"));
        verifier.verifyOn(target, address(registry), address(wrongPm));
    }

    /// @notice Ownership landing anywhere but governance, including the ops Safe, is rejected.
    ///         `setRegistry` repoints every LP subscription and is a governance lever.
    function test_verifyOn_rejectsWrongSubscriberOwner() public {
        (PositionRegistry registry, TELxSubscriber subscriber) =
            _deployWith(positionManager, stateView, governance, support);
        vm.expectRevert(bytes("TELxSubscriber owner -> governance Safe: owner mismatch"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsPendingOwnershipTransfer() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        subscriber.transferOwnership(support);
        vm.expectRevert(bytes("subscriber: unexpected pending ownership transfer"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsInRangeGateDisabled() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.setInRangeRequired(false);
        vm.expectRevert(bytes("registry: inRangeRequired should be enabled by default"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice A registry with an incomplete allowlist would let some TELx pools' LPs subscribe and
    ///         silently refuse others. Every catalog pool for the chain must be registered.
    function test_verifyOn_rejectsMissingPoolRegistration() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        TELxPools.PoolSpec memory spec = TELxPools.spec("POLYGON_EUSD_TEL");
        vm.prank(governance);
        registry.deregisterPool(TELxPools.poolKey(spec).toId());
        vm.expectRevert(bytes("registry: catalog pool not allowlisted: POLYGON_EUSD_TEL"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    // -----------
    // Bytecode
    // -----------

    /// @notice A contract with the same getters but different code passes every wiring check; only
    ///         the twin-codehash compare catches it. `LookalikeRegistry` answers every view the
    ///         verify script asks and is otherwise empty.
    function test_verifyBytecode_rejectsLookalikeRegistry() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        LookalikeRegistry lookalike = new LookalikeRegistry(address(registry));
        vm.expectRevert(bytes("PositionRegistry: deployed bytecode does not match this tree"));
        verifier.verifyBytecode(target, address(lookalike), address(subscriber));
    }

    function test_verifyBytecode_rejectsLookalikeSubscriber() public {
        (PositionRegistry registry,) = _deployWired();
        LookalikeRegistry lookalike = new LookalikeRegistry(address(registry));
        vm.expectRevert(bytes("TELxSubscriber: deployed bytecode does not match this tree"));
        verifier.verifyBytecode(target, address(registry), address(lookalike));
    }

    /// @notice Immutables are part of runtime code, so a registry built against a different
    ///         PositionManager has a different hash even from identical source.
    function test_verifyBytecode_rejectsDifferentImmutables() public {
        (PositionRegistry registry, TELxSubscriber subscriber) =
            _deployWith(BaseAddresses.POSITION_MANAGER, stateView, governance, governance);
        vm.expectRevert(bytes("PositionRegistry: deployed bytecode does not match this tree"));
        verifier.verifyBytecode(target, address(registry), address(subscriber));
    }
}

/// @dev A contract with no relation to PositionRegistry that nevertheless has the right shape. It
///      forwards every call to a real registry, so wiring checks pass; only its own code differs.
contract LookalikeRegistry {
    address private immutable _real;

    constructor(address real) {
        _real = real;
    }

    fallback() external {
        (bool ok, bytes memory ret) = _real.staticcall(msg.data);
        require(ok, "forward failed");
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

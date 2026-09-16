// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "../../contracts/telx/interfaces/IPositionRegistry.sol";
import {PolygonAddresses} from "../../script/shared/PolygonAddresses.sol";
import {VerifyTELxRegistry} from "../../script/telx/VerifyTELxRegistry.s.sol";
import {TELxRegistryScriptBase} from "../../script/telx/base/TELxRegistryScriptBase.sol";

/// @title VerifyTELxRegistryForkTest
/// @notice Proves the post-deploy verification script accepts a correctly wired registry and
///         rejects each way it could be miswired.
/// @dev    The verify script exists because the Safe executes the deploy batch out of band, so the
///         deploy script itself cannot check the result. That makes the verify script the only
///         thing standing between "the Safe executed something" and "the registry is wired the way
///         we intended", and a verify script that passes on a bad deploy is worse than none. So the
///         negative cases are the point of this file: each one deploys a pair that is wrong in
///         exactly one way and asserts the script notices.
///
///         Forks Polygon so the PositionManager and StateView the checks compare against are the
///         real ones; the registry and subscriber are deployed fresh here rather than read from
///         `deployments/`, since no real deploy exists yet.
contract VerifyTELxRegistryForkTest is Test {
    VerifyTELxRegistry internal verifier;
    TELxRegistryScriptBase.ChainTarget internal target;

    address internal governance = PolygonAddresses.GOVERNANCE_SAFE;
    address internal support = PolygonAddresses.SUPPORT_SAFE;

    // Hoisted so a single-shot `vm.prank` is consumed by the role mutation and not by the
    // `registry.X_ROLE()` staticcall that would otherwise precede it in the same expression.
    bytes32 internal constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));

        verifier = new VerifyTELxRegistry();
        target = TELxRegistryScriptBase.ChainTarget({
            name: "polygon",
            rpcUrl: "",
            chainId: PolygonAddresses.CHAIN_ID,
            positionManager: PolygonAddresses.POSITION_MANAGER,
            stateView: PolygonAddresses.STATE_VIEW,
            supportSafe: support,
            admin: governance
        });
    }

    // -----------
    // Fixture
    // -----------

    /// @dev Deploys and wires a pair exactly as the Safe batch would, then lets the caller break
    ///      one thing before verification.
    function _deployWired() internal returns (PositionRegistry registry, TELxSubscriber subscriber) {
        registry = new PositionRegistry(
            IPositionManager(PolygonAddresses.POSITION_MANAGER), StateView(PolygonAddresses.STATE_VIEW), governance
        );
        subscriber = new TELxSubscriber(
            IPositionRegistry(address(registry)), PolygonAddresses.POSITION_MANAGER, support
        );
        vm.startPrank(governance);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();
    }

    // -----------
    // Happy path
    // -----------

    function test_verifyOn_acceptsCorrectWiring() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    // -----------
    // Each way the deploy could be wrong
    // -----------

    function test_verifyOn_rejectsMissingSubscriberRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.revokeRole(SUBSCRIBER_ROLE, address(subscriber));

        vm.expectRevert();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsMissingSupportRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.revokeRole(SUPPORT_ROLE, support);

        vm.expectRevert();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice The governance Safe holding SUBSCRIBER_ROLE would let it inject subscriptions
    ///         directly. Nothing in the deploy grants that, so its presence means something else
    ///         did.
    function test_verifyOn_rejectsGovernanceHoldingSubscriberRole() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, governance);

        vm.expectRevert(bytes("registry: governance Safe must not hold SUBSCRIBER_ROLE"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsWrongRegistryAdmin() public {
        address wrongAdmin = makeAddr("wrongAdmin");
        PositionRegistry registry = new PositionRegistry(
            IPositionManager(PolygonAddresses.POSITION_MANAGER), StateView(PolygonAddresses.STATE_VIEW), wrongAdmin
        );
        TELxSubscriber subscriber =
            new TELxSubscriber(IPositionRegistry(address(registry)), PolygonAddresses.POSITION_MANAGER, support);
        vm.startPrank(wrongAdmin);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();

        vm.expectRevert();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsWrongSubscriberOwner() public {
        PositionRegistry registry = new PositionRegistry(
            IPositionManager(PolygonAddresses.POSITION_MANAGER), StateView(PolygonAddresses.STATE_VIEW), governance
        );
        TELxSubscriber subscriber = new TELxSubscriber(
            IPositionRegistry(address(registry)), PolygonAddresses.POSITION_MANAGER, makeAddr("wrongOwner")
        );
        vm.startPrank(governance);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();

        vm.expectRevert();
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    /// @notice A subscriber built against a different registry than the one being verified is
    ///         the failure a copy-paste of the wrong address in the batch would produce.
    function test_verifyOn_rejectsSubscriberPointingElsewhere() public {
        (PositionRegistry registry,) = _deployWired();
        PositionRegistry other = new PositionRegistry(
            IPositionManager(PolygonAddresses.POSITION_MANAGER), StateView(PolygonAddresses.STATE_VIEW), governance
        );
        TELxSubscriber strayed =
            new TELxSubscriber(IPositionRegistry(address(other)), PolygonAddresses.POSITION_MANAGER, support);
        vm.prank(governance);
        registry.grantRole(SUBSCRIBER_ROLE, address(strayed));

        vm.expectRevert(bytes("subscriber: wrong registry"));
        verifier.verifyOn(target, address(registry), address(strayed));
    }

    /// @notice Wrong Uniswap infrastructure in the constructor is the cross-chain copy-paste error:
    ///         Base's PositionManager on a Polygon deploy.
    function test_verifyOn_rejectsWrongPositionManager() public {
        address basePositionManager = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
        PositionRegistry registry = new PositionRegistry(
            IPositionManager(basePositionManager), StateView(PolygonAddresses.STATE_VIEW), governance
        );
        TELxSubscriber subscriber =
            new TELxSubscriber(IPositionRegistry(address(registry)), basePositionManager, support);
        vm.startPrank(governance);
        registry.grantRole(registry.SUBSCRIBER_ROLE(), address(subscriber));
        registry.grantRole(registry.SUPPORT_ROLE(), support);
        vm.stopPrank();

        vm.expectRevert(bytes("registry: wrong PositionManager"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsInRangeGateDisabled() public {
        (PositionRegistry registry, TELxSubscriber subscriber) = _deployWired();
        vm.prank(governance);
        registry.setInRangeRequired(false);

        vm.expectRevert(bytes("registry: inRangeRequired should be enabled by default"));
        verifier.verifyOn(target, address(registry), address(subscriber));
    }

    function test_verifyOn_rejectsUndeployedAddress() public {
        vm.expectRevert();
        verifier.verifyOn(target, makeAddr("nothingHere"), makeAddr("nothingHereEither"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VotingWeightCalculator} from "contracts/snapshot/core/VotingWeightCalculator.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BalancerAdaptor} from "contracts/snapshot/adaptors/BalancerAdaptor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerVault} from "contracts/snapshot/interfaces/IBalancerVault.sol";
import {IBalancerPool} from "contracts/snapshot/interfaces/IBalancerPool.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";
import {MockSource} from "./mocks/MockSource.sol";
import {NonSourceERC165} from "./mocks/NonSourceERC165.sol";

/// @title VotingWeightCalculatorTest
/// @notice Polygon-fork tests for the central voting-weight calculator that aggregates `ISource`
///         adaptors (Balancer, StakingRewards, StakingModule) and computes a unified TEL weight.
///         Covers source registration, removal, and weight summation. Companion to the per-source
///         test files in this directory.
contract VotingWeightCalculatorTest is Test {
    uint256 constant FORK_BLOCK = 68_000_000;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address constant VOTING_WEIGHT_CALCULATOR = PolygonConstants.VOTING_WEIGHT_CALCULATOR;
    address constant TEL = PolygonConstants.TEL;
    address constant BALANCER_VAULT = PolygonConstants.BALANCER_VAULT;
    address constant WETH_POOL_ADAPTOR = PolygonConstants.WETH_POOL_ADAPTOR;
    address constant BALANCER_POOL = PolygonConstants.BALANCER_POOL;
    bytes32 constant POOL_ID = PolygonConstants.BALANCER_POOL_ID;

    VotingWeightCalculator calculator;
    address owner;
    address nonOwner;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        owner = address(this);
        nonOwner = makeAddr("nonOwner");

        // Deploy fresh instance so we have full ownership control
        calculator = new VotingWeightCalculator(owner);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Deploy a real BalancerAdaptor that works on the fork
    function _deployBalancerAdaptor() internal returns (BalancerAdaptor) {
        return new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            5,
            4
        );
    }

    // ---------------------------------------------------------------
    // addSource
    // ---------------------------------------------------------------

    function test_addSource_happyPath() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();

        calculator.addSource(ISource(address(adaptor)));

        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 1);
        assertEq(address(srcs[0]), address(adaptor));
    }

    function test_addSource_multipleDistinctSources() public {
        // Deploy two distinct adaptors (same params, different addresses)
        BalancerAdaptor a1 = _deployBalancerAdaptor();
        BalancerAdaptor a2 = _deployBalancerAdaptor();

        calculator.addSource(ISource(address(a1)));
        calculator.addSource(ISource(address(a2)));

        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 2);
        assertEq(address(srcs[0]), address(a1));
        assertEq(address(srcs[1]), address(a2));
    }

    function test_addSource_revertsOnDuplicate() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        vm.expectRevert("VotingWeightCalculator: source already added");
        calculator.addSource(ISource(address(adaptor)));
    }

    function test_addSource_revertsForNonISource() public {
        // EOA or contract that doesn't implement ISource
        address noInterface = makeAddr("noInterface");

        // The ERC165 supportsInterface call will revert because noInterface has no code
        vm.expectRevert();
        calculator.addSource(ISource(noInterface));
    }

    function test_addSource_revertsForNonOwner() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
        calculator.addSource(ISource(address(adaptor)));
    }

    // ---------------------------------------------------------------
    // removeSource
    // ---------------------------------------------------------------

    function test_removeSource_singleSource() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        calculator.removeSource(0);

        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 0);
    }

    function test_removeSource_middleElement() public {
        // Add three sources, remove the middle one
        BalancerAdaptor a1 = _deployBalancerAdaptor();
        BalancerAdaptor a2 = _deployBalancerAdaptor();
        BalancerAdaptor a3 = _deployBalancerAdaptor();

        calculator.addSource(ISource(address(a1)));
        calculator.addSource(ISource(address(a2)));
        calculator.addSource(ISource(address(a3)));

        // Remove index 1 (a2); a3 should swap into index 1
        calculator.removeSource(1);

        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 2);
        assertEq(address(srcs[0]), address(a1));
        assertEq(address(srcs[1]), address(a3));
    }

    function test_removeSource_lastElement() public {
        BalancerAdaptor a1 = _deployBalancerAdaptor();
        BalancerAdaptor a2 = _deployBalancerAdaptor();

        calculator.addSource(ISource(address(a1)));
        calculator.addSource(ISource(address(a2)));

        // Remove last index
        calculator.removeSource(1);

        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 1);
        assertEq(address(srcs[0]), address(a1));
    }

    function test_removeSource_revertsOutOfBounds() public {
        // No sources exist
        vm.expectRevert();
        calculator.removeSource(0);
    }

    function test_removeSource_revertsOutOfBounds_withSources() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        vm.expectRevert();
        calculator.removeSource(1); // only index 0 exists
    }

    function test_removeSource_revertsForNonOwner() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
        calculator.removeSource(0);
    }

    // ---------------------------------------------------------------
    // balanceOf
    // ---------------------------------------------------------------

    function test_balanceOf_noSources_returnsZero() public {
        assertEq(calculator.balanceOf(makeAddr("voter")), 0);
    }

    function test_balanceOf_aggregatesMultipleSources() public {
        // Add a real Balancer adaptor and give a voter some BPT
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        address voter = makeAddr("voter");

        // Give voter some Balancer Pool Tokens (BPT)
        deal(BALANCER_POOL, voter, 1_000e18);

        uint256 balance = calculator.balanceOf(voter);
        // The voter holds BPT so balance should be > 0
        assertGt(balance, 0, "Voter with BPT should have voting weight");
    }

    function test_balanceOf_zeroAfterRemovingAllSources() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(adaptor)));

        address voter = makeAddr("voter");
        deal(BALANCER_POOL, voter, 1_000e18);

        // Confirm non-zero first
        assertGt(calculator.balanceOf(voter), 0);

        // Remove the only source
        calculator.removeSource(0);

        // Now should be zero
        assertEq(calculator.balanceOf(voter), 0);
    }

    // ---------------------------------------------------------------
    // getSources
    // ---------------------------------------------------------------

    function test_getSources_empty() public view {
        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 0);
    }

    // ---------------------------------------------------------------
    // Ownership (Ownable2Step)
    // ---------------------------------------------------------------

    function test_owner_isInitialOwner() public view {
        assertEq(calculator.owner(), owner);
    }

    function test_transferOwnership_twoStep() public {
        address newOwner = makeAddr("newOwner");

        calculator.transferOwnership(newOwner);
        // Ownership not yet transferred
        assertEq(calculator.owner(), owner);

        // New owner must accept
        vm.prank(newOwner);
        calculator.acceptOwnership();
        assertEq(calculator.owner(), newOwner);
    }

    function test_pendingOwner_cannotCallOnlyOwner() public {
        address newOwner = makeAddr("newOwner");
        calculator.transferOwnership(newOwner);

        BalancerAdaptor adaptor = _deployBalancerAdaptor();

        // Pending owner should not be able to addSource yet
        vm.prank(newOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                newOwner
            )
        );
        calculator.addSource(ISource(address(adaptor)));
    }

    // ---------------------------------------------------------------
    // balanceOf with multiple sources
    // ---------------------------------------------------------------

    function test_balanceOf_sumsTwoSources() public {
        BalancerAdaptor a1 = _deployBalancerAdaptor();
        BalancerAdaptor a2 = _deployBalancerAdaptor();

        calculator.addSource(ISource(address(a1)));
        calculator.addSource(ISource(address(a2)));

        address voter = makeAddr("voter");
        deal(BALANCER_POOL, voter, 500e18);

        uint256 singleWeight = a1.balanceOf(voter);
        uint256 totalWeight = calculator.balanceOf(voter);

        // Both adaptors point at the same pool, so total == 2 * single
        assertEq(totalWeight, singleWeight * 2);
    }

    // ---------------------------------------------------------------
    // Coverage-gap tests
    // ---------------------------------------------------------------

    /// @dev removeSource emits the correct event with the removed address and index
    function test_removeSource_emitsEvent() public {
        BalancerAdaptor a1 = _deployBalancerAdaptor();
        BalancerAdaptor a2 = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(a1)));
        calculator.addSource(ISource(address(a2)));

        // Removing index 0 should emit SourceRemoved(a1, 0)
        vm.expectEmit(true, false, false, true);
        emit VotingWeightCalculator.SourceRemoved(ISource(address(a1)), 0);
        calculator.removeSource(0);
    }

    /// @dev addSource emits the correct event
    function test_addSource_emitsEvent() public {
        BalancerAdaptor adaptor = _deployBalancerAdaptor();

        vm.expectEmit(true, false, false, false);
        emit VotingWeightCalculator.SourceAdded(ISource(address(adaptor)));
        calculator.addSource(ISource(address(adaptor)));
    }

    /// @dev addSource reverts when contract supports IERC165 but NOT ISource
    function test_addSource_revertsForIERC165WithoutISource() public {
        // Deploy a contract that supports IERC165 but returns false for ISource
        NonSourceERC165 badSource = new NonSourceERC165();

        vm.expectRevert("VotingWeightCalculator: address does not support Source");
        calculator.addSource(ISource(address(badSource)));
    }

    /// @dev balanceOf with a single source that returns zero for the voter
    function test_balanceOf_singleSourceReturnsZero() public {
        MockSource mockSrc = new MockSource();
        // mockSrc.balanceOf returns 0 by default
        calculator.addSource(ISource(address(mockSrc)));

        address voter = makeAddr("zeroVoter");
        assertEq(calculator.balanceOf(voter), 0, "Single source returning zero => total zero");
    }

    /// @dev balanceOf iterates correctly when one source returns zero and another nonzero
    function test_balanceOf_mixedZeroAndNonZeroSources() public {
        MockSource zeroSource = new MockSource();
        MockSource nonZeroSource = new MockSource();
        nonZeroSource.setBalanceOf(makeAddr("mixedVoter"), 77e18);

        calculator.addSource(ISource(address(zeroSource)));
        calculator.addSource(ISource(address(nonZeroSource)));

        uint256 result = calculator.balanceOf(makeAddr("mixedVoter"));
        assertEq(result, 77e18, "Should sum: 0 + 77e18");
    }

    /// @dev balanceOf with three sources, two returning zero
    function test_balanceOf_multipleSourcesMostZero() public {
        MockSource s1 = new MockSource();
        MockSource s2 = new MockSource();
        MockSource s3 = new MockSource();
        address voter = makeAddr("sparseVoter");
        s2.setBalanceOf(voter, 33e18);

        calculator.addSource(ISource(address(s1)));
        calculator.addSource(ISource(address(s2)));
        calculator.addSource(ISource(address(s3)));

        assertEq(calculator.balanceOf(voter), 33e18);
    }

    /// @dev removeSource on a single-element array (exercises the self-swap edge case
    ///      where sources[0] = sources[sources.length - 1])
    function test_removeSource_singleElement_selfSwap() public {
        MockSource s = new MockSource();
        calculator.addSource(ISource(address(s)));

        // Removing the only element: sources[0] = sources[0], then pop
        calculator.removeSource(0);
        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 0);
    }

    /// @dev removeSource on last index of a two-element array (no swap needed)
    function test_removeSource_lastIndex_noSwap() public {
        MockSource s1 = new MockSource();
        MockSource s2 = new MockSource();
        calculator.addSource(ISource(address(s1)));
        calculator.addSource(ISource(address(s2)));

        calculator.removeSource(1);
        ISource[] memory srcs = calculator.getSources();
        assertEq(srcs.length, 1);
        assertEq(address(srcs[0]), address(s1));
    }

    /// @dev removeSource reverts for non-owner even when array is empty
    function test_removeSource_emptyArray_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
        calculator.removeSource(0);
    }

    /// @dev Verify the public `sources` getter by index works correctly
    function test_sources_publicGetter() public {
        BalancerAdaptor a = _deployBalancerAdaptor();
        calculator.addSource(ISource(address(a)));

        assertEq(address(calculator.sources(0)), address(a));
    }

    /// @dev addSource duplicate check traverses the full array
    function test_addSource_duplicateCheckTraversesFullArray() public {
        MockSource s1 = new MockSource();
        MockSource s2 = new MockSource();
        MockSource s3 = new MockSource();
        calculator.addSource(ISource(address(s1)));
        calculator.addSource(ISource(address(s2)));
        calculator.addSource(ISource(address(s3)));

        // Attempting to add s1 (first), s2 (middle), s3 (last) should all revert
        vm.expectRevert("VotingWeightCalculator: source already added");
        calculator.addSource(ISource(address(s1)));

        vm.expectRevert("VotingWeightCalculator: source already added");
        calculator.addSource(ISource(address(s2)));

        vm.expectRevert("VotingWeightCalculator: source already added");
        calculator.addSource(ISource(address(s3)));
    }
}

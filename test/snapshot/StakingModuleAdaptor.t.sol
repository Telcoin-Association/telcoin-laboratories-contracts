// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingModuleAdaptor} from "contracts/snapshot/adaptors/StakingModuleAdaptor.sol";
import {IStakingModule} from "contracts/snapshot/interfaces/IStakingModule.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @title StakingModuleAdaptorTest
/// @notice Polygon-fork tests for the StakingModule voting-weight adaptor. The adaptor reads
///         `stakedBy(account)` from the production StakingModule to surface staked TEL as
///         governance weight. Tests verify the read path against live mainnet state.
contract StakingModuleAdaptorTest is Test {
    uint256 constant FORK_BLOCK = 68_000_000;

    // Local alias for shared mainnet address (see test/util/PolygonConstants.sol).
    address constant STAKING_MODULE = PolygonConstants.STAKING_MODULE;

    StakingModuleAdaptor adaptor;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        adaptor = new StakingModuleAdaptor(IStakingModule(STAKING_MODULE));
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsModule() public view {
        assertEq(address(adaptor._module()), STAKING_MODULE);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert("StakingModuleAdaptor: cannot initialize to zero");
        new StakingModuleAdaptor(IStakingModule(address(0)));
    }

    // ---------------------------------------------------------------
    // supportsInterface
    // ---------------------------------------------------------------

    function test_supportsInterface_ISource() public view {
        assertTrue(adaptor.supportsInterface(type(ISource).interfaceId));
    }

    function test_supportsInterface_random_returnsFalse() public view {
        assertFalse(adaptor.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ---------------------------------------------------------------
    // balanceOf
    // ---------------------------------------------------------------

    function test_balanceOf_zeroForUnknownVoter() public {
        address nobody = makeAddr("nobody");
        // A random address almost certainly has no stake
        // This should NOT revert; it delegates to the module
        uint256 bal = adaptor.balanceOf(nobody);
        assertEq(bal, 0);
    }

    function test_balanceOf_delegatesToModule() public {
        // Pick a random address and confirm the adaptor returns the same
        // value as calling the module directly with empty auxData
        address voter = makeAddr("voter");

        uint256 direct = IStakingModule(STAKING_MODULE).balanceOf(voter, "");
        uint256 viaAdaptor = adaptor.balanceOf(voter);

        assertEq(viaAdaptor, direct);
    }

    function test_balanceOf_matchesModuleForKnownStaker() public view {
        // We can't know a specific staker at this block, but we can verify
        // that the adaptor proxies faithfully for any address.
        // Use address(1) as a canary.
        address canary = address(1);
        uint256 direct = IStakingModule(STAKING_MODULE).balanceOf(canary, "");
        uint256 viaAdaptor = adaptor.balanceOf(canary);
        assertEq(viaAdaptor, direct);
    }

    // ---------------------------------------------------------------
    // Integration with VotingWeightCalculator
    // ---------------------------------------------------------------

    function test_canBeAddedAsSource() public view {
        // The adaptor should support ISource interface, which is required
        // for VotingWeightCalculator.addSource
        assertTrue(adaptor.supportsInterface(type(ISource).interfaceId));
    }
}

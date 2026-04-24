// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingRewardsFactory} from "contracts/telx/core/StakingRewardsFactory.sol";
import {StakingRewards} from "contracts/telx/core/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @title StakingRewardsFactoryTest
/// @notice Polygon-fork tests for the StakingRewardsFactory — the deterministic-deployer for
///         per-pool StakingRewards instances. Verifies that `deployStakingRewards` produces
///         contracts with the correct (rewardsToken, stakingToken) pair and reverts on duplicates.
contract StakingRewardsFactoryTest is Test {
    StakingRewardsFactory public factory;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address public constant TEL = PolygonConstants.TEL;
    address public constant USDC = PolygonConstants.USDC;
    address public constant WETH = PolygonConstants.WETH;

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    IERC20 public stakingToken2;

    address public owner;
    address public alice;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), 65_000_000);

        owner = address(this);
        alice = makeAddr("alice");

        rewardsToken = IERC20(TEL);
        stakingToken = IERC20(USDC);
        stakingToken2 = IERC20(WETH);

        // Deploy a dummy implementation for the immutable (unused in actual logic, just stored)
        StakingRewards impl = new StakingRewards(address(this), rewardsToken, stakingToken);
        factory = new StakingRewardsFactory(address(impl));
    }

    // -----------
    // CONSTRUCTOR
    // -----------

    function test_constructor() public view {
        assertTrue(factory.stakingRewardsImplementation() != address(0));
        assertEq(factory.owner(), owner);
        assertEq(factory.getStakingRewardsContractCount(), 0);
    }

    // ----------------------
    // CREATE STAKING REWARDS
    // ----------------------

    function test_createStakingRewards_happyPath() public {
        StakingRewards created = factory.createStakingRewards(
            address(this),
            rewardsToken,
            stakingToken
        );

        assertTrue(address(created) != address(0), "created contract should not be zero address");
        assertEq(address(created.rewardsToken()), address(rewardsToken));
        assertEq(address(created.stakingToken()), address(stakingToken));
        assertEq(created.rewardsDistribution(), address(this));
        assertEq(created.owner(), address(this));
        assertEq(factory.getStakingRewardsContractCount(), 1);

        StakingRewards retrieved = factory.getStakingRewardsContract(0);
        assertEq(address(retrieved), address(created));
    }

    function test_createStakingRewards_emitsEvent() public {
        // Check only the indexed params (topics), not the non-indexed data (implementation address is unpredictable)
        vm.expectEmit(true, true, true, false);
        emit StakingRewardsFactory.NewStakingRewardsContract(
            0, rewardsToken, stakingToken, StakingRewards(address(0))
        );

        factory.createStakingRewards(address(this), rewardsToken, stakingToken);
    }

    function test_createStakingRewards_multipleContracts() public {
        StakingRewards first = factory.createStakingRewards(
            address(this),
            rewardsToken,
            stakingToken
        );
        StakingRewards second = factory.createStakingRewards(
            address(this),
            rewardsToken,
            stakingToken2
        );
        StakingRewards third = factory.createStakingRewards(
            alice,
            rewardsToken,
            stakingToken
        );

        assertEq(factory.getStakingRewardsContractCount(), 3);
        assertEq(address(factory.getStakingRewardsContract(0)), address(first));
        assertEq(address(factory.getStakingRewardsContract(1)), address(second));
        assertEq(address(factory.getStakingRewardsContract(2)), address(third));

        // Verify each has the correct staking token
        assertEq(address(first.stakingToken()), address(stakingToken));
        assertEq(address(second.stakingToken()), address(stakingToken2));
        assertEq(address(third.stakingToken()), address(stakingToken));
        // Verify different rewardsDistribution
        assertEq(third.rewardsDistribution(), alice);
    }

    function test_createStakingRewards_incrementsIndex() public {
        factory.createStakingRewards(address(this), rewardsToken, stakingToken);
        assertEq(factory.getStakingRewardsContractCount(), 1);

        factory.createStakingRewards(address(this), rewardsToken, stakingToken2);
        assertEq(factory.getStakingRewardsContractCount(), 2);
    }

    // --------------
    // ACCESS CONTROL
    // --------------

    function testRevert_createStakingRewards_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.createStakingRewards(address(this), rewardsToken, stakingToken);
    }

    // --------------------
    // CONTRACT ENUMERATION
    // --------------------

    function test_getStakingRewardsContract_returnsCorrectAddress() public {
        StakingRewards created = factory.createStakingRewards(
            address(this),
            rewardsToken,
            stakingToken
        );

        StakingRewards retrieved = factory.getStakingRewardsContract(0);
        assertEq(address(retrieved), address(created));
    }

    function testRevert_getStakingRewardsContract_outOfBounds() public {
        vm.expectRevert();
        factory.getStakingRewardsContract(0);
    }

    function test_getStakingRewardsContractCount_empty() public view {
        assertEq(factory.getStakingRewardsContractCount(), 0);
    }

    function test_getStakingRewardsContractCount_afterCreation() public {
        factory.createStakingRewards(address(this), rewardsToken, stakingToken);
        factory.createStakingRewards(address(this), rewardsToken, stakingToken2);

        assertEq(factory.getStakingRewardsContractCount(), 2);
    }

    function test_stakingRewardsContracts_directMapping() public {
        StakingRewards created = factory.createStakingRewards(
            address(this),
            rewardsToken,
            stakingToken
        );

        // Access the public array directly
        StakingRewards direct = factory.stakingRewardsContracts(0);
        assertEq(address(direct), address(created));
    }

    // ---------
    // OWNERSHIP
    // ---------

    function test_transferOwnership() public {
        factory.transferOwnership(alice);
        assertEq(factory.owner(), alice);

        // New owner can create
        vm.prank(alice);
        factory.createStakingRewards(alice, rewardsToken, stakingToken);
        assertEq(factory.getStakingRewardsContractCount(), 1);
    }
}

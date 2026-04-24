// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingRewardsManager} from "contracts/telx/core/StakingRewardsManager.sol";
import {StakingRewardsFactory} from "contracts/telx/core/StakingRewardsFactory.sol";
import {StakingRewards} from "contracts/telx/core/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @title StakingRewardsManagerTest
/// @notice Polygon-fork tests for the upgradeable StakingRewardsManager — coordinates the
///         StakingRewardsFactory's per-pool deployments behind a single owner. Tests the BUILDER
///         and SUPPORT role gates, factory address swap, and the `addStakingRewards` registry.
contract StakingRewardsManagerTest is Test {
    StakingRewardsManager public manager;
    StakingRewardsFactory public factory;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address public constant TEL = PolygonConstants.TEL;
    address public constant USDC = PolygonConstants.USDC;
    address public constant WETH = PolygonConstants.WETH;

    IERC20 public rewardToken;
    IERC20 public stakingToken;
    IERC20 public stakingToken2;

    address public deployer;
    address public builder;
    address public maintainer;
    address public supportRole;
    address public adminRole;
    address public executor;
    address public alice;

    bytes32 public constant BUILDER_ROLE = keccak256("BUILDER_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint256 public constant REWARDS_DURATION = 30 days;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), 65_000_000);

        deployer = address(this);
        builder = makeAddr("builder");
        maintainer = makeAddr("maintainer");
        supportRole = makeAddr("support");
        adminRole = makeAddr("admin");
        executor = makeAddr("executor");
        alice = makeAddr("alice");

        rewardToken = IERC20(TEL);
        stakingToken = IERC20(USDC);
        stakingToken2 = IERC20(WETH);

        // Deploy factory (owned by deployer so manager can call createStakingRewards via factory)
        StakingRewards impl = new StakingRewards(deployer, rewardToken, stakingToken);
        factory = new StakingRewardsFactory(address(impl));

        // Deploy manager as upgradeable proxy
        StakingRewardsManager managerImpl = new StakingRewardsManager();
        manager = StakingRewardsManager(
            address(new ERC1967Proxy(address(managerImpl), ""))
        );
        manager.initialize(rewardToken, factory);

        // Transfer factory ownership to manager so it can call createStakingRewards
        factory.transferOwnership(address(manager));

        // Grant roles
        manager.grantRole(BUILDER_ROLE, builder);
        manager.grantRole(MAINTAINER_ROLE, maintainer);
        manager.grantRole(SUPPORT_ROLE, supportRole);
        manager.grantRole(ADMIN_ROLE, adminRole);
        manager.grantRole(EXECUTOR_ROLE, executor);
    }

    // ----------
    // INITIALIZE
    // ----------

    function test_initialize() public view {
        assertEq(address(manager.rewardToken()), address(rewardToken));
        assertEq(address(manager.stakingRewardsFactory()), address(factory));
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function testRevert_initialize_zeroFactory() public {
        StakingRewardsManager newManager = new StakingRewardsManager();
        StakingRewardsManager proxy = StakingRewardsManager(
            address(new ERC1967Proxy(address(newManager), ""))
        );

        vm.expectRevert("StakingRewardsManager: cannot intialize to zero");
        proxy.initialize(rewardToken, StakingRewardsFactory(address(0)));
    }

    function testRevert_initialize_zeroReward() public {
        StakingRewardsManager newManager = new StakingRewardsManager();
        StakingRewardsManager proxy = StakingRewardsManager(
            address(new ERC1967Proxy(address(newManager), ""))
        );

        vm.expectRevert("StakingRewardsManager: cannot intialize to zero");
        proxy.initialize(IERC20(address(0)), factory);
    }

    function testRevert_initialize_doubleInit() public {
        vm.expectRevert();
        manager.initialize(rewardToken, factory);
    }

    // -----------------------------------
    // CREATE NEW STAKING REWARDS CONTRACT
    // -----------------------------------

    function test_createNewStakingRewardsContract() public {
        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.prank(builder);
        manager.createNewStakingRewardsContract(stakingToken, config);

        assertEq(manager.stakingContractsLength(), 1);
        StakingRewards staking = manager.getStakingContract(0);
        assertTrue(address(staking) != address(0));
        assertEq(address(staking.stakingToken()), address(stakingToken));
        assertEq(address(staking.rewardsToken()), address(rewardToken));
        // The manager should be set as rewardsDistribution
        assertEq(staking.rewardsDistribution(), address(manager));
        assertTrue(manager.stakingExists(staking));
    }

    function testRevert_createNewStakingRewardsContract_onlyBuilder() public {
        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.expectRevert();
        vm.prank(alice);
        manager.createNewStakingRewardsContract(stakingToken, config);
    }

    // ----------------------------
    // ADD STAKING REWARDS CONTRACT
    // ----------------------------

    function test_addStakingRewardsContract() public {
        // Create a staking contract externally (owned by deployer initially)
        StakingRewards staking = new StakingRewards(deployer, rewardToken, stakingToken);
        // Transfer ownership to manager so it can call setRewardsDistribution
        staking.transferOwnership(address(manager));

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.prank(builder);
        manager.addStakingRewardsContract(staking, config);

        assertEq(manager.stakingContractsLength(), 1);
        assertTrue(manager.stakingExists(staking));
        assertEq(staking.rewardsDistribution(), address(manager));

        (uint256 duration, uint256 amount) = manager.stakingConfigs(staking);
        assertEq(duration, REWARDS_DURATION);
        assertEq(amount, REWARD_AMOUNT);
    }

    function testRevert_addStakingRewardsContract_alreadyExists() public {
        StakingRewards staking = new StakingRewards(deployer, rewardToken, stakingToken);
        staking.transferOwnership(address(manager));

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.prank(builder);
        manager.addStakingRewardsContract(staking, config);

        vm.expectRevert("StakingRewardsManager: Staking contract already exists");
        vm.prank(builder);
        manager.addStakingRewardsContract(staking, config);
    }

    function testRevert_addStakingRewardsContract_onlyBuilder() public {
        StakingRewards staking = new StakingRewards(deployer, rewardToken, stakingToken);

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.expectRevert();
        vm.prank(alice);
        manager.addStakingRewardsContract(staking, config);
    }

    // -------------------------------
    // REMOVE STAKING REWARDS CONTRACT
    // -------------------------------

    function test_removeStakingRewardsContract() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        vm.expectEmit(true, true, true, true);
        emit StakingRewardsManager.StakingRemoved(staking);

        vm.prank(builder);
        manager.removeStakingRewardsContract(0);

        assertEq(manager.stakingContractsLength(), 0);
        assertFalse(manager.stakingExists(staking));
    }

    function test_removeStakingRewardsContract_swapAndPop() public {
        // Create three contracts
        _createManagedStaking(stakingToken);
        _createManagedStaking(stakingToken2);
        _createManagedStaking(stakingToken);

        StakingRewards first = manager.getStakingContract(0);
        StakingRewards second = manager.getStakingContract(1);
        StakingRewards third = manager.getStakingContract(2);

        // Remove the first (index 0): third should move to index 0
        vm.prank(builder);
        manager.removeStakingRewardsContract(0);

        assertEq(manager.stakingContractsLength(), 2);
        assertEq(address(manager.getStakingContract(0)), address(third));
        assertEq(address(manager.getStakingContract(1)), address(second));
        assertFalse(manager.stakingExists(first));
    }

    function testRevert_removeStakingRewardsContract_invalidIndex() public {
        vm.expectRevert("StakingRewardsManager: invalid index");
        vm.prank(builder);
        manager.removeStakingRewardsContract(0);
    }

    function testRevert_removeStakingRewardsContract_onlyBuilder() public {
        _createManagedStaking(stakingToken);

        vm.expectRevert();
        vm.prank(alice);
        manager.removeStakingRewardsContract(0);
    }

    // ------------------
    // SET STAKING CONFIG
    // ------------------

    function test_setStakingConfig() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        StakingRewardsManager.StakingConfig memory newConfig = StakingRewardsManager.StakingConfig({
            rewardsDuration: 60 days,
            rewardAmount: 20_000e18
        });

        vm.expectEmit(true, true, true, true);
        emit StakingRewardsManager.StakingConfigChanged(staking, newConfig);

        vm.prank(maintainer);
        manager.setStakingConfig(staking, newConfig);

        (uint256 duration, uint256 amount) = manager.stakingConfigs(staking);
        assertEq(duration, 60 days);
        assertEq(amount, 20_000e18);
    }

    function test_setStakingConfig_forNonExistentContract() public {
        // setStakingConfig does not require the contract to be in the array
        StakingRewards someContract = StakingRewards(makeAddr("random"));

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: 7 days,
            rewardAmount: 1000e18
        });

        vm.prank(maintainer);
        manager.setStakingConfig(someContract, config);

        (uint256 duration, uint256 amount) = manager.stakingConfigs(someContract);
        assertEq(duration, 7 days);
        assertEq(amount, 1000e18);
    }

    function testRevert_setStakingConfig_onlyMaintainer() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: 60 days,
            rewardAmount: 20_000e18
        });

        vm.expectRevert();
        vm.prank(alice);
        manager.setStakingConfig(staking, config);

        // builder should also not be able to
        vm.expectRevert();
        vm.prank(builder);
        manager.setStakingConfig(staking, config);
    }

    // ---------------------------
    // SET STAKING REWARDS FACTORY
    // ---------------------------

    function test_setStakingRewardsFactory() public {
        StakingRewardsFactory newFactory = new StakingRewardsFactory(address(1));

        vm.expectEmit(true, true, true, true);
        emit StakingRewardsManager.StakingRewardsFactoryChanged(newFactory);

        vm.prank(maintainer);
        manager.setStakingRewardsFactory(newFactory);

        assertEq(address(manager.stakingRewardsFactory()), address(newFactory));
    }

    function testRevert_setStakingRewardsFactory_zeroAddress() public {
        vm.expectRevert("StakingRewardsManager: Factory cannot be set to zero");
        vm.prank(maintainer);
        manager.setStakingRewardsFactory(StakingRewardsFactory(address(0)));
    }

    function testRevert_setStakingRewardsFactory_onlyMaintainer() public {
        StakingRewardsFactory newFactory = new StakingRewardsFactory(address(1));

        vm.expectRevert();
        vm.prank(alice);
        manager.setStakingRewardsFactory(newFactory);
    }

    // ------
    // TOP UP
    // ------

    function test_topUp_happyPath() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        (uint256 duration, uint256 amount) = manager.stakingConfigs(staking);

        // Fund executor who will be the source
        deal(address(rewardToken), executor, amount);
        vm.prank(executor);
        rewardToken.approve(address(manager), type(uint256).max);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        vm.expectEmit(true, true, true, true);
        emit StakingRewardsManager.ToppedUp(
            staking,
            StakingRewardsManager.StakingConfig({rewardsDuration: duration, rewardAmount: amount})
        );

        vm.prank(executor);
        manager.topUp(executor, indices);

        // Verify the staking contract has been configured
        assertEq(staking.rewardsDuration(), duration);
        assertEq(staking.periodFinish(), block.timestamp + duration);
        assertTrue(staking.rewardRate() > 0);
    }

    function test_topUp_multipleContracts() public {
        _createManagedStaking(stakingToken);
        _createManagedStaking(stakingToken2);

        StakingRewards staking0 = manager.getStakingContract(0);
        StakingRewards staking1 = manager.getStakingContract(1);

        (, uint256 amount0) = manager.stakingConfigs(staking0);
        (, uint256 amount1) = manager.stakingConfigs(staking1);

        uint256 totalAmount = amount0 + amount1;
        deal(address(rewardToken), executor, totalAmount);
        vm.prank(executor);
        rewardToken.approve(address(manager), type(uint256).max);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        vm.prank(executor);
        manager.topUp(executor, indices);

        assertTrue(staking0.rewardRate() > 0, "staking0 should have non-zero reward rate");
        assertTrue(staking1.rewardRate() > 0, "staking1 should have non-zero reward rate");
    }

    function testRevert_topUp_midPeriod() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        (, uint256 amount) = manager.stakingConfigs(staking);
        deal(address(rewardToken), executor, amount * 2);
        vm.prank(executor);
        rewardToken.approve(address(manager), type(uint256).max);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        // First top up succeeds
        vm.prank(executor);
        manager.topUp(executor, indices);

        // Second top up mid-period should revert because setRewardsDuration will fail
        vm.expectRevert(
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        vm.prank(executor);
        manager.topUp(executor, indices);
    }

    function testRevert_topUp_onlyExecutor() public {
        _createManagedStaking(stakingToken);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        vm.expectRevert();
        vm.prank(alice);
        manager.topUp(alice, indices);
    }

    // -------------
    // RECOVER ERC20
    // -------------

    function test_recoverERC20FromStaking() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        // Send some reward tokens directly to the staking contract
        deal(address(rewardToken), address(staking), 1000e18);

        vm.prank(supportRole);
        manager.recoverERC20FromStaking(staking, rewardToken, 500e18, alice);

        assertEq(rewardToken.balanceOf(alice), 500e18);
    }

    function testRevert_recoverERC20FromStaking_onlySupport() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        deal(address(rewardToken), address(staking), 1000e18);

        vm.expectRevert();
        vm.prank(alice);
        manager.recoverERC20FromStaking(staking, rewardToken, 500e18, alice);
    }

    function test_recoverTokens() public {
        // Send tokens to manager contract
        deal(address(rewardToken), address(manager), 1000e18);

        vm.prank(supportRole);
        manager.recoverTokens(rewardToken, 500e18, alice);

        assertEq(rewardToken.balanceOf(alice), 500e18);
    }

    function testRevert_recoverTokens_onlySupport() public {
        deal(address(rewardToken), address(manager), 1000e18);

        vm.expectRevert();
        vm.prank(alice);
        manager.recoverTokens(rewardToken, 500e18, alice);
    }

    // --------------------------
    // TRANSFER STAKING OWNERSHIP
    // --------------------------

    function test_transferStakingOwnership() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        vm.prank(adminRole);
        manager.transferStakingOwnership(staking, alice);

        assertEq(staking.owner(), alice);
    }

    function testRevert_transferStakingOwnership_onlyAdmin() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        vm.expectRevert();
        vm.prank(alice);
        manager.transferStakingOwnership(staking, alice);

        // builder should not be able to
        vm.expectRevert();
        vm.prank(builder);
        manager.transferStakingOwnership(staking, alice);
    }

    // ----------------------------
    // ACCESS CONTROL COMPREHENSIVE
    // ----------------------------

    function test_accessControl_allRolesAssigned() public view {
        assertTrue(manager.hasRole(BUILDER_ROLE, builder));
        assertTrue(manager.hasRole(MAINTAINER_ROLE, maintainer));
        assertTrue(manager.hasRole(SUPPORT_ROLE, supportRole));
        assertTrue(manager.hasRole(ADMIN_ROLE, adminRole));
        assertTrue(manager.hasRole(EXECUTOR_ROLE, executor));
    }

    function test_accessControl_defaultAdmin() public view {
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), alice));
    }

    function testRevert_accessControl_builderCantMaintain() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: 60 days,
            rewardAmount: 20_000e18
        });

        vm.expectRevert();
        vm.prank(builder);
        manager.setStakingConfig(staking, config);
    }

    function testRevert_accessControl_maintainerCantBuild() public {
        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.expectRevert();
        vm.prank(maintainer);
        manager.createNewStakingRewardsContract(stakingToken, config);
    }

    function testRevert_accessControl_executorCantSupport() public {
        deal(address(rewardToken), address(manager), 1000e18);

        vm.expectRevert();
        vm.prank(executor);
        manager.recoverTokens(rewardToken, 500e18, alice);
    }

    function testRevert_accessControl_supportCantAdmin() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);

        vm.expectRevert();
        vm.prank(supportRole);
        manager.transferStakingOwnership(staking, alice);
    }

    // --------------
    // VIEW FUNCTIONS
    // --------------

    function test_stakingContractsLength() public {
        assertEq(manager.stakingContractsLength(), 0);

        _createManagedStaking(stakingToken);
        assertEq(manager.stakingContractsLength(), 1);

        _createManagedStaking(stakingToken2);
        assertEq(manager.stakingContractsLength(), 2);
    }

    function test_getStakingContract() public {
        _createManagedStaking(stakingToken);
        StakingRewards staking = manager.getStakingContract(0);
        assertTrue(address(staking) != address(0));
    }

    // -------
    // HELPERS
    // -------

    function _createManagedStaking(IERC20 _stakingToken) internal {
        StakingRewardsManager.StakingConfig memory config = StakingRewardsManager.StakingConfig({
            rewardsDuration: REWARDS_DURATION,
            rewardAmount: REWARD_AMOUNT
        });

        vm.prank(builder);
        manager.createNewStakingRewardsContract(_stakingToken, config);
    }
}

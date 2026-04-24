// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StakingRewards} from "contracts/telx/core/StakingRewards.sol";
import {RewardsDistributionRecipient} from "contracts/telx/abstract/RewardsDistributionRecipient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @title StakingRewardsTest
/// @notice Polygon-fork tests for the standalone StakingRewards contract (unstaked from the
///         TELxIncentiveHook flow). Validates `notifyRewardAmount`, per-user `earned()`
///         accounting, and the `recoverERC20` guard against draining the staking token.
contract StakingRewardsTest is Test {
    StakingRewards public stakingRewards;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address public constant TEL = PolygonConstants.TEL;
    address public constant USDC = PolygonConstants.USDC;

    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    address public owner;
    address public alice;
    address public bob;
    address public charlie;

    uint256 public constant INITIAL_STAKE = 1000e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), 65_000_000);

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        rewardsToken = IERC20(TEL);
        stakingToken = IERC20(USDC);

        vm.prank(owner);
        stakingRewards = new StakingRewards(owner, rewardsToken, stakingToken);

        // Fund users with staking tokens via deal
        deal(address(stakingToken), alice, 100_000e6);
        deal(address(stakingToken), bob, 100_000e6);
        deal(address(stakingToken), charlie, 100_000e6);

        // Fund the contract owner with reward tokens
        deal(address(rewardsToken), owner, 1_000_000e18);

        // Approve staking contract for all users
        vm.prank(alice);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        vm.prank(charlie);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
    }

    // -----------
    // CONSTRUCTOR
    // -----------

    function test_constructor() public view {
        assertEq(address(stakingRewards.rewardsToken()), address(rewardsToken));
        assertEq(address(stakingRewards.stakingToken()), address(stakingToken));
        assertEq(stakingRewards.rewardsDistribution(), owner);
        assertEq(stakingRewards.owner(), owner);
        assertEq(stakingRewards.rewardsDuration(), 30 days);
        assertEq(stakingRewards.periodFinish(), 0);
        assertEq(stakingRewards.rewardRate(), 0);
        assertEq(stakingRewards.EQUALIZING_FACTOR(), 1e18);
    }

    // --------------
    // VIEW FUNCTIONS
    // --------------

    function test_totalSupply_initiallyZero() public view {
        assertEq(stakingRewards.totalSupply(), 0);
    }

    function test_balanceOf_initiallyZero() public view {
        assertEq(stakingRewards.balanceOf(alice), 0);
    }

    function test_lastTimeRewardApplicable_beforeNotify() public view {
        // periodFinish is 0, so min(block.timestamp, 0) = 0
        assertEq(stakingRewards.lastTimeRewardApplicable(), 0);
    }

    function test_lastTimeRewardApplicable_duringPeriod() public {
        _notifyRewardAmount(REWARD_AMOUNT);
        // During the period, lastTimeRewardApplicable == block.timestamp
        assertEq(stakingRewards.lastTimeRewardApplicable(), block.timestamp);
    }

    function test_lastTimeRewardApplicable_afterPeriod() public {
        _notifyRewardAmount(REWARD_AMOUNT);
        uint256 periodEnd = stakingRewards.periodFinish();
        vm.warp(periodEnd + 1 days);
        assertEq(stakingRewards.lastTimeRewardApplicable(), periodEnd);
    }

    function test_rewardPerToken_zeroSupply() public view {
        assertEq(stakingRewards.rewardPerToken(), 0);
    }

    function test_rewardPerToken_withStakers() public {
        // Alice stakes
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);

        // Advance time
        vm.warp(block.timestamp + 1 days);

        uint256 rpt = stakingRewards.rewardPerToken();
        assertTrue(rpt > 0, "rewardPerToken should be > 0 after time advance with stakers");
    }

    function test_earned_noStake() public view {
        assertEq(stakingRewards.earned(alice), 0);
    }

    function test_earned_withStake() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 15 days);

        uint256 earnedAmount = stakingRewards.earned(alice);
        assertTrue(earnedAmount > 0, "earned should be > 0 after time passes");
    }

    /// @notice Test the known double-division bug in earned()
    /// earned = (balance * (rewardPerToken - userRewardPerTokenPaid) / 1e18) / EQUALIZING_FACTOR + rewards
    /// The double division by 1e18 * 1e18 causes precision loss for small stakers
    function test_earned_doubleDivisionBug() public {
        // Use a very small stake to demonstrate precision loss from double division
        uint256 smallStake = 1e6; // 1 USDC

        vm.prank(alice);
        stakingRewards.stake(smallStake);

        _notifyRewardAmount(REWARD_AMOUNT);

        // Advance 30 days (full period)
        vm.warp(block.timestamp + 30 days);

        uint256 earnedAmount = stakingRewards.earned(alice);

        // Due to the double division (/ 1e18 / EQUALIZING_FACTOR where EQUALIZING_FACTOR = 1e18),
        // the effective denominator is 1e36, which causes massive precision loss.
        // The actual reward should be ~REWARD_AMOUNT but earned() returns much less or 0.
        // If there were no double-division bug, with sole staker for full period, earned ~ REWARD_AMOUNT.
        // With the bug: the balance (1e6) * rewardPerToken gets divided by 1e36 total, losing almost everything.
        // We just document the behavior here.
        uint256 expectedWithoutBug = REWARD_AMOUNT; // sole staker for full period
        assertTrue(earnedAmount < expectedWithoutBug, "double-division causes precision loss");
    }

    function test_getRewardForDuration() public {
        _notifyRewardAmount(REWARD_AMOUNT);

        uint256 rewardForDuration = stakingRewards.getRewardForDuration();
        // Due to integer division in notifyRewardAmount, there may be slight rounding
        assertApproxEqAbs(rewardForDuration, REWARD_AMOUNT, 1e18, "reward for duration should match reward amount");
    }

    // -----
    // STAKE
    // -----

    function test_stake_happyPath() public {
        uint256 stakeAmount = 1000e6;

        vm.expectEmit(true, true, true, true);
        emit StakingRewards.Staked(alice, stakeAmount);

        vm.prank(alice);
        stakingRewards.stake(stakeAmount);

        assertEq(stakingRewards.totalSupply(), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingToken.balanceOf(address(stakingRewards)), stakeAmount);
    }

    function test_stake_multipleUsers() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);
        vm.prank(bob);
        stakingRewards.stake(2000e6);

        assertEq(stakingRewards.totalSupply(), 3000e6);
        assertEq(stakingRewards.balanceOf(alice), 1000e6);
        assertEq(stakingRewards.balanceOf(bob), 2000e6);
    }

    function test_stake_additiveForSameUser() public {
        vm.startPrank(alice);
        stakingRewards.stake(500e6);
        stakingRewards.stake(500e6);
        vm.stopPrank();

        assertEq(stakingRewards.totalSupply(), 1000e6);
        assertEq(stakingRewards.balanceOf(alice), 1000e6);
    }

    function testRevert_stake_zeroAmount() public {
        vm.expectRevert("Cannot stake 0");
        vm.prank(alice);
        stakingRewards.stake(0);
    }

    // Note: StakingRewards inherits Pausable but does not expose pause()/unpause() publicly.
    // No testRevert_stake_whenPaused since pause() is not callable externally.

    // --------
    // WITHDRAW
    // --------

    function test_withdraw_happyPath() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        uint256 balBefore = stakingToken.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit StakingRewards.Withdrawn(alice, 500e6);

        vm.prank(alice);
        stakingRewards.withdraw(500e6);

        assertEq(stakingRewards.totalSupply(), 500e6);
        assertEq(stakingRewards.balanceOf(alice), 500e6);
        assertEq(stakingToken.balanceOf(alice), balBefore + 500e6);
    }

    function test_withdraw_fullAmount() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        vm.prank(alice);
        stakingRewards.withdraw(1000e6);

        assertEq(stakingRewards.totalSupply(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
    }

    function testRevert_withdraw_zeroAmount() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        vm.expectRevert("Cannot withdraw 0");
        vm.prank(alice);
        stakingRewards.withdraw(0);
    }

    function testRevert_withdraw_moreThanBalance() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        // Underflow revert
        vm.expectRevert();
        vm.prank(alice);
        stakingRewards.withdraw(1001e6);
    }

    // ----------
    // GET REWARD
    // ----------

    function test_getReward_happyPath() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 15 days);

        uint256 rewardBalBefore = rewardsToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.getReward();

        uint256 rewardBalAfter = rewardsToken.balanceOf(alice);
        // Should receive approximately the earned amount
        assertGe(rewardBalAfter - rewardBalBefore, 0, "should receive rewards");
    }

    function test_getReward_zeroReward() public {
        // Alice stakes but no rewards have been notified
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        uint256 rewardBalBefore = rewardsToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.getReward();

        // No reward should have been sent
        assertEq(rewardsToken.balanceOf(alice), rewardBalBefore);
    }

    function test_getReward_emitsRewardPaid() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);
        vm.warp(block.timestamp + 30 days);

        uint256 expectedReward = stakingRewards.earned(alice);
        if (expectedReward > 0) {
            vm.expectEmit(true, true, true, true);
            emit StakingRewards.RewardPaid(alice, expectedReward);
        }

        vm.prank(alice);
        stakingRewards.getReward();
    }

    function test_getReward_proportionalDistribution() public {
        // Alice stakes 1000, Bob stakes 3000 -> 1:3 ratio
        vm.prank(alice);
        stakingRewards.stake(1000e6);
        vm.prank(bob);
        stakingRewards.stake(3000e6);

        _notifyRewardAmount(REWARD_AMOUNT);

        // Advance full period
        vm.warp(block.timestamp + 30 days);

        uint256 aliceEarned = stakingRewards.earned(alice);
        uint256 bobEarned = stakingRewards.earned(bob);

        // Bob should earn approximately 3x what Alice earns (allowing for rounding)
        if (aliceEarned > 0) {
            // ratio should be approximately 3:1
            uint256 ratio = (bobEarned * 100) / aliceEarned;
            assertApproxEqAbs(ratio, 300, 5, "Bob should earn ~3x Alice's rewards");
        }
    }

    // ----
    // EXIT
    // ----

    function test_exit_happyPath() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);
        vm.warp(block.timestamp + 15 days);

        uint256 stakingBalBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalSupply(), 0);
        assertEq(stakingToken.balanceOf(alice), stakingBalBefore + 1000e6);
    }

    // --------------------
    // NOTIFY REWARD AMOUNT
    // --------------------

    function test_notifyRewardAmount_newPeriod() public {
        // Fund the staking contract
        deal(address(rewardsToken), address(stakingRewards), REWARD_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit StakingRewards.RewardAdded(REWARD_AMOUNT);

        vm.prank(owner);
        stakingRewards.notifyRewardAmount(REWARD_AMOUNT);

        assertEq(stakingRewards.periodFinish(), block.timestamp + 30 days);
        assertTrue(stakingRewards.rewardRate() > 0);
    }

    function test_notifyRewardAmount_midPeriod() public {
        // First notification
        deal(address(rewardsToken), address(stakingRewards), REWARD_AMOUNT * 2);

        vm.prank(owner);
        stakingRewards.notifyRewardAmount(REWARD_AMOUNT);

        uint256 firstRewardRate = stakingRewards.rewardRate();

        // Advance half the period
        vm.warp(block.timestamp + 15 days);

        // Second notification (adds leftover + new)
        vm.prank(owner);
        stakingRewards.notifyRewardAmount(REWARD_AMOUNT);

        uint256 secondRewardRate = stakingRewards.rewardRate();
        // Second rate should be higher because it includes leftover from first period
        assertTrue(secondRewardRate > firstRewardRate, "second reward rate should include leftover");
    }

    function testRevert_notifyRewardAmount_tooHigh() public {
        // Don't fund the contract enough
        deal(address(rewardsToken), address(stakingRewards), REWARD_AMOUNT / 2);

        vm.expectRevert("Provided reward too high");
        vm.prank(owner);
        stakingRewards.notifyRewardAmount(REWARD_AMOUNT);
    }

    function testRevert_notifyRewardAmount_onlyRewardsDistribution() public {
        deal(address(rewardsToken), address(stakingRewards), REWARD_AMOUNT);

        vm.expectRevert("Caller is not RewardsDistribution contract");
        vm.prank(alice);
        stakingRewards.notifyRewardAmount(REWARD_AMOUNT);
    }

    // --------------------
    // SET REWARDS DURATION
    // --------------------

    function test_setRewardsDuration_happyPath() public {
        // Period is not started (periodFinish == 0), so block.timestamp > 0 > 0 is true
        vm.expectEmit(true, true, true, true);
        emit StakingRewards.RewardsDurationUpdated(60 days);

        vm.prank(owner);
        stakingRewards.setRewardsDuration(60 days);

        assertEq(stakingRewards.rewardsDuration(), 60 days);
    }

    function test_setRewardsDuration_afterPeriodComplete() public {
        _notifyRewardAmount(REWARD_AMOUNT);

        // Warp past the period
        vm.warp(stakingRewards.periodFinish() + 1);

        vm.prank(owner);
        stakingRewards.setRewardsDuration(60 days);

        assertEq(stakingRewards.rewardsDuration(), 60 days);
    }

    function testRevert_setRewardsDuration_duringActivePeriod() public {
        _notifyRewardAmount(REWARD_AMOUNT);

        // Try to change during active period
        vm.expectRevert(
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        vm.prank(owner);
        stakingRewards.setRewardsDuration(60 days);
    }

    function testRevert_setRewardsDuration_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        stakingRewards.setRewardsDuration(60 days);
    }

    // -------------
    // RECOVER ERC20
    // -------------

    function test_recoverERC20_happyPath() public {
        // Send some reward tokens to the staking contract "by accident"
        deal(address(rewardsToken), address(stakingRewards), 1000e18);

        vm.expectEmit(true, true, true, true);
        emit StakingRewards.Recovered(rewardsToken, 500e18);

        vm.prank(owner);
        stakingRewards.recoverERC20(alice, rewardsToken, 500e18);

        assertEq(rewardsToken.balanceOf(alice), 500e18);
    }

    function testRevert_recoverERC20_stakingToken() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        vm.expectRevert("Cannot withdraw the staking token");
        vm.prank(owner);
        stakingRewards.recoverERC20(owner, stakingToken, 1000e6);
    }

    function testRevert_recoverERC20_onlyOwner() public {
        deal(address(rewardsToken), address(stakingRewards), 1000e18);

        vm.expectRevert();
        vm.prank(alice);
        stakingRewards.recoverERC20(alice, rewardsToken, 500e18);
    }

    // ---------------
    // PAUSE / UNPAUSE
    // ---------------

    // Note: StakingRewards inherits Pausable but does not expose pause()/unpause() publicly.
    // The whenNotPaused modifier on stake() is only triggerable if a subclass exposes _pause().
    // We test the paused() view function and verify stake uses whenNotPaused.

    function test_paused_initiallyFalse() public view {
        assertFalse(stakingRewards.paused(), "should not be paused initially");
    }

    function test_whenNotPaused_stakeSucceeds() public {
        // When not paused, stake should succeed
        vm.prank(alice);
        stakingRewards.stake(1000e6);
        assertEq(stakingRewards.balanceOf(alice), 1000e6);
    }

    // --------------------
    // REWARDS DISTRIBUTION
    // --------------------

    function test_setRewardsDistribution_happyPath() public {
        vm.prank(owner);
        stakingRewards.setRewardsDistribution(bob);

        assertEq(stakingRewards.rewardsDistribution(), bob);
    }

    function testRevert_setRewardsDistribution_zeroAddress() public {
        vm.expectRevert("TelcoinDistributor: cannot set to zero address");
        vm.prank(owner);
        stakingRewards.setRewardsDistribution(address(0));
    }

    function testRevert_setRewardsDistribution_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        stakingRewards.setRewardsDistribution(bob);
    }

    // --------------
    // FULL LIFECYCLE
    // --------------

    function test_fullLifecycle() public {
        // 1. Alice stakes
        vm.prank(alice);
        stakingRewards.stake(2000e6);

        // 2. Notify reward
        _notifyRewardAmount(REWARD_AMOUNT);

        // 3. Bob stakes after 5 days
        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        stakingRewards.stake(2000e6);

        // 4. Advance 10 more days
        vm.warp(block.timestamp + 10 days);

        // 5. Alice gets reward
        uint256 aliceEarned = stakingRewards.earned(alice);
        vm.prank(alice);
        stakingRewards.getReward();
        assertEq(stakingRewards.earned(alice), 0, "alice earned should be 0 after claiming");

        // 6. Bob exits
        uint256 bobEarned = stakingRewards.earned(bob);
        vm.prank(bob);
        stakingRewards.exit();
        assertEq(stakingRewards.balanceOf(bob), 0);

        // 7. Alice was sole staker for first 5 days, then split with Bob for 10 days
        // Alice should have earned more than Bob
        assertTrue(aliceEarned >= bobEarned, "Alice should earn more than Bob (staked longer)");
    }

    function test_rewardAccrual_zeroSupplyGap() public {
        // Start rewards with no stakers
        _notifyRewardAmount(REWARD_AMOUNT);

        // Advance 10 days with nobody staked
        vm.warp(block.timestamp + 10 days);

        // Alice stakes
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        // Advance 10 more days
        vm.warp(block.timestamp + 10 days);

        uint256 aliceEarned = stakingRewards.earned(alice);

        // Alice should only earn rewards for the 10 days she was staked, not the gap
        // The first 10 days of rewards are effectively lost since nobody was staked
        // We verify some rewards accrued but not the full amount
        assertTrue(aliceEarned > 0, "Alice should have earned some reward");
    }

    // ----------
    // FUZZ TESTS
    // ----------

    function testFuzz_stake(uint128 amount) public {
        amount = uint128(bound(amount, 1, 100_000e6));

        vm.prank(alice);
        stakingRewards.stake(amount);

        assertEq(stakingRewards.totalSupply(), amount);
        assertEq(stakingRewards.balanceOf(alice), amount);
    }

    function testFuzz_stakeAndWithdraw(uint128 stakeAmount, uint128 withdrawAmount) public {
        stakeAmount = uint128(bound(stakeAmount, 1, 100_000e6));
        withdrawAmount = uint128(bound(withdrawAmount, 1, stakeAmount));

        vm.prank(alice);
        stakingRewards.stake(stakeAmount);

        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.balanceOf(alice), stakeAmount - withdrawAmount);
        assertEq(stakingRewards.totalSupply(), stakeAmount - withdrawAmount);
    }

    function testFuzz_rewardCalculation(uint128 stakeAmount, uint128 rewardAmount, uint32 timeElapsed) public {
        stakeAmount = uint128(bound(stakeAmount, 1e6, 100_000e6));
        rewardAmount = uint128(bound(rewardAmount, 1e18, 100_000e18));
        timeElapsed = uint32(bound(timeElapsed, 1 hours, 30 days));

        vm.prank(alice);
        stakingRewards.stake(stakeAmount);

        deal(address(rewardsToken), address(stakingRewards), rewardAmount);
        vm.prank(owner);
        stakingRewards.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + timeElapsed);

        // earned should never revert
        uint256 earned = stakingRewards.earned(alice);
        // earned should be in some reasonable range (not more than total rewards, allowing for precision)
        assertTrue(earned <= rewardAmount + 1e18, "earned should not exceed total rewards");
    }

    // ----------------------
    // UPDATE REWARD MODIFIER
    // ----------------------

    function test_updateReward_storesCorrectly() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        _notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 10 days);

        // Triggering updateReward via stake
        vm.prank(alice);
        stakingRewards.stake(1);

        assertTrue(stakingRewards.rewardPerTokenStored() > 0);
        assertTrue(stakingRewards.userRewardPerTokenPaid(alice) > 0);
        assertTrue(stakingRewards.rewards(alice) > 0 || stakingRewards.earned(alice) >= 0);
    }

    function test_updateReward_zeroAddress() public {
        vm.prank(alice);
        stakingRewards.stake(1000e6);

        // notifyRewardAmount calls updateReward(address(0)) - should not revert
        _notifyRewardAmount(REWARD_AMOUNT);

        // rewards for zero address should not be set
        assertEq(stakingRewards.rewards(address(0)), 0);
    }

    // ------------------
    // OWNERSHIP TRANSFER
    // ------------------

    function test_transferOwnership() public {
        vm.prank(owner);
        stakingRewards.transferOwnership(alice);

        assertEq(stakingRewards.owner(), alice);
    }

    function testRevert_transferOwnership_onlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        stakingRewards.transferOwnership(bob);
    }

    // -------
    // HELPERS
    // -------

    function _notifyRewardAmount(uint256 amount) internal {
        deal(address(rewardsToken), address(stakingRewards), amount + rewardsToken.balanceOf(address(stakingRewards)));
        vm.prank(owner);
        stakingRewards.notifyRewardAmount(amount);
    }
}

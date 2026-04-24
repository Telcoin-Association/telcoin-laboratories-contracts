// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TelcoinDistributor} from "contracts/protocol/core/TelcoinDistributor.sol";
import {CouncilMember} from "contracts/sablier/core/CouncilMember.sol";
import {ISablierV2Lockup} from "contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/**
 * @title TelcoinDistributor Polygon Fork Tests
 * @notice 100 % branch + line coverage against a Polygon mainnet fork.
 *         Uses `deal()` for token balances and `vm.prank()` for role-based calls.
 *         No mocks -- every external dependency is the real on-chain contract.
 */
contract TelcoinDistributorForkTest is Test {
    // ---------
    // constants
    // ---------
    uint256 constant FORK_BLOCK = 85_621_947;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    IERC20 constant TELCOIN = IERC20(PolygonConstants.TEL);
    ISablierV2Lockup constant SABLIER_LOCKUP = ISablierV2Lockup(PolygonConstants.SABLIER_LOCKUP);
    IERC721 constant TAO_COUNCIL_NFT = IERC721(PolygonConstants.TAO_COUNCIL_NFT);

    uint256 constant CHALLENGE_PERIOD = 1 days;

    // -----
    // state
    // -----
    TelcoinDistributor distributor;

    address owner;         // deployer & owner of the distributor
    address councilMember; // holds a TAO council NFT on-chain
    address nonMember;     // holds no council NFT

    address recipient1;
    address recipient2;
    address recipient3;

    // -----
    // setup
    // -----
    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        owner = makeAddr("owner");
        nonMember = makeAddr("nonMember");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        recipient3 = makeAddr("recipient3");

        // Pick a real council-member address that owns a TAO NFT at the fork block.
        // From the deploy script: first TAO member is 0x9246B2C653015e28087b63dB3B9A7afE4c6eb408
        councilMember = 0x9246B2C653015e28087b63dB3B9A7afE4c6eb408;

        // Verify they actually hold a council NFT
        require(TAO_COUNCIL_NFT.balanceOf(councilMember) > 0, "council member must hold NFT");

        // Deploy the distributor
        vm.prank(owner);
        distributor = new TelcoinDistributor(TELCOIN, CHALLENGE_PERIOD, TAO_COUNCIL_NFT);

        // Fund the owner with TEL and approve the distributor for the exact funded amount —
        // mirrors the production pattern where a Safe is funded with N and approves the
        // distributor for that same N (not type(uint256).max). Bounds per-test pulls to the
        // owner's balance and surfaces a regression where the distributor would over-pull.
        uint256 ownerFunding = 100_000_000e2;
        deal(address(TELCOIN), owner, ownerFunding);
        vm.prank(owner);
        TELCOIN.approve(address(distributor), ownerFunding);
    }

    // -----------
    // CONSTRUCTOR
    // -----------

    function test_constructor_setsImmutables() public view {
        assertEq(address(distributor.TELCOIN()), address(TELCOIN));
        assertEq(address(distributor.councilNft()), address(TAO_COUNCIL_NFT));
        assertEq(distributor.challengePeriod(), CHALLENGE_PERIOD);
        assertEq(distributor.owner(), owner);
    }

    function test_constructor_revertsZeroTelcoin() public {
        vm.expectRevert("TelcoinDistributor: cannot intialize to zero");
        new TelcoinDistributor(IERC20(address(0)), CHALLENGE_PERIOD, TAO_COUNCIL_NFT);
    }

    function test_constructor_revertsZeroCouncil() public {
        vm.expectRevert("TelcoinDistributor: cannot intialize to zero");
        new TelcoinDistributor(TELCOIN, CHALLENGE_PERIOD, IERC721(address(0)));
    }

    function test_constructor_revertsZeroPeriod() public {
        vm.expectRevert("TelcoinDistributor: cannot intialize to zero");
        new TelcoinDistributor(TELCOIN, 0, TAO_COUNCIL_NFT);
    }

    // --------------------------
    // onlyCouncilMember MODIFIER
    // --------------------------

    function test_onlyCouncilMember_revertsNonMember() public {
        address[] memory dests = new address[](1);
        dests[0] = recipient1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        vm.prank(nonMember);
        vm.expectRevert("TelcoinDistributor: Caller is not Council Member");
        distributor.proposeTransaction(100, dests, amts);
    }

    // ------------------
    // proposeTransaction
    // ------------------

    function test_proposeTransaction_happyPath() public {
        address[] memory dests = new address[](2);
        dests[0] = recipient1;
        dests[1] = recipient2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 500;
        amts[1] = 500;

        vm.prank(councilMember);
        vm.expectEmit(true, false, false, true);
        emit TelcoinDistributor.TransactionProposed(0, councilMember);
        distributor.proposeTransaction(1000, dests, amts);

        // Verify stored data via the auto-generated getter.
        // Solidity skips dynamic-array members (destinations, amounts) in the public getter,
        // so we get: (totalWithdrawl, timestamp, challenged, executed).
        (
            uint256 totalWithdrawl,
            uint64 timestamp,
            bool challenged,
            bool executed
        ) = distributor.proposedTransactions(0);

        assertEq(totalWithdrawl, 1000);
        assertEq(timestamp, uint64(block.timestamp));
        assertFalse(challenged);
        assertFalse(executed);
    }

    function test_proposeTransaction_arrayLengthMismatch() public {
        address[] memory dests = new address[](2);
        dests[0] = recipient1;
        dests[1] = recipient2;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 500;

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: array lengths do not match");
        distributor.proposeTransaction(1000, dests, amts);
    }

    function test_proposeTransaction_emptyArrays() public {
        address[] memory dests = new address[](0);
        uint256[] memory amts = new uint256[](0);

        // Empty arrays have equal length -- should succeed
        vm.prank(councilMember);
        distributor.proposeTransaction(0, dests, amts);
    }

    function test_proposeTransaction_revertsWhenPaused() public {
        vm.prank(owner);
        distributor.pause();

        address[] memory dests = new address[](1);
        dests[0] = recipient1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        vm.prank(councilMember);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.proposeTransaction(100, dests, amts);
    }

    function test_proposeTransaction_multipleProposals() public {
        address[] memory dests = new address[](1);
        dests[0] = recipient1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;

        vm.startPrank(councilMember);
        distributor.proposeTransaction(100, dests, amts);
        distributor.proposeTransaction(200, dests, amts);
        distributor.proposeTransaction(300, dests, amts);
        vm.stopPrank();

        (uint256 tw0,,, ) = distributor.proposedTransactions(0);
        (uint256 tw1,,, ) = distributor.proposedTransactions(1);
        (uint256 tw2,,, ) = distributor.proposedTransactions(2);
        assertEq(tw0, 100);
        assertEq(tw1, 200);
        assertEq(tw2, 300);
    }

    // --------------------
    // challengeTransaction
    // --------------------

    function test_challengeTransaction_happyPath() public {
        _propose(1000, recipient1, 1000);

        vm.prank(councilMember);
        vm.expectEmit(true, false, false, true);
        emit TelcoinDistributor.TransactionChallenged(0, councilMember);
        distributor.challengeTransaction(0);

        (,, bool challenged,) = distributor.proposedTransactions(0);
        assertTrue(challenged);
    }

    function test_challengeTransaction_revertsNonMember() public {
        _propose(1000, recipient1, 1000);

        vm.prank(nonMember);
        vm.expectRevert("TelcoinDistributor: Caller is not Council Member");
        distributor.challengeTransaction(0);
    }

    function test_challengeTransaction_revertsInvalidIndex() public {
        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Invalid index");
        distributor.challengeTransaction(0);
    }

    function test_challengeTransaction_revertsAfterChallengePeriod() public {
        _propose(1000, recipient1, 1000);

        // Warp past the challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Challenge period has ended");
        distributor.challengeTransaction(0);
    }

    function test_challengeTransaction_canChallengeAtExactDeadline() public {
        _propose(1000, recipient1, 1000);

        // Warp to exactly the challenge deadline (should still work -- <= check)
        vm.warp(block.timestamp + CHALLENGE_PERIOD);

        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        (,, bool challenged,) = distributor.proposedTransactions(0);
        assertTrue(challenged);
    }

    function test_challengeTransaction_alreadyChallenged() public {
        _propose(1000, recipient1, 1000);

        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        // Challenge again -- contract does NOT revert on double-challenge, it just sets true again
        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        (,, bool challenged,) = distributor.proposedTransactions(0);
        assertTrue(challenged);
    }

    // ------------------
    // executeTransaction
    // ------------------

    function test_executeTransaction_happyPath() public {
        uint256 amount = 5000;
        _propose(amount, recipient1, amount);

        // Warp past challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        uint256 balBefore = TELCOIN.balanceOf(recipient1);

        vm.prank(councilMember);
        distributor.executeTransaction(0);

        assertEq(TELCOIN.balanceOf(recipient1) - balBefore, amount);

        (,,, bool executed) = distributor.proposedTransactions(0);
        assertTrue(executed);
    }

    function test_executeTransaction_multipleDestinations() public {
        address[] memory dests = new address[](3);
        dests[0] = recipient1;
        dests[1] = recipient2;
        dests[2] = recipient3;
        uint256[] memory amts = new uint256[](3);
        amts[0] = 1000;
        amts[1] = 2000;
        amts[2] = 3000;
        uint256 total = 6000;

        vm.prank(councilMember);
        distributor.proposeTransaction(total, dests, amts);

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        distributor.executeTransaction(0);

        assertEq(TELCOIN.balanceOf(recipient1), 1000);
        assertEq(TELCOIN.balanceOf(recipient2), 2000);
        assertEq(TELCOIN.balanceOf(recipient3), 3000);
    }

    function test_executeTransaction_revertsBeforeChallengePeriod() public {
        _propose(1000, recipient1, 1000);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Challenge period has not ended");
        distributor.executeTransaction(0);
    }

    function test_executeTransaction_revertsAtExactDeadline() public {
        _propose(1000, recipient1, 1000);

        // Warp to exactly the deadline -- must be strictly > so this should revert
        vm.warp(block.timestamp + CHALLENGE_PERIOD);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Challenge period has not ended");
        distributor.executeTransaction(0);
    }

    function test_executeTransaction_revertsChallenged() public {
        _propose(1000, recipient1, 1000);

        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: transaction has been challenged");
        distributor.executeTransaction(0);
    }

    function test_executeTransaction_revertsAlreadyExecuted() public {
        _propose(1000, recipient1, 1000);

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        distributor.executeTransaction(0);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: transaction has been previously executed");
        distributor.executeTransaction(0);
    }

    function test_executeTransaction_revertsInvalidIndex() public {
        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Invalid index");
        distributor.executeTransaction(99);
    }

    function test_executeTransaction_revertsNonMember() public {
        _propose(1000, recipient1, 1000);
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(nonMember);
        vm.expectRevert("TelcoinDistributor: Caller is not Council Member");
        distributor.executeTransaction(0);
    }

    function test_executeTransaction_revertsWhenPaused() public {
        _propose(1000, recipient1, 1000);
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(owner);
        distributor.pause();

        vm.prank(councilMember);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.executeTransaction(0);
    }

    // -----------------------------------------
    // batchTelcoin invariant: balance unchanged
    // -----------------------------------------

    function test_batchTelcoin_balanceInvariant() public {
        // Seed the distributor itself with some "stray" TEL
        deal(address(TELCOIN), address(distributor), 999);
        uint256 distributorBalBefore = TELCOIN.balanceOf(address(distributor));

        uint256 amount = 5000;
        _propose(amount, recipient1, amount);
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        distributor.executeTransaction(0);

        // The distributor balance must be unchanged (the invariant in batchTelcoin)
        assertEq(TELCOIN.balanceOf(address(distributor)), distributorBalBefore);
    }

    function test_batchTelcoin_revertsOnLeftovers() public {
        // totalWithdrawl > sum(amounts) means leftover TEL in the contract
        address[] memory dests = new address[](1);
        dests[0] = recipient1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 500;

        vm.prank(councilMember);
        distributor.proposeTransaction(1000, dests, amts); // total 1000, send only 500 => leftover 500

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: must not have leftovers");
        distributor.executeTransaction(0);
    }

    function test_batchTelcoin_revertsOnUnderfunded() public {
        // totalWithdrawl < sum(amounts) -- transfer will revert because the contract
        // doesn't have enough TEL after the transferFrom
        address[] memory dests = new address[](1);
        dests[0] = recipient1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 2000;

        vm.prank(councilMember);
        distributor.proposeTransaction(1000, dests, amts); // total 1000, send 2000

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.prank(councilMember);
        vm.expectRevert(); // ERC20 insufficient balance
        distributor.executeTransaction(0);
    }

    // ------------------
    // setChallengePeriod
    // ------------------

    function test_setChallengePeriod_ownerOnly() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit TelcoinDistributor.ChallengePeriodUpdated(2 days);
        distributor.setChallengePeriod(2 days);

        assertEq(distributor.challengePeriod(), 2 days);
    }

    function test_setChallengePeriod_revertsNonOwner() public {
        vm.prank(councilMember);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, councilMember));
        distributor.setChallengePeriod(2 days);
    }

    function test_setChallengePeriod_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("TelcoinDistributor: period cannot be zero");
        distributor.setChallengePeriod(0);
    }

    function test_setChallengePeriod_retroactiveEffect() public {
        // Propose with current 1-day challenge period
        _propose(1000, recipient1, 1000);

        // Advance half the challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD / 2);

        // Owner extends to 3 days -- the in-flight proposal now has a longer window
        vm.prank(owner);
        distributor.setChallengePeriod(3 days);

        // We're only 12 hours in with a 3-day period. Should still be challengeable.
        vm.prank(councilMember);
        distributor.challengeTransaction(0);
        (,, bool challenged,) = distributor.proposedTransactions(0);
        assertTrue(challenged);
    }

    function test_setChallengePeriod_retroactiveEffect_makesExecutableImmediately() public {
        // Propose with 1-day challenge period
        _propose(1000, recipient1, 1000);
        uint256 proposeTime = block.timestamp;

        // Advance 2 hours
        vm.warp(proposeTime + 2 hours);

        // Owner shrinks to 1 hour -- the proposal is now past its challenge period
        vm.prank(owner);
        distributor.setChallengePeriod(1 hours);

        // Execute should now work because timestamp + 1 hour < block.timestamp
        vm.prank(councilMember);
        distributor.executeTransaction(0);

        (,,, bool executed) = distributor.proposedTransactions(0);
        assertTrue(executed);
    }

    // ------------
    // recoverERC20
    // ------------

    function test_recoverERC20_happyPath() public {
        // Send some TEL to the distributor "by accident"
        deal(address(TELCOIN), address(distributor), 5000);

        vm.prank(owner);
        distributor.recoverERC20(TELCOIN, 5000, recipient1);

        assertEq(TELCOIN.balanceOf(recipient1), 5000);
        assertEq(TELCOIN.balanceOf(address(distributor)), 0);
    }

    function test_recoverERC20_revertsNonOwner() public {
        deal(address(TELCOIN), address(distributor), 5000);

        vm.prank(councilMember);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, councilMember));
        distributor.recoverERC20(TELCOIN, 5000, recipient1);
    }

    // ---------------
    // pause / unpause
    // ---------------

    function test_pause_ownerOnly() public {
        vm.prank(owner);
        distributor.pause();
        assertTrue(distributor.paused());
    }

    function test_pause_revertsNonOwner() public {
        vm.prank(councilMember);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, councilMember));
        distributor.pause();
    }

    function test_unpause_ownerOnly() public {
        vm.prank(owner);
        distributor.pause();

        vm.prank(owner);
        distributor.unpause();
        assertFalse(distributor.paused());
    }

    function test_unpause_revertsNonOwner() public {
        vm.prank(owner);
        distributor.pause();

        vm.prank(councilMember);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, councilMember));
        distributor.unpause();
    }

    function test_pause_blocksChallengeToo_NOT() public {
        // challengeTransaction is NOT guarded by whenNotPaused, only by onlyCouncilMember.
        // Verify that pausing does NOT block challenges.
        _propose(1000, recipient1, 1000);

        vm.prank(owner);
        distributor.pause();

        // Challenge should still work (no whenNotPaused modifier)
        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        (,, bool challenged,) = distributor.proposedTransactions(0);
        assertTrue(challenged);
    }

    // ---------------------------------
    // Ownership transfer (Ownable2Step)
    // ---------------------------------

    function test_ownershipTransfer_twoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        distributor.transferOwnership(newOwner);

        // Not yet the owner
        assertEq(distributor.owner(), owner);

        // Accept
        vm.prank(newOwner);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), newOwner);
    }

    /* ================================================================
     *        Full lifecycle: propose -> wait -> execute
     * ================================================================ */

    function test_lifecycle_proposeWaitExecute() public {
        uint256 amount = 10_000;
        address[] memory dests = new address[](2);
        dests[0] = recipient1;
        dests[1] = recipient2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 4000;
        amts[1] = 6000;

        // Step 1: Propose
        vm.prank(councilMember);
        distributor.proposeTransaction(amount, dests, amts);

        // Step 2: Verify cannot execute early
        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: Challenge period has not ended");
        distributor.executeTransaction(0);

        // Step 3: Wait
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        // Step 4: Execute
        vm.prank(councilMember);
        distributor.executeTransaction(0);

        assertEq(TELCOIN.balanceOf(recipient1), 4000);
        assertEq(TELCOIN.balanceOf(recipient2), 6000);
    }

    /* ================================================================
     *       Full lifecycle: propose -> challenge -> blocked
     * ================================================================ */

    function test_lifecycle_proposeChallengeBlocked() public {
        uint256 amount = 10_000;
        _propose(amount, recipient1, amount);

        // Challenge during the window
        vm.prank(councilMember);
        distributor.challengeTransaction(0);

        // Wait past challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        // Attempt to execute -- should be blocked
        vm.prank(councilMember);
        vm.expectRevert("TelcoinDistributor: transaction has been challenged");
        distributor.executeTransaction(0);

        // Recipient received nothing
        assertEq(TELCOIN.balanceOf(recipient1), 0);
    }

    // -------
    // HELPERS
    // -------

    /// @dev Helper: propose a single-destination transaction
    function _propose(uint256 total, address dest, uint256 amount) internal {
        address[] memory dests = new address[](1);
        dests[0] = dest;
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;

        vm.prank(councilMember);
        distributor.proposeTransaction(total, dests, amts);
    }
}

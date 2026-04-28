// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITokenReceiver} from "./interfaces/ITokenReceiver.sol";
import {CallbackERC20} from "./mocks/CallbackERC20.sol";
import {AlwaysAvailableLockup} from "./mocks/AlwaysAvailableLockup.sol";
import {BurnReentrancyAttacker} from "./mocks/BurnReentrancyAttacker.sol";
import {TransferFromReentrancyAttacker} from "./mocks/TransferFromReentrancyAttacker.sol";

// -------------
// TEST CONTRACT
// -------------
// All three tests assert the EXPECTED safe behaviour.
// They FAIL against the current CouncilMember, proving the
// reentrancy vulnerability exists.
contract CouncilMemberReentrancyTest is Test {
    CouncilMember public council;
    CallbackERC20 public token;
    AlwaysAvailableLockup public lockup;

    address public admin = address(0xA);
    address public member1 = address(0xB);
    address public member3 = address(0xC);

    bytes32 public constant GOV_ROLE = keccak256("GOVERNANCE_COUNCIL_ROLE");

    function setUp() public {
        token = new CallbackERC20();
        lockup = new AlwaysAvailableLockup(IERC20(address(token)));
        token.mint(address(lockup), 1_000_000);

        vm.startPrank(admin);
        CouncilMember impl = new CouncilMember();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                CouncilMember.initialize,
                (
                    IERC20(address(token)),
                    "Test",
                    "T",
                    ISablierV2Lockup(address(lockup)),
                    0
                )
            )
        );
        council = CouncilMember(address(proxy));
        council.grantRole(GOV_ROLE, admin);
        vm.stopPrank();
    }

    /* ─────────────────────────────────────────────────────────
       burn() reentrancy #1: reentrant claim() should revert
       ───────────────────────────────────────────────────────── */
    /// @notice A secure contract would have a reentrancy guard that
    ///         prevents claim() from being called during burn().
    ///         This test FAILS because no such guard exists.
    function test_burn_reentrant_claim_should_revert() public {
        BurnReentrancyAttacker attacker = new BurnReentrancyAttacker(
            council,
            1
        );

        vm.startPrank(admin);
        council.mint(member1); // token 0
        council.mint(address(attacker)); // token 1 (attacker keeps this)
        council.mint(member3); // token 2 (will be burned)
        vm.stopPrank();

        token.enableHook(address(attacker));

        vm.prank(admin);
        council.burn(2, address(attacker));

        // Sanity: the callback must have fired for this test to be meaningful
        assertTrue(attacker.callbackFired(), "Sanity: callback must fire");

        // EXPECTED: a reentrancy guard blocks the reentrant claim()
        assertFalse(
            attacker.reentrantClaimSucceeded(),
            "VULNERABILITY: reentrant claim() succeeded during burn() - no reentrancy guard"
        );
    }

    /* ─────────────────────────────────────────────────────────
       burn() reentrancy #2: burned slot should be cleaned up
       before any external call (CEI)
       ───────────────────────────────────────────────────────── */
    /// @notice After _burn() the balances array cleanup (pop) should
    ///         happen BEFORE TELCOIN.safeTransfer so that no external
    ///         call can observe stale array entries.
    ///         This test FAILS because cleanup happens AFTER the transfer.
    function test_burn_cleanup_before_external_call() public {
        BurnReentrancyAttacker attacker = new BurnReentrancyAttacker(
            council,
            1
        );

        vm.startPrank(admin);
        council.mint(member1); // token 0
        council.mint(address(attacker)); // token 1
        council.mint(member3); // token 2
        vm.stopPrank();

        token.enableHook(address(attacker));

        vm.prank(admin);
        council.burn(2, address(attacker));

        assertTrue(attacker.callbackFired(), "Sanity: callback must fire");

        // EXPECTED: balances[2] is already popped / inaccessible during the callback
        assertFalse(
            attacker.burnedSlotAccessible(),
            "VULNERABILITY: burned balance slot still in array during external call - CEI violation in burn()"
        );
    }

    /* ─────────────────────────────────────────────────────────
       transferFrom() reentrancy: balance should be zeroed
       before TELCOIN.safeTransfer (CEI)
       ───────────────────────────────────────────────────────── */
    /// @notice transferFrom() should zero balances[balanceIndex] BEFORE
    ///         calling TELCOIN.safeTransfer. This test FAILS because
    ///         the zeroing happens AFTER the transfer.
    function test_transferFrom_zeroes_balance_before_transfer() public {
        TransferFromReentrancyAttacker attacker = new TransferFromReentrancyAttacker(
                council,
                0
            );

        vm.startPrank(admin);
        council.mint(address(attacker)); // token 0 -> attacker
        council.mint(member1); // token 1
        vm.stopPrank();

        // Let attacker accumulate a non-zero balance
        vm.prank(admin);
        council.retrieve();
        uint256 balIdx = council.tokenIdToBalanceIndex(0);
        uint256 accruedBalance = council.balances(balIdx);
        assertGt(
            accruedBalance,
            0,
            "Sanity: attacker must have accrued balance"
        );

        token.enableHook(address(attacker));

        vm.prank(admin);
        council.transferFrom(address(attacker), member3, 0);

        assertTrue(attacker.callbackFired(), "Sanity: callback must fire");

        // Debug: log what the attacker saw during the callback
        console.log("Amount received in callback:", attacker.amountReceived());
        console.log("Balance index read:", attacker.balanceIndexRead());
        console.log(
            "Stale balance during callback:",
            attacker.staleBalanceDuringCallback()
        );
        console.log(
            "Balance after transferFrom:",
            council.balances(council.tokenIdToBalanceIndex(0))
        );

        // EXPECTED: balance is zero during the callback (effects before interactions)
        assertEq(
            attacker.staleBalanceDuringCallback(),
            0,
            "VULNERABILITY: balance was non-zero during TELCOIN transfer callback - CEI violation in transferFrom()"
        );
    }
}

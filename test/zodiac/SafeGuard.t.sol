// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeGuard} from "contracts/zodiac/core/SafeGuard.sol";
import {Enum} from "contracts/zodiac/enums/Operation.sol";
import {IReality} from "contracts/zodiac/interfaces/IReality.sol";
import {IGuard} from "contracts/zodiac/interfaces/IGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MockReality} from "./mocks/MockReality.sol";

contract SafeGuardTest is Test {
    // ---------------------------------------------------------------
    // Pin to a recent Polygon block
    // ---------------------------------------------------------------
    uint256 constant FORK_BLOCK = 68_000_000;

    SafeGuard guard;
    MockReality reality;
    address owner;
    address nonOwner;

    // Deterministic addresses for tx parameters
    address constant TO = address(0xBEEF);
    uint256 constant VALUE = 1 ether;
    bytes constant DATA = hex"deadbeef";
    Enum.Operation constant OP = Enum.Operation.Call;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        owner = address(this);
        nonOwner = makeAddr("nonOwner");

        // Deploy fresh SafeGuard; deployer (this) becomes owner
        guard = new SafeGuard();

        // Deploy a MockReality so we can call checkTransaction from it
        reality = new MockReality();
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Builds the same hash that SafeGuard + MockReality produce
    function _txHash(uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(TO, VALUE, DATA, OP, nonce));
    }

    /// @dev Calls checkTransaction on the guard from the reality address,
    ///      which is what a Safe / module does in practice.
    function _callCheckTransaction() internal {
        vm.prank(address(reality));
        guard.checkTransaction(
            TO,
            VALUE,
            DATA,
            OP,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            "", // signatures
            address(0) // msgSender
        );
    }

    // ---------------------------------------------------------------
    // vetoTransaction
    // ---------------------------------------------------------------

    function test_vetoTransaction_happyPath() public {
        bytes32 txHash = _txHash(42);

        assertFalse(guard.transactionHashes(txHash));

        guard.vetoTransaction(txHash, 42);

        assertTrue(guard.transactionHashes(txHash));
        assertEq(guard.nonces(0), 42);
    }

    function test_vetoTransaction_duplicateVeto() public {
        bytes32 txHash = _txHash(1);

        guard.vetoTransaction(txHash, 1);
        assertTrue(guard.transactionHashes(txHash));

        // Vetoing again should NOT revert; it is idempotent
        guard.vetoTransaction(txHash, 1);
        assertTrue(guard.transactionHashes(txHash));

        // nonces array grows each call
        assertEq(guard.nonces(0), 1);
        assertEq(guard.nonces(1), 1);
    }

    function test_vetoTransaction_zeroHash() public {
        bytes32 zeroHash = bytes32(0);

        guard.vetoTransaction(zeroHash, 0);

        assertTrue(guard.transactionHashes(zeroHash));
        assertEq(guard.nonces(0), 0);
    }

    function test_vetoTransaction_revertsForNonOwner() public {
        bytes32 txHash = _txHash(1);

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
        guard.vetoTransaction(txHash, 1);
    }

    // ---------------------------------------------------------------
    // checkTransaction
    // ---------------------------------------------------------------

    function test_checkTransaction_nonVetoedPasses() public {
        // No vetoes registered; call should not revert
        _callCheckTransaction();
    }

    function test_checkTransaction_vetoedTxBlocked() public {
        uint256 nonce = 7;
        bytes32 txHash = _txHash(nonce);

        guard.vetoTransaction(txHash, nonce);

        vm.prank(address(reality));
        vm.expectRevert("SafeGuard: transaction has been vetoed");
        guard.checkTransaction(
            TO,
            VALUE,
            DATA,
            OP,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            address(0)
        );
    }

    function test_checkTransaction_noncesArrayIteration() public {
        // Veto several nonces but none matching a particular (to, value, data, op)
        // Then add the matching one and confirm it reverts.
        uint256 nonceA = 10;
        uint256 nonceB = 20;
        uint256 nonceC = 30;

        // These hashes don't match (TO, VALUE, DATA, OP) for the nonces stored
        // because we veto a hash built with different params
        bytes32 hashA = keccak256(abi.encodePacked(address(0x1), uint256(0), bytes(""), OP, nonceA));
        bytes32 hashB = keccak256(abi.encodePacked(address(0x2), uint256(0), bytes(""), OP, nonceB));

        guard.vetoTransaction(hashA, nonceA);
        guard.vetoTransaction(hashB, nonceB);

        // checkTransaction still passes because _txHash(10) != hashA, _txHash(20) != hashB
        _callCheckTransaction();

        // Now veto the real hash for nonceC
        bytes32 realHash = _txHash(nonceC);
        guard.vetoTransaction(realHash, nonceC);

        // Now it should revert because the loop hits nonce 30 and the hash matches
        vm.prank(address(reality));
        vm.expectRevert("SafeGuard: transaction has been vetoed");
        guard.checkTransaction(
            TO,
            VALUE,
            DATA,
            OP,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            address(0)
        );
    }

    function test_checkTransaction_differentOpPassesEvenIfCallVetoed() public {
        // Veto a Call tx, then check a DelegateCall tx with same params => should pass
        uint256 nonce = 5;
        bytes32 callHash = _txHash(nonce);
        guard.vetoTransaction(callHash, nonce);

        // checkTransaction with DelegateCall should still pass
        vm.prank(address(reality));
        guard.checkTransaction(
            TO,
            VALUE,
            DATA,
            Enum.Operation.DelegateCall,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            address(0)
        );
    }

    // ---------------------------------------------------------------
    // checkAfterExecution
    // ---------------------------------------------------------------

    function test_checkAfterExecution_noOp() public view {
        // Must not revert. It is a no-op.
        guard.checkAfterExecution(bytes32(0), true);
        guard.checkAfterExecution(keccak256("anything"), false);
    }

    // ---------------------------------------------------------------
    // supportsInterface
    // ---------------------------------------------------------------

    function test_supportsInterface_IGuard() public view {
        assertTrue(guard.supportsInterface(type(IGuard).interfaceId));
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(guard.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_random_returnsFalse() public view {
        assertFalse(guard.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ---------------------------------------------------------------
    // Fallback
    // ---------------------------------------------------------------

    function test_fallback_doesNotRevert() public {
        // Sending arbitrary calldata to the guard should hit the fallback
        (bool success,) = address(guard).call(hex"12345678");
        assertTrue(success);
    }

    function test_fallback_emptyCalldata() public {
        // Empty calldata (no receive, hits fallback)
        (bool success,) = address(guard).call("");
        assertTrue(success);
    }

    // ---------------------------------------------------------------
    // Edge case: many vetoes causing gas growth
    // ---------------------------------------------------------------

    function test_manyVetoes_gasGrowth() public {
        uint256 numVetoes = 100;

        // Register many vetoes with unique hashes that do NOT match our test tx
        for (uint256 i = 0; i < numVetoes; i++) {
            bytes32 fakeHash = keccak256(abi.encodePacked("fake", i));
            guard.vetoTransaction(fakeHash, i);
        }

        // checkTransaction must iterate all 100 nonces and pass
        uint256 gasBefore = gasleft();
        _callCheckTransaction();
        uint256 gasUsed = gasBefore - gasleft();

        // Sanity: gas should scale with the nonces array length.
        // With 100 entries we expect measurable gas; confirm it's > 20k.
        assertGt(gasUsed, 20_000, "Gas should scale with nonces array size");

        // Now add 100 more and re-measure
        for (uint256 i = numVetoes; i < numVetoes * 2; i++) {
            bytes32 fakeHash = keccak256(abi.encodePacked("fake", i));
            guard.vetoTransaction(fakeHash, i);
        }

        uint256 gasBefore2 = gasleft();
        _callCheckTransaction();
        uint256 gasUsed2 = gasBefore2 - gasleft();

        // Gas for 200 nonces should be roughly double the gas for 100
        assertGt(gasUsed2, gasUsed, "Gas should increase with more vetoes");
    }

    // ---------------------------------------------------------------
    // Ownership
    // ---------------------------------------------------------------

    function test_owner_isDeployer() public view {
        assertEq(guard.owner(), owner);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        guard.transferOwnership(newOwner);
        assertEq(guard.owner(), newOwner);
    }

    function test_onlyOwner_vetoTransaction_afterTransfer() public {
        address newOwner = makeAddr("newOwner");
        guard.transferOwnership(newOwner);

        // Old owner can no longer veto
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                owner
            )
        );
        guard.vetoTransaction(bytes32(0), 0);

        // New owner can
        vm.prank(newOwner);
        guard.vetoTransaction(bytes32(0), 0);
        assertTrue(guard.transactionHashes(bytes32(0)));
    }
}

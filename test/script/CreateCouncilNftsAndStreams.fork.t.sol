// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreateCouncilNftsAndStreams} from "../../script/sablier/CreateCouncilNftsAndStreams.s.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestConstants} from "../util/TestConstants.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @notice Polygon-fork test of CreateCouncilNftsAndStreams.
/// @dev    The script reads hard-coded Polygon addresses for TEL and the
///         Sablier V2 Lockup, so a Polygon fork + a signer funded with
///         enough TEL to cover every council's stream deposit is sufficient.
///         We use `deal` to front-load TEL on the signer, mirroring how the
///         MEXC fallback address ships with balance on-chain.
contract CreateCouncilNftsAndStreamsForkTest is Test {
    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address internal constant TEL_TOKEN = PolygonConstants.TEL;
    address internal constant SABLIER_LOCKUP = PolygonConstants.SABLIER_LOCKUP;

    CreateCouncilNftsAndStreams internal script;
    address internal sablierSender;
    /// @dev Sum of every council's deposit. Computed at setUp time from the
    ///      script's own `getCouncilsInfo()` so it tracks automatically if
    ///      deposits are ever adjusted — no manual sync required.
    uint256 internal totalTelRequired;

    function setUp() public {
        uint256 forkBlock =
            vm.envOr("FORK_BLOCK_NUMBER", TestConstants.DEFAULT_POLYGON_FORK_BLOCK);
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), forkBlock);

        script = new CreateCouncilNftsAndStreams();
        totalTelRequired = _sumCouncilDeposits(script);

        sablierSender = makeAddr("sablierSender");
        // Fund the signer with enough TEL to cover every stream deposit.
        deal(TEL_TOKEN, sablierSender, totalTelRequired);
    }

    /// @dev Reads the script's council table and sums every deposit. Keeps
    ///      the test aligned with the deploy logic even if deposits change.
    function _sumCouncilDeposits(CreateCouncilNftsAndStreams s)
        internal
        pure
        returns (uint256 total)
    {
        CreateCouncilNftsAndStreams.CouncilConfig[] memory cfgs = s.getCouncilsInfo();
        for (uint256 i = 0; i < cfgs.length; i++) {
            total += cfgs[i].deposit;
        }
    }

    /// @notice End-to-end: deploys the implementation, six proxies, six
    ///         Sablier streams, mints NFTs, rotates roles, and passes every
    ///         sanity check the script asserts in its own tail.
    function test_runWithSigner_bootstrapsAllSixCouncils() public {
        uint256 telBefore = IERC20(TEL_TOKEN).balanceOf(sablierSender);
        assertEq(telBefore, totalTelRequired, "signer pre-funded");

        script.runWithSigner(sablierSender);

        // Every deposit was pulled from the signer into Sablier.
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(sablierSender),
            0,
            "signer TEL fully deposited into streams"
        );
    }

    /// @notice Exercises all three env-resolution branches in `run()`:
    ///         ETH_FROM → direct use, PRIVATE_KEY fallback, MEXC fallback.
    ///         vm.envOr caches within a single forge invocation, so we run
    ///         each path with a fresh script instance + pre-funded signer.
    ///         Bundled into one test because the env cache makes split-test
    ///         env flips unreliable.
    function test_run_resolveSigner_allPaths() public {
        // --- Path 1: ETH_FROM set -> used directly ---
        CreateCouncilNftsAndStreams scriptA = new CreateCouncilNftsAndStreams();
        deal(TEL_TOKEN, sablierSender, totalTelRequired);
        vm.setEnv("ETH_FROM", vm.toString(sablierSender));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0)));
        scriptA.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(sablierSender),
            0,
            "path 1: ETH_FROM signer deposited all TEL"
        );

        // --- Path 2: ETH_FROM cleared + PRIVATE_KEY set -> signer = vm.addr(pk) ---
        uint256 testPk = 0xC0DE;
        address pkSigner = vm.addr(testPk);
        CreateCouncilNftsAndStreams scriptB = new CreateCouncilNftsAndStreams();
        deal(TEL_TOKEN, pkSigner, totalTelRequired);
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(testPk));
        scriptB.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(pkSigner),
            0,
            "path 2: PK-derived signer deposited all TEL"
        );

        // --- Path 3: both cleared -> MEXC fallback address ---
        // The script falls back to a hardcoded MEXC address when no env var
        // is set. We use `deal` to set MEXC's TEL balance to exactly the
        // required amount; this isolates the test from whatever balance MEXC
        // actually holds at the pinned fork block.
        address MEXC = 0x576b81F0c21EDBc920ad63FeEEB2b0736b018A58;
        CreateCouncilNftsAndStreams scriptC = new CreateCouncilNftsAndStreams();
        deal(TEL_TOKEN, MEXC, totalTelRequired);
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0)));
        scriptC.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(MEXC),
            0,
            "path 3: MEXC fallback deposited all TEL into streams"
        );
    }
}

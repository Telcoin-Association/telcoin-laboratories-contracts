// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreateCouncilNftsAndStreams} from "../../script/sablier/CreateCouncilNftsAndStreams.s.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {TestConstants} from "../util/TestConstants.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";
import {ForkOrSkip} from "../util/ForkOrSkip.sol";

/// @notice Polygon-fork test of CreateCouncilNftsAndStreams.
/// @dev    The script reads hard-coded Polygon addresses for TEL and the
///         Sablier V2 Lockup, so a Polygon fork + a signer funded with
///         enough TEL to cover every council's stream deposit is sufficient.
///         We use `deal` to front-load TEL on test signers. The fallback
///         simulation sender is the exception: it runs on its real on-chain
///         TEL v3 balance, proving a dry run without a signer still works.
///
///         Council streams are denominated in TEL v3 (18 decimals) from year 3
///         onwards. Every stream the script creates, and every council NFT
///         contract it deploys, must use TEL v3. The fork is pinned to a block
///         where TEL v3 exists on Polygon.
contract CreateCouncilNftsAndStreamsForkTest is Test {
    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address internal constant TEL_TOKEN = PolygonConstants.TEL_V3;
    address internal constant LEGACY_TEL_TOKEN = PolygonConstants.TEL_V2;
    address internal constant SABLIER_LOCKUP = PolygonConstants.SABLIER_LOCKUP;

    uint256 internal constant COUNCIL_COUNT = 6;
    /// @dev The year-2 council streams, in `getCouncilsInfo()` order.
    uint256 internal constant FIRST_YEAR2_STREAM_ID = 666;
    /// @dev Year-3 streams run for 52 weeks, matching year 2.
    uint40 internal constant STREAM_DURATION = 52 weeks;

    CreateCouncilNftsAndStreams internal script;
    ISablierV2LockupLinear internal lockup;
    address internal sablierSender;
    /// @dev Sum of every council's deposit. Computed at setUp time from the
    ///      script's own `getCouncilsInfo()` so it tracks automatically if
    ///      deposits are ever adjusted - no manual sync required.
    uint256 internal totalTelRequired;

    function setUp() public {
        uint256 forkBlock =
            vm.envOr("FORK_BLOCK_NUMBER", TestConstants.TEL_V3_POLYGON_FORK_BLOCK);
        ForkOrSkip.select("POLYGON_RPC_URL", forkBlock);

        script = new CreateCouncilNftsAndStreams();
        lockup = ISablierV2LockupLinear(SABLIER_LOCKUP);
        totalTelRequired = _sumCouncilDeposits(script);

        sablierSender = makeAddr("sablierSender");
        // Fund the signer with enough TEL v3 to cover every stream deposit.
        deal(TEL_TOKEN, sablierSender, totalTelRequired);
    }

    // -------
    // HELPERS
    // -------

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

    /// @dev Year-3 deposits in TEL v3 base units (18 decimals), in
    ///      `getCouncilsInfo()` order. Same TEL amounts as the year-2 streams
    ///      (IDs 666-671), rescaled from TEL v2's 2 decimals. Kept independent
    ///      of the script so a decimals mistake in the script fails here.
    function _expectedDeposits() internal pure returns (uint128[COUNCIL_COUNT] memory d) {
        d[0] = 4_545_454.5 ether; // TAO
        d[1] = 7_272_727.2 ether; // Platform Council
        d[2] = 3_636_363.6 ether; // Treasury Council
        d[3] = 3_636_363.6 ether; // Compliance Council
        d[4] = 5_454_545.4 ether; // TAN Council
        d[5] = 5_454_545.4 ether; // TELx Council
    }

    /// @dev When the year-3 streams must start: the moment the last year-2
    ///      stream ends, read from the live year-2 streams. The six year-2
    ///      streams were created in separate blocks and end up to 78 seconds
    ///      apart, so starting at the latest end means no year-3 stream overlaps
    ///      any year-2 stream. Kept independent of the script.
    function _expectedStartTime() internal view returns (uint40 start) {
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            uint40 end = lockup.getEndTime(FIRST_YEAR2_STREAM_ID + i);
            if (end > start) start = end;
        }
    }

    /// @dev Checks the six streams created from `firstStreamId` onwards: each
    ///      one is funded in TEL v3 with the expected deposit, starts when the
    ///      year-2 streams end, runs for 52 weeks with no cliff, and streams to
    ///      a council NFT contract that pays out in TEL v3.
    function _assertYear3Streams(uint256 firstStreamId) internal view {
        uint40 expectedStart = _expectedStartTime();

        assertEq(
            lockup.nextStreamId(),
            firstStreamId + COUNCIL_COUNT,
            "script did not create exactly one stream per council"
        );

        uint128[COUNCIL_COUNT] memory expected = _expectedDeposits();
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            uint256 streamId = firstStreamId + i;
            string memory idx = vm.toString(i);

            assertEq(
                address(lockup.getAsset(streamId)),
                TEL_TOKEN,
                string.concat("stream asset is not TEL v3 at council ", idx)
            );
            assertEq(
                lockup.getDepositedAmount(streamId),
                expected[i],
                string.concat("stream deposit mismatch at council ", idx)
            );

            assertEq(
                lockup.getStartTime(streamId),
                expectedStart,
                string.concat("stream does not start when year 2 ends at council ", idx)
            );
            assertGe(
                lockup.getStartTime(streamId),
                lockup.getEndTime(FIRST_YEAR2_STREAM_ID + i),
                string.concat("stream overlaps its year-2 stream at council ", idx)
            );
            assertEq(
                lockup.getEndTime(streamId),
                expectedStart + STREAM_DURATION,
                string.concat("stream does not run for 52 weeks at council ", idx)
            );
            assertEq(
                lockup.getCliffTime(streamId),
                0,
                string.concat("stream has a cliff at council ", idx)
            );

            CouncilMember council = CouncilMember(lockup.getRecipient(streamId));
            assertEq(
                address(council.TELCOIN()),
                TEL_TOKEN,
                string.concat("council NFT does not pay out TEL v3 at council ", idx)
            );
            assertEq(
                council._id(),
                streamId,
                string.concat("council NFT not wired to its stream at council ", idx)
            );
        }
    }

    // -----
    // TESTS
    // -----

    /// @notice The council table carries year-3 deposits in TEL v3 units.
    ///         A table still in TEL v2 units (2 decimals) would stream 1e16x
    ///         too little, so this pins every deposit exactly.
    function test_getCouncilsInfo_depositsAreTelV3Amounts() public view {
        CreateCouncilNftsAndStreams.CouncilConfig[] memory cfgs = script.getCouncilsInfo();
        assertEq(cfgs.length, COUNCIL_COUNT, "unexpected council count");

        uint128[COUNCIL_COUNT] memory expected = _expectedDeposits();
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            assertEq(
                cfgs[i].deposit,
                expected[i],
                string.concat("deposit mismatch at council ", vm.toString(i))
            );
        }
    }

    /// @notice Year-3 council NFTs go to whoever holds the year-2 seats, seat
    ///         for seat. Reads the live year-2 council contracts at the fork
    ///         block and requires the script's member lists to match their
    ///         holders in token-ID order, including addresses that hold more
    ///         than one seat (two on Platform, four on TAN).
    function test_getCouncilsInfo_membersMatchYear2OnChainHolders() public view {
        CreateCouncilNftsAndStreams.CouncilConfig[] memory cfgs = script.getCouncilsInfo();
        address[COUNCIL_COUNT] memory year2 = _year2CouncilNfts();

        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            CouncilMember old = CouncilMember(year2[i]);
            string memory idx = vm.toString(i);
            uint256 seats = old.totalSupply();

            assertEq(
                cfgs[i].members.length,
                seats,
                string.concat("member count mismatch at council ", idx)
            );
            for (uint256 j = 0; j < seats; j++) {
                uint256 tokenId = old.tokenByIndex(j);
                assertEq(
                    cfgs[i].members[j],
                    old.ownerOf(tokenId),
                    string.concat(
                        "member mismatch at council ",
                        idx,
                        ", token ",
                        vm.toString(tokenId)
                    )
                );
            }
        }
    }

    /// @dev The live year-2 council NFT contracts, in `getCouncilsInfo()`
    ///      order. Their streams (IDs 666-671, TEL v2) end 2026-11-25.
    function _year2CouncilNfts() internal pure returns (address[COUNCIL_COUNT] memory a) {
        a[0] = PolygonConstants.TAO_COUNCIL_NFT; // TAO
        a[1] = 0xE22E3C3CF718974767f99f8f1628651Bd69d5915; // Platform Council
        a[2] = 0xa37c7F986fd55e3e5B0542698e4Ba92a1bd61a26; // Treasury Council
        a[3] = 0x24A7F8E40d2ACB8599f0C7343A68FD32f261C9Cf; // Compliance Council
        a[4] = 0xdA7798516F42A5123Dc1E64974526Ad79db7D597; // TAN Council
        a[5] = 0x3393BB417c770CF91741B9E5d50628efEBB9Dc24; // TELx Council
    }

    /// @notice End-to-end: deploys the implementation, six proxies, six
    ///         Sablier streams, mints NFTs, rotates roles, and passes every
    ///         sanity check the script asserts in its own tail. Every stream
    ///         and every council NFT contract must use TEL v3.
    function test_runWithSigner_bootstrapsAllSixCouncils() public {
        uint256 telBefore = IERC20(TEL_TOKEN).balanceOf(sablierSender);
        assertEq(telBefore, totalTelRequired, "signer pre-funded");

        uint256 firstStreamId = lockup.nextStreamId();

        script.runWithSigner(sablierSender);

        // Every deposit was pulled from the signer into Sablier.
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(sablierSender),
            0,
            "signer TEL v3 fully deposited into streams"
        );
        _assertYear3Streams(firstStreamId);
    }

    /// @notice Deploying ahead of time pays nothing early: the new council NFT
    ///         contracts receive nothing until the year-2 streams end, then
    ///         vest linearly from that moment.
    function test_runWithSigner_streamsVestOnlyFromStartTime() public {
        uint40 start = _expectedStartTime();
        assertLt(block.timestamp, start, "fork block must predate the start time");

        uint256 firstStreamId = lockup.nextStreamId();
        script.runWithSigner(sablierSender);

        uint128[COUNCIL_COUNT] memory expected = _expectedDeposits();
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            assertEq(
                lockup.withdrawableAmountOf(firstStreamId + i),
                0,
                "stream vests before the start time"
            );
        }

        // One second before the start time: still nothing.
        vm.warp(start - 1);
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            assertEq(
                lockup.withdrawableAmountOf(firstStreamId + i),
                0,
                "stream vests before the start time"
            );
        }

        // Halfway through year 3: half of each deposit.
        vm.warp(start + STREAM_DURATION / 2);
        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            assertApproxEqAbs(
                lockup.withdrawableAmountOf(firstStreamId + i),
                expected[i] / 2,
                1,
                "stream not half vested halfway through year 3"
            );
        }
    }

    /// @notice The script refuses to run once the start time is less than an
    ///         hour away, or has passed. Minting NFTs after a stream has
    ///         started would credit everything vested so far to the first
    ///         member alone, because each mint after the first triggers
    ///         `_retrieve()` among the members minted so far.
    function test_runWithSigner_revertsWhenTooCloseToStartTime() public {
        uint40 start = _expectedStartTime();

        vm.warp(start - 1 hours + 1);
        vm.expectRevert(
            "Too close to STREAM_START_TIME: NFTs must be minted before the streams start vesting"
        );
        script.runWithSigner(sablierSender);

        vm.warp(start + 1 weeks);
        vm.expectRevert(
            "Too close to STREAM_START_TIME: NFTs must be minted before the streams start vesting"
        );
        script.runWithSigner(sablierSender);
    }

    /// @notice Exactly an hour before the start time is still early enough,
    ///         and nothing vests before the start time.
    function test_runWithSigner_succeedsAnHourBeforeStartTime() public {
        uint40 start = _expectedStartTime();
        vm.warp(start - 1 hours);

        uint256 firstStreamId = lockup.nextStreamId();
        script.runWithSigner(sablierSender);
        _assertYear3Streams(firstStreamId);

        for (uint256 i = 0; i < COUNCIL_COUNT; i++) {
            assertEq(
                lockup.withdrawableAmountOf(firstStreamId + i),
                0,
                "stream vests before the start time"
            );
        }
    }

    /// @notice A signer holding only legacy TEL v2 cannot fund the streams:
    ///         the script must never fall back to the old token.
    function test_runWithSigner_revertsWhenSignerHoldsOnlyTelV2() public {
        address legacyHolder = makeAddr("legacyHolder");
        deal(LEGACY_TEL_TOKEN, legacyHolder, type(uint128).max);

        vm.expectRevert();
        script.runWithSigner(legacyHolder);
    }

    /// @notice Exercises all three env-resolution branches in `run()`:
    ///         ETH_FROM → direct use, PRIVATE_KEY fallback, simulation-sender fallback.
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
        uint256 firstStreamId = lockup.nextStreamId();
        scriptA.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(sablierSender),
            0,
            "path 1: ETH_FROM signer deposited all TEL v3"
        );
        _assertYear3Streams(firstStreamId);

        // --- Path 2: ETH_FROM cleared + PRIVATE_KEY set -> signer = vm.addr(pk) ---
        uint256 testPk = 0xC0DE;
        address pkSigner = vm.addr(testPk);
        CreateCouncilNftsAndStreams scriptB = new CreateCouncilNftsAndStreams();
        deal(TEL_TOKEN, pkSigner, totalTelRequired);
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(testPk));
        firstStreamId = lockup.nextStreamId();
        scriptB.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(pkSigner),
            0,
            "path 2: PK-derived signer deposited all TEL v3"
        );
        _assertYear3Streams(firstStreamId);

        // --- Path 3: both cleared -> fallback simulation sender ---
        // With no signer configured, the script simulates as a hardcoded
        // address that holds TEL v3 on Polygon. No `deal` here: the run uses
        // the address's real balance at the pinned fork block, so this fails
        // if the fallback can no longer fund a dry run.
        address fallbackSender = 0x20dAAcb0864fF9a5e07d05Ea16Fa56cD00fdC16D;
        uint256 fallbackBalanceBefore = IERC20(TEL_TOKEN).balanceOf(fallbackSender);
        assertGe(
            fallbackBalanceBefore,
            totalTelRequired,
            "path 3: fallback sender cannot fund every stream on-chain"
        );
        CreateCouncilNftsAndStreams scriptC = new CreateCouncilNftsAndStreams();
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0)));
        firstStreamId = lockup.nextStreamId();
        scriptC.run();
        assertEq(
            IERC20(TEL_TOKEN).balanceOf(fallbackSender),
            fallbackBalanceBefore - totalTelRequired,
            "path 3: fallback sender did not fund the streams"
        );
        _assertYear3Streams(firstStreamId);
    }
}

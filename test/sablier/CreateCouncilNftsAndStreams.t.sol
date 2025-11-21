// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CreateCouncilNftsAndStreams} from "../../scripts/sablier/CreateCouncilNftsAndStreams.s.sol";

import {ISablierLockup} from "@sablier/lockup/src/interfaces/ISablierLockup.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreateCouncilHarness is CreateCouncilNftsAndStreams {}

contract CreateCouncilNftsAndStreamsTest is Test {
    // Real mainnet Polygon TEL & Sablier lockup addresses on your fork
    address telcoinToken = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;
    address sablierLockup = 0x1E901b0E05A78C011D6D4cfFdBdb28a42A1c32EF;

    CreateCouncilHarness harness;

    function setUp() public {
        harness = new CreateCouncilHarness();
    }

    function testFullDeployAgainstMainnetFork() public {
        address sablierSender = 0xd7e88D492Dc992127384215b8555C9305C218299;

        // 2. Fund sablierSender with TEL & ETH in the fork
        console2.log(
            "balance of sablier sender: ",
            IERC20(telcoinToken).balanceOf(sablierSender)
        );
        deal(telcoinToken, sablierSender, 1e10);

        console2.log(
            "balance of sablier sender: ",
            IERC20(telcoinToken).balanceOf(sablierSender)
        );
        deal(sablierSender, 10 ether);

        // 3. Build config arrays (local variables)
        uint256 length = 1;
        string[] memory names = new string[](length);
        string[] memory symbols = new string[](length);
        uint128[] memory deposits = new uint128[](length);
        address[] memory councilSafeAddresses = new address[](length);

        names[0] = "TESTNFT";
        symbols[0] = "TNFT";
        deposits[0] = 1e6;
        councilSafeAddresses[0] = 0x8Dcf8d134F22aC625A7aFb39514695801CD705b5;

        // 4. Call deploy as sablierSender
        vm.startPrank(sablierSender);

        (
            address implementation,
            address[] memory proxies,
            uint256[] memory streamIds
        ) = harness.deploy(
                sablierSender,
                IERC20(telcoinToken),
                ISablierLockup(sablierLockup),
                ISablierV2Lockup(sablierLockup),
                names,
                symbols,
                deposits,
                councilSafeAddresses
            );

        vm.stopPrank();

        // 5. Basic invariants
        assertEq(proxies.length, 1);
        assertEq(streamIds.length, 1);
        assertTrue(implementation != address(0));

        // 6. Check CouncilMember wiring
        CouncilMember council = CouncilMember(proxies[0]);
        assertEq(address(council.TELCOIN()), telcoinToken);
        assertEq(address(council._lockup()), sablierLockup);
        assertEq(council._id(), streamIds[0]);

        // Optional: if the Sablier interface exposes a way to read stream recipients,
        // you can assert that the recipient is `proxies[0]` here using ISablierLockup.
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {TestSablierV2Lockup} from "../../contracts/sablier/test/TestSablierV2Lockup.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract RevertingLockup is ISablierV2Lockup {
    function withdrawMax(uint256, address) external pure returns (uint128) {
        revert("withdraw failed");
    }
}

/**
 * @title CouncilMemberForkTest
 * @notice Fork-backed test suite using the live Polygon TEL token address.
 *
 * @dev This is intentionally not a "full mainnet integration" test, because the
 *      lockup is still a deterministic test harness.
 *
 * Suggested run:
 *   forge test --match-contract CouncilMemberForkTest -vvv
 */
contract CouncilMemberForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Official/live Polygon TEL contract.
    address internal constant TEL_ADDRESS =
        0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;

    bytes32 internal constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");
    bytes32 internal constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    uint256 internal constant INITIAL_LOCKUP_FUNDING = 100_000;
    uint256 internal constant DIRECT_RESCUE_FUNDING = 100_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    CouncilMember public councilMemberContract;
    IERC20 public telcoin;
    TestSablierV2Lockup public sablierLockup;

    uint256 public id;

    address public admin = address(1);
    address public support = address(2);
    address public member1 = address(3);
    address public member2 = address(4);
    address public member3 = address(5);
    address public member4 = address(6);
    address public recipient = address(7);
    address public externalAddress = address(8);

    uint256 internal forkId;

    /*//////////////////////////////////////////////////////////////
                                   SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        forkId = vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));

        telcoin = IERC20(TEL_ADDRESS);

        // Deterministic harness that simulates the lockup behavior used by CouncilMember.
        sablierLockup = new TestSablierV2Lockup(telcoin);

        id = 0;

        vm.startPrank(admin);
        CouncilMember impl = new CouncilMember();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                CouncilMember.initialize,
                (
                    IERC20(address(telcoin)),
                    "Test Council",
                    "TC",
                    ISablierV2Lockup(address(sablierLockup)),
                    id
                )
            )
        );
        councilMemberContract = CouncilMember(address(proxy));
        councilMemberContract.grantRole(GOVERNANCE_COUNCIL_ROLE, admin);
        councilMemberContract.grantRole(SUPPORT_ROLE, support);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundLockup(uint256 amount) internal {
        // Uses forge-std helper to assign live-token balances on the fork.
        deal(address(telcoin), address(sablierLockup), amount, true);
    }

    function _fundCouncilDirect(uint256 amount) internal {
        deal(address(telcoin), address(councilMemberContract), amount, true);
    }

    function _mintThreeMembers() internal {
        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        councilMemberContract.mint(member3);
        mine();
        vm.stopPrank();
    }

    function mine() internal {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    /*//////////////////////////////////////////////////////////////
                           FORK / TOKEN SANITY
    //////////////////////////////////////////////////////////////*/

    function testFork_usesLivePolygonTelcoin() public view {
        assertEq(address(councilMemberContract.TELCOIN()), TEL_ADDRESS);
        assertEq(
            IERC20Metadata(address(councilMemberContract.TELCOIN())).decimals(),
            2
        );
    }

    function testFork_liveTelcoinHasCode() public view {
        assertGt(TEL_ADDRESS.code.length, 0, "TEL token has no code");
    }

    /*//////////////////////////////////////////////////////////////
                                VALUES - GETTERS
    //////////////////////////////////////////////////////////////*/

    function test_GOVERNANCE_COUNCIL_ROLE() public view {
        assertEq(
            councilMemberContract.GOVERNANCE_COUNCIL_ROLE(),
            GOVERNANCE_COUNCIL_ROLE
        );
    }

    function test_SUPPORT_ROLE() public view {
        assertEq(councilMemberContract.SUPPORT_ROLE(), SUPPORT_ROLE);
    }

    function test_TELCOIN_address() public view {
        assertEq(address(councilMemberContract.TELCOIN()), TEL_ADDRESS);
    }

    function test_id() public view {
        assertEq(councilMemberContract._id(), id);
    }

    function test_hasGovernanceRole() public view {
        assertTrue(
            councilMemberContract.hasRole(GOVERNANCE_COUNCIL_ROLE, admin)
        );
    }

    function test_hasSupportRole() public view {
        assertTrue(councilMemberContract.hasRole(SUPPORT_ROLE, support));
    }

    /*//////////////////////////////////////////////////////////////
                            VALUES - SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_updateLockup_revertsWithoutRole() public {
        vm.prank(support);
        vm.expectRevert();
        councilMemberContract.updateLockup(ISablierV2Lockup(support));
    }

    function test_updateLockup_success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit CouncilMember.LockupUpdated(ISablierV2Lockup(support));
        councilMemberContract.updateLockup(ISablierV2Lockup(support));

        assertEq(address(councilMemberContract._lockup()), support);
    }

    function test_updateID_revertsWithoutRole() public {
        vm.prank(support);
        vm.expectRevert();
        councilMemberContract.updateID(1);
    }

    function test_updateID_success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit CouncilMember.IDUpdated(1);
        councilMemberContract.updateID(1);

        assertEq(councilMemberContract._id(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                MUTATIVE - MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_singleNFT() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), member1, 0);
        councilMemberContract.mint(member1);

        assertEq(councilMemberContract.totalSupply(), 1);
        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.ownerOf(0), member1);
    }

    /*//////////////////////////////////////////////////////////////
                                MUTATIVE - APPROVE
    //////////////////////////////////////////////////////////////*/

    function test_approve_reverts_without_approval() public {
        vm.prank(admin);
        councilMemberContract.mint(member1);

        vm.prank(externalAddress);
        vm.expectRevert();
        councilMemberContract.transferFrom(member1, support, 0);

        assertEq(councilMemberContract.balanceOf(support), 0);
    }

    function test_approve_reverts_approval_from_external_wallet() public {
        vm.prank(admin);
        councilMemberContract.mint(member1);

        vm.prank(externalAddress);
        vm.expectRevert();
        councilMemberContract.approve(support, 0);

        vm.expectRevert();
        vm.prank(externalAddress);
        councilMemberContract.transferFrom(member1, support, 0);

        assertEq(councilMemberContract.balanceOf(support), 0);
    }

    function test_approve_success() public {
        vm.prank(admin);
        councilMemberContract.mint(member1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IERC721.Approval(member1, support, 0);
        councilMemberContract.approve(support, 0);

        vm.prank(support);
        councilMemberContract.transferFrom(member1, support, 0);

        assertEq(councilMemberContract.balanceOf(support), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                MUTATIVE - BURN
    //////////////////////////////////////////////////////////////*/

    function test_burn_revertsWhenLastMember() public {
        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        councilMemberContract.mint(member3);

        councilMemberContract.burn(0, member2);
        councilMemberContract.burn(1, member3);

        vm.expectRevert(
            abi.encodeWithSelector(
                CouncilMember.CouncilMember__MustMaintainCouncil.selector
            )
        );
        councilMemberContract.burn(2, member1);
        vm.stopPrank();
    }

    function test_burn_success() public {
        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        councilMemberContract.mint(member3);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(member2, address(0), 1);
        councilMemberContract.burn(1, admin);
        vm.stopPrank();

        assertEq(councilMemberContract.ownerOf(0), member1);
        assertEq(councilMemberContract.ownerOf(2), member3);

        vm.expectRevert();
        councilMemberContract.ownerOf(1);
    }

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE - TRANSFERFROM
    //////////////////////////////////////////////////////////////*/

    function test_transferFrom_success() public {
        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        vm.stopPrank();

        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.balanceOf(member2), 1);

        vm.prank(admin);
        councilMemberContract.transferFrom(member1, member2, 0);

        assertEq(councilMemberContract.balanceOf(member1), 0);
        assertEq(councilMemberContract.balanceOf(member2), 2);
    }

    function test_safeTransferFrom_success() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();
        councilMemberContract.mint(member2);
        vm.stopPrank();
        mine();

        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.balanceOf(member2), 1);

        vm.prank(admin);
        councilMemberContract.safeTransferFrom(member1, member2, 0);

        assertEq(councilMemberContract.balanceOf(member1), 0);
        assertEq(councilMemberContract.balanceOf(member2), 2);

        // safeTransferFrom should behave identically to transferFrom for tokenomics:
        // member1 gets paid out their accrued balance, token 0's balance zeroed
        assertGt(telcoin.balanceOf(member1), 0);
        assertEq(councilMemberContract.balances(0), 0);
    }

    function test_non_admin_TransferFrom_fails() public {
        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        vm.stopPrank();

        vm.prank(externalAddress);
        vm.expectRevert();
        councilMemberContract.transferFrom(member1, member2, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKENOMICS - MINT
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_mint_correct_balance_accumulation() public {
        // Lockup drips 100 TEL per unique block via TestSablierV2Lockup.
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1); // _update -> _retrieve (supply was 0, no-op)
        mine();

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(councilMemberContract.balances(0), 0);

        vm.prank(admin);
        councilMemberContract.mint(member2); // _update -> _retrieve: 100/1 = 100 to member0
        mine();

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        // member0: 0 + 100 = 100
        assertEq(councilMemberContract.balances(0), 100);
        assertEq(councilMemberContract.balances(1), 0);

        vm.prank(admin);
        councilMemberContract.mint(member3); // _update -> _retrieve: 100/2 = 50 each
        mine();

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(member3), 0);

        // Two retrieves of 100 TEL so far (200 total in contract)
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);
        // member0: 100 + 50 = 150, member1: 0 + 50 = 50, member2: just minted = 0
        assertEq(councilMemberContract.balances(0), 150);
        assertEq(councilMemberContract.balances(1), 50);
        assertEq(councilMemberContract.balances(2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKENOMICS - BURN
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_burn_correct_removal() public {
        // After _mintThreeMembers: balances = [150, 50, 0], contract holds 200 TEL
        _fundLockup(INITIAL_LOCKUP_FUNDING);
        _mintThreeMembers();

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        // burn(2) triggers _update -> _retrieve: +100/3 = +33 each (1 remainder)
        // Pre-burn balances after retrieve: [183, 83, 33]
        // Burns token 2 (member3), sends 33 to member2, pops slot
        vm.prank(admin);
        councilMemberContract.burn(2, member2);
        mine();

        // 200 (prior) + 100 (retrieve) - 33 (paid to member2) = 267
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 267);
        assertEq(councilMemberContract.balances(0), 183);
        assertEq(councilMemberContract.balances(1), 83);
        assertEq(councilMemberContract.balanceOf(member2), 1);

        vm.expectRevert();
        councilMemberContract.balances(2);

        assertEq(councilMemberContract.balanceOf(member3), 0);
        assertEq(councilMemberContract.totalSupply(), 2);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 33);
        assertEq(telcoin.balanceOf(member3), 0);
    }

    function test_tokenomics_burn_internal_accounting() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);
        _mintThreeMembers();

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        vm.prank(admin);
        councilMemberContract.burn(2, member2);
        mine();

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 267); // same as above test
        assertEq(councilMemberContract.balances(0), 183);
        assertEq(councilMemberContract.balances(1), 83);
        assertEq(councilMemberContract.balanceOf(member2), 1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 33);
        assertEq(telcoin.balanceOf(member3), 0);

        vm.prank(admin);
        councilMemberContract.retrieve();
        mine();

        assertEq(councilMemberContract.balances(0), 233);
        assertEq(councilMemberContract.balances(1), 133);

        vm.expectRevert();
        councilMemberContract.balances(2);
    }

    function test_tokenomics_burn_claim_accounting() public {
        // After _mintThreeMembers: balances = [150, 50, 0], contract holds 200 TEL
        _fundLockup(INITIAL_LOCKUP_FUNDING);
        _mintThreeMembers();

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        // burn(0) triggers _update -> _retrieve: +100/3 = +33 each (1 remainder)
        // After retrieve: [183, 83, 33]. Burns token 0 (member1), sends 183 to admin.
        // Swap-and-pop moves token2's balance (slot 2 -> slot 0).
        vm.prank(admin);
        councilMemberContract.burn(0, admin);
        mine();

        // 200 + 100 (retrieve) - 183 (paid to admin) = 117
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 117);

        // After swap-and-pop: token2 moved to index 0, token1 stays at index 1
        assertEq(councilMemberContract.tokenIdToBalanceIndex(1), 1);
        assertEq(councilMemberContract.tokenIdToBalanceIndex(2), 0);

        // balances[0] = old token2's balance = 33, balances[1] = token1's = 83
        assertEq(councilMemberContract.balances(0), 33);
        assertEq(councilMemberContract.balances(1), 83);
        assertEq(councilMemberContract.balanceOf(member2), 1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(member3), 0);
        assertEq(telcoin.balanceOf(admin), 183);

        // retrieve: +100/2 = +50 each
        vm.prank(admin);
        councilMemberContract.retrieve();

        // balances[0] = 33+50 = 83, balances[1] = 83+50 = 133
        assertEq(councilMemberContract.balances(0), 83);
        assertEq(councilMemberContract.balances(1), 133);

        vm.prank(member2);
        vm.expectEmit(true, true, true, true);
        emit CouncilMember.Claim(1, member2, 133);
        councilMemberContract.claim(1, 133);
        assertEq(telcoin.balanceOf(member2), 133);

        vm.prank(member3);
        councilMemberContract.claim(2, 83);
        assertEq(telcoin.balanceOf(member3), 83);
    }

    function test_tokenomics_burn_general(
        uint256 memberCount,
        uint256 burnIndex
    ) public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        memberCount = bound(memberCount, 3, 20);
        burnIndex = bound(burnIndex, 0, memberCount - 1);

        vm.startPrank(admin);
        for (uint256 i = 0; i < memberCount; i++) {
            councilMemberContract.mint(address(uint160(i) + 100));
        }
        vm.stopPrank();

        mine();

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 100); //only 1 retrieve happened as block was not progressed during the loop
        assertEq(councilMemberContract.balances(0), 100);

        for (uint256 i = 1; i < memberCount; i++) {
            assertEq(councilMemberContract.balances(i), 0);
        }

        vm.prank(admin);
        councilMemberContract.retrieve();

        assertEq(councilMemberContract.balances(0), 100 + (100 / memberCount));
        for (uint256 i = 1; i < memberCount; i++) {
            assertEq(councilMemberContract.balances(i), 100 / memberCount);
        }

        vm.prank(admin);
        councilMemberContract.burn(burnIndex, admin);
        mine();

        if (burnIndex == 0) {
            assertEq(
                telcoin.balanceOf(address(councilMemberContract)),
                100 - (100 / memberCount)
            ); // iniital 100 from first mint credited to ID 0 so this + 100/memberCount is sent to admin, leaving 100 - 100/memberCount in the contract
            assertEq(telcoin.balanceOf(admin), 100 + (100 / memberCount));
        } else {
            assertEq(
                telcoin.balanceOf(address(councilMemberContract)),
                200 - (100 / memberCount)
            ); // initial 100 from first mint credited to ID 0, then 100/memberCount credited to each token including the burned one, so burn sends 100/memberCount to admin, leaving 200 - 100/memberCount in the contract
            assertEq(telcoin.balanceOf(admin), 100 / memberCount);
        }

        vm.prank(admin);
        councilMemberContract.mint(address(uint160(memberCount) + 100));

        assertEq(
            councilMemberContract.ownerOf(memberCount),
            address(uint160(memberCount + 100))
        ); // newly minted token given next ID (burnt ID is not reused). tokenId is zero indexed while memberCount is 1 indexed, so tokenId of newly minted is equal to memberCount

        uint256 penultimateTokenId = councilMemberContract.tokenByIndex(
            councilMemberContract.totalSupply() - 1
        ); // get tokenId of penultimate token using ERC721 enumerable function tokenByIndex
        uint256 owed = councilMemberContract.balances(
            councilMemberContract.tokenIdToBalanceIndex(penultimateTokenId)
        );
        address owner = councilMemberContract.ownerOf(penultimateTokenId);

        vm.prank(owner);
        councilMemberContract.claim(penultimateTokenId, owed);

        assertEq(telcoin.balanceOf(owner), owed);
        assertEq(
            councilMemberContract.balances(
                councilMemberContract.tokenIdToBalanceIndex(penultimateTokenId)
            ),
            0
        );

        vm.expectRevert();
        vm.prank(owner);
        councilMemberContract.claim(penultimateTokenId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        TOKENOMICS - TRANSFERFROM
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_transferFrom_funds_remain_with_old_holder()
        public
    {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        councilMemberContract.transferFrom(member1, member2, 0);
        vm.stopPrank();

        assertEq(telcoin.balanceOf(member1), 150);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 50);
    }

    function test_tokenomics_transferFrom_accounting_soundness() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        // Before transfer: balances[0]=150 (member1), balances[1]=50 (member2)
        // transferFrom pays out member1's balance and zeroes it
        councilMemberContract.transferFrom(member1, member2, 0);
        vm.stopPrank();

        // Internal balance for token 0 should be zeroed after transfer payout
        assertEq(councilMemberContract.balances(0), 0);
        // Token 1 (member2) balance unchanged by the transfer
        assertEq(councilMemberContract.balances(1), 50);
        // member2 now owns both tokens
        assertEq(councilMemberContract.ownerOf(0), member2);
        assertEq(councilMemberContract.ownerOf(1), member2);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKENOMICS - CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_claim_claiming_rewards() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        vm.prank(member1);
        councilMemberContract.claim(0, 0);
        mine();

        assertEq(councilMemberContract.balances(0), 100);

        vm.prank(admin);
        councilMemberContract.mint(member2);
        mine();

        vm.prank(member1);
        councilMemberContract.claim(0, 250);
        mine();

        assertEq(councilMemberContract.balances(0), 0);
        assertEq(telcoin.balanceOf(member1), 250);
        assertEq(councilMemberContract.balances(1), 50);
        assertEq(telcoin.balanceOf(member2), 0);

        vm.prank(admin);
        councilMemberContract.mint(member3);
        mine();

        assertEq(councilMemberContract.balances(0), 50);
        assertEq(councilMemberContract.balances(1), 100);
        assertEq(councilMemberContract.balances(2), 0);

        vm.prank(member1);
        councilMemberContract.claim(0, 83);

        assertEq(councilMemberContract.balances(0), 0);
        assertEq(councilMemberContract.balances(1), 133);
        assertEq(councilMemberContract.balances(2), 33);

        assertEq(telcoin.balanceOf(member1), 333);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(member3), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           TOKENOMICS - RETRIEVE
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_retrieve_minting_does_not_affect_claims_but_increases_balance()
        public
    {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(councilMemberContract.balances(0), 0);

        vm.prank(admin);
        councilMemberContract.retrieve();
        mine();

        assertEq(councilMemberContract.balances(0), 100);

        vm.prank(admin);
        councilMemberContract.mint(member2);
        mine();

        assertEq(councilMemberContract.balances(0), 200);

        vm.prank(admin);
        councilMemberContract.retrieve();

        assertEq(councilMemberContract.balances(0), 250);
        assertEq(councilMemberContract.balances(1), 50);
    }

    /*//////////////////////////////////////////////////////////////
                        TOKENOMICS - ERC20 RESCUE
    //////////////////////////////////////////////////////////////*/

    function test_tokenomics_erc20Rescue() public {
        _fundCouncilDirect(DIRECT_RESCUE_FUNDING);

        uint256 amount = telcoin.balanceOf(address(councilMemberContract));
        assertEq(amount, DIRECT_RESCUE_FUNDING);

        vm.prank(support);
        councilMemberContract.erc20Rescue(telcoin, support, amount);

        assertEq(telcoin.balanceOf(support), DIRECT_RESCUE_FUNDING);
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 0);
    }

    function test_tokenomics_erc20Rescue_does_not_corrupt_member_balances()
        public
    {
        _fundLockup(INITIAL_LOCKUP_FUNDING);
        _mintThreeMembers();

        // Members have accrued balances; send extra TEL directly to the contract
        _fundCouncilDirect(
            DIRECT_RESCUE_FUNDING +
                telcoin.balanceOf(address(councilMemberContract))
        );

        uint256 contractBalBefore = telcoin.balanceOf(
            address(councilMemberContract)
        );
        uint256 bal0 = councilMemberContract.balances(0);
        uint256 bal1 = councilMemberContract.balances(1);
        uint256 bal2 = councilMemberContract.balances(2);

        // Rescue only the directly-funded surplus
        vm.prank(support);
        councilMemberContract.erc20Rescue(
            telcoin,
            support,
            DIRECT_RESCUE_FUNDING
        );

        // Internal balances should be unaffected
        assertEq(councilMemberContract.balances(0), bal0);
        assertEq(councilMemberContract.balances(1), bal1);
        assertEq(councilMemberContract.balances(2), bal2);
        assertEq(
            telcoin.balanceOf(address(councilMemberContract)),
            contractBalBefore - DIRECT_RESCUE_FUNDING
        );
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM - NEGATIVE CASES
    //////////////////////////////////////////////////////////////*/

    function test_claim_reverts_when_not_owner() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        vm.prank(member2);
        vm.expectRevert(
            abi.encodeWithSelector(
                CouncilMember.CouncilMember__NotTokenOwner.selector,
                member2,
                0
            )
        );
        councilMemberContract.claim(0, 0);
    }

    function test_claim_reverts_when_amount_exceeds_balance() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        vm.prank(admin);
        councilMemberContract.retrieve();

        uint256 bal = councilMemberContract.balances(0);

        vm.prank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CouncilMember.CouncilMember__InsufficientBalance.selector,
                bal + 1,
                bal
            )
        );
        councilMemberContract.claim(0, bal + 1);
    }

    /*//////////////////////////////////////////////////////////////
                     RETRIEVE - LOCKUP REVERT RESILIENCE
    //////////////////////////////////////////////////////////////*/

    function test_retrieve_succeeds_when_lockup_reverts() public {
        _fundLockup(INITIAL_LOCKUP_FUNDING);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        // Deploy lockup contract which will revert on withdrawMax to simulate a failure in the lockup during retrieve()
        RevertingLockup badLockup = new RevertingLockup();

        // Swap lockup to an address with no code — withdrawMax will revert
        vm.prank(admin);
        councilMemberContract.updateLockup(
            ISablierV2Lockup(address(badLockup))
        );

        // retrieve() should not revert thanks to try/catch
        vm.prank(admin);
        councilMemberContract.retrieve();

        // Balances unchanged since the lockup call failed silently
        assertEq(councilMemberContract.balances(0), 100);
    }
}

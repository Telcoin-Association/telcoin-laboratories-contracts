// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";
import {TestSablierV2Lockup} from "../../contracts/sablier/test/TestSablierV2Lockup.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

contract RevertingLockup is ISablierV2Lockup {
    function withdrawMax(uint256, address) external pure returns (uint128) {
        revert("withdraw failed");
    }

    function withdrawableAmountOf(uint256) external pure returns (uint128) {
        revert("withdrawableAmountOf failed");
    }
}

/**
 * @title MockTelcoin
 * @notice Simple ERC20 mock for testing
 */
contract MockTelcoin is IERC20 {
    string public name = "Telcoin";
    string public symbol = "TEL";
    uint8 public decimals = 2;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(
            allowance[from][msg.sender] >= amount,
            "Insufficient allowance"
        );
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/**
 * @title CouncilMemberTest
 * @notice Comprehensive test suite to identify bugs in CouncilMember contract
 */
contract CouncilMemberTest is Test {
    CouncilMember public councilMemberContract;
    MockTelcoin public telcoin;
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

    bytes32 public constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    /// @dev How much TEL to mint into TestSablierV2Lockup so that _update →
    ///      _retrieve (which fires on every mint after the first) can execute
    ///      TestSablierV2Lockup.withdrawMax without hitting the mock's
    ///      "Insufficient balance" revert. Any amount >= 100 works; the
    ///      specific value doesn't matter beyond being non-zero.
    ///      Used by `_mintThree` below.
    uint256 internal constant LOCKUP_FUND_AMOUNT = 100_000;

    function setUp() public {
        // Deploy mocks
        telcoin = new MockTelcoin();
        sablierLockup = new TestSablierV2Lockup(telcoin);
        id = uint256(0);

        vm.startPrank(admin);

        // Deploy implementation (constructor disables initializers)
        CouncilMember impl = new CouncilMember();

        // Deploy proxy matching production: TransparentUpgradeableProxy
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

    // ----------------
    // VALUES - GETTERS
    // ----------------

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
        assertEq(address(councilMemberContract.TELCOIN()), address(telcoin));
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

    // ----------------
    // VALUES - SETTERS
    // ----------------

    function test_updateLockup_revertsWithoutRole() public {
        vm.prank(support);
        vm.expectRevert();
        councilMemberContract.updateLockup(ISablierV2Lockup(support));
    }

    function test_updateLockup_success() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.updateLockup(ISablierV2Lockup(support));

        assertEq(address(councilMemberContract._lockup()), support);
    }

    function test_updateID_revertsWithoutRole() public {
        vm.prank(support);
        vm.expectRevert();
        councilMemberContract.updateID(1);
    }

    function test_updateID_success() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit CouncilMember.IDUpdated(1);
        councilMemberContract.updateID(1);

        assertEq(councilMemberContract._id(), 1);
    }

    // ---------------
    // MUTATIVE - MINT
    // ---------------

    function test_mint_singleNFT() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), member1, 0);
        councilMemberContract.mint(member1);

        assertEq(councilMemberContract.totalSupply(), 1);
        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.ownerOf(0), member1);
    }

    // ------------------
    // MUTATIVE - APPROVE
    // ------------------

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
        councilMemberContract.transferFrom(member1, support, 0);
        assertEq(councilMemberContract.balanceOf(support), 0);
    }

    function test_approve_success() public {
        telcoin.mint(address(sablierLockup), 100000);

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

    // ---------------
    // MUTATIVE - BURN
    // ---------------

    function test_burn_effect_on_totalSupply() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        councilMemberContract.mint(member3);

        assertEq(councilMemberContract.totalSupply(), 3);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(member2, address(0), 1);
        councilMemberContract.burn(1, admin);
        vm.stopPrank();

        assertEq(councilMemberContract.totalSupply(), 2);
    }

    function test_burn_revertsWhenLastMember() public {
        telcoin.mint(address(sablierLockup), 100000);

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
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        councilMemberContract.mint(member3);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(member2, address(0), 1);
        councilMemberContract.burn(1, admin);
        vm.stopPrank();
        assertEq(councilMemberContract.ownerOf(0), address(member1));
        assertEq(councilMemberContract.ownerOf(2), address(member3));
        vm.expectRevert();
        councilMemberContract.ownerOf(1);
    }

    // -----------------------
    // MUTATIVE - TRANSFERFROM
    // -----------------------

    function test_transferFrom_success() public {
        telcoin.mint(address(sablierLockup), 100000);

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
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        vm.stopPrank();

        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.balanceOf(member2), 1);
        vm.prank(admin);
        councilMemberContract.safeTransferFrom(member1, member2, 0);

        assertEq(councilMemberContract.balanceOf(member1), 0);
        assertEq(councilMemberContract.balanceOf(member2), 2);
    }

    function test_non_admin_TransferFrom_fails() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        vm.stopPrank();

        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.balanceOf(member2), 1);
        vm.prank(externalAddress);
        vm.expectRevert();
        councilMemberContract.transferFrom(member1, member2, 0);
    }

    // -----------------
    // TOKENOMICS - MINT
    // -----------------

    function test_tokenomics_mint_correct_balance_accumulation() public {
        telcoin.mint(address(sablierLockup), 100000);

        // First mint - no rewards yet (totalSupply of NFTs was 0)
        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(councilMemberContract.balances(0), 0);

        // Second mint - 100 TEL distributed to 1 existing member
        vm.prank(admin);
        councilMemberContract.mint(member2);
        mine();

        // tel hasn't been claimed from NFT contract, so TEL not held by members
        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(councilMemberContract.balances(0), 100); // member1 got 100TEL
        assertEq(councilMemberContract.balances(1), 0); // member2 just minted, so no TEL added to balance

        // Third mint - 100 TEL distributed to 2 existing members (50 each)
        vm.prank(admin);
        councilMemberContract.mint(address(member3));
        mine();

        // No members have claimed from NFT contract, so will not have TEL balances
        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(member3), 0);

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);
        assertEq(councilMemberContract.balances(0), 150); // 100 + 50
        assertEq(councilMemberContract.balances(1), 50); // 0 + 50
        assertEq(councilMemberContract.balances(2), 0); // just minted
    }

    // -----------------
    // TOKENOMICS - BURN
    // -----------------

    function test_tokenomics_burn_correct_removal() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        councilMemberContract.mint(member3);
        mine();

        vm.stopPrank();

        // State: balances = [150, 50, 0], contract has 200 TEL
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        // Burn token 2 - Burning calls _retrieve() (via _burn() _update() so tokens pulled from sablier stream
        vm.prank(admin);
        councilMemberContract.burn(2, member2);
        mine();

        // During burn: 100 tokens retrieved from sablier stream, 33 to each member and 1 in runningBalance
        // After burn: balances(2) sent to recipient (member2), leaving 267 TEL on the CouncilMember contract
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 267);
        //
        assertEq(councilMemberContract.balances(0), 183); // 150 + 33
        assertEq(councilMemberContract.balances(1), 83); // 50 + 33
        assertEq(councilMemberContract.balanceOf(member2), 1);

        vm.expectRevert();
        assertEq(councilMemberContract.balances(2), 0); // burned - final array entry should not exist

        assertEq(councilMemberContract.balanceOf(member3), 0); //burned
        assertEq(councilMemberContract.totalSupply(), 2);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 33);
        assertEq(telcoin.balanceOf(member3), 0);
    }

    function test_tokenomics_burn_internal_accounting() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        councilMemberContract.mint(member3);
        mine();

        vm.stopPrank();

        // State: balances = [150, 50, 0], contract has 200 TEL
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        // Burn token 2 - Burning calls _retrieve() (via _burn() _update() so tokens pulled from sablier stream
        vm.prank(admin);
        councilMemberContract.burn(2, member2);
        mine();

        // During burn: 100 tokens retrieved from sablier stream, 33 to each member and 1 in runningBalance
        // After burn: balances(2) sent to recipient (member2), leaving 267 TEL on the CouncilMember contract
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 267);
        //
        assertEq(councilMemberContract.balances(0), 183); // 150 + 33
        assertEq(councilMemberContract.balances(1), 83); // 50 + 33
        assertEq(councilMemberContract.balanceOf(member2), 1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 33);
        assertEq(telcoin.balanceOf(member3), 0);

        // now retrieve again and check balances
        vm.prank(admin);
        councilMemberContract.retrieve();
        mine();
        assertEq(councilMemberContract.balances(0), 233); // 183 + 50
        assertEq(councilMemberContract.balances(1), 133); // 83 + 50

        vm.expectRevert();
        councilMemberContract.balances(2); // burned
    }

    function test_tokenomics_burn_claim_accounting() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        councilMemberContract.mint(member3);
        mine();

        vm.stopPrank();

        // State: balances = [150, 50, 0], contract has 200 TEL
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 200);

        // Burn token 0 - Burning calls _retrieve() (via _burn() _update() so tokens pulled from sablier stream
        vm.prank(admin);
        councilMemberContract.burn(0, admin);
        mine();

        // During burn: 100 tokens retrieved from sablier stream, 33 to each member and 1 in runningBalance
        // After burn: balances(0) sent to recipient (admin), leaving 300-183 = 117 TEL on the CouncilMember contract
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 117);

        assertEq(councilMemberContract.tokenIdToBalanceIndex(1), 1);
        assertEq(councilMemberContract.tokenIdToBalanceIndex(2), 0); // token 2's balance now at index 0 after burn of token 0

        assertEq(councilMemberContract.balances(0), 33); // 0 + 33
        assertEq(councilMemberContract.balances(1), 83); // 50 + 33
        assertEq(councilMemberContract.balanceOf(member2), 1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(member3), 0);
        assertEq(telcoin.balanceOf(admin), 183); // burned token 0 balance

        // now retrieve again and check balances
        vm.prank(admin);
        councilMemberContract.retrieve();
        // mine(); - do not mine so no additional tokens pulled from lockup on subsequent calls
        assertEq(councilMemberContract.balances(0), 83); // 33 + 50
        assertEq(councilMemberContract.balances(1), 133); // 83 + 50

        vm.prank(member2);
        vm.expectEmit(true, true, true, true);
        emit CouncilMember.Claim(1, member2, 133);
        councilMemberContract.claim(1, 133);
        assertEq(telcoin.balanceOf(member2), 133);

        vm.prank(member3);
        councilMemberContract.claim(2, 83); // [Revert] panic: array out-of-bounds access (0x32) in old contract here
        assertEq(telcoin.balanceOf(member3), 83);
    }

    // Test fails with old contract (commit e468c89f6ab56310c9d194b848b63b9c1036dba0)
    function testFuzz_tokenomics_burn_general(
        uint256 memberCount,
        uint256 burnIndex
    ) public {
        telcoin.mint(address(sablierLockup), 100000);

        memberCount = bound(memberCount, 3, 20);
        burnIndex = bound(burnIndex, 0, memberCount - 1); // burn any minted token

        vm.startPrank(admin);

        for (uint256 i = 0; i < memberCount; i++) {
            councilMemberContract.mint(address(uint160(i) + 2));
        }
        vm.stopPrank();
        mine(); // tokens minted without pulling from lockup, all balances zero but next _update will fund contract

        assertEq(telcoin.balanceOf(address(councilMemberContract)), 100);

        assertEq(councilMemberContract.balances(0), 100); // second mint pulls 100 from lockup to first member
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
            );
        } else {
            assertEq(
                telcoin.balanceOf(address(councilMemberContract)),
                200 - (100 / memberCount)
            );
        }

        if (burnIndex == 0) {
            assertEq(telcoin.balanceOf(admin), 100 + (100 / memberCount));
        } else {
            assertEq(telcoin.balanceOf(admin), 100 / memberCount);
        }

        vm.prank(admin);
        councilMemberContract.mint(address(uint160(memberCount + 1)));

        assertEq(
            councilMemberContract.ownerOf(memberCount),
            address(uint160(memberCount + 1))
        ); // newly minted token given next ID (burnt ID is not reused). tokenId is zero indexed while memberCount is 1 indexed, so tokenId of newly minted is equal to memberCount

        uint256 penultimateTokenId = councilMemberContract.tokenByIndex(
            councilMemberContract.totalSupply() - 1
        ); // get tokenId of penultimate token using ERC721 enumerable function tokenByIndex
        uint256 penultimateTokenIdIsOwed = councilMemberContract.balances(
            councilMemberContract.tokenIdToBalanceIndex(penultimateTokenId)
        );
        address penultimateTokenIdOwner = councilMemberContract.ownerOf(
            penultimateTokenId
        );
        vm.prank(penultimateTokenIdOwner);
        councilMemberContract.claim(
            penultimateTokenId,
            penultimateTokenIdIsOwed
        );
        assertEq(
            telcoin.balanceOf(penultimateTokenIdOwner),
            penultimateTokenIdIsOwed
        );
        assertEq(
            councilMemberContract.balances(
                councilMemberContract.tokenIdToBalanceIndex(penultimateTokenId)
            ),
            0
        );
        // penultimate member should not be able to claim
        vm.expectRevert();
        vm.prank(penultimateTokenIdOwner);
        councilMemberContract.claim(penultimateTokenId, 1); // should revert as no balance
    }

    // -------------------------
    // TOKENOMICS - TRANSFERFROM
    // -------------------------

    function test_tokenomics_transferFrom_accounting_soundness() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        mine();

        councilMemberContract.mint(member2);
        mine();

        // State: balances = [100, 0]
        // Transfer triggers _retrieve (100 / 2 = 50 each), then transfers 150 to member
        councilMemberContract.transferFrom(member1, member2, 0);

        vm.stopPrank();
        assertEq(telcoin.balanceOf(member1), 150); // 100 + 50 from retrieve
        assertEq(telcoin.balanceOf(member2), 0);
        assertEq(telcoin.balanceOf(address(councilMemberContract)), 50); // member2's 50
    }

    // ------------------
    // TOKENOMICS - CLAIM
    // ------------------

    function test_tokenomics_claim_claiming_rewards() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        // Claim with 0 balance, claim pulls 100TEL from lockup
        vm.prank(member1);
        councilMemberContract.claim(0, 0);
        mine();
        assertEq(councilMemberContract.balances(0), 100);

        // Mint second member, first gets 100
        vm.prank(admin);
        councilMemberContract.mint(member2);
        mine();

        // balances = [200,0]
        // Claim triggers retrieve (100 / 2 = 50 each), then claim all
        vm.prank(member1);
        councilMemberContract.claim(0, 250); // 200 + 50
        mine();

        assertEq(councilMemberContract.balances(0), 0);
        assertEq(telcoin.balanceOf(member1), 250);
        assertEq(councilMemberContract.balances(1), 50);
        assertEq(telcoin.balanceOf(member2), 0);

        // Mint third member
        vm.prank(admin);
        councilMemberContract.mint(member3);
        mine();

        assertEq(councilMemberContract.balances(0), 50); // 0 + 50
        assertEq(councilMemberContract.balances(1), 100); // 50 + 50
        assertEq(councilMemberContract.balances(2), 0); // just minted

        // Claim retrieves 100TEL => 100 / 3 = 33 TEL to each member
        vm.prank(member1);
        councilMemberContract.claim(0, 83); // 50 + 33

        assertEq(councilMemberContract.balances(0), 0);
        assertEq(councilMemberContract.balances(1), 133); // 100 + 33
        assertEq(councilMemberContract.balances(2), 33); // 0 + 33

        assertEq(telcoin.balanceOf(member1), 333); // 250+83
        assertEq(telcoin.balanceOf(member2), 0); // hasn't claimed
        assertEq(telcoin.balanceOf(member3), 0); // hasn't claimed
    }

    // ---------------------
    // TOKENOMICS - RETRIEVE
    // ---------------------

    function test_tokenomics_retrieve_minting_does_not_affect_claims_but_increases_balance()
        public
    {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);

        assertEq(telcoin.balanceOf(member1), 0);
        assertEq(councilMemberContract.balances(0), 0);

        // Manual retrieve - 100 / 1 = 100
        vm.prank(admin);
        councilMemberContract.retrieve();
        mine();

        assertEq(councilMemberContract.balances(0), 100);

        // Mint second member - triggers retrieve (100 / 1 = 100 to existing)
        vm.prank(admin);
        councilMemberContract.mint(member2);
        mine();

        assertEq(councilMemberContract.balances(0), 200); // 100 + 100

        // Another retrieve - 100 / 2 = 50 each
        vm.prank(admin);
        councilMemberContract.retrieve();

        assertEq(councilMemberContract.balances(0), 250); // 200 + 50
        assertEq(councilMemberContract.balances(1), 50); // 0 + 50
    }

    function test_tokenomics_retrieve_noop_when_zero_withdrawable() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        // First retrieve pulls 100 TEL
        vm.prank(admin);
        councilMemberContract.retrieve();

        assertEq(councilMemberContract.balances(0), 100);

        // Second retrieve in same block — withdrawableAmountOf returns 0, should be a no-op
        vm.prank(admin);
        councilMemberContract.retrieve();

        // Balance unchanged
        assertEq(councilMemberContract.balances(0), 100);
    }

    function test_tokenomics_retrieve_reverts_with_invalid_lockup() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        // Swap to a lockup where withdrawableAmountOf reverts (simulates null/invalid stream)
        RevertingLockup badLockup = new RevertingLockup();
        vm.prank(admin);
        councilMemberContract.updateLockup(
            ISablierV2Lockup(address(badLockup))
        );

        // retrieve() should revert — not silently swallow the error
        vm.prank(admin);
        vm.expectRevert();
        councilMemberContract.retrieve();
    }

    function test_tokenomics_retrieve_reverts_propagate_to_claim() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        RevertingLockup badLockup = new RevertingLockup();
        vm.prank(admin);
        councilMemberContract.updateLockup(
            ISablierV2Lockup(address(badLockup))
        );

        // claim() calls _retrieve() internally — should also revert
        vm.prank(member1);
        vm.expectRevert();
        councilMemberContract.claim(0, 0);
    }

    function test_tokenomics_retrieve_reverts_propagate_to_mint() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.prank(admin);
        councilMemberContract.mint(member1);
        mine();

        RevertingLockup badLockup = new RevertingLockup();
        vm.prank(admin);
        councilMemberContract.updateLockup(
            ISablierV2Lockup(address(badLockup))
        );

        // mint() calls _retrieve() internally — should also revert
        vm.prank(admin);
        vm.expectRevert();
        councilMemberContract.mint(member2);
    }

    function test_tokenomics_retrieve_reverts_propagate_to_burn() public {
        telcoin.mint(address(sablierLockup), 100000);

        vm.startPrank(admin);
        councilMemberContract.mint(member1);
        councilMemberContract.mint(member2);
        mine();
        vm.stopPrank();

        RevertingLockup badLockup = new RevertingLockup();
        vm.prank(admin);
        councilMemberContract.updateLockup(
            ISablierV2Lockup(address(badLockup))
        );

        // burn() calls _retrieve() via _update() — should also revert
        vm.prank(admin);
        vm.expectRevert();
        councilMemberContract.burn(0, admin);
    }

    // -------------------------
    // TOKENOMICS - ERC20 RESCUE
    // -------------------------

    function test_tokenomics_erc20Rescue() public {
        telcoin.mint(address(councilMemberContract), 100000);

        uint256 amount = telcoin.balanceOf(address(councilMemberContract));

        vm.prank(support);
        councilMemberContract.erc20Rescue(
            IERC20(address(telcoin)),
            support,
            amount
        );

        assertEq(telcoin.balanceOf(support), 100000);
    }

    function mine() public {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // --------------------------------
    // INITIALIZE - extra safety checks
    // --------------------------------

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        councilMemberContract.initialize(
            IERC20(address(telcoin)),
            "X",
            "X",
            ISablierV2Lockup(address(sablierLockup)),
            0
        );
    }

    function test_initialize_nameAndSymbol() public view {
        assertEq(councilMemberContract.name(), "Test Council");
        assertEq(councilMemberContract.symbol(), "TC");
    }

    // ---------------------------
    // EIP-165 - supportsInterface
    // ---------------------------
    // NOTE: PR #87 fixed supportsInterface to delegate to super.
    // These tests lock in that behavior.

    function test_supportsInterface_accessControlEnumerable() public view {
        bytes4 iface = type(IAccessControlEnumerable).interfaceId;
        assertTrue(councilMemberContract.supportsInterface(iface));
    }

    function test_supportsInterface_erc721Enumerable() public view {
        bytes4 iface = type(IERC721Enumerable).interfaceId;
        assertTrue(councilMemberContract.supportsInterface(iface));
    }

    function test_supportsInterface_ierc721() public view {
        bytes4 iface = type(IERC721).interfaceId;
        assertTrue(councilMemberContract.supportsInterface(iface));
    }

    function test_supportsInterface_randomFalse() public view {
        assertFalse(councilMemberContract.supportsInterface(0xdeadbeef));
    }

    // ------------------------------
    // ERC721Enumerable - conformance
    // ------------------------------

    function test_erc721Enumerable_totalSupply() public {
        _mintThree();
        assertEq(councilMemberContract.totalSupply(), 3);
    }

    function test_erc721Enumerable_tokenByIndex() public {
        _mintThree();
        assertEq(councilMemberContract.tokenByIndex(0), 0);
        assertEq(councilMemberContract.tokenByIndex(1), 1);
        assertEq(councilMemberContract.tokenByIndex(2), 2);
    }

    function test_erc721Enumerable_tokenOfOwnerByIndex() public {
        _mintThree();
        assertEq(councilMemberContract.tokenOfOwnerByIndex(member1, 0), 0);
        assertEq(councilMemberContract.tokenOfOwnerByIndex(member2, 0), 1);
        assertEq(councilMemberContract.tokenOfOwnerByIndex(member3, 0), 2);
    }

    function test_erc721Enumerable_balanceOf() public {
        _mintThree();
        assertEq(councilMemberContract.balanceOf(member1), 1);
        assertEq(councilMemberContract.balanceOf(member2), 1);
        assertEq(councilMemberContract.balanceOf(member3), 1);
        assertEq(councilMemberContract.balanceOf(externalAddress), 0);
    }

    // ---------------------------
    // APPROVAL - custom overrides
    // ---------------------------

    function test_setApprovalForAll_isNoop() public {
        // setApprovalForAll is overridden to be a no-op on CouncilMember.
        _mintThree();
        vm.prank(member1);
        councilMemberContract.setApprovalForAll(externalAddress, true);
        assertFalse(
            councilMemberContract.isApprovedForAll(member1, externalAddress)
        );
    }

    // --------------------------------------
    // AUTHORIZATION - _isAuthorized override
    // --------------------------------------

    function test_isAuthorized_governanceCanTransfer() public {
        // GOVERNANCE_COUNCIL_ROLE holder can transfer any token without approval.
        _mintThree();
        vm.prank(admin);
        councilMemberContract.transferFrom(member1, externalAddress, 0);
        assertEq(councilMemberContract.ownerOf(0), externalAddress);
    }

    function test_isAuthorized_approvedCanTransfer() public {
        _mintThree();
        address approved = makeAddr("approved");
        vm.prank(admin);
        councilMemberContract.approve(approved, 1);

        vm.prank(approved);
        councilMemberContract.transferFrom(member2, externalAddress, 1);
        assertEq(councilMemberContract.ownerOf(1), externalAddress);
    }

    // --------------------------------
    // _UPDATE HOOK - retrieve ordering
    // --------------------------------

    function test_update_callsRetrieveBeforeMint() public {
        // After first member is minted, subsequent mints invoke _retrieve via _update.
        // With a TestSablierV2Lockup that returns 0, _retrieve is a no-op but still executes.
        _mintThree();
        vm.prank(admin);
        councilMemberContract.mint(makeAddr("newMember"));
        assertEq(councilMemberContract.totalSupply(), 4);
    }

    function test_update_callsRetrieveBeforeTransfer() public {
        _mintThree();
        vm.prank(admin);
        councilMemberContract.transferFrom(member1, externalAddress, 0);
        assertEq(councilMemberContract.ownerOf(0), externalAddress);
    }

    function test_update_firstMintSkipsRetrieve() public {
        // Fresh council with zero supply: _update must skip the _retrieve branch
        // entirely on the first mint.
        CouncilMember impl2 = new CouncilMember();
        bytes memory initData = abi.encodeCall(
            CouncilMember.initialize,
            (
                IERC20(address(telcoin)),
                "Fresh Council",
                "FC",
                ISablierV2Lockup(address(sablierLockup)),
                uint256(0)
            )
        );

        vm.startPrank(admin);
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(
            address(impl2),
            admin,
            initData
        );
        CouncilMember fresh = CouncilMember(address(proxy2));
        fresh.grantRole(GOVERNANCE_COUNCIL_ROLE, admin);

        // totalSupply() == 0 → _update must take the early-return branch and not
        // touch the Sablier lockup.
        fresh.mint(member1);
        vm.stopPrank();

        assertEq(fresh.totalSupply(), 1);
        assertEq(fresh.ownerOf(0), member1);
    }

    // ----------------------
    // LIFECYCLE - edge cases
    // ----------------------

    function test_burnAllButOne_thenMintAgain() public {
        _mintThree();

        vm.startPrank(admin);
        councilMemberContract.burn(2, externalAddress);
        councilMemberContract.burn(1, externalAddress);
        vm.stopPrank();

        assertEq(councilMemberContract.totalSupply(), 1);

        // Counter continues from the last used tokenId — it does not reset.
        address newA = makeAddr("newA");
        address newB = makeAddr("newB");
        vm.startPrank(admin);
        councilMemberContract.mint(newA);
        councilMemberContract.mint(newB);
        vm.stopPrank();

        assertEq(councilMemberContract.totalSupply(), 3);
        assertEq(councilMemberContract.ownerOf(3), newA);
        assertEq(councilMemberContract.ownerOf(4), newB);
    }

    // -------
    // HELPERS
    // -------

    function _mintThree() internal {
        telcoin.mint(address(sablierLockup), LOCKUP_FUND_AMOUNT);
        vm.startPrank(admin);
        councilMemberContract.mint(member1); // tokenId 0
        councilMemberContract.mint(member2); // tokenId 1
        councilMemberContract.mint(member3); // tokenId 2
        vm.stopPrank();
    }

    // -------------------------
    // APPROVAL - removeApproval
    // -------------------------

    function test_removeApproval_clearsApproval() public {
        _mintThree();
        address approved = makeAddr("approved");
        vm.startPrank(admin);
        councilMemberContract.approve(approved, 0);
        assertEq(councilMemberContract.getApproved(0), approved);
        councilMemberContract.removeApproval(0);
        vm.stopPrank();
        assertEq(councilMemberContract.getApproved(0), address(0));
    }

    function test_removeApproval_revertsNonGovernance() public {
        _mintThree();
        vm.prank(externalAddress);
        vm.expectRevert();
        councilMemberContract.removeApproval(0);
    }

    // ------------------------------------------
    // TestSablierV2Lockup - direct mock coverage
    // ------------------------------------------
    // The mock's same-block idempotency paths (withdrawMax returning 0,
    // withdrawableAmountOf returning 0) are not reachable through
    // CouncilMember._retrieve, since that always gates withdrawMax
    // behind withdrawableAmountOf. These tests exercise them directly.

    function test_testSablierV2Lockup_withdrawMax_returnsZeroOnSecondCallSameBlock() public {
        telcoin.mint(address(sablierLockup), 100000);

        // First call in this block: returns 100, transfers 100 tokens.
        uint128 first = sablierLockup.withdrawMax(0, address(this));
        assertEq(first, 100);
        assertEq(telcoin.balanceOf(address(this)), 100);

        // Second call in the same block: returns 0, no-op.
        uint128 second = sablierLockup.withdrawMax(0, address(this));
        assertEq(second, 0);
        assertEq(telcoin.balanceOf(address(this)), 100, "no additional transfer");
    }

    function test_testSablierV2Lockup_withdrawableAmountOf_returnsZeroAfterWithdraw() public {
        telcoin.mint(address(sablierLockup), 100000);

        // Before any withdraw this block, amount is 100.
        assertEq(sablierLockup.withdrawableAmountOf(0), 100);

        // After a withdraw in the same block, subsequent reads return 0.
        sablierLockup.withdrawMax(0, address(this));
        assertEq(sablierLockup.withdrawableAmountOf(0), 0);
    }

    // ------------------------------------
    // OnlyAuthorized modifier - retrieve()
    // ------------------------------------

    function test_retrieve_revertsForUnauthorizedCaller() public {
        // retrieve() is gated by OnlyAuthorized, which requires the caller to
        // either hold GOVERNANCE_COUNCIL_ROLE or own at least one NFT.
        // externalAddress has neither.
        _mintThree();
        vm.prank(externalAddress);
        vm.expectRevert(
            abi.encodeWithSignature(
                "CouncilMember__NotAuthorized(address)",
                externalAddress
            )
        );
        councilMemberContract.retrieve();
    }
}

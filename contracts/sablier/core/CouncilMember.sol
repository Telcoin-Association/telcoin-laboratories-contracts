// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISablierV2Lockup} from "../interfaces/ISablierV2Lockup.sol";

/**
 * @title CouncilMember
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to signify ownership council membership
 * @dev Relies on OpenZeppelin's open source smart contracts
 */
contract CouncilMember is
    ERC721EnumerableUpgradeable,
    AccessControlEnumerableUpgradeable
{
    using SafeERC20 for IERC20;

    /* ========== EVENTS ========== */
    // Event fired when the lockup address is updated
    event LockupUpdated(ISablierV2Lockup newLockup);
    // Event fired when the ID is updated
    event IDUpdated(uint256 newID);

    /* ========== STATE VARIABLES ========== */
    // The main token of this ecosystem
    IERC20 public TELCOIN;
    // the location of tokens
    ISablierV2Lockup public _lockup;
    // the id associated with the sablier NFT
    uint256 public _id;
    // balance left over from last rebalancing
    uint256 private runningBalance;
    // current uncliamed members balances
    uint256[] public balances;
    // index counter
    uint private counter;
    // mapping to new index
    mapping(uint256 tokenId => uint256 balanceIndex)
        public tokenIdToBalanceIndex;
    // reverse of tokenIdToBalanceIndex
    mapping(uint256 balanceIndex => uint256 tokenId)
        public balanceIndexToTokenId;

    /* ========== ROLES ========== */
    // Role assigned for the governance council
    bytes32 public constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");
    // Support role for additional functionality
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    /* ========== INITIALIZER ========== */
    function initialize(
        IERC20 telcoin,
        string memory name_,
        string memory symbol_,
        ISablierV2Lockup lockup_,
        uint256 id_
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        __ERC721_init(name_, symbol_);
        TELCOIN = telcoin;
        _lockup = lockup_;
        _id = id_;
    }

    /************************************************
     *   external functions
     ************************************************/

    /**
     * @notice Allows authorized personnel to retrieve and distribute TELCOIN to council members
     * @dev The main logic behind the TELCOIN distribution is encapsulated in this function.
     * @dev This function should be called before any significant state changes to ensure accurate distribution.
     * @dev Only the owner council members can call this function
     */
    function retrieve() external OnlyAuthorized {
        _retrieve();
    }

    /**
     * @notice Allows council members to claim their allocated amounts of TELCOIN
     * @dev Checks if the caller is the owner of the provided tokenId and if the requested amount is available.
     * @param tokenId The NFT index associated with a council member.
     */
    function claim(uint256 tokenId) external {
        // Ensure the function caller is the owner of the token (council member) they're trying to claim for
        require(
            _msgSender() == ownerOf(tokenId),
            "CouncilMember: caller is not council member holding this NFT index"
        );
        // Retrieve and distribute any pending TELCOIN for all council members
        _retrieve();

        uint256 balanceIndex = tokenIdToBalanceIndex[tokenId];
        uint256 amount = balances[balanceIndex];

        // Ensure the user has something to claim
        require(amount > 0, "CouncilMember: no TELCOIN to claim");

        // Deduct the claimed amount from the token's balance
        balances[balanceIndex] = 0;

        // Safely transfer the claimed amount of TELCOIN to the function caller
        TELCOIN.safeTransfer(_msgSender(), amount);
    }

    /**
     * @notice Replace an existing council member with a new one and withdraws the old member's TELCOIN allocation
     * @param from Address of the current council member to be replaced.
     * @param to Address of the new council member.
     * @param tokenId Token ID of the council member NFT.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721Upgradeable, IERC721) {
        address previousApproval = _getApproved(tokenId);
        super.transferFrom(from, to, tokenId);
        _approve(previousApproval, tokenId, address(0), false);

        uint256 balanceIndex = tokenIdToBalanceIndex[tokenId];
        TELCOIN.safeTransfer(from, balances[balanceIndex]);
    }

    /************************************************
     *   view functions
     ************************************************/

    /**
     * @notice Check if the contract supports a specific interface
     * @dev Overrides the supportsInterface function from OpenZeppelin.
     * @param interfaceId ID of the interface to check for support.
     * @return True if the contract supports the interface, false otherwise.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        pure
        override(
            AccessControlEnumerableUpgradeable,
            ERC721EnumerableUpgradeable
        )
        returns (bool)
    {
        return
            interfaceId ==
            type(AccessControlEnumerableUpgradeable).interfaceId ||
            interfaceId == type(ERC721EnumerableUpgradeable).interfaceId ||
            interfaceId == type(IERC721).interfaceId;
    }

    /************************************************
     *   mutative functions
     ************************************************/

    /**
     * @notice Approve a specific address for a specific NFT
     * @dev Overrides the approve function from ERC721.
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param to Address to be approved.
     * @param tokenId Token ID of the NFT to be approved.
     */
    function approve(
        address to,
        uint256 tokenId
    )
        public
        override(ERC721Upgradeable, IERC721)
        onlyRole(GOVERNANCE_COUNCIL_ROLE)
    {
        _approve(to, tokenId, address(0));
    }

    /**
     * @notice removes approval a specific address for a specific NFT
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param tokenId Token ID of the NFT to be approved.
     */
    function removeApproval(
        uint256 tokenId
    ) public onlyRole(GOVERNANCE_COUNCIL_ROLE) {
        _approve(address(0), tokenId, address(0), false);
    }

    // Does not work because low level calls are overridden
    function setApprovalForAll(
        address,
        bool
    ) public override(ERC721Upgradeable, IERC721) {}

    /**
     * @notice Mint new council member NFTs
     * @dev This function also retrieves and distributes TELCOIN.
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param newMember Address of the new council member.
     */
    function mint(
        address newMember
    ) external onlyRole(GOVERNANCE_COUNCIL_ROLE) {
        uint256 index = counter++;
        _mint(newMember, index);
        tokenIdToBalanceIndex[index] = balances.length;
        balanceIndexToTokenId[balances.length] = index;
        balances.push(0);
    }

    /**
     * @notice Burn a council member NFT
     * @dev The function retrieves and distributes TELCOIN before burning the NFT.
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param tokenId Token ID of the council member NFT to be burned.
     * @param recipient Address to receive the burned NFT holder's TELCOIN allocation.
     */
    function burn(
        uint256 tokenId,
        address recipient
    ) external onlyRole(GOVERNANCE_COUNCIL_ROLE) {
        require(totalSupply() > 1, "CouncilMember: must maintain council");

        _burn(tokenId);
        uint256 balanceIndex = tokenIdToBalanceIndex[tokenId];

        // Transfer balance to recipient
        TELCOIN.safeTransfer(recipient, balances[balanceIndex]);

        // Swap-remove pattern to keep `balances` compact
        uint256 lastIndex = balances.length - 1;

        if (balanceIndex != lastIndex) {
            balances[balanceIndex] = balances[lastIndex];
            uint256 movedTokenId = balanceIndexToTokenId[lastIndex];
            tokenIdToBalanceIndex[movedTokenId] = balanceIndex;
            balanceIndexToTokenId[balanceIndex] = movedTokenId;
        }

        balances.pop();

        // Clean up stale data
        delete tokenIdToBalanceIndex[tokenId];
        delete balanceIndexToTokenId[lastIndex];
    }

    /**
     * @notice Update the lockup address
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param lockup_ New lockup address.
     */
    function updateLockup(
        ISablierV2Lockup lockup_
    ) external onlyRole(GOVERNANCE_COUNCIL_ROLE) {
        _retrieve();
        _lockup = lockup_;
        emit LockupUpdated(lockup_);
    }

    /**
     * @notice Update the ID for a council member
     * @dev Restricted to the GOVERNANCE_COUNCIL_ROLE.
     * @param id_ New ID for the council member.
     */
    function updateID(uint256 id_) external onlyRole(GOVERNANCE_COUNCIL_ROLE) {
        _retrieve();
        _id = id_;
        emit IDUpdated(_id);
    }

    /************************************************
     *   internal functions
     ************************************************/

    /**
     * @notice Retrieve and distribute TELCOIN to council members based on the stream from _target
     * @dev This function fetches the maximum possible TELCOIN and distributes it equally among all council members.
     * @dev It also updates the running balance to ensure accurate distribution during subsequent calls.
     */
    function _retrieve() internal {
        // Execute the withdrawal from the _lockup
        try _lockup.withdrawMax(_id, address(this)) returns (uint128 amount) {
            uint256 finalBalance = uint256(amount) + runningBalance;
            // Distribute the TELCOIN equally among all council members
            uint256 individualBalance = finalBalance / totalSupply();
            // Update the running balance which keeps track of any TELCOIN that can't be evenly distributed
            runningBalance = finalBalance % totalSupply();

            // Add the individual balance to each council member's balance
            for (uint i = 0; i < balances.length; i++) {
                balances[i] += individualBalance;
            }
        } catch {}
    }

    /**
     * @notice Determines if an address is approved or is the owner for a specific token ID
     * @dev This function checks if the spender has GOVERNANCE_COUNCIL_ROLE or is the approved address for the token.
     * @param spender Address to check approval or ownership for.
     * @param tokenId Token ID to check against.
     * @return True if the address is approved or is the owner, false otherwise.
     */
    function _isAuthorized(
        address,
        address spender,
        uint256 tokenId
    ) internal view override returns (bool) {
        return (hasRole(GOVERNANCE_COUNCIL_ROLE, spender) ||
            _getApproved(tokenId) == spender);
    }

    /**
     * @notice Handle operations to be performed before transferring a token
     * @dev This function retrieves and distributes TELCOIN before the token transfer.
     * @dev It is an override of the _beforeTokenTransfer from OpenZeppelin's ERC721.
     * @param to Address from which the token is being transferred.
     * @param tokenId Token ID that's being transferred.
     * @param auth Token ID that's being transferred.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        if (totalSupply() != 0) {
            _retrieve();
        }

        return super._update(to, tokenId, auth);
    }

    /************************************************
     *   helper functions
     ************************************************/

    /**
     * @notice Rescues any ERC20 token sent accidentally to the contract
     * @dev Only addresses with the SUPPORT_ROLE can call this function.
     * @param token ERC20 token address which needs to be rescued.
     * @param destination Address where the tokens will be sent.
     * @param amount Amount of tokens to be transferred.
     */
    function erc20Rescue(
        IERC20 token,
        address destination,
        uint256 amount
    ) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
    }

    /************************************************
     *   modifiers
     ************************************************/

    /**
     * @notice Checks if the caller is authorized either by being a council member or having the GOVERNANCE_COUNCIL_ROLE
     * @dev This modifier is used to restrict certain operations to council members or governance personnel.
     */
    modifier OnlyAuthorized() {
        require(
            hasRole(GOVERNANCE_COUNCIL_ROLE, _msgSender()) ||
                ERC721Upgradeable.balanceOf(_msgSender()) >= 1,
            "CouncilMember: caller is not council member or owner"
        );
        _;
    }
}

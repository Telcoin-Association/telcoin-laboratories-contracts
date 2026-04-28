// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title NonSourceERC165
/// @notice Contract that implements IERC165 but does NOT advertise ISource via
///         supportsInterface. Used by VotingWeightCalculator tests to verify the
///         addSource() path rejects EIP-165-compliant contracts that don't actually
///         implement the ISource selector.
contract NonSourceERC165 is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReality} from "contracts/zodiac/interfaces/IReality.sol";
import {Enum} from "contracts/zodiac/enums/Operation.sol";

/// @title MockReality
/// @notice Minimal IReality stand-in that implements `getTransactionHash` so SafeGuard can
///         compute hashes during `checkTransaction`. SafeGuard tests deploy this as the
///         msg.sender (the simulated Safe) that calls into checkTransaction. The other
///         IReality methods are stubbed and intentionally a no-op since SafeGuard does not
///         exercise them in test paths.
contract MockReality is IReality {
    function getTransactionHash(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 nonce
    ) external pure override returns (bytes32) {
        return keccak256(abi.encodePacked(to, value, data, operation, nonce));
    }

    // Unused stubs required by IReality
    function notifyOfArbitrationRequest(bytes32, address, uint256) external pure override {}
    function submitAnswerByArbitrator(bytes32, bytes32, address) external pure override {}
    function getBestAnswer(bytes32) external pure override returns (bytes32) { return bytes32(0); }
}

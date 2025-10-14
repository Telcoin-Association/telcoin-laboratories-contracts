// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ISource} from "../interfaces/ISource.sol";

/**
 * @title VotingWeightCalculator
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.
 * @dev Relies on OpenZeppelin's Ownable2Step for ownership control and other external interfaces for token
 */
contract VotingWeightCalculator is Ownable2Step {
    /// @notice Emitted when a new liquidity source is added to the voting calculator
    /// @param source The source contract that was added
    event SourceAdded(ISource indexed source);
    /// @notice Emitted when a liquidity source is removed from the voting calculator
    /// @param source The source contract that was removed
    /// @param index The index at which the source was located before removal
    event SourceRemoved(ISource indexed source, uint256 index);

    // Array storing different liquidity sources
    ISource[] public sources;

    // constructor is initialized with address
    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Returns the list of currently whitelisted liquidity sources
     * @return An array of contracts implementing the ISource interface
     */
    function getSources() external view returns (ISource[] memory) {
        return sources;
    }

    /**
     * @notice Adds a new source to be considered when calculating voting weight.
     * @param source liquidity source to be added
     */
    function addSource(ISource source) external onlyOwner {
        require(
            IERC165(address(source)).supportsInterface(
                type(ISource).interfaceId
            ),
            "VotingWeightCalculator: address does not support Source"
        );

        for (uint i = 0; i < sources.length; i++) {
            require(
                sources[i] != source,
                "VotingWeightCalculator: source already added"
            );
        }

        sources.push(ISource(source));
        emit SourceAdded(source);
    }

    /**
     * @notice Removes a token source from the list.
     * @dev It replaces the source to be removed with the last source in the array, then removes the last source.
     * @param index index of the source to be removed.
     */
    function removeSource(uint256 index) external onlyOwner {
        // Replace the source at the index with the last source in the list
        ISource removed = sources[index];
        sources[index] = sources[sources.length - 1];
        sources.pop();
        emit SourceRemoved(removed, index);
    }

    /**
     * @notice Calculates the total voting weight of a voter.
     * @dev Voting weight includes direct Telcoin balance and equivalent balance in whitelisted sources and staking contract.
     * @param voter the address being evaluated
     * @return runningTotal Total voting weight of the voter.
     */
    function balanceOf(
        address voter
    ) public view returns (uint256 runningTotal) {
        uint256 len = sources.length;
        // Loop through each staking contract to add up the TEL balance for the voter
        for (uint i = 0; i < len; i++) {
            runningTotal += sources[i].balanceOf(voter);
        }
    }
}

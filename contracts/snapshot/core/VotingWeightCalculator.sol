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
    // Array storing different liquidity sources
    ISource[] public sources;

    // constructor is initialized with address
    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Adds a new soure to be considered when calculating voting weight.
     * @param source liquidity source to be added
     */
    function addSource(address source) external onlyOwner {
        require(
            IERC165(source).supportsInterface(type(ISource).interfaceId),
            "VotingWeightCalculator: address does not support Source"
        );

        sources.push(ISource(source));
    }

    /**
     * @notice Removes a token source from the list.
     * @dev It replaces the source to be removed with the last source in the array, then removes the last source.
     * @param index index of the source to be removed.
     */
    function removeSource(uint256 index) external onlyOwner {
        // Replace the source at the index with the last source in the list
        ISource source = sources[sources.length - 1];
        sources[index] = source;
        sources.pop(); // Remove the last source
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
        // Loop through each staking contract to add up the TEL balance for the voter
        for (uint i = 0; i < sources.length; i++) {
            runningTotal += sources[i].balanceOf(voter);
        }
    }
}

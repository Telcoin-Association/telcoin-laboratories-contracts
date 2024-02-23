//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// imports
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IStakingModule} from "../interfaces/IStakingModule.sol";
import {ISource} from "../interfaces/ISource.sol";

/**
 * @title StakingModuleAdaptor
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.
 */
contract StakingModuleAdaptor is ISource, IERC165 {
    // refernce to staking contract
    IStakingModule public immutable _module;

    // Constructor initializes the BalancerAdaptor contract with necessary contract references
    constructor(IStakingModule module_) {
        // makes sure no zero values are passed in
        require(
            address(module_) != address(0),
            "StakingModuleAdaptor: cannot initialize to zero"
        );

        // assign values to immutable state
        _module = module_;
    }

    /**
     * @notice Returns if is valid interface
     * @dev Override for supportsInterface to adhere to IERC165 standard
     * @param interfaceId bytes representing the interface
     * @return bool confirmation of matching interfaces
     */
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        // provides affermation of interface so calculator can add
        return interfaceId == type(ISource).interfaceId;
    }

    /**
     * @notice Calculates the voting weight of a voter
     * @dev gets pool share equivalent of the amount of Telcoin in the pool
     * @param voter the address being evaluated
     * @return uint256 Total voting weight of the voter
     */
    function balanceOf(address voter) external view override returns (uint256) {
        // Return the voter's share of Telcoin staking contract
        return _module.balanceOf(voter, "");
    }
}

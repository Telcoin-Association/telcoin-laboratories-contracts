//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// imports
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IStakingRewards} from "../interfaces/IStakingRewards.sol";
import {ISource} from "../interfaces/ISource.sol";

/**
 * @title StakingRewardsAdaptor
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.
 */
contract StakingRewardsAdaptor is ISource, IERC165 {
    // staking contract that holds liquidity
    IStakingRewards public immutable _staking;
    // secondary voting source
    ISource public immutable _source;

    constructor(ISource source_, IStakingRewards staking_) {
        // makes sure no zero values are passed in
        require(
            address(source_) != address(0) && address(staking_) != address(0),
            "StakingRewardsAdaptor: cannot initialize to zero"
        );

        // assign values to immutable state
        _source = source_;
        _staking = staking_;
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
        // If the voter has no balance in the pool, return 0
        if (_staking.balanceOf(voter) == 0) {
            return _staking.earned(voter);
        }

        // Return the voter's share of Telcoin in the pool
        return
            _staking.earned(voter) +
            ((_staking.balanceOf(voter) *
                _source.balanceOf(address(_staking))) / _staking.totalSupply());
    }
}

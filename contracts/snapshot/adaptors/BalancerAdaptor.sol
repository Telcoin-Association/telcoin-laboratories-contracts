//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// imports
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalancerVault, IERC20} from "../interfaces/IBalancerVault.sol";
import {IBalancerPool} from "../interfaces/IBalancerPool.sol";
import {ISource} from "../interfaces/ISource.sol";

/**
 * @title BalancerAdaptor
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.
 */
contract BalancerAdaptor is ISource, IERC165 {
    // Reference to the Telcoin token contract
    IERC20 public immutable TELCOIN;
    // Location where all balancer funds are held
    IBalancerVault public immutable _valut;
    // Valut ID used to reference pool
    bytes32 public immutable _poolId;
    // Address of liquidity pool
    IBalancerPool public immutable _pool;
    // Multiplying Factor
    uint256 public immutable _mFactor;
    // Dividing Factor
    uint256 public immutable _dFactor;

    // Constructor initializes the BalancerAdaptor contract with necessary contract references
    constructor(
        // Reference to the Telcoin token contract
        IERC20 telcoin,
        // Location where all balancer funds are held
        IBalancerVault vault_,
        // Valut ID used to reference pool
        bytes32 poolId_,
        // Address of liquidity pool
        IBalancerPool pool_,
        // Multiplying Factor
        uint256 mFactor_,
        // Dividing Factor
        uint256 dFactor_
    ) {
        // makes sure no zero values are passed in
        require(
            address(telcoin) != address(0) &&
                address(vault_) != address(0) &&
                bytes32(poolId_) != bytes32(0) &&
                address(pool_) != address(0) &&
                mFactor_ != 0 &&
                dFactor_ != 0,
            // error message
            "BalancerAdaptor: cannot initialize to zero"
        );

        // assign values to immutable state
        TELCOIN = telcoin;
        _valut = vault_;
        _poolId = poolId_;
        _pool = pool_;
        _mFactor = mFactor_;
        _dFactor = dFactor_;
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
        if (_pool.balanceOf(voter) == 0) {
            return 0;
        }
        // Retrieve the amount of Telcoin in the pool
        (uint256 amount, , , ) = _valut.getPoolTokenInfo(_poolId, TELCOIN);
        // Return the voter's share of Telcoin in the pool
        return
            ((_pool.balanceOf(voter) * amount * _mFactor) / _dFactor) /
            _pool.totalSupply();
    }
}

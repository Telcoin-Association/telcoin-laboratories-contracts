//SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// imports
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IQuickswapPool.sol";
import "../interfaces/ISource.sol";

/**
 * @title QuickswapAdaptor
 * @author Amir M. Shirif
 * @notice A Telcoin Laboratories Contract
 * @notice A contract to calculate the voting weight based on Telcoin held by an address, considering both direct balance and equivalent in specified sources.
 */
contract QuickswapAdaptor is ISource, IERC165 {
    // Reference to the Telcoin token contract
    IERC20 public immutable TELCOIN;
    // Address of liquidity pool
    IQuickswapPool public immutable _pool;

    // Constructor initializes the BalancerAdaptor contract with necessary contract references
    constructor(IERC20 telcoin, IQuickswapPool pool_) {
        // makes sure no zero values are passed in
        require(
            address(telcoin) != address(0) && address(pool_) != address(0),
            "QuickswapAdaptor: cannot initialize to zero"
        );

        // assign values to immutable state
        TELCOIN = telcoin;
        _pool = pool_;
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

        // Return the voter's share of Telcoin in the pool
        return
            ((_pool.balanceOf(voter) * TELCOIN.balanceOf(address(_pool))) /
                _pool.totalSupply()) * 2;
    }
}

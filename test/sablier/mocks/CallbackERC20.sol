// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenReceiver} from "../interfaces/ITokenReceiver.sol";

/// @title CallbackERC20
/// @notice ERC-20 with an ERC-777-style `tokensReceived` hook. After every successful balance
///         update the contract calls `ITokenReceiver(to).onTokenReceived(from, amount)` if the
///         recipient has the hook enabled and is a contract. Used by the CouncilMember
///         reentrancy tests to open a callback window during the safeTransfer inside burn /
///         transferFrom and prove the reentrancy invariant.
contract CallbackERC20 is IERC20 {
    string public name = "CallbackTelcoin";
    string public symbol = "cTEL";
    uint8 public decimals = 2;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(address => bool) public hookEnabled;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function enableHook(address addr) external {
        hookEnabled[addr] = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        // ERC-777-style callback AFTER balance update
        if (hookEnabled[to] && to.code.length > 0) {
            ITokenReceiver(to).onTokenReceived(msg.sender, amount);
        }
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] < type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        if (hookEnabled[to] && to.code.length > 0) {
            ITokenReceiver(to).onTokenReceived(from, amount);
        }
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

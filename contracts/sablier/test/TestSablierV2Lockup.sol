//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "../interfaces/ISablierV2Lockup.sol";

//TESTING ONLY
contract TestSablierV2Lockup is ISablierV2Lockup {
    IERC20 public _token;
    uint256 public lastBlock;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function withdrawMax(
        uint256,
        address
    ) external override returns (uint128 withdrawnAmount) {
        if (lastBlock != block.timestamp) {
            _token.transfer(msg.sender, 100);
            lastBlock = block.timestamp;
            return 100;
        }
        return 0;
    }
}

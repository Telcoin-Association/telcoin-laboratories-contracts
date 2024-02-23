//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPRBProxy} from "../interfaces/IPRBProxy.sol";

//TESTING ONLY
contract TestProxy is IPRBProxy {
    IERC20 public _token;
    uint256 public lastBlock;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function execute(
        address,
        bytes calldata
    ) external payable override returns (bytes memory response) {
        if (lastBlock != block.timestamp) {
            _token.transfer(msg.sender, 100);
            lastBlock = block.timestamp;
        }
        response = "";
    }
}

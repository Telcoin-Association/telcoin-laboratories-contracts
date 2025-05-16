// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISource} from "../../snapshot/interfaces/ISource.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract TestSource is ISource, IERC165 {
    mapping(address => uint256) public balances;

    function setBalance(address user, uint256 amount) external {
        balances[user] = amount;
    }

    function balanceOf(address user) external view override returns (uint256) {
        return balances[user];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public pure override returns (bool) {
        return interfaceId == type(ISource).interfaceId;
    }

    function getISourceInterfaceId() external pure returns (bytes4) {
        return type(ISource).interfaceId;
    }
}

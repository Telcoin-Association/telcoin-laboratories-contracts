// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ISource} from "../interfaces/ISource.sol";
import {IPositionRegistry} from "../../telx/interfaces/IPositionRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract UniswapAdaptor is ISource, IERC165 {
    IPositionRegistry public immutable registry;

    constructor(IPositionRegistry _registry) {
        registry = _registry;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(ISource).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function balanceOf(
        address voter
    ) external view override returns (uint256 totalVotingWeight) {
        uint256[] memory positionIds = registry.getSubscribedTokenIdsByOwner(voter);

        for (uint256 i = 0; i < positionIds.length; i++) {
            totalVotingWeight += registry.computeVotingWeight(positionIds[i]);
        }
    }
}

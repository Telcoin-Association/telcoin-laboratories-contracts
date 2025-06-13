// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ISource} from "../interfaces/ISource.sol";
import {IPositionRegistry} from "../../telx/interfaces/IPositionRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

//FOR TESTING ONLY
contract MockUniswapAdaptor is ISource, IERC165 {
    IPositionRegistry public immutable registry;
    IPoolManager public immutable poolManager;

    constructor(IPositionRegistry _registry, IPoolManager _poolManager) {
        registry = _registry;
        poolManager = _poolManager;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(ISource).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function testGetAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1) {
        return
            _getAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );
    }

    function balanceOf(
        address voter
    ) external view override returns (uint256 totalVotingWeight) {
        IPositionRegistry.Position[] memory positions = registry
            .getAllActivePositions();

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].provider != voter) continue;
            uint128 liquidity = positions[i].liquidity;
            if (liquidity == 0) continue;

            PoolId poolId = positions[i].poolId;
            (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
                poolManager,
                poolId
            );

            uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(
                positions[i].tickLower
            );
            uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(
                positions[i].tickUpper
            );

            (uint256 amount0, uint256 amount1) = _getAmountsForLiquidity(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );

            uint256 priceX96 = FullMath.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtPriceX96),
                2 ** 96
            );

            uint256 amount1InTEL = FullMath.mulDiv(amount1, 1 << 96, priceX96);

            totalVotingWeight += amount0 + amount1InTEL;
        }
    }

    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            uint256 intermediate = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                sqrtPriceBX96
            );
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceAX96);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint256 intermediate = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                sqrtPriceBX96
            );
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceAX96);
            amount1 = FullMath.mulDiv(
                liquidity,
                sqrtPriceX96 - sqrtPriceAX96,
                FixedPoint96.Q96
            );
        } else {
            amount1 = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                FixedPoint96.Q96
            );
        }
    }
}

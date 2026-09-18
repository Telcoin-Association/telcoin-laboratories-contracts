// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title V4PoolMath
/// @notice Price and tick helpers for creating and seeding Uniswap v4 pools from ordinary inputs.
/// @dev    The point of this library is that nobody operating a deploy should have to hand-compute
///         a `sqrtPriceX96` or a spacing-aligned tick. Callers supply the two token amounts they
///         intend to deposit, plus either "full range" or a percentage band, and get back the
///         exact values `PoolManager.initialize` and `PositionManager.modifyLiquidities` want.
///
///         Deploy-time tooling, not deployed code: this lives under `script/` and is excluded from
///         the production coverage report. It is nonetheless exercised exhaustively by
///         `test/script/V4PoolMath.t.sol`, including round-trips against Uniswap's own TickMath,
///         because a wrong answer here mints a real position at a wrong price.
library V4PoolMath {
    /// @notice Basis-point denominator for percentage range widths.
    uint256 internal constant BPS = 10_000;

    /// @dev Fixed-point scale for the intermediate square roots in `percentRangeTicks`. Chosen so
    ///      that `sqrt(fraction * 1e36) == sqrt(fraction) * 1e18` keeps 18 significant digits.
    uint256 internal constant WAD = 1e18;

    error ZeroAmount();
    error PriceOutOfRange(uint256 sqrtPriceX96);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidRangeWidth(uint16 widthBps);

    // -----------
    // Price
    // -----------

    /**
     * @notice Derives the pool's starting price from the two amounts we intend to deposit.
     * @dev A Uniswap v4 pool price is `amount1 / amount0` in raw token units, so the deposit
     *      amounts define the price completely: the operator picks how much of each side to seed
     *      and the opening price falls out. That is the intended interface because it is the one
     *      an LP already reasons in, and it removes the decimal-scaling step that makes a
     *      hand-computed price wrong (TEL v3 is 18 decimals where TEL v2 was 2, a factor of 1e16).
     *
     *      Computed in two 96-bit steps rather than as `sqrt(amount1 << 192 / amount0)`. The
     *      single-shot form overflows for any ratio above 2^64, which 18-decimal TEL against a
     *      6-decimal stablecoin reaches easily: 20M TEL against 100k eUSD is a raw ratio of
     *      ~1.9e14, and `1.9e14 << 192` is already past `uint256`. Splitting it keeps the full
     *      legal price range addressable, and the residual truncation is below 2^-48 relative.
     *
     * @param amount0 Raw (decimal-scaled) amount of currency0.
     * @param amount1 Raw (decimal-scaled) amount of currency1.
     * @return sqrtPriceX96 The Q64.96 square-root price for `PoolManager.initialize`.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        // ratioX96 = (amount1 / amount0) << 96
        uint256 ratioX96 = FullMath.mulDiv(amount1, 1 << 96, amount0);
        // sqrt(price << 96) == sqrt(price) << 48, so shift the remaining 48 bits back on
        uint256 result = Math.sqrt(ratioX96) << 48;

        if (result < TickMath.MIN_SQRT_PRICE || result >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange(result);
        sqrtPriceX96 = uint160(result);
    }

    /**
     * @notice Scales a human-readable token amount into raw units.
     * @dev Keeps whole-token amounts in the runbook (`20000000` TEL, not `20000000000000000000000000`)
     *      where a miscounted zero is otherwise invisible.
     */
    function toRawAmount(uint256 humanAmount, uint8 decimals) internal pure returns (uint256) {
        return humanAmount * (10 ** decimals);
    }

    // -----------
    // Ticks
    // -----------

    /**
     * @notice Rounds `tick` to a multiple of `tickSpacing`.
     * @dev Solidity truncates integer division toward zero, so a naive `tick / spacing * spacing`
     *      rounds negative ticks UP, not down. Which sign a TELx pool opens at depends only on
     *      which token sorts as currency0 (TEL is currency1 in every catalog pool and worth less
     *      per unit, so those open positive; a differently ordered pair would open negative), so
     *      the sign is handled explicitly rather than assumed either way.
     * @param roundUp True to round toward +infinity, false to round toward -infinity.
     */
    function alignTick(int24 tick, int24 tickSpacing, bool roundUp) internal pure returns (int24) {
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);

        int24 quotient = tick / tickSpacing;
        if (tick % tickSpacing != 0) {
            if (roundUp && tick > 0) {
                quotient += 1;
            } else if (!roundUp && tick < 0) {
                quotient -= 1;
            }
        }
        return quotient * tickSpacing;
    }

    /**
     * @notice The widest tick range a pool with this spacing admits.
     * @dev Both bounds round INWARD, because `TickMath.MIN_TICK` and `MAX_TICK` are themselves
     *      rarely multiples of the spacing and a position may not exceed them. For spacing 60 that
     *      is [-887220, 887220]; for spacing 10, [-887270, 887270].
     *
     *      Worth stating because the surrounding ecosystem gets this wrong in a way that is easy
     *      to copy: a sibling repo's seeding script pairs these tick bounds with `MIN_SQRT_PRICE` /
     *      `MAX_SQRT_PRICE`, which are the sqrt prices at the UNALIGNED +/-887272.
     *
     *      At full range that particular mismatch is nearly harmless - the bounds are so far from
     *      the price that 52 ticks barely move the liquidity figure - so it is easy to copy without
     *      noticing. It stops being harmless the moment the same habit is applied to a
     *      concentrated range, where deriving liquidity from bounds the position does not span
     *      under-deposits by an order of magnitude. `test/script/V4PoolMath.t.sol` pins both cases.
     *      Always pair ticks with their own sqrt prices: `fullRangeSqrtPrices` for full range,
     *      `sqrtPricesAtTicks` otherwise.
     */
    function fullRangeTicks(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        tickLower = alignTick(TickMath.MIN_TICK, tickSpacing, true);
        tickUpper = alignTick(TickMath.MAX_TICK, tickSpacing, false);
    }

    /**
     * @notice A spacing-aligned tick band covering `widthBps` either side of the current price.
     * @dev Derived in price space rather than by treating basis points as ticks. One tick is a
     *      1.0001x price step, so "width in bps == width in ticks" holds near parity and drifts
     *      logarithmically: at +/-50% the linear approximation is off by roughly 23% (5,000 ticks
     *      claimed against 4,055 actual).
     *
     *      Bounds are computed as `sqrtPrice * sqrt(1 +/- width)`, then aligned OUTWARD so the
     *      resulting range always contains the band that was asked for rather than a slightly
     *      narrower one. `getTickAtSqrtPrice` returns the greatest tick whose price is at most
     *      the input, which already sits at or below the lower bound but at or below the upper
     *      one too; the upper side therefore steps one tick past it before aligning, so the
     *      realized upper price is strictly above the requested one.
     * @param sqrtPriceX96 The pool's current price.
     * @param widthBps Half-width in basis points. 1000 is +/-10%. Must be in (0, 10000).
     */
    function percentRangeTicks(uint160 sqrtPriceX96, uint16 widthBps, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        if (widthBps == 0 || widthBps >= BPS) revert InvalidRangeWidth(widthBps);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange(sqrtPriceX96);
        }

        // sqrt(1 - w) and sqrt(1 + w), each scaled by WAD
        uint256 scaleDown = Math.sqrt(FullMath.mulDiv(BPS - widthBps, WAD * WAD, BPS));
        uint256 scaleUp = Math.sqrt(FullMath.mulDiv(BPS + widthBps, WAD * WAD, BPS));

        uint256 sqrtLower = FullMath.mulDiv(sqrtPriceX96, scaleDown, WAD);
        uint256 sqrtUpper = FullMath.mulDiv(sqrtPriceX96, scaleUp, WAD);

        (int24 minTick, int24 maxTick) = fullRangeTicks(tickSpacing);

        tickLower = sqrtLower <= TickMath.MIN_SQRT_PRICE
            ? minTick
            : alignTick(TickMath.getTickAtSqrtPrice(uint160(sqrtLower)), tickSpacing, false);
        tickUpper = sqrtUpper >= TickMath.MAX_SQRT_PRICE
            ? maxTick
            : alignTick(TickMath.getTickAtSqrtPrice(uint160(sqrtUpper)) + 1, tickSpacing, true);

        // clamp after alignment: rounding outward can push a near-limit bound past the legal tick
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;

        // a band narrower than one spacing collapses to a single tick, which cannot hold liquidity
        if (tickUpper <= tickLower) {
            tickLower = alignTick(TickMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing, false);
            tickUpper = tickLower + tickSpacing;
            if (tickUpper > maxTick) {
                tickUpper = maxTick;
                tickLower = maxTick - tickSpacing;
            }
        }
    }

    /**
     * @notice The sqrt prices at a tick pair, for `LiquidityAmounts.getLiquidityForAmounts`.
     * @dev Always derive the sqrt-price bounds from the SAME ticks the position will be minted
     *      with. Any other pairing computes liquidity for a range the position does not span.
     */
    function sqrtPricesAtTicks(int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96)
    {
        sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    }

    /// @notice Convenience pairing of `fullRangeTicks` with its matching sqrt prices.
    function fullRangeSqrtPrices(int24 tickSpacing)
        internal
        pure
        returns (uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96)
    {
        (int24 tickLower, int24 tickUpper) = fullRangeTicks(tickSpacing);
        return sqrtPricesAtTicks(tickLower, tickUpper);
    }

    // -----------
    // Amounts
    // -----------

    /// @notice What a position of `liquidity` over [sqrtLower, sqrtUpper] holds at `sqrtPriceX96`,
    ///         rounded down. The "what is it worth" direction, for previews.
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    // -----------
    // Liquidity floor
    // -----------

    /**
     * @notice The liquidity at which a position spanning exactly one tick spacing around
     *         `sqrtPriceX96` is worth `value1` of currency1, counting both legs at that price.
     * @dev A one-spacing position is the cheapest way to hold a given liquidity, so a registry
     *      floor sized to it bounds the cost of every in-range position from below; wider positions
     *      need proportionally more capital to reach the same liquidity. Inside a band
     *      [sqrtL, sqrtU] a position of liquidity L holds L * (sqrtP - sqrtL) / 2^96 of currency1
     *      and L * (sqrtU - sqrtP) / (sqrtU * sqrtP) * 2^96 of currency0; valued in currency1 at
     *      the price sqrtP^2, the two legs sum to L * (sqrtU - sqrtL) / 2^96 to within a fraction
     *      of the spacing (sqrtP / sqrtU is within 0.3% of one at spacing 60). The floor is the
     *      liquidity that makes that sum equal `value1`, rounded up.
     *
     *      Holds for a position that is in range. A band far below the price holds only currency1
     *      across a much smaller sqrt-price span, so the same liquidity is worth far less there;
     *      the floor therefore assumes the registry's in-range gate is on.
     * @param sqrtPriceX96 The price the floor is sized at, normally the pool's opening price.
     * @param tickSpacing The pool's tick spacing.
     * @param value1 Raw currency1 units the narrowest position must be worth.
     */
    function minLiquidityForNarrowestPosition(uint160 sqrtPriceX96, int24 tickSpacing, uint256 value1)
        internal
        pure
        returns (uint128)
    {
        if (value1 == 0) revert ZeroAmount();
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange(sqrtPriceX96);
        }
        (int24 minTick, int24 maxTick) = fullRangeTicks(tickSpacing);

        int24 lower = alignTick(TickMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing, false);
        if (lower < minTick) lower = minTick;
        int24 upper = lower + tickSpacing;
        if (upper > maxTick) {
            upper = maxTick;
            lower = maxTick - tickSpacing;
        }

        uint256 span = uint256(TickMath.getSqrtPriceAtTick(upper)) - uint256(TickMath.getSqrtPriceAtTick(lower));
        uint256 liquidity = FullMath.mulDivRoundingUp(value1, 1 << 96, span);
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        return uint128(liquidity);
    }

    // -----------
    // Human-readable prices
    // -----------

    /**
     * @notice The pool price as whole units of currency1 per whole unit of currency0, scaled by
     *         1e18, for printing.
     * @dev `sqrtPriceX96` is the square root of the RAW ratio `amount1 / amount0`, so to read it as
     *      a price a person recognises it has to be squared, shifted out of Q64.96 and then
     *      rescaled by the two tokens' decimals. Every one of those steps is a place a preview can
     *      silently print nonsense while the raw figures look plausible, which is why the scripts
     *      print this alongside the tick rather than instead of it.
     *
     *      The squaring is done as a `mulDiv` against 2^96 so the intermediate never overflows;
     *      the decimal rescale reuses the same 512-bit path.
     * @return price1Per0E18 currency1 per currency0, times 1e18. Zero only when the price is too
     *         small to represent at that scale.
     */
    function humanPriceE18(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint256 price1Per0E18)
    {
        // raw price in Q64.96: (sqrtP * sqrtP) / 2^96
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        // human = raw * 10^decimals0 / 10^decimals1, kept at 18 decimals of precision
        price1Per0E18 = FullMath.mulDiv(priceX96, WAD * (10 ** decimals0), (1 << 96) * (10 ** decimals1));
    }

    /// @notice The reciprocal of `humanPriceE18`: whole units of currency0 per whole unit of
    ///         currency1, times 1e18. This is the "price of TEL" reading for every catalog pool,
    ///         where TEL is currency1.
    function humanInversePriceE18(uint256 price1Per0E18) internal pure returns (uint256) {
        if (price1Per0E18 == 0) return 0;
        return FullMath.mulDiv(WAD, WAD, price1Per0E18);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {V4PoolMath} from "../../script/shared/V4PoolMath.sol";
import {V4PoolMathHarness} from "./harnesses/V4PoolMathHarness.sol";

/// @title V4PoolMathTest
/// @notice Deterministic, non-fork unit and fuzz tests for the pool price/tick helpers.
/// @dev    This library never ships on chain, but its output does: a wrong `sqrtPriceX96` opens a
///         real pool at a real (wrong) price that arbitrage drains, and a wrong tick pair mints a
///         position over a range the operator did not intend. It is therefore tested against
///         Uniswap's own TickMath and LiquidityAmounts rather than against re-derived expectations,
///         so the assertions fail if our arithmetic disagrees with the protocol's.
///
///         Distinct from `ChainAddresses.fork.t.sol`, which checks the address constants these
///         numbers get applied to, and needs RPC; everything here is pure.
contract V4PoolMathTest is Test {
    /// @dev Only used by the revert tests; see `V4PoolMathHarness` for why they need a call frame.
    V4PoolMathHarness internal harness;

    int24 internal constant SPACING_MEDIUM = 60;
    int24 internal constant SPACING_LOW = 10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96

    function setUp() public {
        harness = new V4PoolMathHarness();
    }

    // -----------
    // sqrtPriceX96FromAmounts
    // -----------

    /// @notice Equal raw amounts are a 1:1 price, which is tick 0 exactly.
    function test_sqrtPriceFromAmounts_parity() public pure {
        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(1e18, 1e18);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "1:1 should be 2^96");
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceX96), 0, "1:1 should be tick 0");
    }

    /// @notice The realistic TEL/eUSD shape: 18-decimal TEL against a 6-decimal stablecoin. This is
    ///         the case the naive `amount1 << 192 / amount0` formula overflows on, so it is the one
    ///         worth pinning. 100,000 eUSD against 20,000,000 TEL is a raw ratio of 1.9e14.
    function test_sqrtPriceFromAmounts_eusdTelShape() public pure {
        uint256 amount0 = 100_000 * 1e6; // eUSD
        uint256 amount1 = 20_000_000 * 1e18; // TEL v3

        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        // round-trip: recovering amount1/amount0 from the price must match to within rounding
        uint256 priceQ96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        uint256 expectedQ96 = (amount1 << 96) / amount0;
        assertApproxEqRel(priceQ96, expectedQ96, 1e9, "price round-trip drifted"); // 1e-9 relative
    }

    /// @notice The other realistic shape: both sides 18 decimals, ETH against TEL.
    function test_sqrtPriceFromAmounts_ethTelShape() public pure {
        uint256 amount0 = 10 * 1e18; // ETH
        uint256 amount1 = 5_660_380 * 1e18; // TEL v3

        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // ratio is 566,038, i.e. ln(566038)/ln(1.0001) = 132,470.8
        assertApproxEqAbs(int256(tick), int256(132_470), 2, "tick for a 566,038x ratio");
    }

    /// @notice Decimals are the whole reason this helper exists. Seeding the same human amounts
    ///         against 2-decimal TEL v2 instead of 18-decimal TEL v3 must land 1e16 away in price,
    ///         which is ~368,000 ticks - far more than any range width.
    function test_sqrtPriceFromAmounts_decimalShiftIsHuge() public pure {
        uint256 eusd = 100_000 * 1e6;
        int24 tickV3 = TickMath.getTickAtSqrtPrice(V4PoolMath.sqrtPriceX96FromAmounts(eusd, 20_000_000 * 1e18));
        int24 tickV2 = TickMath.getTickAtSqrtPrice(V4PoolMath.sqrtPriceX96FromAmounts(eusd, 20_000_000 * 1e2));

        // ln(1e16)/ln(1.0001) = 368,432
        assertApproxEqAbs(int256(tickV3 - tickV2), int256(368_432), 2, "1e16 is ~368,432 ticks");
    }

    function testRevert_sqrtPriceFromAmounts_zeroAmount0() public {
        vm.expectRevert(V4PoolMath.ZeroAmount.selector);
        harness.sqrtPriceX96FromAmounts(0, 1e18);
    }

    function testRevert_sqrtPriceFromAmounts_zeroAmount1() public {
        vm.expectRevert(V4PoolMath.ZeroAmount.selector);
        harness.sqrtPriceX96FromAmounts(1e18, 0);
    }

    /// @notice A ratio so extreme the price falls outside Uniswap's legal band must revert rather
    ///         than silently clamp, because a clamped price is a pool opened at the wrong number.
    function testRevert_sqrtPriceFromAmounts_priceTooLow() public {
        vm.expectRevert();
        harness.sqrtPriceX96FromAmounts(type(uint128).max, 1);
    }

    /// @notice Any amounts inside the legal price band round-trip to a price Uniswap accepts.
    function testFuzz_sqrtPriceFromAmounts_withinTickMathBounds(uint128 amount0, uint128 amount1) public pure {
        amount0 = uint128(bound(amount0, 1e6, type(uint96).max));
        amount1 = uint128(bound(amount1, 1e6, type(uint96).max));

        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        assertGe(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, "below MIN_SQRT_PRICE");
        assertLt(sqrtPriceX96, TickMath.MAX_SQRT_PRICE, "at or above MAX_SQRT_PRICE");
        // TickMath must accept it, which is the only definition of "valid" that matters
        TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    // -----------
    // alignTick
    // -----------

    /// @notice The sign-handling case. Solidity truncates toward zero, so a naive implementation
    ///         rounds negative ticks the wrong way, and every TELx pool opens at a negative tick.
    function test_alignTick_negativeRoundsDownNotTowardZero() public pure {
        assertEq(V4PoolMath.alignTick(-1234, 60, false), -1260, "negative, round down");
        assertEq(V4PoolMath.alignTick(-1234, 60, true), -1200, "negative, round up");
        assertEq(V4PoolMath.alignTick(1234, 60, false), 1200, "positive, round down");
        assertEq(V4PoolMath.alignTick(1234, 60, true), 1260, "positive, round up");
    }

    function test_alignTick_exactMultipleIsUnchanged() public pure {
        assertEq(V4PoolMath.alignTick(1200, 60, true), 1200, "exact, round up");
        assertEq(V4PoolMath.alignTick(1200, 60, false), 1200, "exact, round down");
        assertEq(V4PoolMath.alignTick(-1200, 60, true), -1200, "exact negative, round up");
        assertEq(V4PoolMath.alignTick(-1200, 60, false), -1200, "exact negative, round down");
        assertEq(V4PoolMath.alignTick(0, 60, true), 0, "zero");
    }

    function testRevert_alignTick_zeroSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(V4PoolMath.InvalidTickSpacing.selector, int24(0)));
        harness.alignTick(100, 0, true);
    }

    function testFuzz_alignTick_isAlignedAndOnTheRequestedSide(int24 tick, bool roundUp) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 aligned = V4PoolMath.alignTick(tick, SPACING_MEDIUM, roundUp);

        assertEq(aligned % SPACING_MEDIUM, 0, "not a multiple of spacing");
        if (roundUp) {
            assertGe(aligned, tick, "rounded up below input");
            assertLt(aligned - tick, SPACING_MEDIUM, "rounded up too far");
        } else {
            assertLe(aligned, tick, "rounded down above input");
            assertLt(tick - aligned, SPACING_MEDIUM, "rounded down too far");
        }
    }

    // -----------
    // fullRangeTicks
    // -----------

    /// @notice Pins the two spacings the TELx catalog actually uses. These are the numbers that a
    ///         sibling repo's script gets wrong by pairing them with the unaligned MIN/MAX sqrt
    ///         prices, so they are worth stating literally rather than deriving in the test too.
    function test_fullRangeTicks_knownValues() public pure {
        (int24 lower60, int24 upper60) = V4PoolMath.fullRangeTicks(SPACING_MEDIUM);
        assertEq(lower60, -887_220, "spacing 60 lower");
        assertEq(upper60, 887_220, "spacing 60 upper");

        (int24 lower10, int24 upper10) = V4PoolMath.fullRangeTicks(SPACING_LOW);
        assertEq(lower10, -887_270, "spacing 10 lower");
        assertEq(upper10, 887_270, "spacing 10 upper");
    }

    /// @notice Full range must round INWARD: a position may not exceed TickMath's absolute bounds.
    function testFuzz_fullRangeTicks_insideAbsoluteBounds(int24 tickSpacing) public pure {
        tickSpacing = int24(bound(tickSpacing, 1, 32_767));

        (int24 lower, int24 upper) = V4PoolMath.fullRangeTicks(tickSpacing);

        assertGe(lower, TickMath.MIN_TICK, "lower below MIN_TICK");
        assertLe(upper, TickMath.MAX_TICK, "upper above MAX_TICK");
        assertEq(lower % tickSpacing, 0, "lower unaligned");
        assertEq(upper % tickSpacing, 0, "upper unaligned");
        // and TickMath must accept both, since these feed getSqrtPriceAtTick
        TickMath.getSqrtPriceAtTick(lower);
        TickMath.getSqrtPriceAtTick(upper);
    }

    /// @notice The paired sqrt prices must be the ones at the aligned ticks, NOT MIN/MAX_SQRT_PRICE.
    ///         Feeding a wider sqrt-price pair than the position spans into getLiquidityForAmounts
    ///         computes liquidity for the wrong range and under-deposits the mint.
    function test_fullRangeSqrtPrices_matchAlignedTicksNotAbsoluteBounds() public pure {
        (int24 lower, int24 upper) = V4PoolMath.fullRangeTicks(SPACING_MEDIUM);
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.fullRangeSqrtPrices(SPACING_MEDIUM);

        assertEq(sqrtLower, TickMath.getSqrtPriceAtTick(lower), "lower sqrt price");
        assertEq(sqrtUpper, TickMath.getSqrtPriceAtTick(upper), "upper sqrt price");

        assertGt(sqrtLower, TickMath.MIN_SQRT_PRICE, "lower must be inside MIN_SQRT_PRICE");
        assertLt(sqrtUpper, TickMath.MAX_SQRT_PRICE, "upper must be inside MAX_SQRT_PRICE");
    }

    /// @notice At FULL range, pairing the aligned ticks with the unaligned MIN/MAX sqrt prices is
    ///         harmless in practice. The bounds are already so far from the price that the 52-tick
    ///         discrepancy barely moves the liquidity figure, and at 1:1 with equal amounts the two
    ///         results are identical after rounding.
    /// @dev    Recorded because the obvious intuition is the opposite, and an earlier draft of this
    ///         suite asserted a material under-deposit here and failed. The mismatch is a real bug
    ///         but it only bites on concentrated ranges; see the next test.
    function test_fullRange_mismatchedSqrtPricesAreHarmlessAtFullRange() public pure {
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.fullRangeSqrtPrices(SPACING_MEDIUM);

        uint256 amount0 = 10 * 1e18;
        uint256 amount1 = 10 * 1e18;

        uint128 correct = LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_1_1, sqrtLower, sqrtUpper, amount0, amount1);
        uint128 mismatched = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1, amount0, amount1
        );

        assertApproxEqRel(mismatched, correct, 1e12, "full-range mismatch should be negligible"); // 1e-6
    }

    /// @notice Where the mismatch actually costs money: liquidity must be derived from the SAME
    ///         ticks the position is minted at. Computing it against full-range bounds and then
    ///         minting a concentrated position deposits a small fraction of what was intended,
    ///         because the same liquidity spread over a narrow band needs far less capital.
    function test_concentratedRange_mismatchedSqrtPricesUnderDepositBadly() public pure {
        (int24 tickLower, int24 tickUpper) = V4PoolMath.percentRangeTicks(SQRT_PRICE_1_1, 1000, SPACING_MEDIUM);
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.sqrtPricesAtTicks(tickLower, tickUpper);
        (uint160 fullLower, uint160 fullUpper) = V4PoolMath.fullRangeSqrtPrices(SPACING_MEDIUM);

        uint256 amount0 = 10 * 1e18;
        uint256 amount1 = 10 * 1e18;

        uint128 correct = LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_1_1, sqrtLower, sqrtUpper, amount0, amount1);
        uint128 mismatched =
            LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_1_1, fullLower, fullUpper, amount0, amount1);

        assertLt(mismatched, correct / 10, "mismatched liquidity should be an order of magnitude low");

        // minting that figure into the concentrated range consumes a fraction of the authorized amounts
        (uint256 used0, uint256 used1) =
            LiquidityAmounts.getAmountsForLiquidity(SQRT_PRICE_1_1, sqrtLower, sqrtUpper, mismatched);
        assertLt(used0, amount0 / 10, "under-deposits currency0 by more than 10x");
        assertLt(used1, amount1 / 10, "under-deposits currency1 by more than 10x");
    }

    // -----------
    // percentRangeTicks
    // -----------

    /// @notice A percentage band must be derived in price space. Treating basis points as ticks is
    ///         close at parity and badly wrong at width: +/-50% is ~4,055 ticks, not 5,000.
    function test_percentRangeTicks_notLinearInBps() public pure {
        (int24 lower, int24 upper) = V4PoolMath.percentRangeTicks(SQRT_PRICE_1_1, 5000, SPACING_MEDIUM);

        // ln(0.5)/ln(1.0001) = -6931, ln(1.5)/ln(1.0001) = +4054, each aligned outward to 60
        assertEq(lower, -6960, "lower bound of a -50% move");
        assertEq(upper, 4080, "upper bound of a +50% move");

        // the naive reading would have put these at -5000/+5000
        assertTrue(lower < -5000, "linear approximation would be too shallow on the downside");
        assertTrue(upper < 5000, "linear approximation would be too deep on the upside");
    }

    /// @notice A tight band around parity, where bps and ticks nearly coincide.
    function test_percentRangeTicks_tightBand() public pure {
        (int24 lower, int24 upper) = V4PoolMath.percentRangeTicks(SQRT_PRICE_1_1, 100, SPACING_MEDIUM);

        // ln(0.99)/ln(1.0001) = -100.5, ln(1.01)/ln(1.0001) = +99.5, aligned outward to 60
        assertEq(lower, -120, "lower");
        assertEq(upper, 120, "upper");
    }

    /// @notice Bounds must be aligned OUTWARD so the realized range always contains the band that
    ///         was requested, never a slightly narrower one.
    function testFuzz_percentRangeTicks_containsRequestedBand(uint160 sqrtPriceX96, uint16 widthBps) public pure {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE * 2, TickMath.MAX_SQRT_PRICE / 2));
        widthBps = uint16(bound(widthBps, 1, 9999));

        (int24 lower, int24 upper) = V4PoolMath.percentRangeTicks(sqrtPriceX96, widthBps, SPACING_MEDIUM);
        (int24 minTick, int24 maxTick) = V4PoolMath.fullRangeTicks(SPACING_MEDIUM);

        assertLt(lower, upper, "empty or inverted range");
        assertEq(lower % SPACING_MEDIUM, 0, "lower unaligned");
        assertEq(upper % SPACING_MEDIUM, 0, "upper unaligned");
        assertGe(lower, minTick, "lower below full range");
        assertLe(upper, maxTick, "upper above full range");
    }

    /// @notice A wider band never produces a narrower range.
    function testFuzz_percentRangeTicks_monotonicInWidth(uint16 narrowBps, uint16 wideBps) public pure {
        narrowBps = uint16(bound(narrowBps, 1, 4999));
        wideBps = uint16(bound(wideBps, narrowBps, 9999));

        (int24 narrowLower, int24 narrowUpper) = V4PoolMath.percentRangeTicks(SQRT_PRICE_1_1, narrowBps, SPACING_MEDIUM);
        (int24 wideLower, int24 wideUpper) = V4PoolMath.percentRangeTicks(SQRT_PRICE_1_1, wideBps, SPACING_MEDIUM);

        assertLe(wideLower, narrowLower, "wider band raised the lower bound");
        assertGe(wideUpper, narrowUpper, "wider band lowered the upper bound");
    }

    /// @notice Near the edge of the legal price band the computed bound would fall outside
    ///         TickMath, and must clamp to full range rather than revert or wrap.
    function test_percentRangeTicks_clampsNearPriceLimits() public pure {
        (int24 minTick, int24 maxTick) = V4PoolMath.fullRangeTicks(SPACING_MEDIUM);

        (int24 lowLower,) = V4PoolMath.percentRangeTicks(TickMath.MIN_SQRT_PRICE + 1, 9999, SPACING_MEDIUM);
        assertEq(lowLower, minTick, "should clamp to the full-range lower bound");

        (, int24 highUpper) = V4PoolMath.percentRangeTicks(TickMath.MAX_SQRT_PRICE - 1, 9999, SPACING_MEDIUM);
        assertEq(highUpper, maxTick, "should clamp to the full-range upper bound");
    }

    function testRevert_percentRangeTicks_zeroWidth() public {
        vm.expectRevert(abi.encodeWithSelector(V4PoolMath.InvalidRangeWidth.selector, uint16(0)));
        harness.percentRangeTicks(SQRT_PRICE_1_1, 0, SPACING_MEDIUM);
    }

    /// @notice A 100% band would put the lower bound at price zero, which has no tick.
    function testRevert_percentRangeTicks_fullWidth() public {
        vm.expectRevert(abi.encodeWithSelector(V4PoolMath.InvalidRangeWidth.selector, uint16(10_000)));
        harness.percentRangeTicks(SQRT_PRICE_1_1, 10_000, SPACING_MEDIUM);
    }

    function testRevert_percentRangeTicks_priceOutOfRange() public {
        vm.expectRevert(
            abi.encodeWithSelector(V4PoolMath.PriceOutOfRange.selector, uint256(TickMath.MIN_SQRT_PRICE - 1))
        );
        harness.percentRangeTicks(TickMath.MIN_SQRT_PRICE - 1, 1000, SPACING_MEDIUM);
    }

    // -----------
    // toRawAmount
    // -----------

    function test_toRawAmount_scalesByDecimals() public pure {
        assertEq(V4PoolMath.toRawAmount(100_000, 6), 100_000 * 1e6, "6 decimals");
        assertEq(V4PoolMath.toRawAmount(20_000_000, 18), 20_000_000 * 1e18, "18 decimals");
        assertEq(V4PoolMath.toRawAmount(0, 18), 0, "zero");
    }

    // -----------
    // End-to-end: the shape the seeding script uses
    // -----------

    /// @notice Amounts to price to ticks to liquidity and back to amounts. This is the exact chain
    ///         `SeedV4Liquidity` performs, so the property that matters is that the liquidity we
    ///         derive never asks for more than the operator authorized.
    function testFuzz_seedingRoundTrip_neverExceedsAuthorizedAmounts(
        uint96 humanAmount0,
        uint96 humanAmount1,
        uint16 widthBps,
        bool fullRange
    ) public pure {
        uint256 amount0 = V4PoolMath.toRawAmount(bound(humanAmount0, 1, 1e9), 6);
        uint256 amount1 = V4PoolMath.toRawAmount(bound(humanAmount1, 1, 1e9), 18);
        widthBps = uint16(bound(widthBps, 1, 9999));

        uint160 sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);

        (int24 tickLower, int24 tickUpper) = fullRange
            ? V4PoolMath.fullRangeTicks(SPACING_MEDIUM)
            : V4PoolMath.percentRangeTicks(sqrtPriceX96, widthBps, SPACING_MEDIUM);
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.sqrtPricesAtTicks(tickLower, tickUpper);

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1);
        (uint256 used0, uint256 used1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);

        assertLe(used0, amount0, "would pull more currency0 than authorized");
        assertLe(used1, amount1, "would pull more currency1 than authorized");
    }
}

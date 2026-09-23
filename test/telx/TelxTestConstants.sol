// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TelxTestConstants
/// @notice Shared fixtures for the TELx unit-test suite (`PositionRegistry.t.sol`,
///         `TELxSubscriber.t.sol`). Centralized so a single edit updates every consumer and
///         reviewers can audit the chosen values in one place, per the INVARIANTS.md
///         test-structure convention. Test files import these rather than redeclaring literals.
library TelxTestConstants {
    /// @notice Tick spacing of the mock test pool.
    int24 internal constant TICK_SPACING = 60;
    /// @notice Default test position range, straddling tick 0.
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    /// @notice Default liquidity for a test position - comfortably above the subscription threshold.
    uint128 internal constant DEFAULT_LIQUIDITY = 10_000;
    /// @notice Total pool liquidity set on the mock StateView. Threshold = POOL_LIQUIDITY / 10_000 = 100.
    uint128 internal constant POOL_LIQUIDITY = 1_000_000;
    /// @notice sqrtPriceX96 for a 1:1 price (tick 0): 2^96.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
}

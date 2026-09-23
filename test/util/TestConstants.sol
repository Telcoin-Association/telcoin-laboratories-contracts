// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TestConstants
/// @notice Shared constants used across the fork test suite. Centralized here
///         so a single edit updates every fork test at once, and so reviewers
///         can audit the chosen values (and the rationale) in one place.
library TestConstants {
    // -------------------
    // POLYGON FORK BLOCKS
    // -------------------

    /// @notice Default Polygon fork block used by deploy-script fork tests
    ///         (`test/script/*.fork.t.sol`) and by
    ///         `CouncilMemberProxyUpgradeFork.t.sol`.
    /// @dev    Chosen because all contracts these tests depend on - TEL
    ///         (`0xdF78...dcc32`), Sablier V2 Lockup (`0x8D87...5f0`), the
    ///         three Balancer TEL pools and their StakingRewards adaptors -
    ///         are deployed and stable at this height. Deploy-script tests
    ///         create their own fresh contracts on top, so they don't need a
    ///         later block; pinning here means every fork test that doesn't
    ///         override sees the same chain state.
    ///
    ///         Overridable per-run via the `FORK_BLOCK_NUMBER` env var.
    uint256 internal constant DEFAULT_POLYGON_FORK_BLOCK = 84_352_545;

    /// @notice Polygon fork block used by the TELx `*.polygon.t.sol` fork tests.
    /// @dev    Later than DEFAULT_POLYGON_FORK_BLOCK because those tests exercise the thin
    ///         PositionRegistry against live Uniswap v4 state: the USDC/eMXN and WETH/TEL pools
    ///         and a recently minted v4 position. Both pools were initialized on-chain after
    ///         block 84.3M, so an earlier fork would make `validPool(...)` return false.
    uint256 internal constant PRODUCTION_STATE_POLYGON_FORK_BLOCK = 85_800_000;
}

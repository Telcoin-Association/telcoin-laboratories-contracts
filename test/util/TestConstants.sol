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
    /// @dev    Chosen because all contracts these tests depend on — TEL
    ///         (`0xdF78...dcc32`), Sablier V2 Lockup (`0x8D87...5f0`), the
    ///         three Balancer TEL pools and their StakingRewards adaptors —
    ///         are deployed and stable at this height. Deploy-script tests
    ///         create their own fresh contracts on top, so they don't need a
    ///         later block; pinning here means every fork test that doesn't
    ///         override sees the same chain state.
    ///
    ///         Overridable per-run via the `FORK_BLOCK_NUMBER` env var.
    uint256 internal constant DEFAULT_POLYGON_FORK_BLOCK = 84_352_545;

    /// @notice Polygon fork block used by `PositionRegistry.polygon.t.sol`.
    /// @dev    Later than DEFAULT_POLYGON_FORK_BLOCK because this file tests
    ///         against the LIVE production PositionRegistry + TELxIncentiveHook
    ///         deployment and their initialized pools (USDC/eMXN and WETH/TEL).
    ///         Those were registered on-chain in mid-production, after block
    ///         84.3M. Using the DEFAULT block would make `validPool(...)`
    ///         return false and the live-state assertions would fail.
    uint256 internal constant PRODUCTION_STATE_POLYGON_FORK_BLOCK = 85_800_000;
}

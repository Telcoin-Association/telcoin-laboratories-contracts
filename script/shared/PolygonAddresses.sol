// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PolygonAddresses
/// @notice Canonical Polygon-mainnet addresses used by deploy scripts and fork tests.
///         These are protocol facts, not per-developer config — they belong in code, not `.env`.
///         Per-environment overrides remain available via `vm.envOr(KEY, PolygonAddresses.X)` in
///         the consuming script when needed (e.g., testnet swaps).
library PolygonAddresses {
    // --- Tokens (publicly known mainnet ERC-20s) ---
    address internal constant TEL = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    // --- Telcoin-deployed tokens (eXYZ stablecoins, etc.) ---
    // FIXME: confirm with the deployment team and replace placeholder before merging if non-zero
    //        is required. Tests fall back to env via `vm.envOr` so unset values are tolerated in
    //        non-prod paths.
    address internal constant EMXN = address(0);

    // --- Telcoin-controlled multisigs ---
    // FIXME: confirm with the deployment team — Polygon SUPPORT_SAFE address.
    address internal constant SUPPORT_SAFE = address(0);

    // --- Uniswap v4 infrastructure (publicly deployed by Uniswap) ---
    // FIXME: confirm against https://docs.uniswap.org/contracts/v4/deployments before relying on
    //        these values in production. Left as placeholders to make a missing check loud.
    address internal constant POOL_MANAGER = address(0);
    address internal constant POSITION_MANAGER = address(0);
    address internal constant UNIVERSAL_ROUTER = address(0);
    address internal constant STATE_VIEW = address(0);
}

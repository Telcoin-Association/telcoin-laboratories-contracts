// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BaseAddresses
/// @notice Canonical Base-mainnet addresses used by deploy scripts and fork tests.
///         See `PolygonAddresses.sol` for the rationale (constants in code, not `.env`).
library BaseAddresses {
    // --- Tokens ---
    // FIXME: confirm with the deployment team — Base TEL address.
    address internal constant TEL = address(0);

    // --- Uniswap v4 infrastructure (publicly deployed by Uniswap) ---
    // FIXME: confirm against https://docs.uniswap.org/contracts/v4/deployments.
    address internal constant POOL_MANAGER = address(0);
    address internal constant POSITION_MANAGER = address(0);
    address internal constant UNIVERSAL_ROUTER = address(0);
    address internal constant STATE_VIEW = address(0);

    // --- Telcoin-controlled multisigs ---
    address internal constant SUPPORT_SAFE = address(0);

    // --- Not applicable on Base (kept for ChainConfig shape parity with Polygon) ---
    address internal constant WETH = address(0);
    address internal constant USDC = address(0);
    address internal constant EMXN = address(0);
}

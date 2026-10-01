// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EthereumConstants
/// @notice Shared Ethereum-mainnet (chain 1) addresses and identifiers used across fork tests.
///         Mirrors `PolygonConstants` so a test that moves between chains only swaps the import.
///         New tests using any of these should import from here rather than redeclaring literals.
library EthereumConstants {
    // ----------
    // Tokens
    // ----------
    /// @notice Legacy TEL. 2 decimals.
    address internal constant TEL_V2 = 0x467Bccd9d29f223BcE8043b84E8C8B282827790F;
    /// @notice TEL v3. 18 decimals. Same address on Ethereum, Polygon and Base.
    address internal constant TEL_V3 = 0x7E13B43065380aCdeC1c2d138c579cbBbafA0731;
    /// @notice Telcoin eUSD. 6 decimals. Same address on Ethereum, Polygon and Base.
    address internal constant EUSD = 0x14913815bCFDE78BAeAd2111F463D038Ac9C2949;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ----------
    // Uniswap v4 infrastructure
    // ----------
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
}

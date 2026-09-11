// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BaseConstants
/// @notice Shared Base-mainnet (chain 8453) addresses and identifiers used across fork tests.
///         Mirrors `PolygonConstants` so a test that moves between chains only swaps the import.
///         New tests using any of these should import from here rather than redeclaring literals.
library BaseConstants {
    // ----------
    // Tokens
    // ----------
    /// @notice Legacy Base TEL. 2 decimals. Backs the pre-migration TELx ETH/TEL pool.
    address internal constant TEL_V2 = 0x09bE1692ca16e06f536F0038fF11D1dA8524aDB1;
    /// @notice TEL v3. 18 decimals. Same address on Ethereum, Polygon and Base.
    address internal constant TEL_V3 = 0x7E13B43065380aCdeC1c2d138c579cbBbafA0731;
    /// @notice Telcoin eUSD. 6 decimals. Same address on Ethereum, Polygon and Base.
    address internal constant EUSD = 0x14913815bCFDE78BAeAd2111F463D038Ac9C2949;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ----------
    // Uniswap v4 infrastructure
    // ----------
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant V4_STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;

    // ----------
    // Legacy TELx pool IDs (TEL v2, pre-migration)
    // ----------
    /// @dev currency0 is native ETH (address(0)), currency1 is TEL_V2, fee 3000, spacing 60.
    bytes32 internal constant TELX_POOL_ID_ETH_TEL =
        0x727b2741ac2b2df8bc9185e1de972661519fc07b156057eeed9b07c50e08829b;
}

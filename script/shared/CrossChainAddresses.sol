// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CrossChainAddresses
/// @notice Addresses that are byte-identical on every chain we deploy to.
/// @dev    Two separate mechanisms land contracts at the same address everywhere, and both are
///         relied on here rather than coincidence:
///           - TEL v3 and the Telcoin stablecoins are deployed through CreateX `deployCreate3`
///             from the Telcoin governance Safe. A CREATE3 address depends only on the factory,
///             the deployer and the salt, never on constructor arguments, so the same salt yields
///             the same address on Ethereum, Polygon and Base.
///           - Permit2 and CreateX are themselves deterministic singletons published at a fixed
///             address across EVM chains.
///
///         The per-chain libraries (`EthereumAddresses`, `PolygonAddresses`, `BaseAddresses`)
///         re-export these so callers keep a single per-chain API, while the literal is written
///         down exactly once and cannot drift between chains.
library CrossChainAddresses {
    // -----------
    // Telcoin tokens (CREATE3, identical on Ethereum / Polygon / Base)
    // -----------

    /// @notice TEL v3. 18 decimals, unlike the 2-decimal legacy TEL it replaces.
    address internal constant TEL_V3 = 0x7E13B43065380aCdeC1c2d138c579cbBbafA0731;

    /// @notice Telcoin Digital Asset Bank eUSD. 6 decimals.
    address internal constant EUSD = 0x14913815bCFDE78BAeAd2111F463D038Ac9C2949;

    /// @notice TEL v2 to v3 migration contract (TokenMigration).
    address internal constant TEL_MIGRATION = 0x2703E00cAE30A7707e4d18C38f8CB6A4a40c2703;

    // -----------
    // Telcoin governance
    // -----------

    /// @notice Telcoin governance Safe. Holds DEFAULT_ADMIN_ROLE on TEL v3 and is the deployer
    ///         Safe for the CREATE3 deployment pipeline shared with the tel-v3 repo.
    address internal constant GOVERNANCE_SAFE = 0x6012dBcb4350Ab297FeB7f96D4d86258062aeB03;

    // -----------
    // Deterministic singletons
    // -----------

    /// @notice Uniswap Permit2.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice CreateX deterministic deployment factory.
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
}

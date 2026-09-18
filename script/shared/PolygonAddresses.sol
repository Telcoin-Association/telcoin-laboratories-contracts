// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainAddresses} from "./CrossChainAddresses.sol";

/// @title PolygonAddresses
/// @notice Canonical Polygon-mainnet (chain 137) addresses used by deploy scripts and fork tests.
///         These are protocol facts, not per-developer config, so they belong in code, not `.env`,
///         and the scripts read them from here with no environment override: a mainnet script
///         that a stray `.env` line could point at a different PositionManager is a script whose
///         preview cannot be trusted.
library PolygonAddresses {
    uint256 internal constant CHAIN_ID = 137;

    // -----------
    // Telcoin tokens
    // -----------

    /// @notice TEL v3, 18 decimals. The token all new TELx pools pair against.
    address internal constant TEL_V3 = CrossChainAddresses.TEL_V3;

    /// @notice Legacy PoS-bridged TEL, 2 decimals. Still the token behind the Balancer pools, the
    ///         Sablier council streams and the legacy TELx v4 pools, so it stays. Never use it in
    ///         TEL v3 pool math: the decimal difference is a factor of 1e16.
    address internal constant TEL_V2 = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;

    /// @notice Telcoin eUSD, 6 decimals.
    address internal constant EUSD = CrossChainAddresses.EUSD;

    /// @notice Telcoin eMXN, 6 decimals. Polygon only.
    address internal constant EMXN = 0x68727e573D21a49c767c3c86A92D9F24bd933c99;

    // -----------
    // Third-party tokens
    // -----------

    /// @notice Polygon has no native ETH, so the TEL/ETH pool pairs against WETH here.
    address internal constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // -----------
    // Uniswap v4 infrastructure
    // -----------

    address internal constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address internal constant POSITION_MANAGER = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;
    address internal constant STATE_VIEW = 0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a;
    address internal constant UNIVERSAL_ROUTER = 0x1095692A6237d83C6a72F3F5eFEdb9A670C49223;
    address internal constant PERMIT2 = CrossChainAddresses.PERMIT2;

    // -----------
    // Telcoin-controlled multisigs
    // -----------

    /// @notice Holds DEFAULT_ADMIN_ROLE on the TELx PositionRegistry.
    address internal constant GOVERNANCE_SAFE = CrossChainAddresses.GOVERNANCE_SAFE;

    /// @notice Holds SUPPORT_ROLE on the registry, for token rescue and nothing else. A 2-of-6 Safe
    ///         whose owner set matches the Base support Safe (`BaseAddresses.SUPPORT_SAFE`), which is how
    ///         the pair was identified: the live registry granted SUPPORT_ROLE to several
    ///         addresses per chain, and only these two are deployed Safes with the same owners.
    address internal constant SUPPORT_SAFE = 0x583D596b0a79C0e83C87851eA9FB1A91e80290B2;
}

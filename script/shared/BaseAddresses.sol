// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainAddresses} from "./CrossChainAddresses.sol";

/// @title BaseAddresses
/// @notice Canonical Base-mainnet (chain 8453) addresses used by deploy scripts and fork tests.
///         See `PolygonAddresses.sol` for the rationale (constants in code, not `.env`).
library BaseAddresses {
    uint256 internal constant CHAIN_ID = 8453;

    // -----------
    // Telcoin tokens
    // -----------

    /// @notice TEL v3, 18 decimals. The token all new TELx pools pair against.
    address internal constant TEL_V3 = CrossChainAddresses.TEL_V3;

    /// @notice Legacy Base TEL, 2 decimals. Backs the existing TELx v4 ETH/TEL pool. Never use it
    ///         in TEL v3 pool math: the decimal difference is a factor of 1e16.
    address internal constant TEL_V2 = 0x09bE1692ca16e06f536F0038fF11D1dA8524aDB1;

    /// @notice Telcoin eUSD, 6 decimals.
    address internal constant EUSD = CrossChainAddresses.EUSD;

    /// @notice eMXN is not deployed on Base. Declared for shape parity with PolygonAddresses.
    address internal constant EMXN = address(0);

    // -----------
    // Third-party tokens
    // -----------

    /// @notice Base has native ETH, so the TEL/ETH pool uses currency0 = address(0) rather than
    ///         this. Kept for routing helpers and shape parity.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // -----------
    // Uniswap v4 infrastructure
    // -----------

    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = CrossChainAddresses.PERMIT2;

    // -----------
    // Telcoin-controlled multisigs
    // -----------

    /// @notice Holds DEFAULT_ADMIN_ROLE on the TELx PositionRegistry.
    address internal constant GOVERNANCE_SAFE = CrossChainAddresses.GOVERNANCE_SAFE;

    /// @notice Holds SUPPORT_ROLE on the registry, for token rescue and nothing else. A 2-of-6 Safe
    ///         whose owner set matches the Polygon support Safe (`PolygonAddresses.SUPPORT_SAFE`).
    /// @dev    Not to be confused with 0x3F00a8CE88C8cf367AD10A5675161e7AFd2472bE, which also holds
    ///         SUPPORT_ROLE on the live Base registry. That address is a Safe on Base with a
    ///         different owner set, and a plain EOA on Polygon, so it is not the cross-chain TELx
    ///         ops multisig and must not be used as one.
    address internal constant SUPPORT_SAFE = 0xE3a465e1460E9987c772c36b91020946BC60Af52;
}

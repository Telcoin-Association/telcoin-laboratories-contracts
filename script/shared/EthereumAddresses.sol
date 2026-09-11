// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainAddresses} from "./CrossChainAddresses.sol";

/// @title EthereumAddresses
/// @notice Canonical Ethereum-mainnet (chain 1) addresses used by deploy scripts and fork tests.
///         These are protocol facts, not per-developer config, so they belong in code, not `.env`.
///         Per-environment overrides remain available via `vm.envOr(KEY, EthereumAddresses.X)` in
///         the consuming script when needed.
library EthereumAddresses {
    uint256 internal constant CHAIN_ID = 1;

    // -----------
    // Telcoin tokens
    // -----------

    /// @notice TEL v3, 18 decimals. The token all new TELx pools pair against.
    address internal constant TEL_V3 = CrossChainAddresses.TEL_V3;

    /// @notice Legacy TEL, 2 decimals. Retained only for migration and legacy-pool tooling.
    ///         Never use this in TEL v3 pool math: the decimal difference is a factor of 1e16.
    address internal constant TEL_V2 = 0x467Bccd9d29f223BcE8043b84E8C8B282827790F;

    /// @notice Telcoin eUSD, 6 decimals.
    address internal constant EUSD = CrossChainAddresses.EUSD;

    // -----------
    // Third-party tokens
    // -----------

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice eMXN is not deployed on Ethereum. Declared for shape parity with PolygonAddresses.
    address internal constant EMXN = address(0);

    // -----------
    // Uniswap v4 infrastructure
    // -----------

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant PERMIT2 = CrossChainAddresses.PERMIT2;

    // -----------
    // Telcoin-controlled multisigs
    // -----------

    /// @notice Holds DEFAULT_ADMIN_ROLE on the TELx PositionRegistry.
    address internal constant GOVERNANCE_SAFE = CrossChainAddresses.GOVERNANCE_SAFE;

    /// @notice Holds SUPPORT_ROLE on the registry and owns the subscriber.
    /// FIXME: Ethereum has no TELx support multisig yet. Polygon and Base both use
    ///        0x3F00a8CE88C8cf367AD10A5675161e7AFd2472bE. Blocks the Ethereum deploy until the
    ///        deployment team supplies one; the deploy script reverts on a zero value rather than
    ///        silently granting SUPPORT_ROLE to address(0).
    address internal constant SUPPORT_SAFE = address(0);
}

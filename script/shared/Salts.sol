// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Salts
/// @notice CREATE3 salts for the TELx contracts deployed through CreateX.
/// @dev    Only the low 11 bytes of each value are used: `SaltMath.guardSalt` rebuilds the salt as
///         [20 bytes deployer Safe][1 byte 0x00][11 bytes suffix]. The zero byte selects CreateX's
///         cross-chain mode, which is what lets the same salt produce the same address on Ethereum,
///         Polygon and Base even though the constructor arguments differ per chain.
///
///         A salt is an address-derivation input, not a label. Never rename a string that has
///         already been used: the name IS the address.
///
///         These are `keccak256` of a descriptive string rather than mined vanity values. The
///         tel-v3 repo mines vanity salts for its user-facing token addresses; the TELx registry
///         and subscriber are contracts that integrations resolve from config rather than type, so
///         a recognisable address buys nothing here.
library Salts {
    /// @notice Thin PositionRegistry deployed for the TEL v3 pool set.
    /// @dev The `_V3` suffix distinguishes this from the live TEL v2 registries, which were
    ///      deployed with plain CREATE2 under a different salt scheme and stay untouched.
    bytes32 internal constant TELX_POSITION_REGISTRY = keccak256("TELX_POSITION_REGISTRY_V3");

    /// @notice TELxSubscriber deployed alongside it.
    bytes32 internal constant TELX_SUBSCRIBER = keccak256("TELX_SUBSCRIBER_V3");
}

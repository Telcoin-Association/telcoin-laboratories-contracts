// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PolygonConstants
/// @notice Shared mainnet addresses + identifiers used across multiple test files.
///         Centralizing them here prevents the silent drift that occurs when one test gets
///         updated to a new value and a sibling test does not. New tests using any of these
///         should import from here rather than redeclaring.
library PolygonConstants {
    // ----------
    // Tokens
    // ----------
    address internal constant TEL = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;
    address internal constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    // ----------
    // Balancer V2
    // ----------
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant BALANCER_POOL = 0xcA6EFA5704f1Ae445e0EE24D9c3Ddde34c5be1C2;
    bytes32 internal constant BALANCER_POOL_ID =
        0xca6efa5704f1ae445e0ee24d9c3ddde34c5be1c2000200000000000000000dbd;

    // ----------
    // Telcoin governance
    // ----------
    address internal constant TAO_COUNCIL_NFT = 0x1dfd0fB84c405780e4Eabe868A0F14107f7B46B3;

    // ----------
    // Sablier
    // ----------
    address internal constant SABLIER_LOCKUP = 0x8D87c5eddb5644D1a714F85930Ca940166e465f0;

    // ----------
    // TELx production deployments
    // ----------
    address internal constant TELX_PRODUCTION_HOOK = 0xD77cC9230Ded5b6591730032975453744532a500;
    address internal constant TELX_PRODUCTION_REGISTRY = 0x2c33fC9c09CfAC5431e754b8fe708B1dA3F5B954;
    address internal constant TELX_PRODUCTION_SUBSCRIBER = 0x3Bf9bAdC67573e7b4756547A2dC0C77368A2062b;

    // ----------
    // Snapshot adaptors (deployed instances)
    // ----------
    address internal constant WETH_POOL_ADAPTOR = 0x7b80BD3098b3D8ba887118E85fF8428231Bd7913;
    address internal constant STAKING_MODULE = 0x92e43Aec69207755CB1E6A8Dc589aAE630476330;
    address internal constant STAKING_REWARDS = 0x7fEb8FEbddB66189417f732B4221a52E23B926C4;
    address internal constant VOTING_WEIGHT_CALCULATOR = 0x3E95aA2605460E8c86166E78CaDab5e99ceaB0aA;
}

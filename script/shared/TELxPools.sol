// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {EthereumAddresses} from "./EthereumAddresses.sol";
import {PolygonAddresses} from "./PolygonAddresses.sol";
import {BaseAddresses} from "./BaseAddresses.sol";

/// @title TELxPools
/// @notice The standardized TELx pool set, as adopted by the TELx Liquidity Framework Alignment
///         and Pool Standardization proposal.
/// @dev    One catalog rather than seven hand-written PoolKeys, so the fee, spacing, currency
///         ordering and decimals of a pool are stated once and every script, test and runbook reads
///         the same row. Pools are addressed by a `CHAIN_SYMBOL0_SYMBOL1` name; the chain prefix is
///         redundant with `block.chainid` on purpose, so that running a Polygon pool against a Base
///         RPC fails on the name instead of silently creating the wrong pool.
///
///         Every pool is vanilla Uniswap v4: `hooks` is always `address(0)`. TELx no longer runs a
///         custom hook, because reward distribution moved to Merkl and a custom hook raises a
///         warning banner in the Uniswap front-end when LPs add or remove liquidity.
library TELxPools {
    /// @notice A pool's full identity plus the decimal metadata needed to scale deposit amounts.
    struct PoolSpec {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint8 decimals0;
        uint8 decimals1;
        string symbol0;
        string symbol1;
        uint256 chainId;
    }

    /// @notice Native ETH participates in a v4 PoolKey as the zero address, not as WETH.
    address internal constant NATIVE = address(0);

    uint24 internal constant FEE_MEDIUM = 3000; // 0.30%, the TEL pairs
    int24 internal constant SPACING_MEDIUM = 60;
    uint24 internal constant FEE_LOW = 500; // 0.05%, the stablecoin pair
    int24 internal constant SPACING_LOW = 10;

    uint8 internal constant DECIMALS_TEL = 18;
    uint8 internal constant DECIMALS_ETH = 18;
    uint8 internal constant DECIMALS_STABLE = 6;

    error UnknownPool(string name);
    error WrongChain(string name, uint256 expected, uint256 actual);
    error UnsortedCurrencies(address currency0, address currency1);

    // -----------
    // Catalog
    // -----------

    /**
     * @notice Resolves a pool name to its full specification.
     * @dev Reverts on an unknown name rather than returning an empty struct, so a typo in a runbook
     *      command fails before anything is broadcast.
     */
    function spec(string memory name) internal pure returns (PoolSpec memory s) {
        bytes32 key = keccak256(bytes(name));

        // --- Ethereum ---
        if (key == keccak256("ETHEREUM_ETH_TEL")) {
            s = PoolSpec({
                currency0: NATIVE,
                currency1: EthereumAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_ETH,
                decimals1: DECIMALS_TEL,
                symbol0: "ETH",
                symbol1: "TEL",
                chainId: EthereumAddresses.CHAIN_ID
            });
        } else if (key == keccak256("ETHEREUM_EUSD_TEL")) {
            s = PoolSpec({
                currency0: EthereumAddresses.EUSD,
                currency1: EthereumAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_STABLE,
                decimals1: DECIMALS_TEL,
                symbol0: "eUSD",
                symbol1: "TEL",
                chainId: EthereumAddresses.CHAIN_ID
            });
            // --- Polygon ---
        } else if (key == keccak256("POLYGON_WETH_TEL")) {
            // Polygon has no native ETH, so the TEL/ETH pool pairs against WETH here.
            s = PoolSpec({
                currency0: PolygonAddresses.WETH,
                currency1: PolygonAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_ETH,
                decimals1: DECIMALS_TEL,
                symbol0: "WETH",
                symbol1: "TEL",
                chainId: PolygonAddresses.CHAIN_ID
            });
        } else if (key == keccak256("POLYGON_EUSD_TEL")) {
            s = PoolSpec({
                currency0: PolygonAddresses.EUSD,
                currency1: PolygonAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_STABLE,
                decimals1: DECIMALS_TEL,
                symbol0: "eUSD",
                symbol1: "TEL",
                chainId: PolygonAddresses.CHAIN_ID
            });
        } else if (key == keccak256("POLYGON_EUSD_EMXN")) {
            // Replaces the legacy USDC/eMXN pool, which is deprecated by the same proposal.
            s = PoolSpec({
                currency0: PolygonAddresses.EUSD,
                currency1: PolygonAddresses.EMXN,
                fee: FEE_LOW,
                tickSpacing: SPACING_LOW,
                hooks: address(0),
                decimals0: DECIMALS_STABLE,
                decimals1: DECIMALS_STABLE,
                symbol0: "eUSD",
                symbol1: "eMXN",
                chainId: PolygonAddresses.CHAIN_ID
            });
            // --- Base ---
        } else if (key == keccak256("BASE_ETH_TEL")) {
            s = PoolSpec({
                currency0: NATIVE,
                currency1: BaseAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_ETH,
                decimals1: DECIMALS_TEL,
                symbol0: "ETH",
                symbol1: "TEL",
                chainId: BaseAddresses.CHAIN_ID
            });
        } else if (key == keccak256("BASE_EUSD_TEL")) {
            s = PoolSpec({
                currency0: BaseAddresses.EUSD,
                currency1: BaseAddresses.TEL_V3,
                fee: FEE_MEDIUM,
                tickSpacing: SPACING_MEDIUM,
                hooks: address(0),
                decimals0: DECIMALS_STABLE,
                decimals1: DECIMALS_TEL,
                symbol0: "eUSD",
                symbol1: "TEL",
                chainId: BaseAddresses.CHAIN_ID
            });
        } else {
            revert UnknownPool(name);
        }

        // A PoolKey with unsorted currencies hashes to a different pool than the one intended and
        // Uniswap will reject it. Checked here so a future catalog edit cannot get it wrong.
        if (s.currency0 >= s.currency1) revert UnsortedCurrencies(s.currency0, s.currency1);
    }

    /// @notice Resolves a pool name and asserts it belongs to the chain we are connected to.
    /// @dev The guard that catches a mismatched `--rpc-url`, which is the easy mistake to make when
    ///      running seven deploys across three chains in one sitting.
    function specForChain(string memory name, uint256 chainId) internal pure returns (PoolSpec memory s) {
        s = spec(name);
        if (s.chainId != chainId) revert WrongChain(name, s.chainId, chainId);
    }

    // -----------
    // Derived values
    // -----------

    /// @notice Builds the Uniswap v4 PoolKey for a spec.
    function poolKey(PoolSpec memory s) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(s.currency0),
            currency1: Currency.wrap(s.currency1),
            fee: s.fee,
            tickSpacing: s.tickSpacing,
            hooks: IHooks(s.hooks)
        });
    }

    /// @notice True when currency0 is native ETH, which changes how the mint is settled: native
    ///         value is sent with the call and swept back, rather than pulled through Permit2.
    function isNativeCurrency0(PoolSpec memory s) internal pure returns (bool) {
        return s.currency0 == NATIVE;
    }

    /// @notice Every pool name in the catalog, in proposal order.
    /// @dev Lets scripts and tests iterate the full set without restating it.
    function allNames() internal pure returns (string[] memory names) {
        names = new string[](7);
        names[0] = "ETHEREUM_ETH_TEL";
        names[1] = "ETHEREUM_EUSD_TEL";
        names[2] = "POLYGON_WETH_TEL";
        names[3] = "POLYGON_EUSD_TEL";
        names[4] = "POLYGON_EUSD_EMXN";
        names[5] = "BASE_ETH_TEL";
        names[6] = "BASE_EUSD_TEL";
    }
}

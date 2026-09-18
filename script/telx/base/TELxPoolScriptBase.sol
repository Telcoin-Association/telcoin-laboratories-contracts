// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EthereumAddresses} from "../../shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../../shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../shared/BaseAddresses.sol";
import {TELxPools} from "../../shared/TELxPools.sol";
import {V4PoolMath} from "../../shared/V4PoolMath.sol";
import {PoolsJson} from "./PoolsJson.sol";

/// @title TELxPoolScriptBase
/// @notice Shared chain resolution, parameter loading, signer resolution and preview logging for
///         the TELx pool scripts.
/// @dev    Pool creation and seeding run from an ordinary deployer EOA rather than through
///         safe-utils: a hookless Uniswap v4 pool is permissionless to initialize, and the
///         registry's allowlist is keyed on the PoolKey, which is known before the pool exists.
///         The registry and subscriber deploy, which does need governance, goes through the Safe.
///
///         Chain infrastructure comes from the shared address libraries only. There is no
///         environment override for a PositionManager or StateView: a script that could be
///         pointed at an arbitrary contract by a stray `.env` line, on mainnet, from a
///         treasury-funded signer, is a script whose preview cannot be trusted. Every resolved
///         address is printed before anything is broadcast instead.
abstract contract TELxPoolScriptBase is Script {
    struct ChainConfig {
        address positionManager;
        address stateView;
        address poolManager;
        address permit2;
        string name;
    }

    error UnsupportedChain(uint256 chainId);
    error MissingChainAddress(string what);

    // -----------
    // Chain resolution
    // -----------

    /// @notice Resolves Uniswap v4 infrastructure for the chain we are connected to, from the
    ///         shared address libraries.
    function _chainConfig() internal view returns (ChainConfig memory config) {
        uint256 chainId = block.chainid;

        if (chainId == EthereumAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: EthereumAddresses.POSITION_MANAGER,
                stateView: EthereumAddresses.STATE_VIEW,
                poolManager: address(0),
                permit2: EthereumAddresses.PERMIT2,
                name: "ethereum"
            });
        } else if (chainId == PolygonAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: PolygonAddresses.POSITION_MANAGER,
                stateView: PolygonAddresses.STATE_VIEW,
                poolManager: address(0),
                permit2: PolygonAddresses.PERMIT2,
                name: "polygon"
            });
        } else if (chainId == BaseAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: BaseAddresses.POSITION_MANAGER,
                stateView: BaseAddresses.STATE_VIEW,
                poolManager: address(0),
                permit2: BaseAddresses.PERMIT2,
                name: "base"
            });
        } else {
            revert UnsupportedChain(chainId);
        }

        if (config.positionManager == address(0)) revert MissingChainAddress("positionManager");
        if (config.stateView == address(0)) revert MissingChainAddress("stateView");
        if (config.permit2 == address(0)) revert MissingChainAddress("permit2");

        // The PoolManager is not a catalog constant of its own: StateView is bound to exactly one,
        // and reading it from there means the two can never disagree.
        config.poolManager = address(StateView(config.stateView).poolManager());
        if (config.poolManager == address(0)) revert MissingChainAddress("poolManager");
    }

    /// @notice Resolves the pool spec and asserts it belongs to the connected chain.
    function _poolSpec(string memory poolName) internal view returns (TELxPools.PoolSpec memory) {
        return TELxPools.specForChain(poolName, block.chainid);
    }

    // -----------
    // Pool parameters
    // -----------

    /// @notice Reads a pool's parameters from `script/telx/pools.json`. See `PoolsJson`.
    function _poolParams(string memory poolName) internal view returns (PoolsJson.PoolParams memory) {
        return PoolsJson.read(poolName);
    }

    /// @dev The defaults block alone, for the explicit-parameter entrypoints that take amounts on
    ///      the command line but still want the reviewed tolerances.
    function _defaultTolerances() internal view returns (int24 maxTickDeviation, uint16 slippageBps) {
        return PoolsJson.defaultTolerances();
    }

    /// @dev Zero amounts are the file's "not decided" marker. Refuse them on any path that would
    ///      set a price or move tokens.
    function _requireAmountsSet(string memory poolName, PoolsJson.PoolParams memory params) internal pure {
        PoolsJson.requireAmountsSet(poolName, params);
    }

    /// @dev Scales whole-token amounts by each side's decimals, refusing anything that cannot be
    ///      a whole-token figure. The scripts take whole tokens precisely so that a miscounted
    ///      zero is visible; this is the backstop for the case where the raw figure was pasted in
    ///      anyway.
    function _rawAmounts(
        string memory poolName,
        TELxPools.PoolSpec memory s,
        uint256 amount0Human,
        uint256 amount1Human
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        return PoolsJson.rawAmounts(poolName, s, amount0Human, amount1Human);
    }

    /// @notice The catalog pools that belong to the connected chain.
    function _poolsOnThisChain() internal view returns (string[] memory names) {
        string[] memory all = TELxPools.allNames();
        uint256 count;
        for (uint256 i; i < all.length; ++i) {
            if (TELxPools.spec(all[i]).chainId == block.chainid) ++count;
        }
        names = new string[](count);
        uint256 j;
        for (uint256 i; i < all.length; ++i) {
            if (TELxPools.spec(all[i]).chainId == block.chainid) names[j++] = all[i];
        }
    }

    // -----------
    // Signer resolution
    // -----------

    /// @notice Resolves the broadcast signer from environment, matching the pattern used by the
    ///         other deploy scripts in this repo: ETH_FROM for hardware wallets, PRIVATE_KEY for
    ///         key-based signing.
    function _resolveSigner() internal view returns (address signer) {
        signer = _trySigner();
        require(signer != address(0), "Set ETH_FROM (ledger) or PRIVATE_KEY");
    }

    /// @dev The signer if one is configured, otherwise zero. Previews use this so they can print
    ///      the signer's balances when a signer is set and still run when none is. A variable that
    ///      is present but does not parse is an error, not an absence: `vm.envOr` would otherwise
    ///      swallow a malformed key into its default and the run would report that no key was set.
    function _trySigner() internal view returns (address) {
        if (vm.envExists("ETH_FROM")) {
            address ethFrom = vm.envAddress("ETH_FROM");
            if (ethFrom != address(0)) return ethFrom;
        }
        if (vm.envExists("PRIVATE_KEY")) {
            uint256 pk = vm.envUint("PRIVATE_KEY");
            if (pk != 0) return vm.addr(pk);
        }
        return address(0);
    }

    // -----------
    // Reads
    // -----------

    /// @notice Current price of a pool, or zero when it has never been initialized.
    function _currentSqrtPriceX96(ChainConfig memory config, PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        (sqrtPriceX96,,,) = StateView(config.stateView).getSlot0(poolId);
    }

    /// @notice The pool's active liquidity at the current tick. Zero for an empty or never-created pool.
    function _poolLiquidity(ChainConfig memory config, PoolId poolId) internal view returns (uint128) {
        return StateView(config.stateView).getLiquidity(poolId);
    }

    /// @notice Whether some position already spans exactly this tick pair.
    /// @dev `liquidityGross` at a tick counts every position with a bound there, so both bounds
    ///      being non-zero is the on-chain signature of a position over this range. It is exact
    ///      for a freshly seeded pool, where the only positions are ours, which is the case the
    ///      double-seed guard exists for.
    function _rangeHasLiquidity(ChainConfig memory config, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (bool)
    {
        StateView stateView = StateView(config.stateView);
        (uint128 grossLower,) = stateView.getTickLiquidity(poolId, tickLower);
        (uint128 grossUpper,) = stateView.getTickLiquidity(poolId, tickUpper);
        return grossLower > 0 && grossUpper > 0;
    }

    function _balance(address currency, address who) internal view returns (uint256) {
        return currency == TELxPools.NATIVE ? who.balance : IERC20(currency).balanceOf(who);
    }

    // -----------
    // Logging
    // -----------

    /// @dev Prints every address the run will touch. There is no override for any of them, so
    ///      this is confirmation rather than configuration, but it is the line to check against
    ///      the explorer before broadcasting from a funded key.
    function _logChain(ChainConfig memory config) internal pure {
        console2.log("Chain:      ", config.name);
        console2.log("  PositionManager:", config.positionManager);
        console2.log("  PoolManager:    ", config.poolManager);
        console2.log("  StateView:      ", config.stateView);
        console2.log("  Permit2:        ", config.permit2);
    }

    /// @dev Prints the pool's identity. Every script echoes this before acting so the operator can
    ///      confirm the right pool on the right chain before anything is broadcast.
    function _logPool(string memory poolName, TELxPools.PoolSpec memory s, PoolKey memory key) internal pure {
        console2.log("Pool:       ", poolName);
        // Pool ids are conventionally read and pasted as hex, so print them that way rather than
        // as the decimal a uint256 would render to.
        console2.log("  poolId:   ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("  currency0:", s.symbol0, s.currency0);
        console2.log("  currency1:", s.symbol1, s.currency1);
        console2.log("  fee:      ", uint256(s.fee));
        console2.log("  spacing:  ", int256(s.tickSpacing));
        console2.log("  hooks:    ", s.hooks);
    }

    /// @dev Prints a price three ways: the raw Q64.96 value Uniswap uses, the tick, and the
    ///      decimal-adjusted figure in both directions. The last is the one a person can check
    ///      against a market quote; the first two are what the chain will actually hold.
    function _logPrice(uint160 sqrtPriceX96, TELxPools.PoolSpec memory s) internal pure {
        console2.log("  sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("  tick:        ", int256(TickMath.getTickAtSqrtPrice(sqrtPriceX96)));

        uint256 price1Per0 = V4PoolMath.humanPriceE18(sqrtPriceX96, s.decimals0, s.decimals1);
        console2.log(string.concat("  ", _fmtE18(price1Per0), " ", s.symbol1, " per ", s.symbol0));
        console2.log(
            string.concat(
                "  ", _fmtE18(V4PoolMath.humanInversePriceE18(price1Per0)), " ", s.symbol0, " per ", s.symbol1
            )
        );
    }

    /// @dev Prints the registry floor the configured amounts and floor value imply, with the
    ///      capital it takes to reach that liquidity in the narrowest band, the configured band and
    ///      the full range, so the governance decision is visible in the units it is made in.
    function _logFloor(string memory poolName, TELxPools.PoolSpec memory s, PoolsJson.PoolParams memory params)
        internal
        pure
    {
        if (params.minPositionValue1Human == 0) {
            console2.log("Registry liquidity floor: minPositionValue1 not set in pools.json");
            return;
        }
        uint160 sqrtPriceX96 = PoolsJson.openingSqrtPrice(poolName, s, params);
        uint128 floor = PoolsJson.minLiquidityFloor(poolName, s, params);
        console2.log("Registry liquidity floor (minLiquidity):", uint256(floor));
        console2.log(
            string.concat(
                "  narrowest band holds about ",
                _fmtUnits(V4PoolMath.toRawAmount(params.minPositionValue1Human, s.decimals1), s.decimals1),
                " ",
                s.symbol1,
                " at this liquidity"
            )
        );
        _logFloorCost("  configured band needs", sqrtPriceX96, floor, params.widthBps, s);
        _logFloorCost("  full range needs", sqrtPriceX96, floor, 0, s);
    }

    function _logFloorCost(
        string memory label,
        uint160 sqrtPriceX96,
        uint128 floor,
        uint16 widthBps,
        TELxPools.PoolSpec memory s
    ) internal pure {
        (int24 lower, int24 upper) = widthBps == 0
            ? V4PoolMath.fullRangeTicks(s.tickSpacing)
            : V4PoolMath.percentRangeTicks(sqrtPriceX96, widthBps, s.tickSpacing);
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.sqrtPricesAtTicks(lower, upper);
        (uint256 amount0, uint256 amount1) = V4PoolMath.amountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, floor);
        console2.log(
            string.concat(
                label,
                " ",
                _fmtUnits(amount0, s.decimals0),
                " ",
                s.symbol0,
                " + ",
                _fmtUnits(amount1, s.decimals1),
                " ",
                s.symbol1
            )
        );
    }

    /// @dev Prints a tick range alongside the full-range bounds for the same spacing, so a
    ///      concentrated band can be seen in proportion to the widest one available.
    function _logRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        (int24 fullLower, int24 fullUpper) = V4PoolMath.fullRangeTicks(tickSpacing);
        console2.log("  tickLower:", int256(tickLower));
        console2.log("  tickUpper:", int256(tickUpper));
        console2.log("  full range lower:", int256(fullLower));
        console2.log("  full range upper:", int256(fullUpper));
    }

    /// @dev Prints the signer's holdings of both currencies against the budget, so a short balance
    ///      shows up in the preview and not as a revert inside the broadcast.
    function _logBalances(TELxPools.PoolSpec memory s, address who, uint256 budget0, uint256 budget1) internal view {
        if (who == address(0)) {
            console2.log("Signer balances: (no ETH_FROM or PRIVATE_KEY set)");
            return;
        }
        uint256 bal0 = _balance(s.currency0, who);
        uint256 bal1 = _balance(s.currency1, who);
        console2.log("Signer balances for", who);
        console2.log(
            string.concat("  ", s.symbol0, ": ", _fmtUnits(bal0, s.decimals0), bal0 < budget0 ? "  SHORT" : "")
        );
        console2.log(
            string.concat("  ", s.symbol1, ": ", _fmtUnits(bal1, s.decimals1), bal1 < budget1 ? "  SHORT" : "")
        );
    }

    /// @dev Prints a raw amount as whole tokens with its raw form beside it, so the reviewed
    ///      figure and the figure the chain sees appear on one line.
    function _logAmount(string memory label, uint256 raw, uint8 decimals, string memory symbol) internal pure {
        console2.log(
            string.concat(
                "  ", label, ": ", _fmtUnits(raw, decimals), " ", symbol, "  (raw ", Strings.toString(raw), ")"
            )
        );
    }

    /// @dev Fixed-point rendering of an 18-decimal figure with six fractional digits.
    function _fmtE18(uint256 xE18) internal pure returns (string memory) {
        return _fmtUnits(xE18, 18);
    }

    /// @dev Renders `raw` in whole units of a `decimals`-decimal token, truncated to six places.
    ///      For a token with fewer than six decimals the fraction is shown at its native width.
    function _fmtUnits(uint256 raw, uint8 decimals) internal pure returns (string memory) {
        uint256 scale = 10 ** decimals;
        uint256 whole = raw / scale;
        uint256 frac = raw % scale;

        uint8 shown = decimals < 6 ? decimals : 6;
        if (shown == 0) return Strings.toString(whole);

        // drop the digits past the sixth place
        frac = frac / (10 ** (decimals - shown));
        string memory fracStr = Strings.toString(frac);
        // left-pad so 0.05 does not print as 0.5
        while (bytes(fracStr).length < shown) {
            fracStr = string.concat("0", fracStr);
        }
        return string.concat(Strings.toString(whole), ".", fracStr);
    }
}

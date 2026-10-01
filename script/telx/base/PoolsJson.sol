// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TELxPools} from "../../shared/TELxPools.sol";
import {V4PoolMath} from "../../shared/V4PoolMath.sol";

/// @title PoolsJson
/// @notice Reader for `script/telx/pools.json`, the one file that holds every per-pool decision
///         the TELx scripts act on: the seed amounts (which set the opening price), the band
///         width, the liquidity floor, and the two tolerances.
/// @dev    Shared by the EOA pool scripts and the Safe registry deploy, which both need the same
///         numbers and must never disagree about them. Every value is range-checked at the point
///         it is read, so an out-of-range figure fails a preview rather than a broadcast.
library PoolsJson {
    /// @notice Per-pool parameters, as read from the file.
    /// @param amount0Human Whole tokens of currency0 budgeted for the seed.
    /// @param amount1Human Whole tokens of currency1 budgeted for the seed.
    /// @param widthBps Half-width of the seeded band in basis points; 0 selects the full range.
    /// @param maxTickDeviation How far the pool's live tick may sit from the tick the amounts imply
    ///        before seeding is refused.
    /// @param slippageBps How far above the computed mint cost the on-chain maximums are set.
    /// @param minPositionValue1Human Whole units of currency1 that the narrowest in-range position
    ///        must be worth to subscribe; the registry's per-pool liquidity floor is derived from
    ///        it at the opening price. Zero means not decided.
    struct PoolParams {
        uint256 amount0Human;
        uint256 amount1Human;
        uint16 widthBps;
        int24 maxTickDeviation;
        uint16 slippageBps;
        uint256 minPositionValue1Human;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Path of the checked-in parameter file, relative to the project root.
    string internal constant PATH = "script/telx/pools.json";

    /// @dev No real seed approaches this many whole tokens of anything, and every raw-unit typo
    ///      (an amount pasted with its decimals already applied) sails past it.
    uint256 internal constant MAX_HUMAN_AMOUNT = 1e15;

    error PoolNotConfigured(string poolName);
    error PoolAmountsNotSet(string poolName);
    error MinPositionValueNotSet(string poolName);
    error AmountImplausible(string poolName, uint256 humanAmount);
    error InvalidWidthBps(string poolName, uint256 widthBps);
    error InvalidSlippageBps(string poolName, uint256 slippageBps);
    error InvalidTickDeviation(string poolName, uint256 maxTickDeviation);

    // -----------
    // Reading
    // -----------

    /// @notice Reads one pool's entry. Amounts and the floor value may be zero (not decided);
    ///         everything else must be in range.
    function read(string memory poolName) internal view returns (PoolParams memory params) {
        string memory json = _json();
        string memory key = string.concat(".pools.", poolName);
        if (!vm.keyExistsJson(json, key)) revert PoolNotConfigured(poolName);

        params.amount0Human = vm.parseJsonUint(json, string.concat(key, ".amount0"));
        params.amount1Human = vm.parseJsonUint(json, string.concat(key, ".amount1"));
        params.minPositionValue1Human = vm.parseJsonUint(json, string.concat(key, ".minPositionValue1"));

        uint256 widthBps = vm.parseJsonUint(json, string.concat(key, ".widthBps"));
        uint256 maxTickDeviation = _orDefault(json, key, "maxTickDeviation");
        uint256 slippageBps = _orDefault(json, key, "slippageBps");

        // Narrow only after checking, so a value that does not fit the field can never wrap into
        // one that does: 65,536 as a uint16 is 0, which would silently mean "full range".
        if (widthBps >= V4PoolMath.BPS) revert InvalidWidthBps(poolName, widthBps);
        if (slippageBps >= V4PoolMath.BPS) revert InvalidSlippageBps(poolName, slippageBps);
        if (maxTickDeviation > uint256(uint24(TickMath.MAX_TICK))) {
            revert InvalidTickDeviation(poolName, maxTickDeviation);
        }

        params.widthBps = uint16(widthBps);
        params.maxTickDeviation = int24(uint24(maxTickDeviation));
        params.slippageBps = uint16(slippageBps);
    }

    /// @notice The `defaults` block alone, for entrypoints that take amounts on the command line
    ///         but still want the reviewed tolerances.
    function defaultTolerances() internal view returns (int24 maxTickDeviation, uint16 slippageBps) {
        string memory json = _json();
        maxTickDeviation = int24(uint24(vm.parseJsonUint(json, ".defaults.maxTickDeviation")));
        slippageBps = uint16(vm.parseJsonUint(json, ".defaults.slippageBps"));
    }

    /// @notice The pool names present in the file.
    function configuredPoolNames() internal view returns (string[] memory) {
        return vm.parseJsonKeys(_json(), ".pools");
    }

    // -----------
    // Checks
    // -----------

    /// @notice Zero amounts are the file's "not decided" marker. Refuse them on any path that would
    ///         set a price, move tokens, or derive a floor from the price.
    function requireAmountsSet(string memory poolName, PoolParams memory params) internal pure {
        if (params.amount0Human == 0 || params.amount1Human == 0) revert PoolAmountsNotSet(poolName);
    }

    /// @notice A zero floor value is likewise "not decided", and a registry must not go live with
    ///         a pool whose cap slots cost nothing.
    function requireFloorSet(string memory poolName, PoolParams memory params) internal pure {
        if (params.minPositionValue1Human == 0) revert MinPositionValueNotSet(poolName);
    }

    /// @notice Scales whole-token amounts by each side's decimals, refusing anything that cannot
    ///         be a whole-token figure.
    function rawAmounts(string memory poolName, TELxPools.PoolSpec memory s, uint256 amount0Human, uint256 amount1Human)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (amount0Human > MAX_HUMAN_AMOUNT) revert AmountImplausible(poolName, amount0Human);
        if (amount1Human > MAX_HUMAN_AMOUNT) revert AmountImplausible(poolName, amount1Human);
        amount0 = V4PoolMath.toRawAmount(amount0Human, s.decimals0);
        amount1 = V4PoolMath.toRawAmount(amount1Human, s.decimals1);
    }

    // -----------
    // Derived values
    // -----------

    /// @notice The opening price the configured amounts imply.
    function openingSqrtPrice(string memory poolName, TELxPools.PoolSpec memory s, PoolParams memory params)
        internal
        pure
        returns (uint160)
    {
        (uint256 amount0, uint256 amount1) = rawAmounts(poolName, s, params.amount0Human, params.amount1Human);
        return V4PoolMath.sqrtPriceX96FromAmounts(amount0, amount1);
    }

    /**
     * @notice The registry liquidity floor for a pool: the liquidity at which a position spanning
     *         exactly one tick spacing at the opening price is worth `minPositionValue1Human` of
     *         currency1.
     * @dev The narrowest in-range position is the cheapest way to hold a given liquidity, so a
     *      floor sized to it bounds the cost of every eligible position from below. Wider
     *      positions need proportionally more capital to reach the same liquidity: roughly 33x
     *      for a +/-10% band and 670x for the full range at spacing 60. Requires the amounts
     *      (for the price) and the floor value to be set.
     */
    function minLiquidityFloor(string memory poolName, TELxPools.PoolSpec memory s, PoolParams memory params)
        internal
        pure
        returns (uint128)
    {
        requireAmountsSet(poolName, params);
        requireFloorSet(poolName, params);
        if (params.minPositionValue1Human > MAX_HUMAN_AMOUNT) {
            revert AmountImplausible(poolName, params.minPositionValue1Human);
        }
        uint256 value1 = V4PoolMath.toRawAmount(params.minPositionValue1Human, s.decimals1);
        return V4PoolMath.minLiquidityForNarrowestPosition(openingSqrtPrice(poolName, s, params), s.tickSpacing, value1);
    }

    // -----------
    // Internals
    // -----------

    function _json() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/", PATH));
    }

    /// @dev A per-pool value when the entry has one, otherwise the file-level default.
    function _orDefault(string memory json, string memory poolKey, string memory field) private view returns (uint256) {
        string memory perPool = string.concat(poolKey, ".", field);
        if (vm.keyExistsJson(json, perPool)) return vm.parseJsonUint(json, perPool);
        return vm.parseJsonUint(json, string.concat(".defaults.", field));
    }
}

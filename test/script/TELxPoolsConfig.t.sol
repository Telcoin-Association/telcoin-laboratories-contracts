// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {TELxPoolScriptBase} from "../../script/telx/base/TELxPoolScriptBase.sol";
import {TELxPoolScriptHarness} from "./harnesses/TELxPoolScriptHarness.sol";
import {PoolsJson} from "../../script/telx/base/PoolsJson.sol";

/// @title TELxPoolsConfigTest
/// @notice Keeps `script/telx/pools.json` and the pool catalog in `TELxPools.sol` in step with each
///         other, and pins the "unset amounts are refused" behaviour the file relies on.
/// @dev    The JSON is the operator-facing surface: it is filled in once for all seven pools and
///         then each script run needs only a pool name. That only works if every catalog pool has
///         an entry and every entry names a real pool, which is easy to break by editing either
///         side alone. Non-fork; reads the file through the same code path the scripts use.
contract TELxPoolsConfigTest is Test {
    TELxPoolScriptHarness internal harness;

    function setUp() public {
        harness = new TELxPoolScriptHarness();
    }

    /// @notice Every pool in the catalog has a parameter entry, and the entry parses.
    function test_everyCatalogPoolIsConfigured() public view {
        string[] memory names = TELxPools.allNames();
        for (uint256 i; i < names.length; ++i) {
            PoolsJson.PoolParams memory p = harness.poolParams(names[i]);
            // The tolerances must be meaningful even before amounts are decided, since they are
            // what the seed's two price guards run on.
            assertLt(p.widthBps, 10_000, string.concat(names[i], ": widthBps must be below 10000"));
            assertGt(p.maxTickDeviation, 0, string.concat(names[i], ": maxTickDeviation must be set"));
            assertLe(p.maxTickDeviation, 500, string.concat(names[i], ": maxTickDeviation over 5% defeats the guard"));
            assertLe(p.slippageBps, 100, string.concat(names[i], ": slippageBps over 1% defeats the maximums"));
        }
    }

    /// @notice The file's `defaults` block supplies the tolerances for every pool that does not
    ///         override them, and the explicit-parameter entrypoints read the same block.
    function test_defaultsApplyToEveryPool() public view {
        (int24 maxTickDeviation, uint16 slippageBps) = harness.defaultTolerances();
        assertEq(maxTickDeviation, 50, "default maxTickDeviation");
        assertEq(slippageBps, 50, "default slippageBps");

        string[] memory names = TELxPools.allNames();
        for (uint256 i; i < names.length; ++i) {
            PoolsJson.PoolParams memory p = harness.poolParams(names[i]);
            assertEq(p.maxTickDeviation, maxTickDeviation, string.concat(names[i], ": maxTickDeviation"));
            assertEq(p.slippageBps, slippageBps, string.concat(names[i], ": slippageBps"));
        }
    }

    /// @notice Every entry in the file names a catalog pool. The reverse of
    ///         `test_everyCatalogPoolIsConfigured`: an entry for a pool nothing will deploy is a
    ///         typo waiting to be seeded.
    function test_everyConfiguredPoolIsInTheCatalog() public view {
        string[] memory configured = harness.configuredPoolNames();
        string[] memory catalog = TELxPools.allNames();
        assertEq(configured.length, catalog.length, "pools.json and the catalog differ in size");
        for (uint256 i; i < configured.length; ++i) {
            bool found;
            for (uint256 j; j < catalog.length; ++j) {
                if (keccak256(bytes(configured[i])) == keccak256(bytes(catalog[j]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("pools.json names a pool the catalog lacks: ", configured[i]));
        }
    }

    /// @notice Every entry carries a `minPositionValue1`, and the floor cannot be derived while it
    ///         or the amounts are undecided, so a registry cannot go out with a zero floor.
    function test_floorIsRefusedWhileUndecided() public {
        string[] memory names = TELxPools.allNames();
        for (uint256 i; i < names.length; ++i) {
            PoolsJson.PoolParams memory p = harness.poolParams(names[i]);
            if (p.amount0Human == 0 || p.amount1Human == 0) {
                vm.expectRevert(abi.encodeWithSelector(PoolsJson.PoolAmountsNotSet.selector, names[i]));
                harness.minLiquidityFloor(names[i], p);
                continue;
            }
            if (p.minPositionValue1Human == 0) {
                vm.expectRevert(abi.encodeWithSelector(PoolsJson.MinPositionValueNotSet.selector, names[i]));
                harness.minLiquidityFloor(names[i], p);
                continue;
            }
            assertGt(harness.minLiquidityFloor(names[i], p), 0, string.concat(names[i], ": floor"));
        }
    }

    /// @notice With amounts and a floor value set, the floor is non-zero and scales with the value.
    function test_floorScalesWithTheValue() public {
        PoolsJson.PoolParams memory p = _params(100_000, 20_000_000);
        p.minPositionValue1Human = 200;
        uint128 one = harness.minLiquidityFloor("POLYGON_EUSD_TEL", p);
        p.minPositionValue1Human = 400;
        uint128 two = harness.minLiquidityFloor("POLYGON_EUSD_TEL", p);
        assertGt(one, 0, "non-zero");
        assertApproxEqAbs(two, 2 * one, 1, "doubles with the value");
    }

    /// @notice A whole-token amount past the sanity bound is refused as a probable raw-unit
    ///         paste, on either side.
    function test_implausibleAmountsAreRefused() public {
        TELxPools.PoolSpec memory s = TELxPools.spec("POLYGON_EUSD_TEL");
        uint256 tooMany = 1e15 + 1;

        vm.expectRevert(abi.encodeWithSelector(PoolsJson.AmountImplausible.selector, "X", tooMany));
        harness.rawAmounts("X", s, tooMany, 1);

        vm.expectRevert(abi.encodeWithSelector(PoolsJson.AmountImplausible.selector, "X", tooMany));
        harness.rawAmounts("X", s, 1, tooMany);

        (uint256 raw0, uint256 raw1) = harness.rawAmounts("X", s, 1e15, 1e15);
        assertEq(raw0, 1e15 * 1e6, "eUSD scaled");
        assertEq(raw1, 1e15 * 1e18, "TEL scaled");
    }

    /// @notice A name that is not in the catalog cannot have an entry either. Guards against a
    ///         typo in the JSON silently configuring a pool that nothing will ever deploy.
    function test_unknownPoolIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(PoolsJson.PoolNotConfigured.selector, "POLYGON_TEL_DOGE"));
        harness.poolParams("POLYGON_TEL_DOGE");
    }

    /// @notice Zero is the file's "not decided" marker and must be refused by anything that would
    ///         set a price or move tokens. Both sides are checked because either one at zero yields
    ///         a division by zero or an infinite price.
    function test_unsetAmountsAreRefused() public {
        PoolsJson.PoolParams memory p;

        p = _params(0, 1);
        vm.expectRevert(abi.encodeWithSelector(PoolsJson.PoolAmountsNotSet.selector, "X"));
        harness.requireAmountsSet("X", p);

        p = _params(1, 0);
        vm.expectRevert(abi.encodeWithSelector(PoolsJson.PoolAmountsNotSet.selector, "X"));
        harness.requireAmountsSet("X", p);

        // and non-zero passes
        p = _params(1, 1);
        harness.requireAmountsSet("X", p);
    }

    /// @notice `planAll` iterates only the pools that belong to the connected chain, so the per-chain
    ///         split of the catalog must be right: three on Polygon, two each elsewhere.
    function test_poolsOnThisChain_matchesCatalogSplit() public {
        vm.chainId(137);
        assertEq(harness.poolsOnThisChain().length, 3, "polygon should have three pools");

        vm.chainId(1);
        assertEq(harness.poolsOnThisChain().length, 2, "ethereum should have two pools");

        vm.chainId(8453);
        assertEq(harness.poolsOnThisChain().length, 2, "base should have two pools");

        vm.chainId(99_999);
        assertEq(harness.poolsOnThisChain().length, 0, "an unknown chain has no pools");
    }

    function _params(uint256 amount0Human, uint256 amount1Human) internal pure returns (PoolsJson.PoolParams memory) {
        return PoolsJson.PoolParams({
            amount0Human: amount0Human,
            amount1Human: amount1Human,
            widthBps: 1000,
            maxTickDeviation: 50,
            slippageBps: 50,
            minPositionValue1Human: 0
        });
    }
}

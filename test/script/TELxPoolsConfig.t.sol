// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TELxPools} from "../../script/shared/TELxPools.sol";
import {TELxPoolScriptBase} from "../../script/telx/base/TELxPoolScriptBase.sol";
import {TELxPoolScriptHarness} from "./harnesses/TELxPoolScriptHarness.sol";

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
            TELxPoolScriptBase.PoolParams memory p = harness.poolParams(names[i]);
            // widthBps is the one field that must always be meaningful, even before amounts are
            // decided: 10,000 or more is not a valid band and would revert at seed time.
            assertLt(p.widthBps, 10_000, string.concat(names[i], ": widthBps must be below 10000"));
        }
    }

    /// @notice A name that is not in the catalog cannot have an entry either. Guards against a
    ///         typo in the JSON silently configuring a pool that nothing will ever deploy.
    function test_unknownPoolIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolNotConfigured.selector, "POLYGON_TEL_DOGE"));
        harness.poolParams("POLYGON_TEL_DOGE");
    }

    /// @notice Zero is the file's "not decided" marker and must be refused by anything that would
    ///         set a price or move tokens. Both sides are checked because either one at zero yields
    ///         a division by zero or an infinite price.
    function test_unsetAmountsAreRefused() public {
        TELxPoolScriptBase.PoolParams memory p;

        p = TELxPoolScriptBase.PoolParams({amount0Human: 0, amount1Human: 1, widthBps: 1000});
        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolAmountsNotSet.selector, "X"));
        harness.requireAmountsSet("X", p);

        p = TELxPoolScriptBase.PoolParams({amount0Human: 1, amount1Human: 0, widthBps: 1000});
        vm.expectRevert(abi.encodeWithSelector(TELxPoolScriptBase.PoolAmountsNotSet.selector, "X"));
        harness.requireAmountsSet("X", p);

        // and non-zero passes
        p = TELxPoolScriptBase.PoolParams({amount0Human: 1, amount1Human: 1, widthBps: 1000});
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
}

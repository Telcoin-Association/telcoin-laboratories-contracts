// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TELxPoolScriptBase} from "../../../script/telx/base/TELxPoolScriptBase.sol";
import {TELxPools} from "../../../script/shared/TELxPools.sol";
import {PoolsJson} from "../../../script/telx/base/PoolsJson.sol";

/// @title TELxPoolScriptHarness
/// @notice Exposes the `internal` configuration readers of `TELxPoolScriptBase` so the checked-in
///         `pools.json` can be asserted against the pool catalog without going through a full
///         script run.
contract TELxPoolScriptHarness is TELxPoolScriptBase {
    function poolParams(string memory poolName) external view returns (PoolsJson.PoolParams memory) {
        return _poolParams(poolName);
    }

    function requireAmountsSet(string memory poolName, PoolsJson.PoolParams memory params) external pure {
        _requireAmountsSet(poolName, params);
    }

    function poolsOnThisChain() external view returns (string[] memory) {
        return _poolsOnThisChain();
    }

    function defaultTolerances() external view returns (int24, uint16) {
        return _defaultTolerances();
    }

    function rawAmounts(string memory poolName, TELxPools.PoolSpec memory s, uint256 amount0Human, uint256 amount1Human)
        external
        pure
        returns (uint256, uint256)
    {
        return _rawAmounts(poolName, s, amount0Human, amount1Human);
    }

    /// @dev The pool names present in the file, read the JSON-to-catalog direction.
    function configuredPoolNames() external view returns (string[] memory) {
        return PoolsJson.configuredPoolNames();
    }

    function minLiquidityFloor(string memory poolName, PoolsJson.PoolParams memory params)
        external
        view
        returns (uint128)
    {
        return PoolsJson.minLiquidityFloor(poolName, TELxPools.spec(poolName), params);
    }
}

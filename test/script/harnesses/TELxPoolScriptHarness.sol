// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TELxPoolScriptBase} from "../../../script/telx/base/TELxPoolScriptBase.sol";

/// @title TELxPoolScriptHarness
/// @notice Exposes the `internal` configuration readers of `TELxPoolScriptBase` so the checked-in
///         `pools.json` can be asserted against the pool catalog without going through a full
///         script run.
contract TELxPoolScriptHarness is TELxPoolScriptBase {
    function poolParams(string memory poolName) external view returns (PoolParams memory) {
        return _poolParams(poolName);
    }

    function requireAmountsSet(string memory poolName, PoolParams memory params) external pure {
        _requireAmountsSet(poolName, params);
    }

    function poolsOnThisChain() external view returns (string[] memory) {
        return _poolsOnThisChain();
    }
}

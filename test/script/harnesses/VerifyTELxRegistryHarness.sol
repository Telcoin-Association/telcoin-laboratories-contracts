// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VerifyTELxRegistry} from "../../../script/telx/VerifyTELxRegistry.s.sol";
import {PoolsJson} from "../../../script/telx/base/PoolsJson.sol";
import {TELxPoolFixtures} from "../TELxPoolFixtures.sol";

/// @title VerifyTELxRegistryHarness
/// @notice `VerifyTELxRegistry` with the pool parameters taken from `TELxPoolFixtures` instead of
///         the checked-in `pools.json`, whose amounts and floors are still undecided.
contract VerifyTELxRegistryHarness is VerifyTELxRegistry {
    function _poolParams(string memory poolName) internal pure override returns (PoolsJson.PoolParams memory) {
        return TELxPoolFixtures.params(poolName);
    }
}

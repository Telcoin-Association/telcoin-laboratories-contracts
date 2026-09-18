// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SeedV4Liquidity} from "../../../script/telx/SeedV4Liquidity.s.sol";
import {TELxPools} from "../../../script/shared/TELxPools.sol";
import {PoolsJson} from "../../../script/telx/base/PoolsJson.sol";

/// @title SeedV4LiquidityHarness
/// @notice Exposes the plan builder and the mint encoder of `SeedV4Liquidity`, so a fork test can
///         hold a plan fixed while the pool moves underneath it and then execute exactly the mint
///         the script would have sent. That is the only way to exercise the on-chain maximums in
///         isolation: the script itself always re-reads the live price first.
contract SeedV4LiquidityHarness is SeedV4Liquidity {
    function chainConfig() external view returns (ChainConfig memory) {
        return _chainConfig();
    }

    function explicitParams(uint256 amount0Human, uint256 amount1Human, uint16 widthBps)
        external
        view
        returns (PoolsJson.PoolParams memory)
    {
        return _explicitParams(amount0Human, amount1Human, widthBps);
    }

    function buildPlan(string memory poolName, PoolsJson.PoolParams memory params, bool allowProjected)
        external
        view
        returns (SeedPlan memory)
    {
        return _buildPlan(_chainConfig(), _poolSpec(poolName), poolName, params, allowProjected);
    }

    function encodeMint(string memory poolName, SeedPlan memory p, SeedOptions memory opts)
        external
        view
        returns (bytes memory)
    {
        return _encodeMint(_poolSpec(poolName), p, opts);
    }

    function nativeValue(string memory poolName, SeedPlan memory p) external view returns (uint256) {
        return _nativeValue(_poolSpec(poolName), p);
    }
}

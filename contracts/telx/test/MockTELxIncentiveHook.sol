// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {TELxIncentiveHook} from "../core/TELxIncentiveHook.sol";

/// @title TELxIncentiveHookDeployable
/// @notice Test-only subclass of TELxIncentiveHook that skips the real hook-
///         address validation. Uniswap v4 requires hook contracts to be
///         deployed at addresses whose lower bits match the permissions
///         flags; in unit tests we bypass this check so hooks can be deployed
///         at arbitrary CREATE2 addresses via `deployCodeTo`.
contract TELxIncentiveHookDeployable is TELxIncentiveHook {
    constructor(IPoolManager _poolManager, address _positionManager, IPositionRegistry _registry)
        TELxIncentiveHook(_poolManager, _positionManager, _registry)
    {}

    function validateHookAddress(BaseHook _this) internal pure override {}
}

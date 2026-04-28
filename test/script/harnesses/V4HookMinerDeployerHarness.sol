// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4HookMinerDeployer} from "../../../script/V4HookMinerDeployer.s.sol";
import {PositionRegistry} from "../../../contracts/telx/core/PositionRegistry.sol";

/// @notice Test harness exposing internal state accessors for V4HookMinerDeployer.
///         Lives in its own file (not inline in the .t.sol) so the test file stays focused
///         on test logic. Imported only by `test/script/V4HookMinerDeployer.fork.t.sol`.
contract V4HookMinerDeployerHarness is V4HookMinerDeployer {
    function exposed_positionRegistry() external view returns (PositionRegistry) {
        return positionRegistry;
    }

    function exposed_hookAddress() external view returns (address) {
        return hookAddress;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {DeployBase} from "forge-deploy-utils/DeployBase.sol";
import {SaltMath} from "forge-deploy-utils/libraries/SaltMath.sol";
import {EthereumAddresses} from "../../shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../../shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../shared/BaseAddresses.sol";
import {Salts} from "../../shared/Salts.sol";
import {TELxPools} from "../../shared/TELxPools.sol";
import {PoolsJson} from "./PoolsJson.sol";

/// @title TELxRegistryScriptBase
/// @notice What the TELx registry deploy and verify scripts have in common: the per-chain targets,
///         the chain-selection loop, and the CREATE3 address prediction.
/// @dev    Kept separate from the deploy logic so that `VerifyTELxRegistry` can iterate the same
///         chains and predict the same addresses without inheriting any of the batching or Safe
///         proposal machinery it has no use for. Both scripts read the chain list from here, so
///         adding a chain is one edit.
abstract contract TELxRegistryScriptBase is DeployBase {
    struct ChainTarget {
        string name;
        string rpcUrl;
        uint256 chainId;
        address positionManager;
        address stateView;
        address supportSafe;
        address admin;
    }

    ChainTarget[] internal allChains;

    // -----------
    // Chain targets
    // -----------

    /// @dev Populates `allChains` from the shared address libraries. RPC URLs come from env and are
    ///      allowed to be empty: a chain with no URL is skipped by `_selectChain`, so deploying or
    ///      verifying one chain at a time does not require every chain's endpoint to be configured.
    function _loadChainTargets() internal {
        allChains.push(
            ChainTarget({
                name: "ethereum",
                rpcUrl: vm.envOr("ETHEREUM_RPC_URL", string("")),
                chainId: EthereumAddresses.CHAIN_ID,
                positionManager: EthereumAddresses.POSITION_MANAGER,
                stateView: EthereumAddresses.STATE_VIEW,
                // Still address(0): Ethereum has no TELx support multisig yet, so the deploy
                // refuses this chain until the deployment team supplies one.
                supportSafe: EthereumAddresses.SUPPORT_SAFE,
                admin: EthereumAddresses.GOVERNANCE_SAFE
            })
        );

        allChains.push(
            ChainTarget({
                name: "polygon",
                rpcUrl: vm.envOr("POLYGON_RPC_URL", string("")),
                chainId: PolygonAddresses.CHAIN_ID,
                positionManager: PolygonAddresses.POSITION_MANAGER,
                stateView: PolygonAddresses.STATE_VIEW,
                supportSafe: PolygonAddresses.SUPPORT_SAFE,
                admin: PolygonAddresses.GOVERNANCE_SAFE
            })
        );

        allChains.push(
            ChainTarget({
                name: "base",
                rpcUrl: vm.envOr("BASE_RPC_URL", string("")),
                chainId: BaseAddresses.CHAIN_ID,
                positionManager: BaseAddresses.POSITION_MANAGER,
                stateView: BaseAddresses.STATE_VIEW,
                supportSafe: BaseAddresses.SUPPORT_SAFE,
                admin: BaseAddresses.GOVERNANCE_SAFE
            })
        );
    }

    /**
     * @dev Decides whether to act on `target` this run and, if so, forks it and asserts the fork is
     *      the chain we think it is.
     * @return selected False when the chain is filtered out by `CHAIN` or has no RPC configured.
     */
    function _selectChain(ChainTarget memory target) internal returns (bool selected) {
        string memory only = vm.envOr("CHAIN", string(""));
        if (bytes(only).length > 0 && keccak256(bytes(target.name)) != keccak256(bytes(only))) return false;

        // A chain with no RPC configured is skipped rather than fatal. Working one chain at a time
        // is the normal way to run these scripts, and requiring every chain's URL to be present in
        // order to touch one of them would be a trap rather than a safety check.
        if (bytes(target.rpcUrl).length == 0) {
            console.log("Skipping %s: no RPC URL configured", target.name);
            return false;
        }

        vm.createSelectFork(target.rpcUrl);

        require(
            block.chainid == target.chainId,
            string.concat(
                "Chain ID mismatch: expected ",
                vm.toString(target.chainId),
                " but connected to ",
                vm.toString(block.chainid)
            )
        );
        return true;
    }

    // -----------
    // Liquidity floors
    // -----------

    /// @dev A pool's parameters from `pools.json`. Virtual so a fork test can supply fixture values
    ///      without editing the checked-in file, whose amounts are a business decision.
    function _poolParams(string memory poolName) internal view virtual returns (PoolsJson.PoolParams memory) {
        return PoolsJson.read(poolName);
    }

    /// @notice The registry liquidity floor for a catalog pool, derived from its configured
    ///         opening price and `minPositionValue1`. Reverts while either is undecided.
    /// @dev The deploy batch sets this and the verify script asserts it, from the same derivation,
    ///      so the two cannot disagree. A zero floor is what makes a cap slot cost nothing.
    function _expectedFloor(string memory poolName) internal view returns (uint128) {
        return PoolsJson.minLiquidityFloor(poolName, TELxPools.spec(poolName), _poolParams(poolName));
    }

    // -----------
    // Address prediction
    // -----------

    /// @notice The addresses the deploy lands on, derived from the deployer Safe and the salts.
    /// @dev Identical on every chain because CreateX runs in cross-chain mode; constructor
    ///      arguments play no part. Exposed so the runbook, the verify script and the tests can all
    ///      assert cross-chain parity from one source.
    function predictedAddresses() public view returns (address registry, address subscriber) {
        registry = _computeCreate3Address(SaltMath.guardSalt(deployerSafeAddress, Salts.TELX_POSITION_REGISTRY));
        subscriber = _computeCreate3Address(SaltMath.guardSalt(deployerSafeAddress, Salts.TELX_SUBSCRIBER));
    }
}

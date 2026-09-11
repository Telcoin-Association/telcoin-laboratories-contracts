// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";
import {PolygonAddresses} from "./shared/PolygonAddresses.sol";
import {BaseAddresses} from "./shared/BaseAddresses.sol";

/**
 * @title DeployTELxRegistry
 * @notice Deploys the thin (post-V4-hook-removal) TELx PositionRegistry and its TELxSubscriber.
 * @dev There is no hook to mine or pool to initialize anymore: TELx pools are vanilla Uniswap v4.
 *      The script deploys the registry + subscriber and wires roles. The registry admin is left
 *      with the deployer for the team to hand off to governance separately.
 *
 *      Usage:
 *        forge script script/DeployTELxRegistry.s.sol:DeployTELxRegistry \
 *            --rpc-url $POLYGON_RPC_URL --private-key $DEPLOYER_PK --broadcast
 */
contract DeployTELxRegistry is Script {
    struct ChainConfig {
        address positionManager;
        address stateView;
        address supportSafe;
    }

    mapping(uint256 => ChainConfig) public chainConfigs;

    address public deployer;
    PositionRegistry public positionRegistry;
    TELxSubscriber public telxSubscriber;

    function setUp() public {
        _loadChainConfigs();
    }

    /// @dev Test-friendly config loader that does not require DEPLOYER_PK. `setUp()` and tests both
    ///      call it; production `run()` resolves the signer from env and delegates afterwards.
    function _loadChainConfigs() internal {
        chainConfigs[137] = ChainConfig({
            positionManager: vm.envOr("POLYGON_POSITION_MANAGER", PolygonAddresses.POSITION_MANAGER),
            stateView: vm.envOr("POLYGON_STATE_VIEW", PolygonAddresses.STATE_VIEW),
            supportSafe: vm.envOr("POLYGON_SUPPORT_SAFE", PolygonAddresses.SUPPORT_SAFE)
        });
        chainConfigs[8453] = ChainConfig({
            positionManager: vm.envOr("BASE_POSITION_MANAGER", BaseAddresses.POSITION_MANAGER),
            stateView: vm.envOr("BASE_STATE_VIEW", BaseAddresses.STATE_VIEW),
            supportSafe: vm.envOr("BASE_SUPPORT_SAFE", BaseAddresses.SUPPORT_SAFE)
        });
    }

    /// @notice Production entrypoint. Resolves the signer from `DEPLOYER_PK` and delegates.
    function run() public {
        runWithSigner(vm.addr(vm.envUint("DEPLOYER_PK")));
    }

    /// @notice Explicit-signer entrypoint. Production `run()` delegates here; tests call it directly.
    function runWithSigner(address signer) public {
        deployer = signer;
        ChainConfig storage config = _getChainConfig(block.chainid);

        vm.startBroadcast(deployer);

        // deployer is admin during setup; the team hands DEFAULT_ADMIN_ROLE off to governance later
        positionRegistry =
            new PositionRegistry(IPositionManager(config.positionManager), StateView(config.stateView), deployer);

        // the support safe owns the subscriber so governance can repoint `registry` if needed
        telxSubscriber = new TELxSubscriber(
            IPositionRegistry(address(positionRegistry)), config.positionManager, config.supportSafe
        );

        positionRegistry.grantRole(positionRegistry.SUBSCRIBER_ROLE(), address(telxSubscriber));
        positionRegistry.grantRole(positionRegistry.SUPPORT_ROLE(), config.supportSafe);

        vm.stopBroadcast();

        _postDeploymentChecks(config);

        console.log("TELx registry deployment successful");
        console.log("  PositionRegistry: %s", address(positionRegistry));
        console.log("  TELxSubscriber:   %s", address(telxSubscriber));
    }

    function _getChainConfig(uint256 chainId) internal view returns (ChainConfig storage) {
        ChainConfig storage config = chainConfigs[chainId];
        require(config.positionManager != address(0), "Unsupported chainId");
        require(config.stateView != address(0), "Missing stateView");
        require(config.supportSafe != address(0), "Missing supportSafe");
        return config;
    }

    function _postDeploymentChecks(ChainConfig storage config) internal view {
        require(address(positionRegistry.positionManager()) == config.positionManager, "registry positionManager");
        require(address(positionRegistry.stateView()) == config.stateView, "registry stateView");
        require(
            positionRegistry.hasRole(positionRegistry.SUBSCRIBER_ROLE(), address(telxSubscriber)), "!SUBSCRIBER_ROLE"
        );
        require(positionRegistry.hasRole(positionRegistry.SUPPORT_ROLE(), config.supportSafe), "!SUPPORT_ROLE");
        require(address(telxSubscriber.registry()) == address(positionRegistry), "subscriber registry");
        require(telxSubscriber.positionManager() == config.positionManager, "subscriber positionManager");
        require(telxSubscriber.owner() == config.supportSafe, "subscriber owner");
    }
}

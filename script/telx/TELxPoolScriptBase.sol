// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EthereumAddresses} from "../shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../shared/PolygonAddresses.sol";
import {BaseAddresses} from "../shared/BaseAddresses.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {V4PoolMath} from "../shared/V4PoolMath.sol";

/// @title TELxPoolScriptBase
/// @notice Shared chain resolution, signer resolution and preview logging for the TELx pool
///         scripts.
/// @dev    Pool creation and seeding run from an ordinary deployer EOA rather than through
///         safe-utils: a hookless Uniswap v4 pool is permissionless to initialize, and the thin
///         PositionRegistry treats any initialized pool as valid, so no admin call sits between
///         creating a pool and an LP being able to subscribe to it. The registry and subscriber
///         deploy, which does need governance, goes through the Safe instead.
abstract contract TELxPoolScriptBase is Script {
    struct ChainConfig {
        address positionManager;
        address stateView;
        address permit2;
        string name;
    }

    error UnsupportedChain(uint256 chainId);
    error MissingChainAddress(string what);

    // -----------
    // Chain resolution
    // -----------

    /// @notice Resolves Uniswap v4 infrastructure for the chain we are connected to.
    /// @dev Library constants are the defaults; each is overridable via `vm.envOr` so the same
    ///      script can be pointed at a testnet deployment without editing code.
    function _chainConfig() internal view returns (ChainConfig memory config) {
        uint256 chainId = block.chainid;

        if (chainId == EthereumAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: vm.envOr("ETHEREUM_POSITION_MANAGER", EthereumAddresses.POSITION_MANAGER),
                stateView: vm.envOr("ETHEREUM_STATE_VIEW", EthereumAddresses.STATE_VIEW),
                permit2: vm.envOr("ETHEREUM_PERMIT2", EthereumAddresses.PERMIT2),
                name: "ethereum"
            });
        } else if (chainId == PolygonAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: vm.envOr("POLYGON_POSITION_MANAGER", PolygonAddresses.POSITION_MANAGER),
                stateView: vm.envOr("POLYGON_STATE_VIEW", PolygonAddresses.STATE_VIEW),
                permit2: vm.envOr("POLYGON_PERMIT2", PolygonAddresses.PERMIT2),
                name: "polygon"
            });
        } else if (chainId == BaseAddresses.CHAIN_ID) {
            config = ChainConfig({
                positionManager: vm.envOr("BASE_POSITION_MANAGER", BaseAddresses.POSITION_MANAGER),
                stateView: vm.envOr("BASE_STATE_VIEW", BaseAddresses.STATE_VIEW),
                permit2: vm.envOr("BASE_PERMIT2", BaseAddresses.PERMIT2),
                name: "base"
            });
        } else {
            revert UnsupportedChain(chainId);
        }

        if (config.positionManager == address(0)) revert MissingChainAddress("positionManager");
        if (config.stateView == address(0)) revert MissingChainAddress("stateView");
        if (config.permit2 == address(0)) revert MissingChainAddress("permit2");
    }

    /// @notice Resolves the pool spec and asserts it belongs to the connected chain.
    function _poolSpec(string memory poolName) internal view returns (TELxPools.PoolSpec memory) {
        return TELxPools.specForChain(poolName, block.chainid);
    }

    // -----------
    // Signer resolution
    // -----------

    /// @notice Resolves the broadcast signer from environment, matching the pattern used by the
    ///         other deploy scripts in this repo: ETH_FROM for hardware wallets, PRIVATE_KEY for
    ///         key-based signing.
    function _resolveSigner() internal view returns (address signer) {
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) return ethFrom;

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        require(pk != 0, "Set ETH_FROM (ledger) or PRIVATE_KEY");
        return vm.addr(pk);
    }

    // -----------
    // Reads
    // -----------

    /// @notice Current price of a pool, or zero when it has never been initialized.
    function _currentSqrtPriceX96(ChainConfig memory config, PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateView(config.stateView).getSlot0(poolId);
    }

    // -----------
    // Logging
    // -----------

    /// @dev Prints the pool's identity. Every script echoes this before acting so the operator can
    ///      confirm the right pool on the right chain before anything is broadcast.
    function _logPool(string memory poolName, TELxPools.PoolSpec memory s, PoolKey memory key) internal pure {
        console2.log("Pool:       ", poolName);
        // Pool ids are conventionally read and pasted as hex, so print them that way rather than
        // as the decimal a uint256 would render to.
        console2.log("  poolId:   ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("  currency0:", s.symbol0, s.currency0);
        console2.log("  currency1:", s.symbol1, s.currency1);
        console2.log("  fee:      ", uint256(s.fee));
        console2.log("  spacing:  ", int256(s.tickSpacing));
        console2.log("  hooks:    ", s.hooks);
    }

    /// @dev Prints a price both as the raw Q64.96 value Uniswap uses and as the tick, which is the
    ///      form that can be eyeballed against an existing pool.
    function _logPrice(uint160 sqrtPriceX96) internal pure {
        console2.log("  sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("  tick:        ", int256(TickMath.getTickAtSqrtPrice(sqrtPriceX96)));
    }

    /// @dev Prints a tick range alongside the full-range bounds for the same spacing, so a
    ///      concentrated band can be seen in proportion to the widest one available.
    function _logRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        (int24 fullLower, int24 fullUpper) = V4PoolMath.fullRangeTicks(tickSpacing);
        console2.log("  tickLower:", int256(tickLower));
        console2.log("  tickUpper:", int256(tickUpper));
        console2.log("  full range lower:", int256(fullLower));
        console2.log("  full range upper:", int256(fullUpper));
    }
}

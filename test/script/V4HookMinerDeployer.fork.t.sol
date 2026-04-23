// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {V4HookMinerDeployer} from "../../script/V4HookMinerDeployer.s.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxIncentiveHook} from "../../contracts/telx/core/TELxIncentiveHook.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";
import {TestConstants} from "../util/TestConstants.sol";

/// @notice Harness exposing internal state accessors and calls for the script.
contract V4HookMinerDeployerHarness is V4HookMinerDeployer {
    function exposed_positionRegistry() external view returns (PositionRegistry) {
        return positionRegistry;
    }

    function exposed_hookAddress() external view returns (address) {
        return hookAddress;
    }
}

/// @notice Tests of V4HookMinerDeployer's guard + validation logic.
///
/// @dev    Full end-to-end coverage requires a Base RPC URL (for
///         `BASE_ETH_TEL`) plus live Uniswap v4 infrastructure addresses.
///         Those live in environment vars the team sets only on their
///         deployment boxes. Here we exercise:
///           - setUp env parsing
///           - _getChainConfig validation (unsupported chainId reverts)
///           - _getPoolConfig validation (unsupported pool name reverts,
///             placeholder currencies revert)
///           - runWithSigner signature + delegation
///
///         The integration path (actual hook mining + pool initialization)
///         is covered manually by the deployment team on testnets pre-mainnet;
///         adding env-specific fork tests here is a follow-up once Base RPC
///         + Polygon v4 addresses are wired into team secrets.
contract V4HookMinerDeployerForkTest is Test {
    // Arbitrary non-zero placeholders for env vars the script reads in setUp.
    // Actual values don't matter for the validation tests.
    address internal constant PLACEHOLDER = 0x1111111111111111111111111111111111111111;
    address internal constant SIGNER = address(0xDEAD);

    V4HookMinerDeployerHarness internal script;

    function setUp() public {
        uint256 forkBlock =
            vm.envOr("FORK_BLOCK_NUMBER", TestConstants.DEFAULT_POLYGON_FORK_BLOCK);
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), forkBlock);
        _setAllEnvPlaceholders();
        script = new V4HookMinerDeployerHarness();
        script.setUp();
    }

    /// @notice setUp must read every env var without reverting and populate
    ///         every non-zero field of both ChainConfigs. If the script ever
    ///         adds, removes, or reorders a field, this test catches the
    ///         regression.
    function test_setUp_loadsAllEnvVars() public view {
        _assertChainConfigPopulated(137); // Polygon
        _assertChainConfigPopulated(8453); // Base
    }

    /// @notice Chain IDs outside the known set (137, 8453) must revert.
    function test_runWithSigner_unsupportedChainId_reverts() public {
        // Polygon fork is active (chainid 137). Override chainid to an
        // unconfigured value to trigger _getChainConfig's guard.
        vm.chainId(99_999);
        vm.expectRevert(bytes("Unsupported chainId"));
        script.runWithSigner("BASE_ETH_TEL", 0, SIGNER);
    }

    /// @notice Pool names outside the hard-coded set must revert.
    function test_runWithSigner_unsupportedPool_reverts() public {
        // Reset chainid to Polygon in case the prior unsupportedChainId test
        // ran first and left it at 99_999. vm.chainId is per-test in setUp
        // but not reset automatically mid-suite.
        vm.chainId(137);
        vm.expectRevert(bytes("Unsupported pool"));
        script.runWithSigner("ARBITRUM_ETH_USDC", 0, SIGNER);
    }

    /// @notice sqrtPriceX96 must be 0 — the CLI-provided value is explicitly
    ///         rejected until off-chain computation support lands.
    function test_runWithSigner_nonZeroSqrtPrice_reverts() public {
        // See above: defensive chainid reset to Polygon.
        vm.chainId(137);
        vm.expectRevert(bytes("CLI-provided sqrtPriceX96 not yet supported, must use 0"));
        script.runWithSigner("POLYGON_WETH_TEL", 12345, SIGNER);
    }

    /// @notice The production `run()` wrapper resolves the signer from
    ///         DEPLOYER_PK and delegates. We can't fully E2E this on Polygon
    ///         (placeholder env addresses aren't real v4 infra) so the
    ///         script reverts partway through — but only AFTER the env-var
    ///         resolution path runs, which is the branch we want covered.
    ///
    ///         The specific revert: `StateView(placeholder).getSlot0(poolId)`
    ///         staticcalls an address with no code, which returns empty
    ///         returndata, so Solidity's ABI decoder reverts with zero
    ///         return data. A stricter `vm.expectRevert(bytes(""))` would
    ///         match that empty-data revert exactly — but some Foundry
    ///         versions (including the GitHub Actions toolchain at time
    ///         of writing) panic in alloy-dyn-abi when decoding a 0-byte
    ///         revert against a 0-length expected error. Using bare
    ///         `vm.expectRevert()` sidesteps the panic; we accept the
    ///         slightly looser match.
    function test_run_resolvesSignerFromDeployerPk() public {
        vm.chainId(137); // defensive reset — see note in sibling tests
        vm.setEnv("DEPLOYER_PK", vm.toString(uint256(0xCAFE)));
        vm.expectRevert();
        script.run("POLYGON_WETH_TEL", 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Asserts every address field of `script.chainConfigs(chainId)` is
    ///      populated. Because `_setAllEnvPlaceholders` sets every env var
    ///      to the same PLACEHOLDER, every field should equal PLACEHOLDER —
    ///      except `nativeToken`, which the script hardcodes to address(0)
    ///      for both chains (see the script's `_loadChainConfigs`).
    function _assertChainConfigPopulated(uint256 chainId) internal view {
        (
            address poolManager,
            address positionManager,
            address universalRouter,
            address stateView,
            address telToken,
            address wethToken,
            address nativeToken,
            address usdcToken,
            address emxnToken,
            address supportSafe
        ) = script.chainConfigs(chainId);
        assertEq(poolManager, PLACEHOLDER, "poolManager");
        assertEq(positionManager, PLACEHOLDER, "positionManager");
        assertEq(universalRouter, PLACEHOLDER, "universalRouter");
        assertEq(stateView, PLACEHOLDER, "stateView");
        assertEq(telToken, PLACEHOLDER, "telToken");
        assertEq(wethToken, PLACEHOLDER, "wethToken");
        assertEq(nativeToken, address(0), "nativeToken (script hardcodes to 0)");
        assertEq(usdcToken, PLACEHOLDER, "usdcToken");
        assertEq(emxnToken, PLACEHOLDER, "emxnToken");
        assertEq(supportSafe, PLACEHOLDER, "supportSafe");
    }

    function _setAllEnvPlaceholders() internal {
        string[] memory keys = new string[](18);
        keys[0] = "POLYGON_POOL_MANAGER";
        keys[1] = "POLYGON_POSITION_MANAGER";
        keys[2] = "POLYGON_UNIVERSAL_ROUTER";
        keys[3] = "POLYGON_STATE_VIEW";
        keys[4] = "POLYGON_TEL_TOKEN";
        keys[5] = "POLYGON_WETH_TOKEN";
        keys[6] = "POLYGON_USDC_TOKEN";
        keys[7] = "POLYGON_EMXN_TOKEN";
        keys[8] = "POLYGON_SUPPORT_SAFE";
        keys[9] = "BASE_POOL_MANAGER";
        keys[10] = "BASE_POSITION_MANAGER";
        keys[11] = "BASE_UNIVERSAL_ROUTER";
        keys[12] = "BASE_STATE_VIEW";
        keys[13] = "BASE_TEL_TOKEN";
        keys[14] = "BASE_WETH_TOKEN";
        keys[15] = "BASE_USDC_TOKEN";
        keys[16] = "BASE_EMXN_TOKEN";
        keys[17] = "BASE_SUPPORT_SAFE";
        for (uint256 i = 0; i < keys.length; i++) {
            vm.setEnv(keys[i], vm.toString(PLACEHOLDER));
        }
    }
}

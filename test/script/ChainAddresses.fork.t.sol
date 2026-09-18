// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IImmutableState} from "@uniswap/v4-periphery/src/interfaces/IImmutableState.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {EthereumAddresses} from "../../script/shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../../script/shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../script/shared/BaseAddresses.sol";
import {CrossChainAddresses} from "../../script/shared/CrossChainAddresses.sol";

/// @title ChainAddressesForkTest
/// @notice Asserts every constant in `script/shared/*Addresses.sol` against the live chain it
///         claims to describe. These libraries are the inputs to pool creation and to the registry
///         deploy, and a single mistyped nibble there is both easy to make and expensive to find:
///         a wrong token address produces a real but worthless pool, and a wrong Uniswap address
///         produces a deploy that reverts only after the Safe batch is signed. Checking them in CI
///         turns that into a red test.
///
///         Differs from its neighbours in `test/script/` in that it exercises no contract of ours.
///         It is a data-integrity test over checked-in constants, deliberately run against the
///         chain tip rather than a pinned block: the question is "is this address correct today",
///         and a pinned block would let a constant rot silently after the pin.
abstract contract ChainAddressesForkTest is Test {
    /// @dev Asserts `token` is a live ERC-20 reporting exactly this symbol and decimal count.
    ///      Decimals are the load-bearing half: TEL v2 and TEL v3 differ by 1e16, and every
    ///      sqrtPriceX96 we derive is wrong by that factor if the two are swapped.
    function _assertToken(address token, string memory symbol, uint8 decimals, string memory label) internal view {
        assertGt(token.code.length, 0, string.concat(label, ": no code"));
        assertEq(IERC20Metadata(token).symbol(), symbol, string.concat(label, ": symbol"));
        assertEq(IERC20Metadata(token).decimals(), decimals, string.concat(label, ": decimals"));
    }

    function _assertHasCode(address target, string memory label) internal view {
        assertGt(target.code.length, 0, string.concat(label, ": no code"));
    }

    /// @dev Asserts `target` is a deployed Safe, not merely a non-zero address. "Has code" is too
    ///      weak a check for a multisig constant: an address can be a live Safe on one chain and a
    ///      plain EOA on another, which is exactly how an earlier draft of these libraries came to
    ///      list a Polygon EOA as the Polygon support multisig.
    /// @return owners The Safe's owner set, so callers can compare it across chains.
    function _assertIsSafe(address target, string memory label) internal view returns (address[] memory owners) {
        _assertHasCode(target, label);
        assertGt(ISafe(target).getThreshold(), 0, string.concat(label, ": not a Safe (no threshold)"));
        owners = ISafe(target).getOwners();
        assertGt(owners.length, 0, string.concat(label, ": Safe has no owners"));
    }

    /// @dev StateView and PositionManager both expose the PoolManager they were built against.
    ///      Cross-checking them catches the realistic failure of copying one chain's row out of
    ///      the Uniswap deployments table into another chain's library.
    function _assertV4Wiring(address poolManager, address positionManager, address stateView) internal view {
        _assertHasCode(poolManager, "POOL_MANAGER");
        _assertHasCode(positionManager, "POSITION_MANAGER");
        _assertHasCode(stateView, "STATE_VIEW");
        assertEq(
            address(IImmutableState(stateView).poolManager()), poolManager, "STATE_VIEW points at a different PoolManager"
        );
        assertEq(
            address(IImmutableState(positionManager).poolManager()),
            poolManager,
            "POSITION_MANAGER points at a different PoolManager"
        );
    }

    /// @dev The cross-chain CREATE3 claim is the reason a single `TEL_V3` constant is safe to
    ///      reuse everywhere, so each chain re-asserts it rather than trusting the shared library.
    function _assertCrossChainIdentity(address telV3, address eusd) internal pure {
        assertEq(telV3, CrossChainAddresses.TEL_V3, "TEL_V3 diverged from the cross-chain constant");
        assertEq(eusd, CrossChainAddresses.EUSD, "EUSD diverged from the cross-chain constant");
    }
}

/// @title EthereumAddressesForkTest
/// @notice Verifies `script/shared/EthereumAddresses.sol` against Ethereum mainnet.
contract EthereumAddressesForkTest is ChainAddressesForkTest {
    /// @dev CI gates the fork suite on `POLYGON_RPC_URL` alone, so a repo that has that secret but
    ///      not `ETHEREUM_RPC_URL` would fail here on a missing env var rather than skipping.
    ///      Ethereum is the newest chain in these libraries and the likeliest secret to be missing,
    ///      so this suite skips itself instead of going red.
    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, EthereumAddresses.CHAIN_ID, "wrong chain");
    }

    function test_tokens() public view {
        _assertToken(EthereumAddresses.TEL_V3, "TEL", 18, "TEL_V3");
        _assertToken(EthereumAddresses.TEL_V2, "TEL", 2, "TEL_V2");
        _assertToken(EthereumAddresses.EUSD, "eUSD", 6, "EUSD");
        _assertToken(EthereumAddresses.WETH, "WETH", 18, "WETH");
        _assertToken(EthereumAddresses.USDC, "USDC", 6, "USDC");
        _assertCrossChainIdentity(EthereumAddresses.TEL_V3, EthereumAddresses.EUSD);
    }

    /// @notice eMXN is Polygon-only. Asserting the zero here keeps a future copy-paste from
    ///         quietly introducing an Ethereum eUSD/eMXN pool that has no eMXN behind it.
    function test_emxn_notDeployedOnEthereum() public pure {
        assertEq(EthereumAddresses.EMXN, address(0), "EMXN should be unset on Ethereum");
    }

    function test_uniswapV4Infrastructure() public view {
        _assertV4Wiring(
            EthereumAddresses.POOL_MANAGER, EthereumAddresses.POSITION_MANAGER, EthereumAddresses.STATE_VIEW
        );
        _assertHasCode(EthereumAddresses.UNIVERSAL_ROUTER, "UNIVERSAL_ROUTER");
        _assertHasCode(EthereumAddresses.PERMIT2, "PERMIT2");
    }

    function test_multisigs() public view {
        _assertIsSafe(EthereumAddresses.GOVERNANCE_SAFE, "GOVERNANCE_SAFE");
    }

    /// @notice Ethereum has no TELx support multisig yet, and the registry deploy cannot run until
    ///         it does. This test documents the gap and fails the moment someone fills the
    ///         constant in, prompting them to delete it and add the owner-set comparison against
    ///         Polygon that `BaseAddressesForkTest.test_supportSafe_ownersMatchPolygon` performs.
    function test_supportSafe_stillUnset() public pure {
        assertEq(
            EthereumAddresses.SUPPORT_SAFE,
            address(0),
            "Ethereum SUPPORT_SAFE is now set; replace this test with the owner-set comparison against Polygon"
        );
    }

    /// @notice The address that is easy to reach for and wrong. It is a live Safe on Ethereum, so
    ///         every structural check passes, but its owners are not the TELx ops owners. Pinned
    ///         here so the constant can never be filled with it without a test saying why not.
    function test_supportSafe_isNotTheUnrelatedEthereumSafe() public view {
        address unrelated = 0x3F00a8CE88C8cf367AD10A5675161e7AFd2472bE;
        assertTrue(unrelated.code.length > 0, "the decoy is a deployed contract on Ethereum");
        assertNotEq(EthereumAddresses.SUPPORT_SAFE, unrelated, "SUPPORT_SAFE must not be the unrelated Safe");
    }
}

/// @title PolygonAddressesForkTest
/// @notice Verifies `script/shared/PolygonAddresses.sol` against Polygon mainnet.
contract PolygonAddressesForkTest is ChainAddressesForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));
        assertEq(block.chainid, PolygonAddresses.CHAIN_ID, "wrong chain");
    }

    function test_tokens() public view {
        _assertToken(PolygonAddresses.TEL_V3, "TEL", 18, "TEL_V3");
        _assertToken(PolygonAddresses.TEL_V2, "TEL", 2, "TEL_V2");
        _assertToken(PolygonAddresses.EUSD, "eUSD", 6, "EUSD");
        _assertToken(PolygonAddresses.EMXN, "eMXN", 6, "EMXN");
        _assertToken(PolygonAddresses.WETH, "WETH", 18, "WETH");
        _assertToken(PolygonAddresses.USDC, "USDC", 6, "USDC");
        _assertCrossChainIdentity(PolygonAddresses.TEL_V3, PolygonAddresses.EUSD);
    }

    function test_uniswapV4Infrastructure() public view {
        _assertV4Wiring(PolygonAddresses.POOL_MANAGER, PolygonAddresses.POSITION_MANAGER, PolygonAddresses.STATE_VIEW);
        _assertHasCode(PolygonAddresses.UNIVERSAL_ROUTER, "UNIVERSAL_ROUTER");
        _assertHasCode(PolygonAddresses.PERMIT2, "PERMIT2");
    }

    function test_multisigs() public view {
        _assertIsSafe(PolygonAddresses.GOVERNANCE_SAFE, "GOVERNANCE_SAFE");
        _assertIsSafe(PolygonAddresses.SUPPORT_SAFE, "SUPPORT_SAFE");
    }
}

/// @title BaseAddressesForkTest
/// @notice Verifies `script/shared/BaseAddresses.sol` against Base mainnet.
contract BaseAddressesForkTest is ChainAddressesForkTest {
    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        assertEq(block.chainid, BaseAddresses.CHAIN_ID, "wrong chain");
    }

    function test_tokens() public view {
        _assertToken(BaseAddresses.TEL_V3, "TEL", 18, "TEL_V3");
        _assertToken(BaseAddresses.TEL_V2, "TEL", 2, "TEL_V2");
        _assertToken(BaseAddresses.EUSD, "eUSD", 6, "EUSD");
        _assertToken(BaseAddresses.WETH, "WETH", 18, "WETH");
        _assertToken(BaseAddresses.USDC, "USDC", 6, "USDC");
        _assertCrossChainIdentity(BaseAddresses.TEL_V3, BaseAddresses.EUSD);
    }

    function test_emxn_notDeployedOnBase() public pure {
        assertEq(BaseAddresses.EMXN, address(0), "EMXN should be unset on Base");
    }

    function test_uniswapV4Infrastructure() public view {
        _assertV4Wiring(BaseAddresses.POOL_MANAGER, BaseAddresses.POSITION_MANAGER, BaseAddresses.STATE_VIEW);
        _assertHasCode(BaseAddresses.UNIVERSAL_ROUTER, "UNIVERSAL_ROUTER");
        _assertHasCode(BaseAddresses.PERMIT2, "PERMIT2");
    }

    function test_multisigs() public view {
        _assertIsSafe(BaseAddresses.GOVERNANCE_SAFE, "GOVERNANCE_SAFE");
        _assertIsSafe(BaseAddresses.SUPPORT_SAFE, "SUPPORT_SAFE");
    }

    /// @notice The Base and Polygon support Safes are meant to be the same multisig replicated
    ///         across chains, and matching owner sets are what identify them as such. Several
    ///         addresses hold SUPPORT_ROLE on the live registries, so without this check it is easy
    ///         to pick the wrong one: 0x3F00a8CE... also holds the role on Base but has a
    ///         different owner set and is an EOA on Polygon.
    /// @dev    Reads Polygon in a second fork, then returns to Base so later tests are unaffected.
    function test_supportSafe_ownersMatchPolygon() public {
        address[] memory baseOwners = ISafe(BaseAddresses.SUPPORT_SAFE).getOwners();

        uint256 baseFork = vm.activeFork();
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));
        address[] memory polygonOwners = ISafe(PolygonAddresses.SUPPORT_SAFE).getOwners();
        vm.selectFork(baseFork);

        assertEq(baseOwners.length, polygonOwners.length, "support Safe owner counts differ");
        for (uint256 i; i < baseOwners.length; ++i) {
            assertEq(baseOwners[i], polygonOwners[i], "support Safe owner sets differ");
        }
    }
}

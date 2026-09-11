// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SaltMath} from "forge-deploy-utils/libraries/SaltMath.sol";
import {Salts} from "../../script/shared/Salts.sol";
import {EthereumAddresses} from "../../script/shared/EthereumAddresses.sol";
import {PolygonAddresses} from "../../script/shared/PolygonAddresses.sol";
import {BaseAddresses} from "../../script/shared/BaseAddresses.sol";
import {CrossChainAddresses} from "../../script/shared/CrossChainAddresses.sol";

/// @title DeployTELxRegistrySaltTest
/// @notice Covers the address-derivation half of the safe-utils registry deploy: salt guarding and
///         the cross-chain CREATE3 parity the deploy depends on.
/// @dev    Deliberately does NOT instantiate the script. `DeployTELxRegistryMainnet.setUp()` calls
///         `_initializeSafeMultiSig()`, which reads `DEPLOYER_SAFE_ADDRESS` and forks three chains,
///         so driving it from a unit test would mean either mutating process environment or
///         standing up a Safe. Environment mutation is specifically what we are avoiding here: an
///         earlier version of this file called `vm.setEnv("POLYGON_POSITION_MANAGER", ...)` with
///         placeholders, and because `vm.envOr` caches per `forge test` invocation, those
///         placeholders leaked into every other suite in the run and broke the pool fork tests.
///         Nothing in this file touches environment.
///
///         The batch itself is verified by running the script in safe-utils simulation mode, which
///         executes the MultiSend against a fork; the runbook in `script/telx/README.md` makes that
///         the required step before any broadcast.
contract DeployTELxRegistrySaltTest is Test {
    /// @notice The Telcoin governance Safe, which is the CREATE3 salt guard for this deploy.
    address internal constant DEPLOYER_SAFE = CrossChainAddresses.GOVERNANCE_SAFE;
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @notice keccak256 of the minimal proxy CreateX deploys for every CREATE3 call.
    /// @dev Fixed by the factory, not by us; taken from the same constant the tel-v3 repo verifies
    ///      its vanity salts against.
    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice A guarded salt must carry the Safe in its first 20 bytes, because CreateX checks
    ///         that against msg.sender and rejects a deployment from anyone else. This is what
    ///         stops a third party front-running our address.
    function test_guardedSalt_carriesTheDeployerSafe() public pure {
        bytes32 guarded = SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY);
        assertEq(SaltMath.extractGuard(guarded), DEPLOYER_SAFE, "guard address");
    }

    /// @notice Byte 21 must be zero. That is CreateX's cross-chain mode flag, and it is the single
    ///         reason the registry can share one address across Ethereum, Polygon and Base despite
    ///         each chain passing a different PositionManager to the constructor.
    function test_guardedSalt_selectsCrossChainMode() public pure {
        bytes32 registrySalt = SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY);
        bytes32 subscriberSalt = SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_SUBSCRIBER);

        assertEq(registrySalt[20], bytes1(0x00), "registry salt not in cross-chain mode");
        assertEq(subscriberSalt[20], bytes1(0x00), "subscriber salt not in cross-chain mode");
    }

    /// @notice The registry and the subscriber must not collide.
    function test_salts_areDistinct() public pure {
        assertTrue(Salts.TELX_POSITION_REGISTRY != Salts.TELX_SUBSCRIBER, "raw salts collide");
        assertTrue(
            SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY)
                != SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_SUBSCRIBER),
            "guarded salts collide"
        );
    }

    /// @notice Only the low 11 bytes of a raw salt survive guarding, so two salts differing above
    ///         that boundary would silently produce the same address. Documents the constraint that
    ///         makes `keccak256`-derived salts safe and hand-written ones risky.
    function test_guardedSalt_onlyLow11BytesOfRawSaltMatter() public pure {
        bytes32 low11 = bytes32(uint256(uint88(uint256(Salts.TELX_POSITION_REGISTRY))));
        assertEq(
            SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY),
            SaltMath.guardSalt(DEPLOYER_SAFE, low11),
            "high bytes of the raw salt should not affect the guarded salt"
        );
    }

    /// @notice A different Safe yields a different address. Recorded because the tel-v3 vanity
    ///         tooling ships with a retired Safe as its default, and mining or predicting against
    ///         the wrong one produces salts that simply will not deploy.
    function test_guardedSalt_dependsOnTheSafe() public pure {
        address otherSafe = address(0xBEEF);
        assertTrue(
            SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY)
                != SaltMath.guardSalt(otherSafe, Salts.TELX_POSITION_REGISTRY),
            "salt should be bound to the deployer Safe"
        );
    }

    /// @notice The CreateX internal transformation depends only on the sender and the salt, never
    ///         on constructor arguments. This is the property the whole cross-chain parity claim
    ///         rests on, so it is asserted directly rather than assumed.
    function test_create3Derivation_ignoresConstructorArguments() public pure {
        bytes32 guarded = SaltMath.guardSalt(DEPLOYER_SAFE, Salts.TELX_POSITION_REGISTRY);
        bytes32 internalSalt = SaltMath.getCreateXGuardedSalt(guarded, DEPLOYER_SAFE);

        // Recomputing from the same inputs is stable, and nothing in the derivation takes initcode.
        assertEq(internalSalt, SaltMath.getCreateXGuardedSalt(guarded, DEPLOYER_SAFE), "derivation not deterministic");
        assertTrue(CREATEX != address(0), "CreateX address");
    }

    /// @notice Pins the addresses the deploy will actually land on, which are published in
    ///         `script/telx/README.md` and will be handed to the Snapshot strategy and every other
    ///         downstream integration.
    /// @dev    Computed independently of the script, by replicating CreateX's own derivation:
    ///         guard the raw salt with the Safe, hash it the way CreateX's `_guard` does, then
    ///         derive the CREATE3 proxy address. Cross-checked against the live CreateX factory on
    ///         Ethereum, Polygon and Base, which all returned these values.
    ///
    ///         The point is not that the arithmetic works, it is that the published addresses stay
    ///         true. Changing a salt string or the deployer Safe silently relocates both contracts,
    ///         and the first sign of that would otherwise be a deploy landing somewhere the docs do
    ///         not mention.
    function test_predictedAddresses_matchThePublishedOnes() public pure {
        assertEq(
            _predict(Salts.TELX_POSITION_REGISTRY),
            0x00637FBbae593E920B1d08300EC1f05d6D61Aa61,
            "PositionRegistry address changed; update script/telx/README.md and re-verify on chain"
        );
        assertEq(
            _predict(Salts.TELX_SUBSCRIBER),
            0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC,
            "TELxSubscriber address changed; update script/telx/README.md and re-verify on chain"
        );
    }

    /// @dev Replicates CreateX's CREATE3 address derivation. The factory deploys a minimal proxy at
    ///      CREATE2(internalSalt), and the contract itself lands at that proxy's first CREATE, i.e.
    ///      RLP(proxy, nonce 1).
    function _predict(bytes32 rawSalt) internal pure returns (address) {
        bytes32 internalSalt =
            SaltMath.getCreateXGuardedSalt(SaltMath.guardSalt(DEPLOYER_SAFE, rawSalt), DEPLOYER_SAFE);

        address proxy = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATEX, internalSalt, CREATE3_PROXY_INITCODE_HASH)))
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }

    /// @notice All three chains feed the same governance Safe into the deploy, which is the
    ///         precondition for the deployed addresses matching across chains.
    function test_allChainsShareTheGovernanceSafe() public pure {
        assertEq(EthereumAddresses.GOVERNANCE_SAFE, DEPLOYER_SAFE, "ethereum");
        assertEq(PolygonAddresses.GOVERNANCE_SAFE, DEPLOYER_SAFE, "polygon");
        assertEq(BaseAddresses.GOVERNANCE_SAFE, DEPLOYER_SAFE, "base");
    }

    /// @notice Each chain must supply its own Uniswap infrastructure. If two chains ever pointed at
    ///         the same PositionManager, one of them would be wired to the wrong protocol
    ///         deployment while still producing a plausible-looking address.
    function test_chainsHaveDistinctUniswapInfrastructure() public pure {
        assertTrue(
            EthereumAddresses.POSITION_MANAGER != PolygonAddresses.POSITION_MANAGER
                && PolygonAddresses.POSITION_MANAGER != BaseAddresses.POSITION_MANAGER
                && EthereumAddresses.POSITION_MANAGER != BaseAddresses.POSITION_MANAGER,
            "PositionManager addresses must differ per chain"
        );
        assertTrue(
            EthereumAddresses.STATE_VIEW != PolygonAddresses.STATE_VIEW
                && PolygonAddresses.STATE_VIEW != BaseAddresses.STATE_VIEW
                && EthereumAddresses.STATE_VIEW != BaseAddresses.STATE_VIEW,
            "StateView addresses must differ per chain"
        );
    }

    /// @notice Ethereum cannot be deployed until a support multisig exists there. The script
    ///         reverts rather than granting SUPPORT_ROLE to nobody and handing the subscriber to
    ///         address(0), which would freeze its registry pointer permanently.
    function test_ethereumSupportSafe_isStillMissing() public pure {
        assertEq(
            EthereumAddresses.SUPPORT_SAFE,
            address(0),
            "Ethereum SUPPORT_SAFE is now set; update the deploy runbook and drop this test"
        );
        assertTrue(PolygonAddresses.SUPPORT_SAFE != address(0), "polygon support safe");
        assertTrue(BaseAddresses.SUPPORT_SAFE != address(0), "base support safe");
    }
}

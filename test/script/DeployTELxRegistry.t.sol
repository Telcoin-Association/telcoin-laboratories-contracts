// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployTELxRegistry} from "../../script/DeployTELxRegistry.s.sol";
import {PositionRegistry} from "../../contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "../../contracts/telx/core/TELxSubscriber.sol";

/// @notice Tests for the thin-registry deploy script. No fork is needed: the script deploys fresh
///         contracts and only stores the v4 infrastructure addresses, so placeholder addresses
///         drive a full end-to-end run plus the unsupported-chain guard.
contract DeployTELxRegistryTest is Test {
    address internal constant PLACEHOLDER_POSITION_MANAGER = 0x1111111111111111111111111111111111111111;
    address internal constant PLACEHOLDER_STATE_VIEW = 0x2222222222222222222222222222222222222222;
    address internal constant PLACEHOLDER_SUPPORT_SAFE = 0x3333333333333333333333333333333333333333;
    address internal constant SIGNER = address(0xD0E);

    DeployTELxRegistry internal script;

    function setUp() public {
        // every chain config field resolves from env; set placeholders before the script loads them
        string[6] memory keys = [
            "POLYGON_POSITION_MANAGER",
            "POLYGON_STATE_VIEW",
            "POLYGON_SUPPORT_SAFE",
            "BASE_POSITION_MANAGER",
            "BASE_STATE_VIEW",
            "BASE_SUPPORT_SAFE"
        ];
        address[6] memory values = [
            PLACEHOLDER_POSITION_MANAGER,
            PLACEHOLDER_STATE_VIEW,
            PLACEHOLDER_SUPPORT_SAFE,
            PLACEHOLDER_POSITION_MANAGER,
            PLACEHOLDER_STATE_VIEW,
            PLACEHOLDER_SUPPORT_SAFE
        ];
        for (uint256 i; i < keys.length; ++i) {
            vm.setEnv(keys[i], vm.toString(values[i]));
        }

        script = new DeployTELxRegistry();
        script.setUp();
    }

    function test_runWithSigner_deploysAndWiresRoles() public {
        vm.chainId(137);
        script.runWithSigner(SIGNER);

        PositionRegistry registry = script.positionRegistry();
        TELxSubscriber subscriber = script.telxSubscriber();

        assertEq(address(registry.positionManager()), PLACEHOLDER_POSITION_MANAGER, "registry positionManager");
        assertEq(address(registry.stateView()), PLACEHOLDER_STATE_VIEW, "registry stateView");
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), SIGNER), "deployer holds admin");
        assertTrue(registry.hasRole(registry.SUBSCRIBER_ROLE(), address(subscriber)), "subscriber role granted");
        assertTrue(registry.hasRole(registry.SUPPORT_ROLE(), PLACEHOLDER_SUPPORT_SAFE), "support role granted");

        assertEq(address(subscriber.registry()), address(registry), "subscriber registry");
        assertEq(subscriber.positionManager(), PLACEHOLDER_POSITION_MANAGER, "subscriber positionManager");
        assertEq(subscriber.owner(), PLACEHOLDER_SUPPORT_SAFE, "subscriber owner");
    }

    function test_runWithSigner_unsupportedChainId_reverts() public {
        vm.chainId(99_999);
        vm.expectRevert(bytes("Unsupported chainId"));
        script.runWithSigner(SIGNER);
    }

    function test_run_resolvesSignerFromDeployerPk() public {
        vm.chainId(137);
        uint256 deployerPk = uint256(0xCAFE);
        vm.setEnv("DEPLOYER_PK", vm.toString(deployerPk));

        script.run();

        assertEq(script.deployer(), vm.addr(deployerPk), "signer resolved from DEPLOYER_PK");
        assertTrue(
            script.positionRegistry().hasRole(script.positionRegistry().DEFAULT_ADMIN_ROLE(), vm.addr(deployerPk)),
            "resolved signer holds admin"
        );
    }
}

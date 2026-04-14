// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";

interface IProxyAdmin {
    function owner() external view returns (address);

    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes memory data
    ) external payable;
}

contract UpgradeCouncilMember is Script {
    // EIP-1967 storage slots
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 internal constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");

    /// @notice All proxy addresses to upgrade.
    function getProxies() internal pure returns (address[] memory proxies) {
        proxies = new address[](6);
        proxies[0] = address(0x1dfd0fB84c405780e4Eabe868A0F14107f7B46B3); // TAO Council
        proxies[1] = address(0xE22E3C3CF718974767f99f8f1628651Bd69d5915); // Platform Council
        proxies[2] = address(0xa37c7F986fd55e3e5B0542698e4Ba92a1bd61a26); // Treasury Council
        proxies[3] = address(0x24A7F8E40d2ACB8599f0C7343A68FD32f261C9Cf); // Compliance Council
        proxies[4] = address(0xdA7798516F42A5123Dc1E64974526Ad79db7D597); // TAN Council
        proxies[5] = address(0x3393BB417c770CF91741B9E5d50628efEBB9Dc24); // TELx Council
    }

    function _readAddressSlot(
        address target,
        bytes32 slot
    ) internal view returns (address) {
        bytes32 raw = vm.load(target, slot);
        return address(uint160(uint256(raw)));
    }

    function _resolveSigner() internal view returns (address signer) {
        // ---- Resolve signer (same pattern as CreateCouncilNftsAndStreams) ----
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) {
            signer = ethFrom;
        } else {
            uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
            require(pk != 0, "Set ETH_FROM (ledger) or PRIVATE_KEY");
            signer = vm.addr(pk);
        }
        return signer;
    }

    function run() external {
        address signer = _resolveSigner();
        runWithSigner(signer);
        console2.log("===== All upgrades complete =====");
    }

    function runWithSigner(
        address signer
    ) public returns (address newImplementation) {
        console2.log("Signer:", signer);

        address[] memory proxies = getProxies();

        // ---- Pre-flight: verify all proxies are valid and signer owns all ProxyAdmins ----
        for (uint256 i = 0; i < proxies.length; i++) {
            require(
                proxies[i] != address(0),
                "Proxy address not set - update getProxies()"
            );
            require(proxies[i].code.length > 0, "Proxy has no code");

            address proxyAdmin = _readAddressSlot(proxies[i], ADMIN_SLOT);
            address proxyAdminOwner = IProxyAdmin(proxyAdmin).owner();
            require(
                proxyAdminOwner == signer,
                string.concat(
                    "Signer is not ProxyAdmin owner for proxy index ",
                    vm.toString(i)
                )
            );
        }

        // ---- Snapshot pre-upgrade state ----
        uint256[] memory totalSupplies = new uint256[](proxies.length);
        address[] memory telAddresses = new address[](proxies.length);
        address[] memory lockupAddresses = new address[](proxies.length);
        uint256[] memory streamIds = new uint256[](proxies.length);

        for (uint256 i = 0; i < proxies.length; i++) {
            CouncilMember council = CouncilMember(proxies[i]);
            totalSupplies[i] = council.totalSupply();
            telAddresses[i] = address(council.TELCOIN());
            lockupAddresses[i] = address(council._lockup());
            streamIds[i] = council._id();
        }

        // ---- Begin broadcast ----
        vm.startBroadcast(signer);

        // Deploy single new implementation
        CouncilMember newImpl = new CouncilMember();
        newImplementation = address(newImpl);
        console2.log("New implementation deployed:", newImplementation);

        // Verify the constructor has disabled initializers
        (bool initSuccess, ) = newImplementation.call(
            abi.encodeWithSelector(
                CouncilMember.initialize.selector,
                IERC20(address(0)),
                "",
                "",
                ISablierV2Lockup(address(0)),
                0
            )
        );
        require(
            !initSuccess,
            "CRITICAL: implementation initializer is NOT disabled"
        );

        // Upgrade each proxy
        for (uint256 i = 0; i < proxies.length; i++) {
            address proxyAdmin = _readAddressSlot(proxies[i], ADMIN_SLOT);

            console2.log("---");
            console2.log("Upgrading proxy:", proxies[i]);
            console2.log("  ProxyAdmin:", proxyAdmin);

            IProxyAdmin(proxyAdmin).upgradeAndCall(
                proxies[i],
                newImplementation,
                bytes("") // no reinitializer needed
            );

            console2.log("  Upgraded successfully");
        }

        vm.stopBroadcast();

        // ---- Post-upgrade verification ----
        console2.log("===== Post-upgrade verification =====");

        // Ensure implementation initializer is disabled
        (bool initSuccessPost, ) = newImplementation.call(
            abi.encodeWithSelector(
                CouncilMember.initialize.selector,
                IERC20(address(0)),
                "",
                "",
                ISablierV2Lockup(address(0)),
                0
            )
        );
        require(
            !initSuccessPost,
            "CRITICAL: implementation initializer is NOT disabled"
        );
        console2.log("Implementation initializer locked: OK");

        for (uint256 i = 0; i < proxies.length; i++) {
            CouncilMember council = CouncilMember(proxies[i]);

            // Implementation slot updated
            address implAfter = _readAddressSlot(
                proxies[i],
                IMPLEMENTATION_SLOT
            );
            require(
                implAfter == newImplementation,
                "Implementation slot not updated"
            );

            // Storage preserved
            require(
                council.totalSupply() == totalSupplies[i],
                "totalSupply changed"
            );
            require(
                address(council.TELCOIN()) == telAddresses[i],
                "TELCOIN changed"
            );
            require(
                address(council._lockup()) == lockupAddresses[i],
                "lockup changed"
            );
            require(council._id() == streamIds[i], "streamId changed");

            // Verify each token's owner and balance index are intact
            for (uint256 j = 0; j < totalSupplies[i]; j++) {
                uint256 tid = council.tokenByIndex(j);
                council.ownerOf(tid); // reverts if broken
                uint256 balIdx = council.tokenIdToBalanceIndex(tid);
                council.balances(balIdx); // reverts if out of bounds
            }

            console2.log("Proxy", proxies[i], "verified OK");
        }
        return newImplementation;
    }
}

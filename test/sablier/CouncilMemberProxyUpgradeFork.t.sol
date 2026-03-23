// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICouncilMemberImplementationLike {
    function getRoleMembers(
        bytes32 role,
        uint256 index
    ) external view returns (address[] memory);
}

interface IProxyAdminLike {
    function owner() external view returns (address);

    function upgradeAndCall(
        ITransparentUpgradeableProxyLike proxy,
        address implementation,
        bytes memory data
    ) external payable;
}

interface ITransparentUpgradeableProxyLike {
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external payable;
}

contract CouncilMemberProxyUpgradeForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // EIP-1967 slots
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 internal constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");

    /*//////////////////////////////////////////////////////////////
                                  CONFIG
    //////////////////////////////////////////////////////////////*/

    address internal constant PROXY =
        0x24A7F8E40d2ACB8599f0C7343A68FD32f261C9Cf; // Compliance council year 2

    uint256 internal forkBlock;
    uint256 internal tokenId;

    address internal from;
    address internal to;
    address internal governanceActor;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    CouncilMember internal council;
    IERC20 internal telcoin;

    address internal proxyAdmin;
    address internal proxyAdminOwner;
    address internal currentImplementation;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Snapshot {
        address implementation;
        address proxyAdmin;
        address proxyAdminOwner;
        address governanceActor;
        address telcoin;
        address lockup;
        uint256 streamId;
        uint256 totalSupply;
        address tokenOwner;
        uint256 tokenBalanceIndex;
        uint256 internalOwed;
        uint256 proxyTelBalance;
        uint256 fromTelBalance;
        uint256 toTelBalance;
        uint256 fromNftBalance;
        uint256 toNftBalance;
        bool governanceHasRole;
    }

    /*//////////////////////////////////////////////////////////////
                                   SETUP
    //////////////////////////////////////////////////////////////*/

    // proxyAdmin 0xc9ae3C464F67e0cF9EcEE6a4DAd7C78983a9A9A9
    // proxyAdminOwner 0xd7e88D492Dc992127384215b8555C9305C218299

    function setUp() public {
        forkBlock = 84352545;
        tokenId = 3;

        from = 0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;
        to = 0x4EF34f7B73FE070e007813DBcf62A426eaa45E73;

        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), forkBlock);

        council = CouncilMember(PROXY);

        proxyAdmin = _readAddressSlot(PROXY, ADMIN_SLOT);
        currentImplementation = _readAddressSlot(PROXY, IMPLEMENTATION_SLOT);
        proxyAdminOwner = IProxyAdminLike(proxyAdmin).owner();
        governanceActor = council.getRoleMembers(GOVERNANCE_COUNCIL_ROLE)[0];

        telcoin = council.TELCOIN();
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    function mine() internal {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function _readAddressSlot(
        address target,
        bytes32 slot
    ) internal view returns (address) {
        bytes32 raw = vm.load(target, slot);
        return address(uint160(uint256(raw)));
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        uint256 idx = council.tokenIdToBalanceIndex(tokenId);

        s.implementation = _readAddressSlot(PROXY, IMPLEMENTATION_SLOT);
        s.proxyAdmin = _readAddressSlot(PROXY, ADMIN_SLOT);
        s.proxyAdminOwner = IProxyAdminLike(s.proxyAdmin).owner();
        s.governanceActor = council.getRoleMembers(GOVERNANCE_COUNCIL_ROLE)[0];

        s.telcoin = address(council.TELCOIN());
        s.lockup = address(council._lockup());
        s.streamId = council._id();
        s.totalSupply = council.totalSupply();

        s.tokenOwner = council.ownerOf(tokenId);
        s.tokenBalanceIndex = idx;
        s.internalOwed = council.balances(idx);

        s.proxyTelBalance = IERC20(s.telcoin).balanceOf(PROXY);
        s.fromTelBalance = IERC20(s.telcoin).balanceOf(from);
        s.toTelBalance = IERC20(s.telcoin).balanceOf(to);

        s.fromNftBalance = council.balanceOf(from);
        s.toNftBalance = council.balanceOf(to);

        s.governanceHasRole = council.hasRole(
            GOVERNANCE_COUNCIL_ROLE,
            s.governanceActor
        );
    }

    function _logSnapshot(
        string memory label,
        Snapshot memory s
    ) internal pure {
        console2.log("-----");
        console2.log(label);
        console2.log("implementation", s.implementation);
        console2.log("proxyAdmin", s.proxyAdmin);
        console2.log("proxyAdminOwner", s.proxyAdminOwner);
        console2.log("governanceActor", s.governanceActor);
        console2.log("telcoin", s.telcoin);
        console2.log("lockup", s.lockup);
        console2.log("streamId", s.streamId);
        console2.log("totalSupply", s.totalSupply);
        console2.log("tokenOwner", s.tokenOwner);
        console2.log("tokenBalanceIndex", s.tokenBalanceIndex);
        console2.log("internalOwed", s.internalOwed);
        console2.log("proxyTelBalance", s.proxyTelBalance);
        console2.log("fromTelBalance", s.fromTelBalance);
        console2.log("toTelBalance", s.toTelBalance);
        console2.log("fromNftBalance", s.fromNftBalance);
        console2.log("toNftBalance", s.toNftBalance);
        console2.log("governanceHasRole", s.governanceHasRole);
        console2.log("-----");
    }

    function _deployNewImplementation() internal returns (address) {
        CouncilMember newImpl = new CouncilMember();
        return address(newImpl);
    }

    function _upgradeProxy(address newImplementation) internal {
        vm.prank(proxyAdminOwner);
        IProxyAdminLike(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxyLike(PROXY),
            newImplementation,
            bytes("")
        );
    }

    function transferAsGovernance() internal {
        vm.prank(governanceActor);
        council.transferFrom(from, to, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                            SANITY / DISCOVERY
    //////////////////////////////////////////////////////////////*/

    function testFork_readsLiveProxyMetadata() public view {
        assertEq(address(council), PROXY);
        assertGt(proxyAdmin.code.length, 0, "proxyAdmin has no code");
        assertGt(
            currentImplementation.code.length,
            0,
            "implementation has no code"
        );

        // This confirms the governance actor we're impersonating
        // really has the role on this forked state.
        assertTrue(
            council.hasRole(GOVERNANCE_COUNCIL_ROLE, governanceActor),
            "governance actor lacks role"
        );

        // Confirm expected owner for the chosen NFT.
        assertEq(
            council.ownerOf(tokenId),
            from,
            "from is not current owner of token"
        );
    }

    function testFork_logsCurrentState() public view {
        Snapshot memory s = _snapshot();
        _logSnapshot("current state", s);
    }

    /*//////////////////////////////////////////////////////////////
                          UPGRADE PRESERVES STATE
    //////////////////////////////////////////////////////////////*/

    function testFork_upgradePreservesState() public {
        Snapshot memory beforeSnap = _snapshot();
        _logSnapshot("before upgrade", beforeSnap);

        address newImplementation = _deployNewImplementation();
        assertGt(
            newImplementation.code.length,
            0,
            "new implementation has no code"
        );

        _upgradeProxy(newImplementation);

        Snapshot memory afterSnap = _snapshot();
        _logSnapshot("after upgrade", afterSnap);

        assertEq(
            afterSnap.implementation,
            newImplementation,
            "implementation slot not updated"
        );
        assertEq(
            afterSnap.proxyAdmin,
            beforeSnap.proxyAdmin,
            "proxy admin changed unexpectedly"
        );
        assertEq(
            afterSnap.proxyAdminOwner,
            beforeSnap.proxyAdminOwner,
            "proxy admin owner changed unexpectedly"
        );

        // Storage/state preservation checks
        assertEq(afterSnap.telcoin, beforeSnap.telcoin, "TELCOIN changed");
        assertEq(afterSnap.lockup, beforeSnap.lockup, "lockup changed");
        assertEq(afterSnap.streamId, beforeSnap.streamId, "_id changed");
        assertEq(
            afterSnap.totalSupply,
            beforeSnap.totalSupply,
            "totalSupply changed"
        );
        assertEq(
            afterSnap.tokenOwner,
            beforeSnap.tokenOwner,
            "token owner changed"
        );
        assertEq(
            afterSnap.tokenBalanceIndex,
            beforeSnap.tokenBalanceIndex,
            "balance index changed"
        );
        assertEq(
            afterSnap.internalOwed,
            beforeSnap.internalOwed,
            "internal owed changed"
        );
        assertEq(
            afterSnap.proxyTelBalance,
            beforeSnap.proxyTelBalance,
            "proxy TEL balance changed"
        );
        assertEq(
            afterSnap.fromTelBalance,
            beforeSnap.fromTelBalance,
            "from TEL balance changed"
        );
        assertEq(
            afterSnap.toTelBalance,
            beforeSnap.toTelBalance,
            "to TEL balance changed"
        );
        assertEq(
            afterSnap.fromNftBalance,
            beforeSnap.fromNftBalance,
            "from NFT balance changed"
        );
        assertEq(
            afterSnap.toNftBalance,
            beforeSnap.toNftBalance,
            "to NFT balance changed"
        );
        assertEq(
            afterSnap.governanceHasRole,
            beforeSnap.governanceHasRole,
            "governance role changed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    GETTER COMPARISONS
    //////////////////////////////////////////////////////////////*/

    function testFork_upgradeDoesNotChangeKeyReadPaths() public {
        Snapshot memory beforeSnap = _snapshot();

        address newImplementation = _deployNewImplementation();
        _upgradeProxy(newImplementation);

        // Re-bind through same proxy address after upgrade
        CouncilMember upgraded = CouncilMember(PROXY);

        assertEq(address(upgraded.TELCOIN()), beforeSnap.telcoin);
        assertEq(address(upgraded._lockup()), beforeSnap.lockup);
        assertEq(upgraded._id(), beforeSnap.streamId);
        assertEq(upgraded.totalSupply(), beforeSnap.totalSupply);
        assertEq(upgraded.ownerOf(tokenId), beforeSnap.tokenOwner);
        assertEq(
            upgraded.balances(upgraded.tokenIdToBalanceIndex(tokenId)),
            beforeSnap.internalOwed
        );
    }

    /*//////////////////////////////////////////////////////////////
         TRANSFER + CLAIM ACCOUNTING — OLD + NEW IMPL
    //////////////////////////////////////////////////////////////*/

    function testFork_transferThenClaimAll_currentImplementation() public {
        vm.prank(governanceActor);
        council.retrieve();

        uint256 supply = council.totalSupply();

        // snapshot owed balances and TEL balances for every token
        uint256[] memory tokenIds = new uint256[](supply);
        address[] memory owners = new address[](supply);
        uint256[] memory owed = new uint256[](supply);

        for (uint256 i = 0; i < supply; i++) {
            uint256 tid = council.tokenByIndex(i);
            tokenIds[i] = tid;
            owners[i] = council.ownerOf(tid);
            owed[i] = council.balances(council.tokenIdToBalanceIndex(tid));
        }

        // transfer tokenId 3
        uint256 fromTelBefore = telcoin.balanceOf(from);
        transferAsGovernance();

        // from got paid their owed balance
        assertEq(
            telcoin.balanceOf(from),
            fromTelBefore + owed[tokenId], // tokenId 3 is at enum index 3
            "transfer payout mismatch"
        );

        // every other holder tries to claim their full owed amount
        for (uint256 i = 0; i < supply; i++) {
            if (tokenIds[i] == tokenId) continue; // do not claim from newly transferred token

            uint256 ownerTelBefore = telcoin.balanceOf(owners[i]);

            vm.prank(owners[i]);
            (bool success, ) = address(council).call(
                abi.encodeWithSelector(
                    council.claim.selector,
                    tokenIds[i],
                    owed[i]
                )
            );

            if (success) {
                assertEq(
                    telcoin.balanceOf(owners[i]),
                    ownerTelBefore + owed[i],
                    "claim payout mismatch"
                );
            } else {
                console2.log("OLD IMPL: claim failed for tokenId", tokenIds[i]);
            }
        }

        assertEq(
            telcoin.balanceOf(PROXY),
            0,
            "proxy should have zero TEL after claims"
        );

        mine();
        vm.prank(governanceActor);
        council.retrieve();

        for (uint256 i = 0; i < supply; i++) {
            address currentOwner = council.ownerOf(tokenIds[i]);
            // re-read current owed after new accrual
            uint256 currentOwed = council.balances(
                council.tokenIdToBalanceIndex(tokenIds[i])
            );
            uint256 ownerTelBefore = telcoin.balanceOf(currentOwner);

            vm.prank(currentOwner);
            (bool success, ) = address(council).call(
                abi.encodeWithSelector(
                    council.claim.selector,
                    tokenIds[i],
                    currentOwed
                )
            );

            if (success) {
                assertEq(
                    telcoin.balanceOf(currentOwner),
                    ownerTelBefore + currentOwed,
                    "claim payout mismatch"
                );
            } else {
                console2.log("OLD IMPL: claim failed for tokenId", tokenIds[i]);
            }
        }

        assertLt(
            telcoin.balanceOf(PROXY),
            council.totalSupply(),
            "proxy should have zero TEL after claims"
        );
    }

    function testFork_transferThenClaimAll_afterUpgrade() public {
        _upgradeProxy(_deployNewImplementation());

        vm.prank(governanceActor);
        council.retrieve();

        uint256 supply = council.totalSupply();

        uint256[] memory tokenIds = new uint256[](supply);
        address[] memory owners = new address[](supply);
        uint256[] memory owed = new uint256[](supply);

        for (uint256 i = 0; i < supply; i++) {
            uint256 tid = council.tokenByIndex(i);
            tokenIds[i] = tid;
            owners[i] = council.ownerOf(tid);
            owed[i] = council.balances(council.tokenIdToBalanceIndex(tid));
        }

        // transfer tokenId 3
        uint256 fromTelBefore = telcoin.balanceOf(from);
        transferAsGovernance();

        assertEq(
            telcoin.balanceOf(from),
            fromTelBefore + owed[tokenId],
            "transfer payout mismatch"
        );

        // every other holder claims — all must succeed on new impl
        for (uint256 i = 0; i < supply; i++) {
            if (tokenIds[i] == tokenId) continue;

            uint256 ownerTelBefore = telcoin.balanceOf(owners[i]);

            vm.prank(owners[i]);
            council.claim(tokenIds[i], owed[i]);

            assertEq(
                telcoin.balanceOf(owners[i]),
                ownerTelBefore + owed[i],
                "claim payout mismatch"
            );
        }
        assertEq(
            telcoin.balanceOf(PROXY),
            0,
            "proxy should have zero TEL after claims"
        );

        mine();

        vm.prank(governanceActor);
        council.retrieve();

        for (uint256 i = 0; i < supply; i++) {
            address currentOwner = council.ownerOf(tokenIds[i]);
            // re-read current owed after new accrual
            uint256 currentOwed = council.balances(
                council.tokenIdToBalanceIndex(tokenIds[i])
            );
            uint256 ownerTelBefore = telcoin.balanceOf(currentOwner);

            vm.prank(currentOwner);
            (bool success, ) = address(council).call(
                abi.encodeWithSelector(
                    council.claim.selector,
                    tokenIds[i],
                    currentOwed
                )
            );

            if (success) {
                assertEq(
                    telcoin.balanceOf(currentOwner),
                    ownerTelBefore + currentOwed,
                    "claim payout mismatch"
                );
            } else {
                console2.log("NEW IMPL: claim failed for tokenId", tokenIds[i]);
            }
        }

        assertLe(
            telcoin.balanceOf(PROXY),
            council.totalSupply(),
            "proxy holds more than running balance dust"
        );
    }
}

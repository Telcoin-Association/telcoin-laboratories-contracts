// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {UpgradeCouncilMember} from "../../script/sablier/UpgradeCouncilMember.s.sol";
import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";

interface IProxyAdminLike {
    function owner() external view returns (address);

    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes memory data
    ) external payable;
}

contract UpgradeCouncilMemberHarness is UpgradeCouncilMember {
    function exposed_getProxies() external pure returns (address[] memory) {
        return getProxies();
    }

    function exposed_readAddressSlot(
        address target,
        bytes32 slot
    ) external view returns (address) {
        return _readAddressSlot(target, slot);
    }

    function exposed_runWithSigner(
        address signer
    ) external returns (address newImplementation) {
        return runWithSigner(signer);
    }
}

contract CouncilMemberUpgradeForkTest is Test {
    // ---------
    // CONSTANTS
    // ---------

    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 internal constant GOVERNANCE_COUNCIL_ROLE =
        keccak256("GOVERNANCE_COUNCIL_ROLE");

    // ---------------------------
    // REPRESENTATIVE PROXY CONFIG
    // ---------------------------

    // Compliance Council proxy (example) from UpgradeCouncilMember::getProxies()[3]
    // the representative proxy we run functional behavior tests against
    address internal constant BEHAVIOUR_PROXY =
        0x24A7F8E40d2ACB8599f0C7343A68FD32f261C9Cf;

    // Address of compliance council's safe, which should have both GOVERNANCE_COUNCIL_ROLE and SUPPORT_ROLE
    address internal constant EXPECTED_SAFE =
        0x0454D03C2010862277262Cb306749e829ee97591;

    // From getCouncilsInfo() compliance council (behaviour proxy) members
    address internal constant MEMBER_0 =
        0x5e671bB9F225F3090DA69BB374a648d0F15fF3fB;
    address internal constant MEMBER_1 =
        0x19BeC353c5eFdEBEEdfA88698BcF89225F9325EE;
    address internal constant MEMBER_2 =
        0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;
    address internal constant MEMBER_3 =
        0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;

    // -----
    // STATE
    // -----

    UpgradeCouncilMemberHarness internal script;
    uint256 internal forkId;

    CouncilMember internal behaviourCouncil;
    IERC20 internal behaviourTelcoin;

    address internal behaviourProxyAdmin;
    address internal behaviourProxyAdminOwner;
    address internal behaviourCurrentImplementation;
    address internal behaviourGovernanceActor;

    uint256 internal behaviourTokenId;
    address internal behaviourFrom;
    address internal behaviourTo;

    // -----
    // TYPES
    // -----

    struct GlobalSnapshot {
        address proxy;
        address proxyAdmin;
        address implBefore;
        uint256 totalSupply;
        address tel;
        address lockup;
        uint256 streamId;
        uint256[] tokenIds;
        address[] tokenOwners;
        uint256[] tokenBalanceIndexes;
        uint256[] internalOwed;
    }

    struct BehaviourSnapshot {
        address implementation;
        address proxyAdmin;
        address proxyAdminOwner;
        address governanceActor;
        address telcoin;
        address lockup;
        uint256 streamId;
        uint256 totalSupply;
        uint256[] tokenIds;
        address[] tokenOwners;
        uint256[] tokenBalanceIndexes;
        uint256[] internalOwed;
        uint256 proxyTelBalance;
        uint256 fromTelBalance;
        uint256 toTelBalance;
        uint256 fromNftBalance;
        uint256 toNftBalance;
        bool governanceHasRole;
        bool safeHasGovernanceRole;
        bool safeHasSupportRole;
    }

    // -----
    // SETUP
    // -----

    function setUp() external {
        string memory rpcUrl = vm.envString("POLYGON_RPC_URL");
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));

        if (forkBlock == 0) {
            forkId = vm.createFork(rpcUrl, uint256(84352545));
        } else {
            forkId = vm.createFork(rpcUrl, forkBlock);
        }
        vm.selectFork(forkId);

        script = new UpgradeCouncilMemberHarness();

        behaviourCouncil = CouncilMember(BEHAVIOUR_PROXY);
        behaviourProxyAdmin = _readAddressSlot(BEHAVIOUR_PROXY, ADMIN_SLOT);
        behaviourCurrentImplementation = _readAddressSlot(
            BEHAVIOUR_PROXY,
            IMPLEMENTATION_SLOT
        );
        behaviourProxyAdminOwner = IProxyAdminLike(behaviourProxyAdmin).owner();
        behaviourGovernanceActor = behaviourCouncil.getRoleMembers(
            GOVERNANCE_COUNCIL_ROLE
        )[0];
        behaviourTelcoin = behaviourCouncil.TELCOIN();

        // Representative transfer scenario on compliance council
        behaviourTokenId = 3;
        behaviourFrom = MEMBER_2;
        behaviourTo = makeAddr("behaviourTo");
    }

    // -------
    // HELPERS
    // -------

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

    function _assertImplementationInitializerLocked(
        address implementation
    ) internal {
        (bool success, ) = implementation.call(
            abi.encodeWithSelector(
                CouncilMember.initialize.selector,
                IERC20(address(0)),
                "",
                "",
                ISablierV2Lockup(address(0)),
                0
            )
        );
        assertFalse(success, "implementation initializer is not locked");
    }

    function _snapshotGlobalProxy(
        address proxy,
        address proxyAdmin
    ) internal view returns (GlobalSnapshot memory s) {
        CouncilMember council = CouncilMember(proxy);

        s.proxy = proxy;
        s.proxyAdmin = proxyAdmin;
        s.implBefore = _readAddressSlot(proxy, IMPLEMENTATION_SLOT);
        s.totalSupply = council.totalSupply();
        s.tel = address(council.TELCOIN());
        s.lockup = address(council._lockup());
        s.streamId = council._id();

        s.tokenIds = new uint256[](s.totalSupply);
        s.tokenOwners = new address[](s.totalSupply);
        s.tokenBalanceIndexes = new uint256[](s.totalSupply);
        s.internalOwed = new uint256[](s.totalSupply);

        for (uint256 j = 0; j < s.totalSupply; j++) {
            uint256 tid = council.tokenByIndex(j);
            uint256 balIdx = council.tokenIdToBalanceIndex(tid);

            s.tokenIds[j] = tid;
            s.tokenOwners[j] = council.ownerOf(tid);
            s.tokenBalanceIndexes[j] = balIdx;
            s.internalOwed[j] = council.balances(balIdx);
        }
    }

    function _snapshotBehaviour()
        internal
        view
        returns (BehaviourSnapshot memory s)
    {
        s.implementation = _readAddressSlot(
            BEHAVIOUR_PROXY,
            IMPLEMENTATION_SLOT
        );
        s.proxyAdmin = _readAddressSlot(BEHAVIOUR_PROXY, ADMIN_SLOT);
        s.proxyAdminOwner = IProxyAdminLike(s.proxyAdmin).owner();
        s.governanceActor = behaviourCouncil.getRoleMembers(
            GOVERNANCE_COUNCIL_ROLE
        )[0];

        s.telcoin = address(behaviourCouncil.TELCOIN());
        s.lockup = address(behaviourCouncil._lockup());
        s.streamId = behaviourCouncil._id();
        s.totalSupply = behaviourCouncil.totalSupply();

        s.tokenIds = new uint256[](s.totalSupply);
        s.tokenOwners = new address[](s.totalSupply);
        s.tokenBalanceIndexes = new uint256[](s.totalSupply);
        s.internalOwed = new uint256[](s.totalSupply);

        for (uint256 i = 0; i < s.totalSupply; i++) {
            uint256 tid = behaviourCouncil.tokenByIndex(i);
            uint256 balIdx = behaviourCouncil.tokenIdToBalanceIndex(tid);

            s.tokenIds[i] = tid;
            s.tokenOwners[i] = behaviourCouncil.ownerOf(tid);
            s.tokenBalanceIndexes[i] = balIdx;
            s.internalOwed[i] = behaviourCouncil.balances(balIdx);
        }

        s.proxyTelBalance = IERC20(s.telcoin).balanceOf(BEHAVIOUR_PROXY);
        s.fromTelBalance = IERC20(s.telcoin).balanceOf(behaviourFrom);
        s.toTelBalance = IERC20(s.telcoin).balanceOf(behaviourTo);
        s.fromNftBalance = behaviourCouncil.balanceOf(behaviourFrom);
        s.toNftBalance = behaviourCouncil.balanceOf(behaviourTo);

        s.governanceHasRole = behaviourCouncil.hasRole(
            GOVERNANCE_COUNCIL_ROLE,
            s.governanceActor
        );
        s.safeHasGovernanceRole = behaviourCouncil.hasRole(
            GOVERNANCE_COUNCIL_ROLE,
            EXPECTED_SAFE
        );
        s.safeHasSupportRole = behaviourCouncil.hasRole(
            behaviourCouncil.SUPPORT_ROLE(),
            EXPECTED_SAFE
        );
    }

    function _transferAsGovernance() internal {
        vm.prank(behaviourGovernanceActor);
        behaviourCouncil.transferFrom(
            behaviourFrom,
            behaviourTo,
            behaviourTokenId
        );
    }

    function _assertBehaviourStaticStateMatchesSnapshot(
        BehaviourSnapshot memory beforeSnap
    ) internal view {
        assertEq(
            address(behaviourCouncil.TELCOIN()),
            beforeSnap.telcoin,
            "TELCOIN changed"
        );
        assertEq(
            address(behaviourCouncil._lockup()),
            beforeSnap.lockup,
            "lockup changed"
        );
        assertEq(behaviourCouncil._id(), beforeSnap.streamId, "_id changed");
        assertEq(
            behaviourCouncil.totalSupply(),
            beforeSnap.totalSupply,
            "totalSupply changed"
        );

        assertEq(
            behaviourCouncil.hasRole(GOVERNANCE_COUNCIL_ROLE, EXPECTED_SAFE),
            beforeSnap.safeHasGovernanceRole,
            "safe governance role changed"
        );
        assertEq(
            behaviourCouncil.hasRole(
                behaviourCouncil.SUPPORT_ROLE(),
                EXPECTED_SAFE
            ),
            beforeSnap.safeHasSupportRole,
            "safe support role changed"
        );

        for (uint256 i = 0; i < beforeSnap.totalSupply; i++) {
            uint256 tid = beforeSnap.tokenIds[i];

            assertEq(
                behaviourCouncil.tokenByIndex(i),
                tid,
                "tokenByIndex changed"
            );
            assertEq(
                behaviourCouncil.ownerOf(tid),
                beforeSnap.tokenOwners[i],
                "ownerOf changed"
            );
            assertEq(
                behaviourCouncil.tokenIdToBalanceIndex(tid),
                beforeSnap.tokenBalanceIndexes[i],
                "tokenIdToBalanceIndex changed"
            );
            assertEq(
                behaviourCouncil.balances(
                    behaviourCouncil.tokenIdToBalanceIndex(tid)
                ),
                beforeSnap.internalOwed[i],
                "balances changed"
            );
        }
    }

    // --------------------------
    // SCRIPT-LEVEL REAL COVERAGE
    // --------------------------

    function test_liveFork_scriptRun_upgradesAllProxiesAndPreservesState()
        external
    {
        address[] memory proxies = script.exposed_getProxies();
        uint256 len = proxies.length;
        assertEq(len, 6, "unexpected proxy count");

        GlobalSnapshot[] memory beforeState = new GlobalSnapshot[](len);

        // assume same signer owns all ProxyAdmins, and infer that signer from first ProxyAdmin owner
        address expectedSigner = IProxyAdminLike(
            script.exposed_readAddressSlot(proxies[0], ADMIN_SLOT)
        ).owner();

        for (uint256 i = 0; i < len; i++) {
            address proxy = proxies[i];
            assertTrue(proxy != address(0), "proxy is zero");
            assertGt(proxy.code.length, 0, "proxy has no code");

            address proxyAdmin = script.exposed_readAddressSlot(
                proxy,
                ADMIN_SLOT
            );
            assertTrue(proxyAdmin != address(0), "proxy admin is zero");
            assertGt(proxyAdmin.code.length, 0, "proxy admin has no code");

            address owner = IProxyAdminLike(proxyAdmin).owner();
            assertEq(
                owner,
                expectedSigner,
                string.concat(
                    "proxy admin owner mismatch at index ",
                    vm.toString(i)
                )
            );

            beforeState[i] = _snapshotGlobalProxy(proxy, proxyAdmin);
        }

        address newImplementation = script.exposed_runWithSigner(
            expectedSigner
        );

        assertTrue(
            newImplementation != address(0),
            "new implementation is zero"
        );
        assertTrue(
            newImplementation != beforeState[0].implBefore, // all proxies point to same implementation, just use first
            "implementation did not change"
        );
        assertGt(
            newImplementation.code.length,
            0,
            "new implementation has no code"
        );

        _assertImplementationInitializerLocked(newImplementation);

        for (uint256 i = 0; i < len; i++) {
            GlobalSnapshot memory snap = beforeState[i];
            CouncilMember council = CouncilMember(snap.proxy);

            address implAfter = script.exposed_readAddressSlot(
                snap.proxy,
                IMPLEMENTATION_SLOT
            );
            assertEq(
                implAfter,
                newImplementation,
                "implementation slot mismatch"
            );

            address adminAfter = script.exposed_readAddressSlot(
                snap.proxy,
                ADMIN_SLOT
            );
            assertEq(adminAfter, snap.proxyAdmin, "proxy admin changed");

            assertEq(
                council.totalSupply(),
                snap.totalSupply,
                "totalSupply changed"
            );
            assertEq(address(council.TELCOIN()), snap.tel, "TELCOIN changed");
            assertEq(address(council._lockup()), snap.lockup, "lockup changed");
            assertEq(council._id(), snap.streamId, "streamId changed");

            assertEq(
                council.totalSupply(),
                snap.tokenIds.length,
                "snapshot supply mismatch"
            );

            for (uint256 j = 0; j < snap.totalSupply; j++) {
                uint256 tidAfter = council.tokenByIndex(j);
                assertEq(tidAfter, snap.tokenIds[j], "tokenByIndex changed");

                address ownerAfter = council.ownerOf(tidAfter);
                assertEq(ownerAfter, snap.tokenOwners[j], "ownerOf changed");

                uint256 balIdxAfter = council.tokenIdToBalanceIndex(tidAfter);
                assertEq(
                    balIdxAfter,
                    snap.tokenBalanceIndexes[j],
                    "tokenIdToBalanceIndex changed"
                );

                assertEq(
                    council.balances(balIdxAfter),
                    snap.internalOwed[j],
                    "balances changed"
                );
            }
        }
    }

    function test_liveFork_reverts_ifSignerIsNotProxyAdminOwner() external {
        address badSigner = makeAddr("badSigner");

        vm.expectRevert();
        script.exposed_runWithSigner(badSigner);
    }

    /// @dev Exercises the full script entrypoint (`run()`), which drives
    ///      `_resolveSigner` through the ETH_FROM env path. This is the
    ///      only coverage for signer resolution; the other script tests
    ///      call `runWithSigner` directly and would miss a regression in
    ///      `_resolveSigner`.
    function test_liveFork_scriptRun_viaEthFromEnv() external {
        address[] memory proxies = script.exposed_getProxies();
        address expectedSigner = IProxyAdminLike(
            script.exposed_readAddressSlot(proxies[0], ADMIN_SLOT)
        ).owner();

        address implBefore = script.exposed_readAddressSlot(
            proxies[0],
            IMPLEMENTATION_SLOT
        );

        vm.setEnv("ETH_FROM", vm.toString(expectedSigner));
        script.run();

        address implAfter = script.exposed_readAddressSlot(
            proxies[0],
            IMPLEMENTATION_SLOT
        );
        assertTrue(
            implAfter != address(0),
            "implementation slot is zero after run()"
        );
        assertTrue(
            implAfter != implBefore,
            "implementation did not change after run()"
        );
        assertGt(implAfter.code.length, 0, "new implementation has no code");
        _assertImplementationInitializerLocked(implAfter);

        for (uint256 i = 1; i < proxies.length; i++) {
            assertEq(
                script.exposed_readAddressSlot(proxies[i], IMPLEMENTATION_SLOT),
                implAfter,
                "proxy not at new implementation after run()"
            );
        }
    }

    // ---------------------------
    // REPRESENTATIVE PROXY SANITY
    // ---------------------------

    function testFork_representative_readsLiveProxyMetadata() external view {
        assertEq(address(behaviourCouncil), BEHAVIOUR_PROXY);
        assertGt(behaviourProxyAdmin.code.length, 0, "proxyAdmin has no code");
        assertGt(
            behaviourCurrentImplementation.code.length,
            0,
            "implementation has no code"
        );

        assertTrue(
            behaviourCouncil.hasRole(
                GOVERNANCE_COUNCIL_ROLE,
                behaviourGovernanceActor
            ),
            "governance actor lacks role"
        );

        assertTrue(
            behaviourCouncil.hasRole(GOVERNANCE_COUNCIL_ROLE, EXPECTED_SAFE),
            "expected safe lacks governance role"
        );

        assertTrue(
            behaviourCouncil.hasRole(
                behaviourCouncil.SUPPORT_ROLE(),
                EXPECTED_SAFE
            ),
            "expected safe lacks support role"
        );

        assertEq(
            behaviourCouncil.totalSupply(),
            4,
            "unexpected compliance supply"
        );

        assertEq(behaviourCouncil.ownerOf(0), MEMBER_0, "owner(0) mismatch");
        assertEq(behaviourCouncil.ownerOf(1), MEMBER_1, "owner(1) mismatch");
        assertEq(behaviourCouncil.ownerOf(2), MEMBER_2, "owner(2) mismatch");
        assertEq(behaviourCouncil.ownerOf(3), MEMBER_3, "owner(3) mismatch");

        assertEq(
            behaviourCouncil.ownerOf(behaviourTokenId),
            behaviourFrom,
            "from is not current owner of token"
        );
    }

    // ------------------------------------------
    // REPRESENTATIVE PROXY POST-SCRIPT BEHAVIOUR
    // ------------------------------------------

    /// @dev Ensure TEL/NFT balances for proxy/from/to and the governance/safe roles are preserved.
    function testFork_scriptUpgrade_representativeBalanceAndRoleDeltas()
        external
    {
        BehaviourSnapshot memory beforeSnap = _snapshotBehaviour();

        address[] memory proxies = script.exposed_getProxies();
        address expectedSigner = IProxyAdminLike(
            script.exposed_readAddressSlot(proxies[0], ADMIN_SLOT)
        ).owner();

        // Run the script with the expected signer
        address newImplementation = script.exposed_runWithSigner(
            expectedSigner
        );

        assertEq(
            _readAddressSlot(BEHAVIOUR_PROXY, IMPLEMENTATION_SLOT),
            newImplementation,
            "representative proxy not upgraded"
        );

        BehaviourSnapshot memory afterSnap = _snapshotBehaviour();

        // ensure change of implementation did not affect any of these balances or roles, which are critical for the representative transfer scenario
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
        assertEq(
            afterSnap.safeHasGovernanceRole,
            beforeSnap.safeHasGovernanceRole,
            "safe governance role changed"
        );
        assertEq(
            afterSnap.safeHasSupportRole,
            beforeSnap.safeHasSupportRole,
            "safe support role changed"
        );
    }

    // final run through test, covered by Council Member unit tests
    function testFork_scriptUpgrade_thenRepresentative_transferThenClaimAll()
        external
    {
        BehaviourSnapshot memory beforeSnap = _snapshotBehaviour();

        address[] memory proxies = script.exposed_getProxies();
        address expectedSigner = IProxyAdminLike(
            script.exposed_readAddressSlot(proxies[0], ADMIN_SLOT)
        ).owner();

        address newImplementation = script.exposed_runWithSigner(
            expectedSigner
        );
        _assertImplementationInitializerLocked(newImplementation);

        // confirm static state preserved on representative proxy before exercising behaviour
        assertEq(
            _readAddressSlot(BEHAVIOUR_PROXY, IMPLEMENTATION_SLOT),
            newImplementation,
            "representative proxy not upgraded"
        );
        _assertBehaviourStaticStateMatchesSnapshot(beforeSnap);

        vm.prank(behaviourGovernanceActor);
        behaviourCouncil.retrieve();

        uint256 supply = behaviourCouncil.totalSupply();

        uint256[] memory tokenIds = new uint256[](supply);
        address[] memory owners = new address[](supply);
        uint256[] memory owed = new uint256[](supply);

        for (uint256 i = 0; i < supply; i++) {
            uint256 tid = behaviourCouncil.tokenByIndex(i);
            tokenIds[i] = tid;
            owners[i] = behaviourCouncil.ownerOf(tid);
            owed[i] = behaviourCouncil.balances(
                behaviourCouncil.tokenIdToBalanceIndex(tid)
            );
        }

        uint256 transferTokenOwed = behaviourCouncil.balances(
            behaviourCouncil.tokenIdToBalanceIndex(behaviourTokenId)
        );

        uint256 fromTelBefore = behaviourTelcoin.balanceOf(behaviourFrom);
        _transferAsGovernance();

        assertEq(
            behaviourTelcoin.balanceOf(behaviourFrom),
            fromTelBefore + transferTokenOwed,
            "transfer payout mismatch"
        );

        for (uint256 i = 0; i < supply; i++) {
            if (tokenIds[i] == behaviourTokenId) continue;

            uint256 ownerTelBefore = behaviourTelcoin.balanceOf(owners[i]);

            vm.prank(owners[i]);
            behaviourCouncil.claim(tokenIds[i], owed[i]);

            assertEq(
                behaviourTelcoin.balanceOf(owners[i]),
                ownerTelBefore + owed[i],
                "claim payout mismatch"
            );
        }

        assertEq(
            behaviourTelcoin.balanceOf(BEHAVIOUR_PROXY),
            0,
            "proxy should have zero TEL after claims"
        );

        mine();

        vm.prank(behaviourGovernanceActor);
        behaviourCouncil.retrieve();

        for (uint256 i = 0; i < supply; i++) {
            address currentOwner = behaviourCouncil.ownerOf(tokenIds[i]);
            uint256 currentOwed = behaviourCouncil.balances(
                behaviourCouncil.tokenIdToBalanceIndex(tokenIds[i])
            );
            uint256 ownerTelBefore = behaviourTelcoin.balanceOf(currentOwner);

            vm.prank(currentOwner);
            behaviourCouncil.claim(tokenIds[i], currentOwed);

            assertEq(
                behaviourTelcoin.balanceOf(currentOwner),
                ownerTelBefore + currentOwed,
                "post-upgrade claim payout mismatch"
            );
        }

        assertLe(
            behaviourTelcoin.balanceOf(BEHAVIOUR_PROXY),
            behaviourCouncil.totalSupply(),
            "proxy holds more than running balance dust"
        );
    }

}

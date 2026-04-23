// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployBalancerAdaptor} from "../../script/DeployBalancerAdaptor.s.sol";
import {BalancerAdaptor} from "../../contracts/snapshot/adaptors/BalancerAdaptor.sol";
import {StakingRewardsAdaptor} from "../../contracts/snapshot/adaptors/StakingRewardsAdaptor.sol";
import {VotingWeightCalculator} from "../../contracts/snapshot/core/VotingWeightCalculator.sol";
import {ISource} from "../../contracts/snapshot/interfaces/ISource.sol";
import {TestConstants} from "../util/TestConstants.sol";

/// @notice Polygon-fork test of DeployBalancerAdaptor. Exercises the full
///         `runWithSigner(signer)` flow: deploys VotingWeightCalculator,
///         three BalancerAdaptors and three StakingRewardsAdaptors, registers
///         each adaptor as a source on the calculator, and begins ownership
///         transfer.
/// @dev    The script uses CREATE2 with keccak256("VotingWeightCalculator") as
///         salt. CREATE2 is scoped to the calling contract (the script
///         instance we deploy here), so the resulting address never collides
///         with prior mainnet deployments made by other script instances.
contract DeployBalancerAdaptorForkTest is Test {
    // ---------------------------------------------------------------------
    // These constants MIRROR the hardcoded addresses inside
    // script/DeployBalancerAdaptor.s.sol::_getConfigs(). They're duplicated
    // here (rather than exposed via a harness) because `_getConfigs` is
    // internal + pure with no external entry point. If the script's configs
    // ever change, update BOTH. Consider this the single-source-of-truth
    // reference; the table below is the mirror.
    // ---------------------------------------------------------------------
    address internal constant TELCOIN = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant PENDING_OWNER = 0xc1612C97537c2CC62a11FC4516367AB6F62d4B23;

    address internal constant POOL0 = 0xcA6EFA5704f1Ae445e0EE24D9c3Ddde34c5be1C2; // TEL80/WETH20
    address internal constant POOL1 = 0x3bd8a254163f8328efCC4F8c36da566753462433; // TEL80/USDC20
    address internal constant POOL2 = 0xE1E09ce7aAC2740846d9B6D9D56f588c65314eCB; // TEL80/WBTC20

    address internal constant STAKING0 = 0x7fEb8FEbddB66189417f732B4221a52E23B926C4;
    address internal constant STAKING1 = 0x8f702676830ddCA2801A4a7cDB971CDE4DF697AE;
    address internal constant STAKING2 = 0x79E5A6fFe2E6bA053A80e1B199c4F328938F40CA;

    DeployBalancerAdaptor internal deployScript;
    address internal deployer;

    function setUp() public {
        uint256 forkBlock =
            vm.envOr("FORK_BLOCK_NUMBER", TestConstants.DEFAULT_POLYGON_FORK_BLOCK);
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), forkBlock);
        deployer = makeAddr("deployer");
        deployScript = new DeployBalancerAdaptor();
    }

    /*//////////////////////////////////////////////////////////////
                        _resolveSigner paths via run()

        vm.envOr appears to cache within a single forge test invocation,
        which makes split-test coverage of the three env-var paths
        unreliable — one test sets ETH_FROM, a later test can't flip it
        back because the cached first-read value sticks. The robust
        workaround is to exercise all three paths sequentially in a
        single test with a fresh DeployBalancerAdaptor instance per path.
    //////////////////////////////////////////////////////////////*/

    function test_run_resolveSigner_allPaths() public {
        address testEthFrom = makeAddr("ethFromLedger");
        uint256 testPk = 0xA11CE;
        address pkSigner = vm.addr(testPk);

        // Path 1: ETH_FROM set → used directly.
        vm.setEnv("ETH_FROM", vm.toString(testEthFrom));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0)));
        VotingWeightCalculator vwcA = deployScript.run();
        assertEq(vwcA.owner(), testEthFrom, "path 1: owner == ETH_FROM");
        assertEq(vwcA.pendingOwner(), PENDING_OWNER);

        // Path 2: ETH_FROM cleared, PRIVATE_KEY set → signer = vm.addr(pk).
        DeployBalancerAdaptor scriptTwo = new DeployBalancerAdaptor();
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(testPk));
        VotingWeightCalculator vwcB = scriptTwo.run();
        assertEq(vwcB.owner(), pkSigner, "path 2: owner derived from PK");

        // Path 3: both cleared → _resolveSigner reverts.
        DeployBalancerAdaptor scriptThree = new DeployBalancerAdaptor();
        vm.setEnv("ETH_FROM", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0)));
        vm.expectRevert(bytes("Set ETH_FROM (ledger) or PRIVATE_KEY"));
        scriptThree.run();
    }

    /// @notice Full run: every deploy, role grant, and source registration
    ///         the script performs, plus the Ownable2Step ownership transfer
    ///         to the mainnet recipient.
    function test_runWithSigner_deploysEverythingAndBeginsOwnershipTransfer() public {
        VotingWeightCalculator vwc = deployScript.runWithSigner(deployer);

        // Ownable2Step: live owner is still the deployer until the recipient
        // calls acceptOwnership(); pendingOwner is set.
        assertEq(vwc.owner(), deployer, "live owner should still be deployer pre-accept");
        assertEq(vwc.pendingOwner(), PENDING_OWNER, "pendingOwner should be set");

        // All three sources registered in script order.
        _assertSourceAtIndex(vwc, 0, POOL0, STAKING0);
        _assertSourceAtIndex(vwc, 1, POOL1, STAKING1);
        _assertSourceAtIndex(vwc, 2, POOL2, STAKING2);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertSourceAtIndex(
        VotingWeightCalculator vwc,
        uint256 index,
        address expectedPool,
        address expectedStaking
    ) internal view {
        ISource source = ISource(vwc.sources(index));
        StakingRewardsAdaptor staking = StakingRewardsAdaptor(address(source));
        assertEq(address(staking._staking()), expectedStaking, "staking rewards mismatch");

        BalancerAdaptor balancer = BalancerAdaptor(address(staking._source()));
        assertEq(address(balancer._valut()), BALANCER_VAULT, "balancer vault mismatch");
        assertEq(address(balancer._pool()), expectedPool, "balancer pool mismatch");
        assertEq(address(balancer.TELCOIN()), TELCOIN, "TELCOIN mismatch");
        assertEq(balancer._mFactor(), 5, "mFactor mismatch");
        assertEq(balancer._dFactor(), 4, "dFactor mismatch");
    }
}

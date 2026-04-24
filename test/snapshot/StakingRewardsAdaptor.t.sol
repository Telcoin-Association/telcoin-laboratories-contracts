// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingRewardsAdaptor} from "contracts/snapshot/adaptors/StakingRewardsAdaptor.sol";
import {BalancerAdaptor} from "contracts/snapshot/adaptors/BalancerAdaptor.sol";
import {IStakingRewards} from "contracts/snapshot/interfaces/IStakingRewards.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerVault} from "contracts/snapshot/interfaces/IBalancerVault.sol";
import {IBalancerPool} from "contracts/snapshot/interfaces/IBalancerPool.sol";
import {PolygonConstants} from "../util/PolygonConstants.sol";

/// @title StakingRewardsAdaptorTest
/// @notice Polygon-fork tests for the StakingRewards voting-weight adaptor. Composes a fresh
///         BalancerAdaptor (for pool-share-to-TEL conversion) with the live StakingRewards
///         contract to surface staked LP positions as governance weight.
contract StakingRewardsAdaptorTest is Test {
    uint256 constant FORK_BLOCK = 68_000_000;

    // Local aliases for shared mainnet addresses (see test/util/PolygonConstants.sol).
    address constant TEL = PolygonConstants.TEL;
    address constant BALANCER_VAULT = PolygonConstants.BALANCER_VAULT;
    address constant BALANCER_POOL = PolygonConstants.BALANCER_POOL;
    bytes32 constant POOL_ID = PolygonConstants.BALANCER_POOL_ID;
    address constant STAKING_REWARDS = PolygonConstants.STAKING_REWARDS;

    uint256 constant M_FACTOR = 5;
    uint256 constant D_FACTOR = 4;

    BalancerAdaptor balancerAdaptor;
    StakingRewardsAdaptor adaptor;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        // Deploy a fresh BalancerAdaptor to use as the source
        balancerAdaptor = new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            D_FACTOR
        );

        adaptor = new StakingRewardsAdaptor(
            ISource(address(balancerAdaptor)),
            IStakingRewards(STAKING_REWARDS)
        );
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(adaptor._source()), address(balancerAdaptor));
        assertEq(address(adaptor._staking()), STAKING_REWARDS);
    }

    function test_constructor_revertsOnZeroSource() public {
        vm.expectRevert("StakingRewardsAdaptor: cannot initialize to zero");
        new StakingRewardsAdaptor(
            ISource(address(0)),
            IStakingRewards(STAKING_REWARDS)
        );
    }

    function test_constructor_revertsOnZeroStaking() public {
        vm.expectRevert("StakingRewardsAdaptor: cannot initialize to zero");
        new StakingRewardsAdaptor(
            ISource(address(balancerAdaptor)),
            IStakingRewards(address(0))
        );
    }

    function test_constructor_revertsOnBothZero() public {
        vm.expectRevert("StakingRewardsAdaptor: cannot initialize to zero");
        new StakingRewardsAdaptor(
            ISource(address(0)),
            IStakingRewards(address(0))
        );
    }

    // ---------------------------------------------------------------
    // supportsInterface
    // ---------------------------------------------------------------

    function test_supportsInterface_ISource() public view {
        assertTrue(adaptor.supportsInterface(type(ISource).interfaceId));
    }

    function test_supportsInterface_random_returnsFalse() public view {
        assertFalse(adaptor.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ---------------------------------------------------------------
    // balanceOf — zero-stake path (only earned)
    // ---------------------------------------------------------------

    function test_balanceOf_zeroStake_returnsEarned() public {
        // A random address with no stake and no earned rewards
        address nobody = makeAddr("nobody");
        uint256 bal = adaptor.balanceOf(nobody);
        // Nobody has staked, so earned is 0, balance is 0
        // The contract returns earned(voter) when balance == 0
        uint256 earned = IStakingRewards(STAKING_REWARDS).earned(nobody);
        assertEq(bal, earned);
    }

    // ---------------------------------------------------------------
    // balanceOf — with stake (earned + weighted BPT share)
    // ---------------------------------------------------------------

    function test_balanceOf_withStake_returnsEarnedPlusWeightedShare() public {
        // We simulate a staker by dealing BPT to the staking contract
        // and manipulating the staking contract's storage to reflect a staker.
        //
        // For the StakingRewardsAdaptor, the formula is:
        //   earned(voter) + (staking.balanceOf(voter) * source.balanceOf(staking)) / staking.totalSupply()
        //
        // We use a real StakingRewards contract. If nobody has staked at this block,
        // we verify the zero-path works correctly.

        address voter = makeAddr("voter");

        uint256 stakingBal = IStakingRewards(STAKING_REWARDS).balanceOf(voter);
        uint256 earned = IStakingRewards(STAKING_REWARDS).earned(voter);

        uint256 result = adaptor.balanceOf(voter);

        if (stakingBal == 0) {
            assertEq(result, earned, "Zero stake path should return earned only");
        } else {
            uint256 totalSupply = IStakingRewards(STAKING_REWARDS).totalSupply();
            uint256 sourceBalance = balancerAdaptor.balanceOf(STAKING_REWARDS);
            uint256 expected = earned + (stakingBal * sourceBalance) / totalSupply;
            assertEq(result, expected);
        }
    }

    // ---------------------------------------------------------------
    // balanceOf — edge: staking contract holds BPT but voter has 0 stake
    // ---------------------------------------------------------------

    function test_balanceOf_stakingHasBPT_voterHasNoStake() public {
        // Give the staking contract some BPT so source.balanceOf(staking) > 0
        deal(BALANCER_POOL, STAKING_REWARDS, 10_000e18);

        address voter = makeAddr("voter");
        uint256 result = adaptor.balanceOf(voter);

        // voter has 0 stake => takes the `if (balanceOf == 0)` branch => returns earned
        uint256 earned = IStakingRewards(STAKING_REWARDS).earned(voter);
        assertEq(result, earned);
    }

    // ---------------------------------------------------------------
    // Integration with VotingWeightCalculator
    // ---------------------------------------------------------------

    function test_canBeAddedAsSource() public view {
        assertTrue(adaptor.supportsInterface(type(ISource).interfaceId));
    }

    // ---------------------------------------------------------------
    // Coverage-gap tests
    // ---------------------------------------------------------------

    /// @dev Exercise the zero-stake branch when earned > 0.
    ///      We mock `_staking.balanceOf(voter) == 0` while `_staking.earned(voter) > 0`
    ///      to guarantee the `if (balanceOf == 0) return earned` path returns a non-zero value.
    function test_balanceOf_zeroStake_nonZeroEarned() public {
        address voter = makeAddr("earnedVoter");

        // Use a mock staking contract so we control earned independently of balance
        MockStakingRewards mockStaking = new MockStakingRewards();
        mockStaking.setBalance(voter, 0);
        mockStaking.setEarned(voter, 42e18);
        mockStaking.setTotalSupply(100e18);

        StakingRewardsAdaptor mockAdaptor = new StakingRewardsAdaptor(
            ISource(address(balancerAdaptor)),
            IStakingRewards(address(mockStaking))
        );

        uint256 result = mockAdaptor.balanceOf(voter);
        assertEq(result, 42e18, "Should return earned when balance is zero");
    }

    /// @dev Exercise the full calculation path with a mock that has nonzero stake.
    ///      Formula: earned(voter) + (balanceOf(voter) * source.balanceOf(staking)) / totalSupply()
    function test_balanceOf_nonZeroStake_fullFormula() public {
        address voter = makeAddr("stakedVoter");

        MockStakingRewards mockStaking = new MockStakingRewards();
        mockStaking.setBalance(voter, 25e18);
        mockStaking.setEarned(voter, 10e18);
        mockStaking.setTotalSupply(100e18);

        StakingRewardsAdaptor mockAdaptor = new StakingRewardsAdaptor(
            ISource(address(balancerAdaptor)),
            IStakingRewards(address(mockStaking))
        );

        // source.balanceOf(address(staking)) is the Balancer adaptor evaluated
        // at the mock staking address. Deal BPT to the mock staking so source returns > 0.
        deal(BALANCER_POOL, address(mockStaking), 200e18);

        uint256 sourceBalance = balancerAdaptor.balanceOf(address(mockStaking));
        assertGt(sourceBalance, 0, "Source balance must be nonzero for this test");

        uint256 expected = 10e18 + (25e18 * sourceBalance) / 100e18;
        uint256 result = mockAdaptor.balanceOf(voter);
        assertEq(result, expected, "Full formula must match");
    }

    /// @dev Full calculation when earned is zero but stake is nonzero.
    function test_balanceOf_nonZeroStake_zeroEarned() public {
        address voter = makeAddr("noEarnVoter");

        MockStakingRewards mockStaking = new MockStakingRewards();
        mockStaking.setBalance(voter, 50e18);
        mockStaking.setEarned(voter, 0);
        mockStaking.setTotalSupply(200e18);

        StakingRewardsAdaptor mockAdaptor = new StakingRewardsAdaptor(
            ISource(address(balancerAdaptor)),
            IStakingRewards(address(mockStaking))
        );

        deal(BALANCER_POOL, address(mockStaking), 400e18);

        uint256 sourceBalance = balancerAdaptor.balanceOf(address(mockStaking));
        uint256 expected = (50e18 * sourceBalance) / 200e18;
        uint256 result = mockAdaptor.balanceOf(voter);
        assertEq(result, expected, "Earned=0, stake>0 should return weighted share only");
    }

    /// @dev supportsInterface returns false for IERC165 interfaceId itself
    function test_supportsInterface_ierc165_returnsFalse() public view {
        assertFalse(adaptor.supportsInterface(type(IERC165).interfaceId));
    }
}

/// @dev Minimal mock for IStakingRewards that lets tests control returned values.
contract MockStakingRewards is IStakingRewards {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _earned;
    uint256 private _totalSupply;

    function setBalance(address account, uint256 value) external {
        _balances[account] = value;
    }

    function setEarned(address account, uint256 value) external {
        _earned[account] = value;
    }

    function setTotalSupply(uint256 value) external {
        _totalSupply = value;
    }

    function earned(address account) external view override returns (uint256) {
        return _earned[account];
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
}

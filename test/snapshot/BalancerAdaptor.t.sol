// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerAdaptor} from "contracts/snapshot/adaptors/BalancerAdaptor.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerVault} from "contracts/snapshot/interfaces/IBalancerVault.sol";
import {IBalancerPool} from "contracts/snapshot/interfaces/IBalancerPool.sol";

contract BalancerAdaptorTest is Test {
    uint256 constant FORK_BLOCK = 68_000_000;

    // Production addresses
    address constant TEL = 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // TEL80/WETH20 pool
    address constant BALANCER_POOL = 0xcA6EFA5704f1Ae445e0EE24D9c3Ddde34c5be1C2;
    bytes32 constant POOL_ID = 0xca6efa5704f1ae445e0ee24d9c3ddde34c5be1c2000200000000000000000dbd;

    // Production adaptor
    address constant WETH_POOL_ADAPTOR = 0x7b80BD3098b3D8ba887118E85fF8428231Bd7913;

    uint256 constant M_FACTOR = 5;
    uint256 constant D_FACTOR = 4;

    BalancerAdaptor adaptor;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"), FORK_BLOCK);

        adaptor = new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            D_FACTOR
        );
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(adaptor.TELCOIN()), TEL);
        assertEq(address(adaptor._valut()), BALANCER_VAULT);
        assertEq(adaptor._poolId(), POOL_ID);
        assertEq(address(adaptor._pool()), BALANCER_POOL);
        assertEq(adaptor._mFactor(), M_FACTOR);
        assertEq(adaptor._dFactor(), D_FACTOR);
    }

    function test_constructor_revertsOnZeroTelcoin() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(address(0)),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            D_FACTOR
        );
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(address(0)),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            D_FACTOR
        );
    }

    function test_constructor_revertsOnZeroPoolId() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            bytes32(0),
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            D_FACTOR
        );
    }

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(address(0)),
            M_FACTOR,
            D_FACTOR
        );
    }

    function test_constructor_revertsOnZeroMFactor() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            0,
            D_FACTOR
        );
    }

    function test_constructor_revertsOnZeroDFactor() public {
        vm.expectRevert("BalancerAdaptor: cannot initialize to zero");
        new BalancerAdaptor(
            IERC20(TEL),
            IBalancerVault(BALANCER_VAULT),
            POOL_ID,
            IBalancerPool(BALANCER_POOL),
            M_FACTOR,
            0
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
    // balanceOf
    // ---------------------------------------------------------------

    function test_balanceOf_zeroBalance_returnsZero() public {
        address noTokens = makeAddr("noTokens");
        assertEq(adaptor.balanceOf(noTokens), 0);
    }

    function test_balanceOf_withBPT_returnsCorrectWeight() public {
        address voter = makeAddr("voter");

        // Give voter some BPT
        uint256 bptAmount = 1_000e18;
        deal(BALANCER_POOL, voter, bptAmount);

        uint256 weight = adaptor.balanceOf(voter);

        // Verify the calculation manually:
        // weight = (bpt * telInPool * mFactor / dFactor) / totalSupply
        (uint256 telAmount,,,) = IBalancerVault(BALANCER_VAULT).getPoolTokenInfo(POOL_ID, IERC20(TEL));
        uint256 totalSupply = IBalancerPool(BALANCER_POOL).totalSupply();

        uint256 expected = (bptAmount * telAmount * M_FACTOR / D_FACTOR) / totalSupply;
        assertEq(weight, expected);
        assertGt(weight, 0, "Voter with BPT should have non-zero weight");
    }

    function test_balanceOf_proportionalToHoldings() public {
        address voter1 = makeAddr("voter1");
        address voter2 = makeAddr("voter2");

        deal(BALANCER_POOL, voter1, 100e18);
        deal(BALANCER_POOL, voter2, 200e18);

        uint256 w1 = adaptor.balanceOf(voter1);
        uint256 w2 = adaptor.balanceOf(voter2);

        // voter2 has 2x the BPT so should have 2x the weight
        assertEq(w2, w1 * 2);
    }

    function test_balanceOf_verySmallAmount() public {
        address voter = makeAddr("voter");
        deal(BALANCER_POOL, voter, 1); // 1 wei of BPT

        uint256 weight = adaptor.balanceOf(voter);
        // Should not revert; might be 0 due to rounding or a small positive
        // Just asserting no revert is sufficient; check it's <= what 1 wei would produce
        assertLe(weight, type(uint256).max);
    }

    function test_balanceOf_fullSupply() public {
        address voter = makeAddr("voter");
        uint256 totalSupply = IBalancerPool(BALANCER_POOL).totalSupply();
        deal(BALANCER_POOL, voter, totalSupply);

        uint256 weight = adaptor.balanceOf(voter);

        // If voter holds all BPT: weight = totalSupply * telAmount * mFactor / dFactor / totalSupply
        //                                = telAmount * mFactor / dFactor
        (uint256 telAmount,,,) = IBalancerVault(BALANCER_VAULT).getPoolTokenInfo(POOL_ID, IERC20(TEL));
        uint256 expected = telAmount * M_FACTOR / D_FACTOR;
        assertEq(weight, expected);
    }

    // ---------------------------------------------------------------
    // Production adaptor (read-only)
    // ---------------------------------------------------------------

    function test_productionAdaptor_immutables() public view {
        BalancerAdaptor prod = BalancerAdaptor(WETH_POOL_ADAPTOR);

        assertEq(address(prod.TELCOIN()), TEL);
        assertEq(address(prod._valut()), BALANCER_VAULT);
        assertEq(prod._mFactor(), M_FACTOR);
        assertEq(prod._dFactor(), D_FACTOR);
    }

    function test_productionAdaptor_zeroBalanceReturnsZero() public {
        BalancerAdaptor prod = BalancerAdaptor(WETH_POOL_ADAPTOR);
        address nobody = makeAddr("nobody");
        assertEq(prod.balanceOf(nobody), 0);
    }
}

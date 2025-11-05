// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BalancerAdaptor} from "contracts/snapshot/adaptors/BalancerAdaptor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerVault} from "contracts/snapshot/interfaces/IBalancerVault.sol";
import {IBalancerPool} from "contracts/snapshot/interfaces/IBalancerPool.sol";
import {StakingRewardsAdaptor} from "contracts/snapshot/adaptors/StakingRewardsAdaptor.sol";
import {ISource} from "contracts/snapshot/interfaces/ISource.sol";
import {IStakingRewards} from "contracts/snapshot/interfaces/IStakingRewards.sol";
import {VotingWeightCalculator} from "contracts/snapshot/core/VotingWeightCalculator.sol";

contract DeployBalancerAdaptor is Script {
    struct PoolConfig {
        address telcoin;
        address vault;
        bytes32 poolId;
        address pool;
        uint256 mFactor;
        uint256 dFactor;
        address stakingContract;
    }

    // -------------------------------------------------------------------
    // Choose which pool to deploy for here (0, 1, or 2)
    // -------------------------------------------------------------------
    // uint256 constant POOL_INDEX = 0;

    // -------------------------------------------------------------------
    // Hard-coded configs for each pool - parameters copied from existing deployments
    // -------------------------------------------------------------------
    function _getConfigs() internal pure returns (PoolConfig[] memory cfgs) {
        cfgs = new PoolConfig[](3);

        // POOL 0 TEL80/WETH20 (existing Source: 0x7b80BD3098b3D8ba887118E85fF8428231Bd7913)
        cfgs[0] = PoolConfig({
            telcoin: 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32,
            vault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            poolId: 0xca6efa5704f1ae445e0ee24d9c3ddde34c5be1c2000200000000000000000dbd,
            pool: 0xcA6EFA5704f1Ae445e0EE24D9c3Ddde34c5be1C2,
            mFactor: 5,
            dFactor: 4,
            stakingContract: 0x7fEb8FEbddB66189417f732B4221a52E23B926C4 // required by StakingRewardsAdaptor
        });

        // POOL 1 — TEL80/USDC20 (existing source: 0x590779B3B868b3F3d69985165006b007c78a42ba)
        cfgs[1] = PoolConfig({
            telcoin: 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32,
            vault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            poolId: 0x3bd8a254163f8328efcc4f8c36da566753462433000200000000000000000dc1,
            pool: 0x3bd8a254163f8328efCC4F8c36da566753462433,
            mFactor: 5,
            dFactor: 4,
            stakingContract: 0x8f702676830ddCA2801A4a7cDB971CDE4DF697AE // required by StakingRewardsAdaptor
        });

        // POOL 2 — TEL80/WBTC20 (existing source: 0x548EE52F64a6c262bc744b90F9448Ac80359F4E9)
        cfgs[2] = PoolConfig({
            telcoin: 0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32,
            vault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            poolId: 0xe1e09ce7aac2740846d9b6d9d56f588c65314ecb000200000000000000000dbe,
            pool: 0xE1E09ce7aAC2740846d9B6D9D56f588c65314eCB,
            mFactor: 5,
            dFactor: 4,
            stakingContract: 0x79E5A6fFe2E6bA053A80e1B199c4F328938F40CA // required by StakingRewardsAdaptor
        });
    }

    // -------------------------------------------------------------------
    // Main run() — deploys the chosen pool config
    // -------------------------------------------------------------------
    function run() external {
        // deploy VotingWeightCalculator
        vm.startBroadcast();

        VotingWeightCalculator votingWeightCalculator = new VotingWeightCalculator{
                salt: keccak256("VotingWeightCalculator")
            }(msg.sender);

        require(
            votingWeightCalculator.owner() == msg.sender,
            "VWC: wrong owner"
        );

        vm.stopBroadcast();

        console2.log(
            " VotingWeightCalculator deployed to:",
            address(votingWeightCalculator)
        );

        PoolConfig[] memory cfgs = _getConfigs();

        for (uint256 i = 0; i < cfgs.length; i++) {
            PoolConfig memory c = cfgs[i];

            vm.startBroadcast();
            // deploy each source contract, matching exisiting parameters
            BalancerAdaptor balancerAdaptor = new BalancerAdaptor(
                IERC20(c.telcoin),
                IBalancerVault(c.vault),
                c.poolId,
                IBalancerPool(c.pool),
                c.mFactor,
                c.dFactor
            );

            require(
                address(balancerAdaptor.TELCOIN()) == c.telcoin,
                "TELCOIN mismatch"
            );
            require(
                address(balancerAdaptor._valut()) == c.vault,
                "Vault mismatch"
            );
            require(
                balancerAdaptor._mFactor() == c.mFactor,
                "mFactor mismatch"
            );
            require(
                balancerAdaptor._dFactor() == c.dFactor,
                "dFactor mismatch"
            );

            // deploy the corresponding staking rewards adaptor, linking to balancerAdaptor and stakingContract
            StakingRewardsAdaptor stakingRewardsAdaptor = new StakingRewardsAdaptor(
                    ISource(balancerAdaptor),
                    IStakingRewards(c.stakingContract)
                );

            // add stakingRewardsAdaptor to votingWeightCalculator as source

            votingWeightCalculator.addSource(ISource(stakingRewardsAdaptor));

            require(
                address(votingWeightCalculator.sources(i)) ==
                    address(stakingRewardsAdaptor),
                "source not registered"
            );

            vm.stopBroadcast();

            console2.log(
                "----------------------------------------------------"
            );
            console2.log(" Deployed BalancerAdaptor for pool index", i);
            console2.log(
                " Balancer Adaptor deployed to:",
                address(balancerAdaptor)
            );
            console2.log(
                " Staking Rewards Adaptor deployed to:",
                address(stakingRewardsAdaptor)
            );
            console2.log(
                " VotingWeightCalculator: source ",
                address(stakingRewardsAdaptor),
                "added"
            );
            console2.log(
                "----------------------------------------------------"
            );
        }

        vm.startBroadcast();
        // begin transfer of ownership to new address (recipeint must accept ownership)
        votingWeightCalculator.transferOwnership(
            0xc1612C97537c2CC62a11FC4516367AB6F62d4B23
        );
        vm.stopBroadcast();
    }
}

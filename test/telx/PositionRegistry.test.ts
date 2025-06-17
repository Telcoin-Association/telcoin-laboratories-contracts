import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PositionRegistry, TestTelcoin, TestPoolManager } from "../../typechain-types";

describe("PositionRegistry", function () {
    // Signer roles for tests
    let deployer: SignerWithAddress;
    let lp1: SignerWithAddress;
    let lp2: SignerWithAddress;

    // Core contracts
    let rewardToken: TestTelcoin;
    let registry: PositionRegistry;
    let poolManager: TestPoolManager;

    // Default position configuration
    const poolId = ethers.ZeroHash;
    const tickLower = -600;
    const tickUpper = 600;
    const liquidityDelta = 1000;

    let positionId: string;

    beforeEach(async function () {
        [deployer, lp1, lp2] = await ethers.getSigners();

        // Deploy mock token and registry
        const TestToken = await ethers.getContractFactory("TestToken");
        rewardToken = await TestToken.deploy(deployer.address);
        await rewardToken.waitForDeployment();

        const PoolManager = await ethers.getContractFactory("TestPoolManager");
        poolManager = await PoolManager.deploy();

        const PositionRegistry = await ethers.getContractFactory("PositionRegistry");
        registry = await PositionRegistry.deploy(await rewardToken.getAddress(), await poolManager.getAddress());
        await registry.waitForDeployment();

        // Precompute position ID
        positionId = (await registry.getPositionId(lp1.address, poolId, tickLower, tickUpper));

        // Grant necessary roles for calling reward + update functions
        const SUPPORT_ROLE = await registry.SUPPORT_ROLE();
        const UNI_HOOK_ROLE = await registry.UNI_HOOK_ROLE();
        await registry.grantRole(SUPPORT_ROLE, deployer.address);
        await registry.grantRole(UNI_HOOK_ROLE, deployer.address);
        await registry.updateTelPosition(poolId, 1);
    });

    describe("Values", () => {
        it("Static Values", async () => {
            // Check block and token immutables
            expect(await registry.lastRewardBlock()).to.equal((await ethers.provider.getBlock("latest"))!.number - 3);
            expect(await registry.telcoin()).to.equal(await rewardToken.getAddress());

            // Check role hash constants
            const UNI_HOOK_ROLE = await registry.UNI_HOOK_ROLE();
            const SUPPORT_ROLE = await registry.SUPPORT_ROLE();

            expect(UNI_HOOK_ROLE).to.equal(ethers.keccak256(ethers.toUtf8Bytes("UNI_HOOK_ROLE")));
            expect(SUPPORT_ROLE).to.equal(ethers.keccak256(ethers.toUtf8Bytes("SUPPORT_ROLE")));
        });

        it("Dynamic Values", async () => {
            await registry.addOrUpdatePosition(lp1.address, poolId, tickLower, tickUpper, liquidityDelta);
            const intermediatePosition = await registry.getPosition(positionId);

            // Validate position state
            expect(intermediatePosition.provider).to.equal(lp1.address);
            expect(intermediatePosition.poolId).to.equal(poolId);
            expect(intermediatePosition.tickLower).to.equal(tickLower);
            expect(intermediatePosition.tickUpper).to.equal(tickUpper);
            expect(intermediatePosition.liquidity).to.equal(liquidityDelta);
        });

        it("should return true for a valid TEL pool", async () => {
            expect(await registry.validPool(poolId)).to.equal(true);
        });

        it("should return false for an untracked TEL pool", async () => {
            const fakePool = ethers.keccak256(ethers.toUtf8Bytes("fake"));
            expect(await registry.validPool(fakePool)).to.equal(false);
        });

        it("should return true for active routers", async () => {
            await registry.updateRegistry(lp1.address, true);
            expect(await registry.activeRouters(lp1.address)).to.equal(true);
        });

        it("should return false for unknown routers", async () => {
            expect(await registry.activeRouters(lp2.address)).to.equal(false);
        });

        it("should update TEL position and emit event", async () => {
            const newPool = ethers.keccak256(ethers.toUtf8Bytes("new"));
            await expect(registry.updateTelPosition(newPool, 1))
                .to.emit(registry, "TelPositionUpdated")
                .withArgs(newPool, 1);
        });

        it("should revert on invalid TEL index", async () => {
            await expect(
                registry.updateTelPosition(poolId, 3)
            ).to.be.revertedWith("PositionRegistry: Invalid location");
        });
    });

    describe("addOrUpdatePosition", () => {
        it("should add a new position", async () => {
            const positionId = await registry.getPositionId(lp1.address, poolId, tickLower, tickUpper);

            // Add position and expect event
            await expect(
                registry.addOrUpdatePosition(lp1.address, poolId, tickLower, tickUpper, liquidityDelta)
            )
                .to.emit(registry, "PositionUpdated")
                .withArgs(positionId, lp1.address, poolId, tickLower, tickUpper, liquidityDelta);

            // Validate state after adding
            const position = await registry.getPosition(positionId);
            expect(position.provider).to.equal(lp1.address);
            expect(position.poolId).to.equal(poolId);
            expect(position.tickLower).to.equal(tickLower);
            expect(position.tickUpper).to.equal(tickUpper);
            expect(position.liquidity).to.equal(liquidityDelta);

            // Position should appear in active list
            const activeIds = await registry.getAllActivePositionIds();
            expect(activeIds).to.include(positionId);
        });

        it("should update and then remove a position", async () => {
            const positionId = await registry.getPositionId(lp1.address, poolId, tickLower, tickUpper);

            // Add then remove same position
            await registry.addOrUpdatePosition(lp1.address, poolId, tickLower, tickUpper, liquidityDelta);
            // Remove the same amount to zero it out, expect removal
            await expect(
                registry.addOrUpdatePosition(lp1.address, poolId, tickLower, tickUpper, -liquidityDelta)
            )
                .to.emit(registry, "PositionRemoved")
                .withArgs(positionId, lp1.address, poolId, tickLower, tickUpper);

            // Expect it to be removed from storage and index
            expect(await registry.getPosition(positionId)).to.be.reverted;
            const allIds = await registry.getAllActivePositionIds();
            expect(allIds).to.not.include(positionId);
        });

        it("should revert when querying voting weight for a non-existent position", async () => {
            const dummyPositionId = ethers.ZeroHash;
            expect(await
                registry.computeVotingWeight(dummyPositionId)
            ).to.equal(0);
        });

        it("should allow SUPPORT_ROLE to rescue tokens", async () => {
            await rewardToken.transfer(await registry.getAddress(), 1000);
            const before = await rewardToken.balanceOf(lp1.address);
            await registry.erc20Rescue(rewardToken.getAddress(), lp1.address, 1000);
            const after = await rewardToken.balanceOf(lp1.address);
            expect(after - before).to.equal(1000);
        });
    });

    describe("addRewards", () => {
        it("should allow adding rewards to multiple providers", async () => {
            const providers = [lp1.address, lp2.address];
            const amounts = [100, 250];
            const total = 350;
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;

            await rewardToken.approve(await registry.getAddress(), total);

            await expect(registry.addRewards(providers, amounts, total, rewardBlock))
                .to.emit(registry, "UpdateBlockStamp")
                .withArgs(rewardBlock, total);

            expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(100);
            expect(await registry.getUnclaimedRewards(lp2.address)).to.equal(250);
            expect(await rewardToken.balanceOf(await registry.getAddress())).to.equal(total);
        });
        it("should allow adding rewards to multiple providers", async () => {
            const providers = [lp1.address, lp2.address];
            const amounts = [100, 250];
            const total = 350;
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;

            await rewardToken.approve(await registry.getAddress(), total);

            await expect(registry.addRewards(providers, amounts, total, rewardBlock))
                .to.emit(registry, "RewardsAdded")
                .withArgs(lp1.address, 100)
                .and.to.emit(registry, "RewardsAdded")
                .withArgs(lp2.address, 250)
                .and.to.emit(registry, "UpdateBlockStamp")
                .withArgs(rewardBlock, total);

            expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(100);
            expect(await registry.getUnclaimedRewards(lp2.address)).to.equal(250);
        });

        it("should fail if array lengths do not match", async () => {
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;
            await expect(
                registry.addRewards([lp1.address], [100, 200], 300, rewardBlock)
            ).to.be.revertedWith("PositionRegistry: Length mismatch");
        });

        it("should fail if total doesn't match sum", async () => {
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;
            await rewardToken.approve(await registry.getAddress(), 500);

            await expect(
                registry.addRewards([lp1.address, lp2.address], [100, 200], 500, rewardBlock)
            ).to.be.revertedWith("PositionRegistry: Total amount mismatch");
        });

        it("should return all active positions", async () => {
            await registry.addOrUpdatePosition(lp1.address, poolId, tickLower, tickUpper, liquidityDelta);
            await registry.addOrUpdatePosition(lp2.address, poolId, tickLower + 60, tickUpper + 60, liquidityDelta * 2);

            const allPositions = await registry.getAllActivePositions();
            expect(allPositions.length).to.equal(2);
            expect(allPositions[0].provider).to.equal(lp1.address);
            expect(allPositions[1].provider).to.equal(lp2.address);
        });

        it("should fail if rewardBlock is <= lastRewardBlock", async () => {
            const lastRewardBlock = await registry.lastRewardBlock();
            await rewardToken.approve(await registry.getAddress(), 100);
            await expect(
                registry.addRewards([lp1.address], [100], 100, lastRewardBlock)
            ).to.be.revertedWith("PositionRegistry: Block must be greater than last reward block");
        });

        it("should update lastRewardBlock and contract balance after rewards are added", async () => {
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;
            const total = 300;
            await rewardToken.approve(await registry.getAddress(), total);
            const oldBalance = await rewardToken.balanceOf(await registry.getAddress());

            await registry.addRewards([lp1.address, lp2.address], [100, 200], total, rewardBlock);

            expect(await rewardToken.balanceOf(await registry.getAddress()) - oldBalance).to.equal(total);
            expect(await registry.lastRewardBlock()).to.equal(rewardBlock);
        });
    });

    describe("claim", () => {
        it("should allow a user to claim rewards", async () => {
            const rewardBlock = (await ethers.provider.getBlock("latest"))!.number + 1;
            await rewardToken.approve(await registry.getAddress(), 500);
            await registry.addRewards([lp1.address], [500], 500, rewardBlock);

            await expect(registry.connect(lp1).claim())
                .to.emit(registry, "RewardsClaimed")
                .withArgs(lp1.address, 500);

            expect(await rewardToken.balanceOf(lp1.address)).to.equal(500);
            expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(0);
        });

        it("should revert if user has no claimable rewards", async () => {
            await expect(registry.connect(lp2).claim())
                .to.be.revertedWith("PositionRegistry: No claimable rewards");
        });

        it("should allow claiming multiple times if rewards are re-added", async () => {
            const rewardBlock1 = (await ethers.provider.getBlock("latest"))!.number + 1;
            await rewardToken.approve(await registry.getAddress(), 200);
            await registry.addRewards([lp1.address], [200], 200, rewardBlock1);

            await registry.connect(lp1).claim();
            expect(await rewardToken.balanceOf(lp1.address)).to.equal(200);

            const rewardBlock2 = rewardBlock1 + 1;
            await rewardToken.approve(await registry.getAddress(), 300);
            await registry.addRewards([lp1.address], [300], 300, rewardBlock2);

            await registry.connect(lp1).claim();
            expect(await rewardToken.balanceOf(lp1.address)).to.equal(500);
        });
    });

    describe("erc20Rescue", () => {
        it("should rescue ERC20 tokens to a destination address", async () => {
            const amountToSend = 1000;
            await rewardToken.transfer(await registry.getAddress(), amountToSend);

            const before = await rewardToken.balanceOf(lp1.address);
            await registry.erc20Rescue(rewardToken.getAddress(), lp1.address, amountToSend);
            const after = await rewardToken.balanceOf(lp1.address);

            expect(after - before).to.equal(amountToSend);
        });
    });
});
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  PositionRegistry,
  TestTelcoin,
  TestPoolManager,
  TestPositionManager,
} from "../../typechain-types";

describe("PositionRegistry", function () {
  // Signer roles for tests
  let deployer: SignerWithAddress;
  let lp1: SignerWithAddress;
  let lp2: SignerWithAddress;

  // Core contracts
  let rewardToken: TestTelcoin;
  let registry: PositionRegistry;
  let poolManager: TestPoolManager;
  let positionManager: TestPositionManager;

  // Default position configuration
  const poolId = ethers.toBeHex(1, 32);
  const tickLower = -600;
  const tickUpper = 600;
  const liquidityDelta = 1000;

  beforeEach(async function () {
    [deployer, lp1, lp2] = await ethers.getSigners();

    // Deploy mock token and registry
    const TestToken = await ethers.getContractFactory("TestToken");
    rewardToken = await TestToken.deploy(deployer.address);
    await rewardToken.waitForDeployment();

    const TestPositionManager = await ethers.getContractFactory(
      "TestPositionManager"
    );
    positionManager = await TestPositionManager.deploy();
    await positionManager.waitForDeployment();

    const PoolManager = await ethers.getContractFactory("TestPoolManager");
    poolManager = await PoolManager.deploy();

    const PositionRegistry = await ethers.getContractFactory(
      "PositionRegistry"
    );
    registry = await PositionRegistry.deploy(
      await rewardToken.getAddress(),
      await poolManager.getAddress(),
      await positionManager.getAddress()
    );
    await registry.waitForDeployment();

    // Grant necessary roles for calling reward + update functions
    const SUPPORT_ROLE = await registry.SUPPORT_ROLE();
    const UNI_HOOK_ROLE = await registry.UNI_HOOK_ROLE();
    const SUBSCRIBER_ROLE = await registry.SUBSCRIBER_ROLE();
    await registry.grantRole(SUPPORT_ROLE, deployer.address);
    await registry.grantRole(UNI_HOOK_ROLE, deployer.address);
    await registry.grantRole(SUBSCRIBER_ROLE, deployer.address);
    await registry.updateTelPosition(poolId, 1);
  });

  describe("Values", () => {
    it("Static Values", async () => {
      // Check block and token immutables
      expect(await registry.telcoin()).to.equal(await rewardToken.getAddress());

      // Check role hash constants
      const UNI_HOOK_ROLE = await registry.UNI_HOOK_ROLE();
      const SUPPORT_ROLE = await registry.SUPPORT_ROLE();

      expect(UNI_HOOK_ROLE).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes("UNI_HOOK_ROLE"))
      );
      expect(SUPPORT_ROLE).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes("SUPPORT_ROLE"))
      );
    });

    it("should return true for a valid TEL pool", async () => {
      expect(await registry.validPool(poolId)).to.equal(true);
    });

    it("should return false for an untracked TEL pool", async () => {
      const fakePool = ethers.keccak256(ethers.toUtf8Bytes("fake"));
      expect(await registry.validPool(fakePool)).to.equal(false);
    });

    it("should return true for active routers", async () => {
      await registry.updateRouter(lp1.address, true);
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
      await expect(registry.updateTelPosition(poolId, 3)).to.be.revertedWith(
        "PositionRegistry: Invalid location"
      );
    });
  });

  describe("addOrUpdatePosition", () => {
    it("should add a new position", async () => {
      // Add position and expect event
      registry.addOrUpdatePosition(100, poolId, liquidityDelta);
    });

    it("should revert when querying voting weight for a non-existent position", async () => {
      expect(await registry.computeVotingWeight(ethers.ZeroHash)).to.equal(0);
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

      await rewardToken.approve(await registry.getAddress(), total);

      await expect(registry.addRewards(providers, amounts, total))
        .to.emit(registry, "RewardsAdded")
        .withArgs(lp1.address, 100);

      expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(100);
      expect(await registry.getUnclaimedRewards(lp2.address)).to.equal(250);
      expect(await rewardToken.balanceOf(await registry.getAddress())).to.equal(
        total
      );
    });
    it("should allow adding rewards to multiple providers", async () => {
      const providers = [lp1.address, lp2.address];
      const amounts = [100, 250];
      const total = 350;

      await rewardToken.approve(await registry.getAddress(), total);

      await expect(registry.addRewards(providers, amounts, total))
        .to.emit(registry, "RewardsAdded")
        .withArgs(lp1.address, 100)
        .and.to.emit(registry, "RewardsAdded")
        .withArgs(lp2.address, 250);

      expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(100);
      expect(await registry.getUnclaimedRewards(lp2.address)).to.equal(250);
    });

    it("should fail if array lengths do not match", async () => {
      await expect(
        registry.addRewards([lp1.address], [100, 200], 300)
      ).to.be.revertedWith("PositionRegistry: Length mismatch");
    });

    it("should fail if total doesn't match sum", async () => {
      await rewardToken.approve(await registry.getAddress(), 500);

      await expect(
        registry.addRewards([lp1.address, lp2.address], [100, 200], 500)
      ).to.be.revertedWith("PositionRegistry: Total amount mismatch");
    });
  });

  describe("claim", () => {
    it("should allow a user to claim rewards", async () => {
      await rewardToken.approve(await registry.getAddress(), 500);
      await registry.addRewards([lp1.address], [500], 500);

      await expect(registry.connect(lp1).claim())
        .to.emit(registry, "RewardsClaimed")
        .withArgs(lp1.address, 500);

      expect(await rewardToken.balanceOf(lp1.address)).to.equal(500);
      expect(await registry.getUnclaimedRewards(lp1.address)).to.equal(0);
    });

    it("should revert if user has no claimable rewards", async () => {
      await expect(registry.connect(lp2).claim()).to.be.revertedWith(
        "PositionRegistry: No claimable rewards"
      );
    });

    it("should allow claiming multiple times if rewards are re-added", async () => {
      await rewardToken.approve(await registry.getAddress(), 200);
      await registry.addRewards([lp1.address], [200], 200);

      await registry.connect(lp1).claim();
      expect(await rewardToken.balanceOf(lp1.address)).to.equal(200);

      await rewardToken.approve(await registry.getAddress(), 300);
      await registry.addRewards([lp1.address], [300], 300);

      await registry.connect(lp1).claim();
      expect(await rewardToken.balanceOf(lp1.address)).to.equal(500);
    });
  });

  describe("erc20Rescue", () => {
    it("should rescue ERC20 tokens to a destination address", async () => {
      const amountToSend = 1000;
      await rewardToken.transfer(await registry.getAddress(), amountToSend);

      const before = await rewardToken.balanceOf(lp1.address);
      await registry.erc20Rescue(
        rewardToken.getAddress(),
        lp1.address,
        amountToSend
      );
      const after = await rewardToken.balanceOf(lp1.address);

      expect(after - before).to.equal(amountToSend);
    });
  });
});

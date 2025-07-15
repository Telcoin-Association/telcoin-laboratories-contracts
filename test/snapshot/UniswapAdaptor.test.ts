import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
    TestSource,
    UniswapAdaptor,
    TestPoolManager,
    PositionRegistry
} from "../../typechain-types";


// Mocks & constants
const tickLower = -600;
const tickUpper = 600;
const liquidity = 5000;

const dummyPoolId = ethers.keccak256(ethers.toUtf8Bytes("mock-pool"));

describe("UniswapAdaptor", function () {
    let deployer: SignerWithAddress;
    let user: SignerWithAddress;
    let registry: PositionRegistry;
    let poolManager: TestPoolManager;
    let adaptor: UniswapAdaptor;
    let mockSource: TestSource;

    beforeEach(async () => {
        [deployer, user] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("TestToken");
        const rewardToken = await Token.deploy(deployer.address);

        const PoolManager = await ethers.getContractFactory("TestPoolManager");
        poolManager = await PoolManager.deploy();


        const Registry = await ethers.getContractFactory("PositionRegistry");
        registry = await Registry.deploy(await rewardToken.getAddress(), await poolManager.getAddress(), await poolManager.getAddress());
        await registry.grantRole(await registry.SUPPORT_ROLE(), deployer.address);
        await registry.grantRole(await registry.UNI_HOOK_ROLE(), deployer.address);

        const Mock = await ethers.getContractFactory("TestSource");
        mockSource = await Mock.deploy();

        const Adaptor = await ethers.getContractFactory("UniswapAdaptor");
        adaptor = await Adaptor.deploy(await registry.getAddress());

        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: ethers.ZeroAddress,
        };

        await registry.updateTelPosition(dummyPoolId, 1);
        // Seed the registry with an active position
        await registry.addOrUpdatePosition(
            1,
            user.address,
            dummyPoolId,
            tickLower,
            tickUpper,
            liquidity
        );
    });

    it("should support the ISource interface", async () => {
        const selector = await mockSource.getISourceInterfaceId();
        expect(await adaptor.supportsInterface(selector)).to.be.true;
    });

    it("should return voting weight > 0 if user has a position", async () => {
        // Default tick = 0 so sqrtPrice = 1.0 (Q96)
        await poolManager.setSlot0(2n ** 96n, 0, 0, 0);

        const weight = await adaptor.balanceOf(user.address);
        expect(weight).to.be.gt(0);
    });

    it("should return 0 voting weight if user has no positions", async () => {
        const weight = await adaptor.balanceOf(ethers.Wallet.createRandom().address);
        expect(weight).to.equal(0);
    });
});

import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
    TestSource,
    MockUniswapAdaptor,
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
    let adaptor: MockUniswapAdaptor;
    let mockSource: TestSource;

    beforeEach(async () => {
        [deployer, user] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("TestToken");
        const rewardToken = await Token.deploy(deployer.address);

        const Registry = await ethers.getContractFactory("PositionRegistry");
        registry = await Registry.deploy(await rewardToken.getAddress());

        await registry.grantRole(await registry.UNI_HOOK_ROLE(), deployer.address);

        const PoolManager = await ethers.getContractFactory("TestPoolManager");
        poolManager = await PoolManager.deploy();

        const Mock = await ethers.getContractFactory("TestSource");
        mockSource = await Mock.deploy();

        const Adaptor = await ethers.getContractFactory("MockUniswapAdaptor");
        adaptor = await Adaptor.deploy(await registry.getAddress(), await poolManager.getAddress());

        // Seed the registry with an active position
        await registry.addOrUpdatePosition(
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

    describe("_getAmountsForLiquidity", () => {
        const Q96 = BigInt(2) ** BigInt(96);
        const liquidity = BigInt(1_000_000);

        it("should calculate amount0 when all liquidity is in token0", async () => {
            const sqrtPriceX96 = Q96;
            const sqrtPriceAX96 = Q96 * BigInt(2); // lower
            const sqrtPriceBX96 = Q96 * BigInt(4); // upper

            const result = await adaptor.testGetAmountsForLiquidity(
                sqrtPriceX96 / BigInt(2), // Below A
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );

            expect(result.amount0).to.be.gt(0);
            expect(result.amount1).to.equal(0);
        });

        it("should calculate both amount0 and amount1 when in range", async () => {
            const sqrtPriceAX96 = Q96;
            const sqrtPriceBX96 = Q96 * BigInt(2);
            const sqrtPriceX96 = Q96 + (Q96 / BigInt(2)); // In range

            const result = await adaptor.testGetAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );

            expect(result.amount0).to.be.gt(0);
            expect(result.amount1).to.be.gt(0);
        });

        it("should calculate amount1 when all liquidity is in token1", async () => {
            const sqrtPriceAX96 = Q96;
            const sqrtPriceBX96 = Q96 * BigInt(2);
            const sqrtPriceX96 = sqrtPriceBX96 + Q96; // Above B

            const result = await adaptor.testGetAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );

            expect(result.amount0).to.equal(0);
            expect(result.amount1).to.be.gt(0);
        });

        it("should swap A and B if AX96 > BX96", async () => {
            const sqrtPriceAX96 = Q96 * BigInt(4); // intentionally higher
            const sqrtPriceBX96 = Q96 * BigInt(2);
            const sqrtPriceX96 = Q96 * BigInt(3);

            const result = await adaptor.testGetAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );

            expect(result.amount1).to.be.gt(0); // token1 only
        });
    });
});

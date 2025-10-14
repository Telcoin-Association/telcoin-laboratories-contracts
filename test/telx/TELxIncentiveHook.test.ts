import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
    MockTELxIncentiveHook,
    PositionRegistry,
    TestPoolManager
} from "../../typechain-types";

describe("MockTELxIncentiveHook", function () {
    let deployer: SignerWithAddress;
    let user: SignerWithAddress;
    let poolManager: TestPoolManager;
    let registry: PositionRegistry;
    let hook: MockTELxIncentiveHook;
    const poolId = ethers.toBeHex(1, 32);

    beforeEach(async () => {
        [deployer, user] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("TestToken", deployer);
        const rewardToken = await Token.deploy(deployer.address);

        const PoolManager = await ethers.getContractFactory("TestPoolManager", deployer);
        poolManager = await PoolManager.deploy();

        const Registry = await ethers.getContractFactory("PositionRegistry", deployer);
        registry = await Registry.deploy(await rewardToken.getAddress(), await poolManager.getAddress(), await poolManager.getAddress());

        const Hook = await ethers.getContractFactory("MockTELxIncentiveHook", deployer);
        hook = await Hook.deploy(await poolManager.getAddress(), await registry.getAddress());

        await registry.grantRole(await registry.UNI_HOOK_ROLE(), deployer.address);
        await registry.grantRole(await registry.SUPPORT_ROLE(), deployer.address);
        await registry.grantRole(await registry.UNI_HOOK_ROLE(), await hook.getAddress());
    });

    it("should initialize with correct registry", async () => {
        expect(await hook.registry()).to.equal(await registry.getAddress());
    });

    it("should return correct hook permissions", async () => {
        const perms = await hook.getHookPermissions();
        expect(perms.beforeAddLiquidity).to.be.true;
        expect(perms.afterSwap).to.be.true;
        expect(perms.beforeRemoveLiquidity).to.be.true;
        expect(perms.afterAddLiquidity).to.be.false;
        expect(perms.afterRemoveLiquidity).to.be.false;
    });

    it("should not emit SwapOccurredWithTick on _afterSwap", async () => {
        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: await hook.getAddress(),
        };

        const swapParams = {
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0,
        };

        await poolManager.setSlot0(0, 123, 0, 0); // tick = 123

        const amount0 = 1000n;
        const amount1 = -950n;

        // Pack amount0 and amount1 into a single int256
        const delta = (amount0 << 128n) | (amount1 & ((1n << 128n) - 1n));
        await expect(
            poolManager.callAfterSwap(
                await hook.getAddress(),
                user.address,
                poolKey,
                swapParams,
                delta,
                "0x"
            )
        );
    });

    it("should emit SwapOccurredWithTick on _afterSwap", async () => {
        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: await hook.getAddress(),
        };

        const swapParams = {
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0,
        };

        const abiCoder = new ethers.AbiCoder();
        const poolId = ethers.keccak256(
            abiCoder.encode(
                ["address", "address", "uint24", "int24", "address"],
                [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks]
            )
        );
        await poolManager.setSlot0(0, 123, 0, 0); // tick = 123

        const amount0 = 1000n;
        const amount1 = -950n;

        // Pack amount0 and amount1 into a single int256
        const delta = (amount0 << 128n) | (amount1 & ((1n << 128n) - 1n));
        await registry.updateTelPosition(poolId, 1);
        await expect(
            poolManager.callAfterSwap(
                await hook.getAddress(),
                user.address,
                poolKey,
                swapParams,
                delta,
                "0x"
            )
        ).to.emit(hook, "SwapOccurredWithTick").withArgs(poolId, user.address, 1000n, -950n, 123);
    });

    it("should call _beforeAddLiquidity and update registry", async () => {
        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: await hook.getAddress(),
        };
        const params = {
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000,
            salt: "0x1000000000000000000000000000000000000000000000000000000000000000"
        };

        await registry.updateTelPosition("0x1110000000000000000000000000000000000000000000000000000000000000", 1);

        await poolManager.callBeforeAddLiquidity(
            await hook.getAddress(),
            user.address,
            poolKey,
            params,
            "0x"
        );
    });

    it("should call _beforeRemoveLiquidity and zero out position", async () => {
        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: await hook.getAddress(),
        };
        const tickLower = -100;
        const tickUpper = 100;
        const liquidityDelta = 5000;
        await registry.updateTelPosition(poolId, 1);

        const params = {
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000,
            salt: "0x1000000000000000000000000000000000000000000000000000000000000000"
        };

        await poolManager.callBeforeAddLiquidity(
            await hook.getAddress(),
            user.address,
            poolKey,
            params,
            "0x"
        );

        poolManager.callBeforeRemoveLiquidity(
            await hook.getAddress(),
            user.address,
            poolKey,
            {
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -liquidityDelta,
                salt: "0x1000000000000000000000000000000000000000000000000000000000000000",
            },
            "0x"
        )

        const position = await registry.getPosition("0x1000000000000000000000000000000000000000000000000000000000000000");
        expect(position.provider).to.equal(ethers.ZeroAddress);
        expect(position.liquidity).to.equal(0);
    });

    it("should skip _afterSwap if pool is not TEL-associated", async () => {
        const poolKey = {
            currency0: ethers.ZeroAddress,
            currency1: ethers.ZeroAddress,
            fee: 3000,
            tickSpacing: 60,
            hooks: await hook.getAddress(),
        };

        const swapParams = {
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0,
        };

        const amount0 = 1000n;
        const amount1 = -900n;
        const delta = (amount0 << 128n) | (amount1 & ((1n << 128n) - 1n));

        await expect(
            poolManager.callAfterSwap(
                await hook.getAddress(),
                user.address,
                poolKey,
                swapParams,
                delta,
                "0x"
            )
        ).to.not.emit(hook, "SwapOccurredWithTick");
    });
});

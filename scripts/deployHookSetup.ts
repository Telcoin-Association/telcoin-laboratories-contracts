import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

async function main() {
    const [deployer]: SignerWithAddress[] = await ethers.getSigners();
    console.log("Deploying with:", deployer.address);

    // Constants
    const TEL_TOKEN = "0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32";
    const POOL_MANAGER = "0x67366782805870060151383f4bbff9dab53e5cd6";
    const POSITION_MANAGER = "0x1ec2ebf4f37e7363fdfe3551602425af0b3ceef9";

    // 1. Deploy PositionRegistry
    const PositionRegistryFactory = await ethers.getContractFactory("PositionRegistry");
    const positionRegistry = await PositionRegistryFactory.deploy(TEL_TOKEN, POOL_MANAGER, POSITION_MANAGER);
    await positionRegistry.waitForDeployment();
    const positionRegistryAddress = await positionRegistry.getAddress();
    console.log("✅ PositionRegistry deployed at:", positionRegistryAddress);

    // 2. Deploy TELxIncentiveHook
    const IncentiveHookFactory = await ethers.getContractFactory("TELxIncentiveHook");
    const incentiveHook = await IncentiveHookFactory.deploy(POOL_MANAGER, POSITION_MANAGER, positionRegistryAddress);
    await incentiveHook.waitForDeployment();
    const incentiveHookAddress = await incentiveHook.getAddress();
    console.log("✅ TELxIncentiveHook deployed at:", incentiveHookAddress);

    // 3. Deploy TELxSubscriber
    const SubscriberFactory = await ethers.getContractFactory("TELxSubscriber");
    const subscriber = await SubscriberFactory.deploy(positionRegistryAddress, POSITION_MANAGER);
    await subscriber.waitForDeployment();
    const subscriberAddress = await subscriber.getAddress();
    console.log("✅ TELxSubscriber deployed at:", subscriberAddress);
}

main().catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
});
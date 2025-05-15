// calculate_rewards.js

const { ethers } = require("hardhat");
const { BigNumber } = ethers;
const ABI = require("./abis/PositionRegistry.json");

// CONFIG
const POSITION_REGISTRY = "0xYourPositionRegistryAddress";
const START_BLOCK = 12345678; // will be pulled from registry
const END_BLOCK = 12349999; // set manually or by timestamp
const TOTAL_REWARD = ethers.utils.parseUnits("1000", 18); // 1000 tokens to distribute

async function main() {
    const provider = ethers.provider;
    const registry = new ethers.Contract(POSITION_REGISTRY, ABI, provider);

    // Step 1: Determine start block from registry
    const lastRewardBlock = await registry.lastRewardBlock();
    const startBlock = lastRewardBlock.toNumber();
    console.log(`Last reward block: ${startBlock}`);

    // Step 2: Get all active positions
    const activeIds = await registry.getAllActivePositionIds();
    const positions = await Promise.all(
        activeIds.map(id => registry.getPosition(id))
    );

    // Step 3: Initialize weight tracker
    const lpWeights = {}; // { address: BigNumber }
    let totalWeight = BigNumber.from(0);

    // Step 4: Scan SwapOccurredWithTick events
    const iface = new ethers.utils.Interface(ABI);
    const topic = iface.getEventTopic("SwapOccurredWithTick");

    const logs = await provider.getLogs({
        address: POSITION_REGISTRY,
        topics: [topic],
        fromBlock: startBlock,
        toBlock: END_BLOCK
    });

    console.log(`Found ${logs.length} swap events`);

    for (const log of logs) {
        const parsed = iface.parseLog(log);
        const tick = parsed.args.currentTick;

        for (const posId of activeIds) {
            const pos = await registry.getPosition(posId);
            const inRange = tick >= pos.tickLower && tick < pos.tickUpper;

            if (inRange) {
                const addr = pos.provider.toLowerCase();
                const weight = BigNumber.from(pos.liquidity);

                lpWeights[addr] = (lpWeights[addr] || BigNumber.from(0)).add(weight);
                totalWeight = totalWeight.add(weight);
            }
        }
    }

    console.log("\nReward distribution:");
    for (const [lp, weight] of Object.entries(lpWeights)) {
        const share = weight.mul(TOTAL_REWARD).div(totalWeight);
        console.log(`${lp}: ${ethers.utils.formatUnits(share, 18)} tokens`);
    }
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});

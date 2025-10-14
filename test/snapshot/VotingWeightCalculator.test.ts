import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { VotingWeightCalculator, TestSource } from "../../typechain-types";

describe("VotingWeightCalculator", () => {
    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let calculator: VotingWeightCalculator;
    let mockSource: TestSource;
    let anotherSource: TestSource;

    beforeEach(async () => {
        [owner, user] = await ethers.getSigners();

        const Calculator = await ethers.getContractFactory("VotingWeightCalculator");
        calculator = await Calculator.deploy(owner.address);

        const Mock = await ethers.getContractFactory("TestSource");
        mockSource = await Mock.deploy();
        anotherSource = await Mock.deploy();

        await mockSource.setBalance(user.address, 100);
        await anotherSource.setBalance(user.address, 200);
    });

    it("should add a valid source", async () => {
        await calculator.addSource(mockSource.getAddress());
        const sources = await calculator.getSources();
        expect(sources[0]).to.equal(await mockSource.getAddress());
    });

    it("should revert when adding a duplicate source", async () => {
        await calculator.addSource(mockSource.getAddress());
        await expect(
            calculator.addSource(mockSource.getAddress())
        ).to.be.revertedWith("VotingWeightCalculator: source already added");
    });

    it("should remove a source", async () => {
        await calculator.addSource(mockSource.getAddress());
        await expect(calculator.removeSource(0))
            .to.emit(calculator, "SourceRemoved")
            .withArgs(await mockSource.getAddress(), 0);
        expect((await calculator.getSources()).length).to.equal(0);
    });

    it("should calculate the correct balance from one source", async () => {
        await calculator.addSource(mockSource.getAddress());
        const result = await calculator.balanceOf(user.address);
        expect(result).to.equal(100);
    });

    it("should calculate the correct aggregate balance from multiple sources", async () => {
        await calculator.addSource(mockSource.getAddress());
        await calculator.addSource(anotherSource.getAddress());
        const result = await calculator.balanceOf(user.address);
        expect(result).to.equal(300);
    });
});
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { CouncilMember, TestTelcoin, TestProxy } from "../../typechain-types";

describe("CouncilMember", () => {
    let admin: SignerWithAddress;
    let support: SignerWithAddress;
    let member: SignerWithAddress;
    let holder: SignerWithAddress;
    let councilMember: CouncilMember;
    let telcoin: TestTelcoin;
    let proxy: TestProxy;

    let target: SignerWithAddress;
    let id: number = 0;
    let governanceRole: string = ethers.keccak256(ethers.toUtf8Bytes("GOVERNANCE_COUNCIL_ROLE"));
    let supportRole: string = ethers.keccak256(ethers.toUtf8Bytes("SUPPORT_ROLE"));

    beforeEach(async () => {
        [admin, support, member, holder, target] = await ethers.getSigners();

        const TestTelcoinFactory = await ethers.getContractFactory("TestTelcoin", admin);
        telcoin = await TestTelcoinFactory.deploy(admin.address);

        const TestStreamFactory = await ethers.getContractFactory("TestProxy", admin);
        proxy = await TestStreamFactory.deploy(await telcoin.getAddress());

        const CouncilMemberFactory = await ethers.getContractFactory("CouncilMember", admin);
        councilMember = await CouncilMemberFactory.deploy();

        await councilMember.initialize(await telcoin.getAddress(), "Test Council", "TC", await proxy.getAddress(), target.address, target.address, id);
        await councilMember.grantRole(governanceRole, admin.address);
        await councilMember.grantRole(supportRole, support.address);
    });

    describe("Values", () => {
        describe("Getters", () => {
            it("GOVERNANCE_COUNCIL_ROLE", async () => {
                expect(await councilMember.GOVERNANCE_COUNCIL_ROLE()).to.equal(governanceRole);
            });

            it("SUPPORT_ROLE", async () => {
                expect(await councilMember.SUPPORT_ROLE()).to.equal(supportRole);
            });

            it("TELCOIN address", async () => {
                expect(await councilMember.TELCOIN()).to.equal(await telcoin.getAddress());
            });

            it("proxy address", async () => {
                expect(await councilMember._proxy()).to.equal(await proxy.getAddress());
            });

            it("target address", async () => {
                expect(await councilMember._target()).to.equal(target.address);
            });

            it("id", async () => {
                expect(await councilMember._id()).to.equal(id);
            });

            it("has governance role", async () => {
                expect(await councilMember.hasRole(governanceRole, admin.address)).to.equal(true);
            });

            it("has support role", async () => {
                expect(await councilMember.hasRole(supportRole, support.address)).to.equal(true);
            });

            it("has AccessControlEnumerableUpgradeable interface", async () => {
                expect(await councilMember.supportsInterface('0x5bfad1a8')).to.equal(true);
            });

            it("has ERC721EnumerableUpgradeable interface", async () => {
                expect(await councilMember.supportsInterface('0x79f154c4')).to.equal(true);
            });
        });

        describe("Setters", () => {
            describe("updateStream", () => {
                describe("Failure", () => {
                    it("updateStream should fail when caller does not have role", async () => {
                        await expect(councilMember.connect(support).updateProxy(support.address)).to.be.reverted;
                    });
                });

                describe("Success", () => {
                    it("updateStream", async () => {
                        expect(await councilMember.updateProxy(support.address)).emit(councilMember, 'ProxyUpdated').withArgs(support.address);
                        expect(await councilMember._proxy()).to.equal(support.address);
                    });
                });
            })

            describe("updateTarget", () => {
                describe("Failure", () => {
                    it("updateTarget should fail when caller does not have role", async () => {
                        await expect(councilMember.connect(support).updateTarget(support.address)).to.be.reverted;
                    });
                });

                describe("Success", () => {
                    it("updateTarget", async () => {
                        await expect(councilMember.updateTarget(support.address)).emit(councilMember, 'TargetUpdated').withArgs(support.address);
                        expect(await councilMember._target()).to.equal(support.address);
                    });
                });
            })

            describe("updateLockup", () => {
                describe("Failure", () => {
                    it("updateLockup should fail when caller does not have role", async () => {
                        await expect(councilMember.connect(support).updateLockup(support.address)).to.be.reverted;
                    });
                });

                describe("Success", () => {
                    it("updateLockup", async () => {
                        await expect(councilMember.updateLockup(support.address)).emit(councilMember, 'LockupUpdated').withArgs(support.address);
                        expect(await councilMember._lockup()).to.equal(support.address);
                    });
                });
            })

            describe("updateID", () => {
                describe("Failure", () => {
                    it("updateID should fail when caller does not have role", async () => {
                        await expect(councilMember.connect(support).updateID(1)).to.be.reverted;
                    });
                });

                describe("Success", () => {
                    it("updateID", async () => {
                        await expect(councilMember.updateID(1)).emit(councilMember, 'IDUpdated').withArgs(1);
                        expect(await councilMember._id()).to.equal(1);
                    });
                });
            })
        });
    });

    describe("mutative", () => {
        beforeEach(async () => {
            telcoin.transfer(await proxy.getAddress(), 100000);
        });

        describe("mint", () => {
            it("mint a single NFT", async () => {
                await expect(councilMember.mint(member.address)).emit(councilMember, 'Transfer');
                expect(await councilMember.totalSupply()).to.equal(1);
                expect(await councilMember.balanceOf(member.address)).to.equal(1);
                expect(await councilMember.ownerOf(0)).to.equal(member.address);
            });
        });

        describe("approve", () => {
            beforeEach(async () => {
                await expect(councilMember.mint(member.address));
                expect(await councilMember.balanceOf(support.address)).to.equal(0);
            });

            describe("Failure", () => {
                it("approval is created for and only for designated address", async () => {
                    await expect(councilMember.connect(holder).transferFrom(member.address, support.address, 0)).to.be.reverted;
                    expect(await councilMember.balanceOf(support.address)).to.equal(0);
                });
            });

            describe("Success", () => {
                it("approval is created for and only for designated address", async () => {
                    await expect(councilMember.connect(admin).approve(support.address, 0)).emit(councilMember, 'Approval');
                    await expect(councilMember.connect(support).transferFrom(member.address, support.address, 0)).to.be.not.reverted;
                    expect(await councilMember.balanceOf(support.address)).to.equal(1);
                });
            });
        });

        describe("burn", () => {
            beforeEach(async () => {
                telcoin.transfer(await proxy.getAddress(), 100000);
                expect(await councilMember.mint(member.address)).to.not.reverted;
                expect(await councilMember.mint(support.address)).to.not.reverted;
                expect(await councilMember.mint(await proxy.getAddress())).to.not.reverted;
            });

            describe("Failure", () => {
                it("the correct removal is made", async () => {
                    await expect(councilMember.burn(0, member.address)).to.not.reverted;
                    await expect(councilMember.burn(1, support.address)).to.not.reverted;
                    await expect(councilMember.burn(2, support.address)).to.revertedWith("CouncilMember: must maintain council");
                });
            });

            describe("Success", () => {
                it("the correct removal is made", async () => {
                    await expect(councilMember.burn(1, support.address)).emit(councilMember, "Transfer");
                });
            });
        });

        describe("Extended burn", () => {
            beforeEach(async () => {
                telcoin.transfer(await proxy.getAddress(), 100000);
                await councilMember.mint(member.address)
                await councilMember.mint(support.address)
                await councilMember.mint(await proxy.getAddress())
                await councilMember.mint(member.address)
                await councilMember.mint(support.address)
                await councilMember.mint(await proxy.getAddress())
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(member.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(5);

                await expect(councilMember.burn(0, support.address)).emit(councilMember, "Transfer").withArgs(member.address, "0x0000000000000000000000000000000000000000", 0);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(member.address)).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(0);
                expect(await councilMember.balanceIndexToTokenId(0)).to.equal(5);

                await councilMember.mint(member.address)

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(member.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(support.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(5);

                await expect(councilMember.burn(1, support.address)).emit(councilMember, "Transfer").withArgs(support.address, "0x0000000000000000000000000000000000000000", 1);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(support.address)).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(1);
                expect(await councilMember.balanceIndexToTokenId(1)).to.equal(5);

                await councilMember.mint(support.address)

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(support.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(5);

                await expect(councilMember.burn(2, support.address)).emit(councilMember, "Transfer").withArgs(await proxy.getAddress(), "0x0000000000000000000000000000000000000000", 2);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(2);
                expect(await councilMember.balanceIndexToTokenId(2)).to.equal(5);

                await councilMember.mint(await proxy.getAddress())

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(member.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(5);

                await expect(councilMember.burn(3, support.address)).emit(councilMember, "Transfer").withArgs(member.address, "0x0000000000000000000000000000000000000000", 3);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(member.address)).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(3);
                expect(await councilMember.balanceIndexToTokenId(3)).to.equal(5);

                await councilMember.mint(member.address)

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(member.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(support.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(5);

                await expect(councilMember.burn(4, support.address)).emit(councilMember, "Transfer").withArgs(support.address, "0x0000000000000000000000000000000000000000", 4);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(support.address)).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(4);
                expect(await councilMember.balanceIndexToTokenId(4)).to.equal(5);

                await councilMember.mint(support.address)

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(support.address)).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });

            it("the correct removal is made", async () => {
                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(0)).to.equal(0);

                await expect(councilMember.burn(5, support.address)).emit(councilMember, "Transfer").withArgs(await proxy.getAddress(), "0x0000000000000000000000000000000000000000", 5);

                expect(await councilMember.totalSupply()).to.equal(5);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(1);
                expect(await councilMember.tokenIdToBalanceIndex(5)).to.equal("115792089237316195423570985008687907853269984665640564039457584007913129639935");
                expect(await councilMember.balanceIndexToTokenId(0)).to.equal(0);

                await councilMember.mint(await proxy.getAddress())

                expect(await councilMember.totalSupply()).to.equal(6);
                expect(await councilMember.balanceOf(await proxy.getAddress())).to.equal(2);
                expect(await councilMember.tokenIdToBalanceIndex(6)).to.equal(5);
                expect(await councilMember.balanceIndexToTokenId(5)).to.equal(6);
            });
        });

        describe("transferFrom", () => {
            beforeEach(async () => {
                expect(await councilMember.mint(member.address));
                expect(await councilMember.mint(support.address));
            });

            describe("Success", () => {
                it("the correct removal is made", async () => {
                    expect(await councilMember.balanceOf(member.address)).to.equal(1);
                    expect(await councilMember.balanceOf(support.address)).to.equal(1);
                    expect(await councilMember.transferFrom(member.address, support.address, 0)).to.not.reverted;
                    expect(await councilMember.balanceOf(member.address)).to.equal(0);
                    expect(await councilMember.balanceOf(support.address)).to.equal(2);
                });
            });
        });
    });

    describe("tokenomics", () => {
        beforeEach(async () => {
            telcoin.transfer(await proxy.getAddress(), 100000);
        });

        describe("mint", () => {
            it("correct balance accumulation", async () => {
                await expect(councilMember.mint(member.address)).to.not.reverted;
                expect(await telcoin.balanceOf(member.address)).to.equal(0);
                // // mint(0) => 0 TEL
                expect(await councilMember.balances(0)).to.equal(0);

                await expect(councilMember.mint(support.address)).to.not.reverted;
                expect(await telcoin.balanceOf(member.address)).to.equal(0);
                expect(await telcoin.balanceOf(support.address)).to.equal(0);
                // mint(1) => 100 TEL
                expect(await councilMember.balances(0)).to.equal(100);
                // mint(1) => 0 TEL
                expect(await councilMember.balances(1)).to.equal(0);

                await expect(councilMember.mint(await councilMember.getAddress())).to.not.reverted;
                expect(await telcoin.balanceOf(member.address)).to.equal(0);
                expect(await telcoin.balanceOf(support.address)).to.equal(0);
                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(200);
                // mint(1) => 50 TEL + mint(2) => 100 TEL
                expect(await councilMember.balances(0)).to.equal(150);
                // mint(2) => 50 TEL
                expect(await councilMember.balances(1)).to.equal(50);
                // // mint(2) => 0 TEL
                expect(await councilMember.balances(2)).to.equal(0);
            });
        });

        describe("burn", () => {
            it("the correct removal is made", async () => {
                await expect(councilMember.mint(member.address)).to.not.reverted;
                await expect(councilMember.mint(support.address)).to.not.reverted;
                await expect(councilMember.mint(await councilMember.getAddress())).to.not.reverted;

                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(200);
                await expect(councilMember.burn(2, holder.address)).to.not.reverted;
                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(267);

                //100 TEL / totalSupply() = 33 + runningBalance 1 TEL

                // mint(0) => 0 TEL + mint(1) => 100 TEL + mint(2) => 50 TEL + burn(2) => 33 TEL
                expect(await councilMember.balances(0)).to.equal(183);
                // mint(1) => 0 TEL + mint(2) => 50 TEL + burn(2) => 33 TEL
                expect(await councilMember.balances(1)).to.equal(83);
                // mint(2) => 0 TEL + burn(2) => 33 TEL
                expect(await telcoin.balanceOf(holder.address)).to.equal(33);
            });
        });

        describe("transferFrom", () => {
            it("funds remain with old office holder", async () => {
                expect(await councilMember.mint(member.address));
                expect(await councilMember.mint(support.address));

                expect(await councilMember.transferFrom(member.address, support.address, 0)).to.not.reverted;
                // mint(0) => 100 TEL + mint(1) => 50 TEL
                expect(await telcoin.balanceOf(member.address)).to.equal(150);
                // mint(0) => 0 TEL + mint(1) => 0 TEL
                expect(await telcoin.balanceOf(support.address)).to.equal(0);
                // mint(1) => 50 TEL
                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(50);
            });

            it("funds sent to different holder", async () => {
                expect(await councilMember.mint(member.address));
                expect(await councilMember.mint(support.address));

                expect(await councilMember.transferFrom(member.address, support.address, 0)).to.not.reverted;
                // mint(0) => 0 TEL + mint(1) => 0 TEL
                expect(await telcoin.balanceOf(support.address)).to.equal(0);
                // mint(0) => 100 TEL + mint(1) => 50 TEL
                expect(await telcoin.balanceOf(member.address)).to.equal(150);
                // mint(1) => 50 TEL
                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(50);
            });
        });

        describe("claim", () => {
            it("claiming rewards", async () => {
                await expect(councilMember.mint(member.address));
                await expect(councilMember.connect(member).claim(0, 100)).to.not.reverted;
                expect(await councilMember.balances(0)).to.equal(0);

                await expect(councilMember.mint(support.address)).to.not.reverted;
                await expect(councilMember.connect(member).claim(0, 200)).to.be.revertedWith("CouncilMember: withdrawal amount is higher than balance");
                await expect(councilMember.connect(member).claim(0, 100)).to.not.reverted;
                expect(await councilMember.balances(0)).to.equal(50);
                expect(await councilMember.balances(1)).to.equal(50);

                await expect(councilMember.mint(member.address)).to.not.reverted;
                expect(await councilMember.balances(0)).to.equal(100);
                expect(await councilMember.balances(1)).to.equal(100);
                expect(await councilMember.balances(2)).to.equal(0);
                await expect(councilMember.connect(member).claim(0, 100)).to.not.reverted;
                expect(await councilMember.balances(0)).to.equal(33);
                expect(await councilMember.balances(1)).to.equal(133);
                expect(await councilMember.balances(2)).to.equal(33);

                expect(await telcoin.balanceOf(member.address)).to.equal(300);
                expect(await telcoin.balanceOf(support.address)).to.equal(0);
                expect(await telcoin.balanceOf(await councilMember.getAddress())).to.equal(200);
            });
        });

        describe("retrieve", () => {
            it("minting does not affect claims, but does increase balance", async () => {
                await expect(councilMember.mint(member.address));
                expect(await telcoin.balanceOf(member.address)).to.equal(0);
                // mint(0) => 0 TEL
                expect(await councilMember.balances(0)).to.equal(0);

                await expect(councilMember.retrieve()).to.not.reverted;
                // mint(0) => 0 TEL + retrieve() => 100 TEL
                expect(await councilMember.balances(0)).to.equal(100);

                await expect(councilMember.mint(support.address)).to.not.reverted;
                // mint(0) => 0 TEL + retrieve() => 100 TEL + mint(1) => 100 TEL
                expect(await councilMember.balances(0)).to.equal(200);

                await expect(councilMember.retrieve()).to.not.reverted;
                // mint(0) => 0 TEL + retrieve() => 100 TEL + mint(1) => 100 TEL+ retrieve() => 50 TEL
                expect(await councilMember.balances(0)).to.equal(250);
                // retrieve() => 50 TEL
                expect(await councilMember.balances(1)).to.equal(50);
            });
        });

        describe("erc20Rescue", () => {
            it("rescue tokens", async () => {
                await telcoin.transfer(await councilMember.getAddress(), 100000);
                await expect(councilMember.connect(support).erc20Rescue(await telcoin.getAddress(), support.address, await telcoin.balanceOf(await councilMember.getAddress()))).to.not.reverted;
                expect(await telcoin.balanceOf(support.address)).to.equal(100000);
            });
        });
    });
});
//supportsInterface 
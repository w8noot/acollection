import {expect} from "chai";
import {ethers} from "hardhat";
import {BigNumber as BN, Signer} from "ethers";
import {
  ACollection,
  ACollection__factory,
  FraudDeciderWeb2,
  FraudDeciderWeb2__factory,
} from "../typechain-types";
import "@nomicfoundation/hardhat-chai-matchers";

const genRanHex = (size: number) =>
  [...Array(size)]
    .map(() => Math.floor(Math.random() * 16).toString(16))
    .join("");

describe("Success transfer", async () => {
  let accounts: Signer[];
  let fraudDecider: FraudDeciderWeb2;
  let collectionInstance: ACollection;

  before(async () => {
    accounts = await ethers.getSigners();

    const fraudDeciderFactory = new FraudDeciderWeb2__factory(accounts[0]);
    const collectionFactory = new ACollection__factory(accounts[0]);

    fraudDecider = await fraudDeciderFactory.deploy();
    collectionInstance = await collectionFactory.deploy(
      "Collection name",
      "CN",
      "",
      accounts[1].getAddress(),
      "0x",
      fraudDecider.address,
      true,
    );
  });

  it("mint", async () => {
    await collectionInstance.connect(accounts[1]).mintWithoutId(accounts[1].getAddress(), "a", "0x");
  });

  it("init transfer", async () => {
    const tokenId = BN.from(0);
    let transferNumber = await collectionInstance.transferCounts(tokenId);
    transferNumber = transferNumber.add(1); // count increments in initTransfer and before emitting

    const tx = await collectionInstance
      .connect(accounts[1])
      .initTransfer(
        tokenId,
        accounts[2].getAddress(),
        "0x",
        ethers.constants.AddressZero
      );
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferInit")
      .withArgs(tokenId, await accounts[1].getAddress(), await accounts[2].getAddress(), transferNumber);
  });

  it("set public key", async () => {
    const tokenId = BN.from(0);
    const transferNumber = await collectionInstance.transferCounts(tokenId);
    const tx = await collectionInstance.connect(accounts[2])
      .setTransferPublicKey(tokenId, "0x12", transferNumber);
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferPublicKeySet")
      .withArgs(tokenId, "0x12");
  });

  it("set encrypted password", async () => {
    const tx = await collectionInstance.connect(accounts[1])
      .approveTransfer(BN.from(0), "0x34");
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferPasswordSet")
      .withArgs(BN.from(0), "0x34");
  });

  it("finalize transfer", async() => {
    const tx = await collectionInstance.connect(accounts[2])
      .finalizeTransfer(BN.from(0));
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferFinished")
      .withArgs(BN.from(0));
    await expect(tx)
      .to
      .emit(collectionInstance, "Transfer")
      .withArgs(await accounts[1].getAddress(), await accounts[2].getAddress(), BN.from(0));
  });

  it("ownership should should change after transfer", async () => {
    const tokenOwner = await collectionInstance.ownerOf(BN.from(0));
    expect(tokenOwner).eq(await accounts[2].getAddress())
  });
});

describe("Transfer with fraud", async () => {
  let accounts: Signer[];
  let fraudDecider: FraudDeciderWeb2;
  let collectionInstance: ACollection;

  before(async () => {
    accounts = await ethers.getSigners();

    const fraudDeciderFactory = new FraudDeciderWeb2__factory(accounts[0]);
    const collectionFactory = new ACollection__factory(accounts[0]);
    
    fraudDecider = await fraudDeciderFactory.deploy();
    collectionInstance = await collectionFactory.deploy(
      "Collection name",
      "CN",
      "",
      accounts[1].getAddress(),
      "0x",
      fraudDecider.address,
      true,
    );
  });

  it("mint", async () => {
    await collectionInstance.connect(accounts[1]).mintWithoutId(accounts[1].getAddress(), "b", "0x");
  });

  it("init transfer", async () => {
    const tokenId = BN.from(0);
    let transferNumber = await collectionInstance.transferCounts(tokenId);
    transferNumber = transferNumber.add(1); // count increments in initTransfer and before emitting

    const tx = await collectionInstance.connect(accounts[1])
      .initTransfer(BN.from(0),
        accounts[2].getAddress(), "0x", ethers.constants.AddressZero);
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferInit")
      .withArgs(BN.from(0), await accounts[1].getAddress(), await accounts[2].getAddress(), transferNumber);
  });

  it("set public key", async () => {
    const tokenId = BN.from(0);
    const transferNumber = await collectionInstance.transferCounts(tokenId);
    const tx = await collectionInstance.connect(accounts[2])
      .setTransferPublicKey(tokenId, "0x1234", transferNumber);
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferPublicKeySet")
      .withArgs(BN.from(0), "0x1234");
  });

  it("set encrypted password", async () => {
    const tx = await collectionInstance.connect(accounts[1])
      .approveTransfer(BN.from(0), "0x3421");
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferPasswordSet")
      .withArgs(BN.from(0), "0x3421");
  });

  it("report fraud", async () => {
    const tx = await collectionInstance.connect(accounts[2])
      .reportFraud(BN.from(0), "0x12");
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferFraudReported")
      .withArgs(BN.from(0));
  });

  it("fraud approved", async () => {
    const tx = await fraudDecider.connect(accounts[0])
      .lateDecision(collectionInstance.address, BN.from(0), false);
    await expect(tx)
      .to
      .emit(collectionInstance, "TransferFraudDecided")
      .withArgs(BN.from(0), false);
    await expect(tx)
      .to
      .emit(collectionInstance, "Transfer")
      .withArgs(await accounts[1].getAddress(), await accounts[2].getAddress(), BN.from(0));
  });
});
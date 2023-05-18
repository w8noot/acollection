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
      accounts[3].getAddress(),
      accounts[4].getAddress(),
      "0x",
      fraudDecider.address,
      true,
    );
  });

  it("mint", async () => {
    await collectionInstance.connect(accounts[1]).mint(accounts[1].getAddress(), BN.from(0), "a", "0x");
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

  it("mint batch", async () => {
    await collectionInstance.connect(accounts[1]).mintBatchWithoutMeta(
      accounts[0].getAddress(),
      BN.from(5990),
      BN.from(20),
      Array(20).fill("0x"),
    )


    const common = await collectionInstance.commonTokensCount();
    const uncommon = await collectionInstance.uncommonTokensCount();
    const payed = await collectionInstance.payedTokensCount();

    expect(common.eq(BN.from(10 + 1))).true; // +1 because we've minted common earlier
    expect(uncommon.eq(BN.from(10))).true;
    expect(payed.eq(BN.from(0))).true;
  })

  it("attach meta", async () => {
    const commonArr = Array(10).fill(0).map((_, i) => `${i}c`) ;
    const uncommonArr = Array(10).fill(0).map((_, i) => `${i}u`);

    await collectionInstance.connect(accounts[1]).attachMetaBatch(
      BN.from(5990),
      BN.from(20),
      commonArr,
      uncommonArr,
      Array(0),
    );

    const resArr = [];
    for(let i = BN.from(5990); i.lt(6010); i = i.add(BN.from(1))) {
      resArr.push(await collectionInstance.tokenUris(i));
    }
  
    expect(commonArr.concat(uncommonArr)).deep.eq(resArr);
  })
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
      accounts[3].getAddress(),
      accounts[4].getAddress(),
      "0x",
      fraudDecider.address,
      true,
    );
  });

  it("mint", async () => {
    await collectionInstance.connect(accounts[1]).mint(accounts[1].getAddress(), BN.from(0), "b", "0x");
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
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./IFraudDecider.sol";
import "./IEncryptedFileToken.sol";
import "./IEncryptedFileTokenUpgradeable.sol";
import "./IEncryptedFileTokenCallbackReceiver.sol";
import "./Whitelist.sol";

contract ACollection is Whitelist, IEncryptedFileToken, ERC721Enumerable, AccessControl {
    using ECDSA for bytes32;
    
    /// @dev TokenData - struct with basic token data
    struct TokenData {
        uint256 id;             // token id
        string metaUri;         // metadata uri
        bytes data;             // additional data
    }

    /// @dev TransferInfo - transfer process info
    struct TransferInfo {
        uint256 id;                                             // token id
        address initiator;                                      // transfer initiator
        address from;                                           // transfer sender
        address to;                                             // transfer target
        IEncryptedFileTokenCallbackReceiver callbackReceiver;  // callback receiver
        bytes data;                                             // transfer data
        bytes publicKey;                                        // public key of receiver
        bytes encryptedPassword;                                // encrypted password
        bool fraudReported;                                     // if fraud reported while finalizing transfer
        uint256 publicKeySetAt;                                 // public key set at
        uint256 passwordSetAt;                                  // password set at
        uint256 blockTimestamp;
        bytes32 blockHash;
    }

    uint256 public constant PERCENT_MULTIPLIER = 10000;
    bytes32 public constant COMMON_WHITELIST_APPROVER_ROLE = keccak256("COMMON_WHITELIST_APPROVER");
    bytes32 public constant UNCOMMON_WHITELIST_APPROVER_ROLE = keccak256("UNCOMMON_WHITELIST_APPROVER");
    address public commonWhitelistApprover;
    address public uncommonWhitelistApprover;
    string[] public commonCids;
    string[] public uncommonCids;
    string[] public payedCids;

    bytes public collectionData;                               // collection additional data
    string private contractMetaUri;                            // contract-level metadata
    mapping(uint256 => string) public tokenUris;               // mapping of token metadata uri
    mapping(uint256 => bytes) public tokenData;                // mapping of token additional data
    uint256 public tokensCount;                                // count of minted tokens
    uint256 public tokensLimit;                                // mint limit
    uint256 public commonTokensCount;                          // count of free minted common tokens
    uint256 public commonTokensLimit;                          // free mint common tokens limit
    uint256 public uncommonTokensCount;                        // count of free minted uncommon tokens
    uint256 public uncommonTokensLimit;                        // free mint uncommon tokens limit
    uint256 public payedTokensCount;                           // count of minted tokens
    uint256 public payedTokensLimit;                           // mint limit
    mapping(uint256 => TransferInfo) private transfers;        // transfer details
    mapping(uint256 => uint256) public transferCounts;         // count of transfers per transfer
    bool private fraudLateDecisionEnabled;                     // false if fraud decision is instant
    IFraudDecider private fraudDecider_;                       // fraud decider
    uint256 public finalizeTransferTimeout;                    // Time before transfer finalizes automatically 
    uint256 private salesStartTimestamp;                       // Time when users can start transfer tokens 
    uint256 public whitelistDeadline;
    uint256 public whitelistDiscount;                         // 1 - 0.01%
    uint256 private nonce = 0;

    constructor(
        string memory name,
        string memory symbol,
        string memory _contractMetaUri,
        address _admin,
        address _commonWhitelistApprover,
        address _uncommonWhitelistApprover,
        bytes memory _data,
        IFraudDecider _fraudDecider,
        bool _fraudLateDecisionEnabled,
        string[] memory cids
    ) ERC721(name, symbol) {
        tokensCount = 0;
        tokensLimit = 10000;
        commonTokensCount = 0;                         
        commonTokensLimit = 6000;                     
        uncommonTokensCount = 0;                       
        uncommonTokensLimit = 1000;                   
        payedTokensCount = 0;                          
        payedTokensLimit = 3000;

        contractMetaUri = _contractMetaUri;
        collectionData = _data;
        fraudDecider_ = _fraudDecider;
        fraudLateDecisionEnabled = _fraudLateDecisionEnabled;
        finalizeTransferTimeout = 24 hours;
        salesStartTimestamp = block.timestamp - 1 minutes;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(COMMON_WHITELIST_APPROVER_ROLE, _commonWhitelistApprover);
        commonWhitelistApprover = _commonWhitelistApprover;
        _grantRole(UNCOMMON_WHITELIST_APPROVER_ROLE, _uncommonWhitelistApprover);
        uncommonWhitelistApprover = _uncommonWhitelistApprover;

        require(cids.length == 10000, "Mark3dCollection: wrong amount of cids");
        commonCids = new string[](commonTokensLimit);
        uncommonCids = new string[](uncommonTokensLimit);
        payedCids = new string[](payedTokensLimit);

        for (uint i = 0; i < cids.length; i++) {
            if (i < commonTokensLimit) {
                commonCids[i] = cids[i];
            } else if (i < commonTokensLimit+uncommonTokensLimit) {
                uncommonCids[i - commonTokensLimit] = cids[i];
            } else {
                payedCids[i - commonTokensLimit+uncommonTokensLimit] = cids[i];
            }
        }
    }

    function setWhitelistParams(
        uint256 deadline,
        uint256 discount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistDeadline = deadline;
        whitelistDiscount = discount;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, IERC165, AccessControl) returns (bool) {
        return interfaceId == type(IEncryptedFileToken).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
    /// @return Metadata file URI
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return tokenUris[tokenId];
    }

    /// @dev Function to detect if fraud decision instant. Should return false in EVM chains and true in Filecoin
    /// @return Boolean indicating if fraud decision will be instant
    function fraudDecisionInstant() external view returns (bool) {
        return !fraudLateDecisionEnabled;
    }

    /// @dev Function to get fraud decider instance for this token
    /// @return IFraudDecider instance
    function fraudDecider() external view returns (IFraudDecider) {
        return fraudDecider_;
    }

    /// @dev Mint function. Can called only by the owner
    /// @param to - token receiver
    /// @param id - token id
    /// @param metaUri - metadata uri
    /// @param _data - additional token data
    function mint(
        address to,
        uint256 id,
        string memory metaUri,
        bytes memory _data
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(metaUri).length > 0, "Mark3dCollection: empty meta uri");
        require(id < tokensLimit, "Mark3dCollection: limit reached");
        _mint(to, id, metaUri, _data);
    }
    
    /// @dev Mint batch of tokens without metaUri. Can called only by the owner
    /// @param to - tokens receiver
    /// @param startId - tokenId of the first token to mint
    /// @param count - tokens quantity to mint
    /// @param _data - additional token data list
    function mintBatchWithoutMeta(address to, uint256 startId, uint256 count, bytes[] memory _data) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(startId + count-1 < tokensLimit, "Mark3dCollection: number of tokens exceeds tokensLimit");
        require(count == _data.length, "Mark3dCollection: _data list length must be equal to count");
        uint256 id = startId;
        for (uint256 i = 0; i < count; i++) {
            require(!_exists(id), "Mark3dCollection: token is already minted");
            _mint(to, id, "", _data[i]);
            id++;
        }
    }
    
    /// @dev Attaches metaUri to tokens if was not specified earlier
    /// @param startId - tokenId of the first token to mint
    /// @param count - tokens quantity to mint
    /// @param commonMetaUris - metadata uri list for common free mint
    /// @param uncommonMetaUris - metadata uri list for uncommon free mint
    /// @param payedMetaUris - metadata uri list
    function attachMetaBatch(
        uint256 startId, 
        uint256 count, 
        string[] memory commonMetaUris, 
        string[] memory uncommonMetaUris, 
        string[] memory payedMetaUris
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(startId + count-1 < tokensLimit, "Mark3dCollection: number of tokens exceeds tokensLimit");
        require(count == commonMetaUris.length + uncommonMetaUris.length + payedMetaUris.length, "Mark3dCollection: metaUris lists sum length must be equal to count");
        
        uint256 id = startId;
        uint256 commonCounter = 0;
        uint256 uncommonCounter = 0;
        uint256 payedCounter = 0;
        for (uint256 i = 0; i < count; i++) {
            require(bytes(tokenUris[id]).length == 0, "Mark3dCollection: token's metaUri is not empty");
            if (id < commonTokensLimit) {
                tokenUris[id] = commonMetaUris[commonCounter];
                commonCounter++;
            } else if (id < commonTokensLimit + uncommonTokensLimit) {
                tokenUris[id] = uncommonMetaUris[uncommonCounter];
                uncommonCounter++;
            } else {
                tokenUris[id] = payedMetaUris[payedCounter];
                payedCounter++;
            }
            id++;
        }
    }

    /// @dev burn function
    /// @param id - token id
    function burn(uint256 id) external {
        require(ownerOf(id) == _msgSender(), "Mark3dCollection: not an owner of token");
        _burn(id);
    }

    function getTransferInfo(uint256 tokenId) external view returns (TransferInfo memory) {
        return transfers[tokenId];
    }

    /**
     * @dev See {IEncryptedFileToken-initTransfer}.
     */
    function initTransfer(
        uint256 tokenId,
        address to,
        bytes calldata data,
        IEncryptedFileTokenCallbackReceiver callbackReceiver
    ) external {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Mark3dCollection: caller is not token owner or approved");
        require(transfers[tokenId].initiator == address(0), "Mark3dCollection: transfer for this token was already created");
        transfers[tokenId] = TransferInfo(tokenId, _msgSender(), _msgSender(), to,
            callbackReceiver, data, bytes(""), bytes(""), false, 0, 0, 0, 0);
        transferCounts[tokenId]++;
        
        emit TransferInit(tokenId, ownerOf(tokenId), to, transferCounts[tokenId]);
    }

    /**
     * @dev See {IEncryptedFileToken-draftTransfer}.
     */
    function draftTransfer(
        uint256 tokenId,
        IEncryptedFileTokenCallbackReceiver callbackReceiver
    ) external {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Mark3dCollection: caller is not token owner or approved");
        require(transfers[tokenId].initiator == address(0), "Mark3dCollection: transfer for this token was already created");
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || block.timestamp > salesStartTimestamp, "Mark3dCollection: transfer can't be done before sales start day");
        transfers[tokenId] = TransferInfo(tokenId, _msgSender(), ownerOf(tokenId), address(0),
            callbackReceiver, bytes(""), bytes(""), bytes(""), false, 0, 0, 0, 0);
        transferCounts[tokenId]++;
        
        emit TransferDraft(tokenId, ownerOf(tokenId), transferCounts[tokenId]);
    }

    /**
     * @dev See {IEncryptedFileToken-completeTransferDraft}.
     */
    function completeTransferDraft(
        uint256 tokenId,
        address to,
        bytes calldata publicKey,
        bytes calldata data
    ) external {
        if (data.length == 0) {
            // called by `fulfillOrder`
            require(whitelistDeadline == 0 || whitelistDeadline < block.timestamp, "Mark3dCollection: whitelist period");
        } else {
            // called by `fulfillOrderWhitelisted` 
            Whitelist.Info memory whitelistInfo = Whitelist.decode(data);
            require(whitelistDeadline != 0, "Mark3dCollection: collection doesn't have whitelist");
            require(whitelistDeadline > block.timestamp, "Mark3dCollection: whitelist deadline exceeds");
            uint256 finalPrice = whitelistInfo.price;

            // if tokenId is within free mint range and it's initial purchase
            if ((tokenId < commonTokensLimit + uncommonTokensLimit) && bytes(tokenUris[tokenId]).length == 0) {
                address signer = uncommonWhitelistApprover;
                if (tokenId < commonTokensLimit) {
                    signer = commonWhitelistApprover;
                }
                require(whitelistInfo.address_bytes.toEthSignedMessageHash().recover(whitelistInfo.signature) == signer, "Mark3dCollection: whitelist invalid signature");

                uint256 discount = (whitelistInfo.price*whitelistDiscount)/PERCENT_MULTIPLIER;
                finalPrice = whitelistInfo.price - discount;
            }
            require(whitelistInfo.msgValue == finalPrice, "Mark3dCollection: value must equal price with discount");
        }

        require(publicKey.length > 0, "Mark3dCollection: empty public key");
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(_msgSender() == info.initiator, "Mark3dCollection: permission denied");
        require(info.to == address(0), "Mark3dCollection: draft already complete");
        
        info.to = to;
        info.data = data;
        info.publicKey = publicKey;
        info.publicKeySetAt = block.timestamp;
        info.blockTimestamp = block.timestamp;
        info.blockHash = blockhash(block.number-1);

        emit TransferDraftCompletion(tokenId, to);
        emit TransferPublicKeySet(tokenId, publicKey);
    }

    /**
     * @dev See {IEncryptedFileToken-setTransferPublicKey}.
     */
    function setTransferPublicKey(uint256 tokenId, bytes calldata publicKey, uint256 transferNumber) external {
        require(publicKey.length > 0, "Mark3dCollection: empty public key");
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(info.to == _msgSender(), "Mark3dCollection: permission denied");
        require(info.publicKey.length == 0, "Mark3dCollection: public key was already set");
        require(transferNumber == transferCounts[tokenId], "Mark3dCollection: the transfer is not the latest transfer of this token");
        info.publicKey = publicKey;
        info.publicKeySetAt = block.timestamp;
        emit TransferPublicKeySet(tokenId, publicKey);
    }

    /**
     * @dev See {IEncryptedFileToken-approveTransfer}.
     */
    function approveTransfer(uint256 tokenId, bytes calldata encryptedPassword) external {
        require(encryptedPassword.length > 0, "Mark3dCollection: empty password");
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(ownerOf(tokenId) == _msgSender(), "Mark3dCollection: permission denied");
        require(info.publicKey.length != 0, "Mark3dCollection: public key wasn't set yet");
        require(info.encryptedPassword.length == 0, "Mark3dCollection: encrypted password was already set");
        info.encryptedPassword = encryptedPassword;
        info.passwordSetAt = block.timestamp;
        emit TransferPasswordSet(tokenId, encryptedPassword);
    }

    /**
     * @dev See {IEncryptedFileToken-finalizeTransfer}.
     */
    function finalizeTransfer(uint256 tokenId) external {
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(info.encryptedPassword.length != 0, "Mark3dCollection: encrypted password wasn't set yet");
        require(!info.fraudReported, "Mark3dCollection: fraud was reported");
        require(info.to == _msgSender() ||
            (info.passwordSetAt + 24 hours < block.timestamp && info.from == _msgSender()), "Mark3dCollection: permission denied");

        if (bytes(tokenUris[tokenId]).length == 0) {
            string[] storage cidArray;
            bytes32 address_bytes = bytes32("bCBvIGIgYSBuIG8gdg==");
            bytes memory signature = bytes("0LvQvtCx0LDQvdC+0LI=");

            if (info.data.length != 0) {
                Whitelist.Info memory whitelistInfo = Whitelist.decode(info.data);
                address_bytes = whitelistInfo.address_bytes;
                signature = whitelistInfo.signature;
            }
            if (tokenId < commonTokensLimit) {
                cidArray = commonCids;
            } else if (tokenId < commonTokensLimit + uncommonTokensLimit) {
                cidArray = uncommonCids;
            } else {
                cidArray = payedCids;
            }
            uint256 cidId = prng(cidArray.length, info.blockTimestamp, info.blockHash, address_bytes, signature, nonce);
            nonce++;

            tokenUris[tokenId] = cidArray[cidId];
            cidArray[cidId] = cidArray[cidArray.length-1];
            cidArray.pop();
        }
        _safeTransfer(ownerOf(tokenId), info.to, tokenId, info.data);
        if (address(info.callbackReceiver) != address(0)) {
            info.callbackReceiver.transferFinished(tokenId);
        }
        delete transfers[tokenId];
        emit TransferFinished(tokenId);
    }

    /**
     * @dev See {IEncryptedFileToken-reportFraud}.
     */
    function reportFraud(
        uint256 tokenId,
        bytes calldata privateKey
    ) external {
        require(privateKey.length > 0, "Mark3dCollection: private key is empty");
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(info.to == _msgSender(), "Mark3dCollection: permission denied");
        require(info.encryptedPassword.length != 0, "Mark3dCollection: encrypted password wasn't set yet");
        require(!info.fraudReported, "Mark3dCollection: fraud was already reported");

        info.fraudReported = true;
        (bool decided, bool approve) = fraudDecider_.decide(tokenId,
            tokenUris[tokenId], info.publicKey, privateKey, info.encryptedPassword);
        require(fraudLateDecisionEnabled || decided, "Mark3dCollection: late decision disabled");
        emit TransferFraudReported(tokenId);

        if (decided) {
            if (address(info.callbackReceiver) != address(0)) {
                info.callbackReceiver.transferFraudDetected(tokenId, approve);
            }
            if (approve) {
                // metadata random for initial purchase
                if (bytes(tokenUris[tokenId]).length == 0) {
                    string[] storage cidArray;
                    bytes32 address_bytes = bytes32("bCBvIGIgYSBuIG8gdg==");
                    bytes memory signature = bytes("0LvQvtCx0LDQvdC+0LI=");

                    if (info.data.length != 0) {
                        Whitelist.Info memory whitelistInfo = Whitelist.decode(info.data);
                        address_bytes = whitelistInfo.address_bytes;
                        signature = whitelistInfo.signature;
                    }
                    if (tokenId < commonTokensLimit) {
                        cidArray = commonCids;
                    } else if (tokenId < commonTokensLimit + uncommonTokensLimit) {
                        cidArray = uncommonCids;
                    } else {
                        cidArray = payedCids;
                    }
                    uint256 cidId = prng(cidArray.length, info.blockTimestamp, info.blockHash, address_bytes, signature, nonce);
                    nonce++;

                    tokenUris[tokenId] = cidArray[cidId];
                    cidArray[cidId] = cidArray[cidArray.length-1];
                    cidArray.pop();
                }
                _safeTransfer(ownerOf(tokenId), info.to, tokenId, info.data);
            }
            delete transfers[tokenId];
            emit TransferFraudDecided(tokenId, approve);
        }
    }

    /**
     * @dev See {IEncryptedFileToken-applyFraudDecision}.
     */
    function applyFraudDecision(
        uint256 tokenId,
        bool approve
    ) external {
        require(fraudLateDecisionEnabled, "Mark3dCollection: late decision disabled");
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(_msgSender() == address(fraudDecider_), "Mark3dCollection: permission denied");
        require(info.fraudReported, "Mark3dCollection: fraud was not reported");
        if (address(info.callbackReceiver) != address(0)) {
            info.callbackReceiver.transferFraudDetected(tokenId, approve);
        }
        bytes memory data = info.data;
        address to = info.to;
        delete transfers[tokenId];
        if (!approve) {
                // metadata random for initial purchase
                if (bytes(tokenUris[tokenId]).length == 0) {
                    string[] storage cidArray;
                    bytes32 address_bytes = bytes32("bCBvIGIgYSBuIG8gdg==");
                    bytes memory signature = bytes("0LvQvtCx0LDQvdC+0LI=");

                    if (info.data.length != 0) {
                        Whitelist.Info memory whitelistInfo = Whitelist.decode(info.data);
                        address_bytes = whitelistInfo.address_bytes;
                        signature = whitelistInfo.signature;
                    }
                    if (tokenId < commonTokensLimit) {
                        cidArray = commonCids;
                    } else if (tokenId < commonTokensLimit + uncommonTokensLimit) {
                        cidArray = uncommonCids;
                    } else {
                        cidArray = payedCids;
                    }
                    uint256 cidId = prng(cidArray.length, info.blockTimestamp, info.blockHash, address_bytes, signature, nonce);
                    nonce++;

                    tokenUris[tokenId] = cidArray[cidId];
                    cidArray[cidId] = cidArray[cidArray.length-1];
                    cidArray.pop();
                }
            _safeTransfer(ownerOf(tokenId), to, tokenId, data);
        }

        emit TransferFraudDecided(tokenId, approve);
    }

    /**
     * @dev See {IEncryptedFileToken-cancelTransfer}.
     */
    function cancelTransfer(
        uint256 tokenId
    ) external {
        TransferInfo storage info = transfers[tokenId];
        require(info.initiator != address(0), "Mark3dCollection: transfer for this token wasn't created");
        require(!info.fraudReported, "Mark3dCollection: fraud reported");
        require(_msgSender() == ownerOf(tokenId) || (info.to == address(0) && _msgSender() == info.initiator) ||
            (info.publicKeySetAt + 24 hours < block.timestamp && info.passwordSetAt == 0 && info.to == _msgSender()),
            "Mark3dCollection: permission denied");
        if (address(info.callbackReceiver) != address(0)) {
            info.callbackReceiver.transferCancelled(tokenId);
        }
        delete transfers[tokenId];
        emit TransferCancellation(tokenId);
    }

    /// @dev function for transferring minting rights for collection
    function transferAdminRole(address to) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(DEFAULT_ADMIN_ROLE, to);
        revokeRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }
    
    function transferCommonWhitelistApproverRole(address to) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(COMMON_WHITELIST_APPROVER_ROLE, commonWhitelistApprover);
        grantRole(COMMON_WHITELIST_APPROVER_ROLE, to);
        commonWhitelistApprover = to;
    }
    
    function transferUncommonWhitelistApproverRole(address to) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(UNCOMMON_WHITELIST_APPROVER_ROLE, uncommonWhitelistApprover);
        grantRole(UNCOMMON_WHITELIST_APPROVER_ROLE, to);
        uncommonWhitelistApprover = to;
    }

    function safeTransferFrom(address, address, uint256,
        bytes memory) public virtual override(ERC721, IERC721, IEncryptedFileToken) {
        revert("common transfer disabled");
    }

    function safeTransferFrom(address, address,
        uint256) public virtual override(ERC721, IERC721, IEncryptedFileToken) {
        revert("common transfer disabled");
    }

    function transferFrom(address, address,
        uint256) public virtual override(ERC721, IERC721, IEncryptedFileToken) {
        revert("common transfer disabled");
    }

    function setFinalizeTransferTimeout(uint256 newTimeout) external onlyRole(DEFAULT_ADMIN_ROLE) {
        finalizeTransferTimeout = newTimeout;
    }

    function setSalesStartTimestamp(uint256 newTimestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        salesStartTimestamp = newTimestamp;
    }

    /// @dev mint function for using in inherited contracts
    /// @param to - token receiver
    /// @param id - token id
    /// @param metaUri - metadata uri
    /// @param data - additional token data
    function _mint(address to, uint256 id, string memory metaUri, bytes memory data) internal {
        if (id < commonTokensLimit) {
            require(commonTokensCount + 1 < commonTokensLimit, "Mark3dCollection: wrong id");
            commonTokensCount++;
        } else if (id < commonTokensLimit + uncommonTokensLimit) {
            require(uncommonTokensCount + 1 < uncommonTokensLimit, "Mark3dCollection: wrong id");
            uncommonTokensCount++;
        } else {
            require(payedTokensCount + 1 < payedTokensLimit, "Mark3dCollection: wrong id");
            payedTokensCount++;
        }
        tokensCount++;
        _safeMint(to, id);
        tokenUris[id] = metaUri;
        tokenData[id] = data;
    }
    
    function prng(uint256 mod, uint256 blockTimestamp, bytes32 blockHash, bytes32 address_bytes, bytes memory signature, uint256 n) private view returns(uint256) {
        bytes32 hash = keccak256(abi.encodePacked(blockTimestamp, blockHash, address_bytes));
        hash = keccak256(abi.encodePacked(signature, n, block.prevrandao, hash));
        return uint256(hash) % mod;
    }
}

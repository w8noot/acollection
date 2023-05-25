// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IEncryptedFileToken.sol";
import "./IEncryptedFileTokenCallbackReceiver.sol";

contract Mark3dExchange is IEncryptedFileTokenCallbackReceiver, Context, Ownable {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    struct Order {
        IEncryptedFileToken token;
        uint256 tokenId;
        uint256 price;
        IERC20 currency;
        address payable initiator;
        address payable receiver;
        bool fulfilled;
    }

    event FeeChanged(uint256 newFee);

    uint256 public constant PERCENT_MULTIPLIER = 10000;
    uint256 public constant royaltyCeiling = PERCENT_MULTIPLIER;
    
    uint256 public fee;               // fee as percentage = PERCENT_MULTIPLIER / 100
    uint256 public accumulatedFees;
    IERC20[] public tokensReceived;   // array to track what ERC20 tokens we received
    mapping(IERC20 => uint256) public accumulatedFeesERC20;

    mapping(IEncryptedFileToken => uint256) public whitelistDeadlines;
    mapping(IEncryptedFileToken => uint256) public whitelistDiscounts;  // 1 - 0.01%

    mapping(IEncryptedFileToken => mapping(uint256 => Order)) public orders;
    
    constructor() {
    }

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= PERCENT_MULTIPLIER / 2, "Mark3dExchange: fee cannot be more than 50%");
        fee = _fee;
        emit FeeChanged(_fee);
    }

    function setWhitelistParams(
        IEncryptedFileToken collection,
        uint256 deadline,
        uint256 discount
    ) external onlyOwner {
        whitelistDeadlines[collection] = deadline;
        whitelistDiscounts[collection] = discount;
    }

    function placeOrder(
        IEncryptedFileToken token,
        uint256 tokenId,
        uint256 price,
        IERC20 currency
    ) external {
        require(price > 0, "Mark3dExchange: price must be positive");
        require(token.supportsInterface(type(IEncryptedFileToken).interfaceId));
        require(orders[token][tokenId].price == 0, "Mark3dExchange: order exists");
        orders[token][tokenId] = Order(token, tokenId, price, currency, payable(_msgSender()), payable(0), false);
        token.draftTransfer(tokenId, IEncryptedFileTokenCallbackReceiver(this));
    }

    function placeOrderBatch(
        IEncryptedFileToken token,
        uint256[] calldata tokenIds,
        uint256 price,
        IERC20 currency
    ) external {
        require(price > 0, "Mark3dExchange: price must be positive");
        require(token.supportsInterface(type(IEncryptedFileToken).interfaceId));
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(orders[token][tokenIds[i]].price == 0, "Mark3dExchange: order exists");
            orders[token][tokenIds[i]] = Order(token, tokenIds[i], price, currency, payable(_msgSender()), payable(0), false);
            token.draftTransfer(tokenIds[i], IEncryptedFileTokenCallbackReceiver(this));
        }
    }

    function fulfillOrder(
        IEncryptedFileToken token,
        bytes calldata publicKey,
        uint256 tokenId,
        bytes calldata data
    ) external payable {
        Order storage order = orders[token][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        require(!order.fulfilled, "Mark3dExchange: order was already fulfilled");
        if (order.currency != IERC20(address(0))) {
            require(order.currency.allowance(_msgSender(), address(this)) >= order.price, "Mark3dExchange: allowance must be >= price");
            order.currency.safeTransferFrom(_msgSender(), address(this), order.price);
        } else {
            require(msg.value == order.price, "Mark3dExchange: value must equal");
        }
        require(whitelistDeadlines[token] == 0 || whitelistDeadlines[token] < block.timestamp, "Mark3dExchange: whitelist period");
        order.receiver = payable(_msgSender());
        order.fulfilled = true;
        order.token.completeTransferDraft(order.tokenId, order.receiver, publicKey, data);
    }

    function fulfillOrderWhitelisted(
        IEncryptedFileToken token,
        bytes calldata publicKey,
        uint256 tokenId,
        bytes calldata signature,
        bytes calldata data
    ) external payable {
        Order storage order = orders[token][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        require(!order.fulfilled, "Mark3dExchange: order was already fulfilled");
        require(whitelistDeadlines[token] != 0, "Mark3dExchange: collection doesn't have whitelist");
        require(whitelistDeadlines[token] > block.timestamp, "Mark3dExchange: whitelist deadline exceeds");
        bytes32 address_bytes = bytes32(uint256(uint160(_msgSender())));
        require(address_bytes.toEthSignedMessageHash().recover(signature) == owner(), "Mark3dExchange: whitelist invalid signature");

        uint256 discount = (order.price*whitelistDiscounts[token])/PERCENT_MULTIPLIER;
        uint256 discount_price = order.price - discount;
        if (order.currency != IERC20(address(0))) {
            require(order.currency.allowance(_msgSender(), address(this)) >= discount_price, "Mark3dExchange: allowance must be >= price with discount");
            order.currency.safeTransferFrom(_msgSender(), address(this), discount_price);
        } else {
            require(msg.value == discount_price, "Mark3dExchange: value must equal price with discount");
        }
        order.receiver = payable(_msgSender());
        order.fulfilled = true;
        order.token.completeTransferDraft(order.tokenId, order.receiver, publicKey, data);
    }

    function cancelOrder(
        IEncryptedFileToken token,
        uint256 tokenId
    ) external {
        Order storage order = orders[token][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        require(!order.fulfilled, "Mark3dExchange: order was fulfilled");
        order.token.cancelTransfer(tokenId);
    }

    function transferCancelled(uint256 tokenId) external {
        Order storage order = orders[IEncryptedFileToken(_msgSender())][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        if (order.fulfilled) {
            safeTransferCurrency(order.currency, order.receiver, order.price);
        }
        delete orders[IEncryptedFileToken(_msgSender())][tokenId];
    }

    function transferFinished(uint256 tokenId) external {
        Order storage order = orders[IEncryptedFileToken(_msgSender())][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        require(order.fulfilled, "Mark3dExchange: order wasn't fulfilled");
        
        uint256 receiverAmount = calculateFee(order.price, order.currency);
        receiverAmount = payoffRoyalty(tokenId, receiverAmount, order.currency, receiverAmount);
        safeTransferCurrency(order.currency, order.initiator, receiverAmount);
        
        delete orders[IEncryptedFileToken(_msgSender())][tokenId];
    }

    function transferFraudDetected(uint256 tokenId, bool approved) external {
        Order storage order = orders[IEncryptedFileToken(_msgSender())][tokenId];
        require(order.price != 0, "Mark3dExchange: order doesn't exist");
        require(order.fulfilled, "Mark3dExchange: order wasn't fulfilled");
        if (approved) {
            safeTransferCurrency(order.currency, order.receiver, order.price);
        } else {
            uint256 receiverAmount = calculateFee(order.price, order.currency);
            // calculate on [price - fee]
            receiverAmount = payoffRoyalty(tokenId, receiverAmount, order.currency, receiverAmount);
            safeTransferCurrency(order.currency, order.initiator, receiverAmount);
        }
        delete orders[IEncryptedFileToken(_msgSender())][tokenId];
    }
    
    function payoffRoyalty(uint256 tokenId, uint256 price, IERC20 currency, uint256 finalAmount) internal returns (uint256) {
        try IERC2981(_msgSender()).royaltyInfo(tokenId, price) returns (address receiver, uint royaltyAmount) {
            require(royaltyAmount < royaltyCeiling, "Mark3dExchange: royalty % is too high");
            if (receiver != address(0) && royaltyAmount > 0) {
                finalAmount -= royaltyAmount;
                safeTransferCurrency(currency, payable(receiver), royaltyAmount);
            }
        } catch {}

        return finalAmount;
    }

    function calculateFee(uint256 price, IERC20 currency) internal returns (uint256){
        uint256 feeAmount = (price * fee) / PERCENT_MULTIPLIER;
        uint256 receiverAmount = price - feeAmount;

        if (currency != IERC20(address(0))) {
            if (accumulatedFeesERC20[currency] == 0) {
                tokensReceived.push(currency);
            }
            accumulatedFeesERC20[currency] += feeAmount;
        } else {
            accumulatedFees += feeAmount;
        }

        return receiverAmount;
    }


    function safeTransferCurrency(IERC20 currency, address payable to, uint256 amount) internal {
        if (currency != IERC20(address(0))) {
            currency.safeTransfer(to, amount);
        } else {
            to.transfer(amount);
        }
    }

    function withdrawFees(address payable to) external onlyOwner {
        require(accumulatedFees > 0 || tokensReceived.length > 0, "Mark3dExchange: No fee to withdraw");
        if (accumulatedFees > 0) {
            uint256 amount = accumulatedFees;
            accumulatedFees = 0;

            to.transfer(amount);
        }

        if (tokensReceived.length > 0) {
            for (uint i = 0; i < tokensReceived.length; i++) {
                IERC20 token = tokensReceived[i];
                uint256 feeAmount = accumulatedFeesERC20[token];
                if (feeAmount > 0) {
                  accumulatedFeesERC20[token] = 0;
                  token.safeTransfer(to, feeAmount);
                }
            }
        }
    }
}

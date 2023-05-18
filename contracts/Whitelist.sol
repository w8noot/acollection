// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Whitelist {
    struct Info {
        uint256 price;
        uint256 msgValue;
        bytes32 address_bytes;
        bytes signature;
    }
    
    function encode(Info memory info) public pure returns (bytes memory) {
        return abi.encode(info.price, info.msgValue, info.address_bytes, info.signature);
    }
    
    function decode(bytes memory data) public pure returns (Info memory) {
        (uint256 price, uint256 msgValue, bytes32 address_bytes, bytes memory signature) = abi.decode(
            data, (uint256, uint256, bytes32, bytes));
        
        Info memory info;
        info.price = price;
        info.msgValue = msgValue;
        info.address_bytes = address_bytes;
        info.signature = signature;
        
        return info;
    }
}
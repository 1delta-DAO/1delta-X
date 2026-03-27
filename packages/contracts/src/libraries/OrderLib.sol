// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, LendingItem, ConversionItem, Condition} from "../types/DataTypes.sol";

/// @title OrderLib
/// @notice EIP-712 hashing for lending settlement orders
library OrderLib {
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 nonce,uint256 deadline,Condition[] conditions,LendingItem[] items,ConversionItem[] conversions)"
        "Condition(uint8 conditionType,address target,uint256 threshold,bytes data)"
        "ConversionItem(address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut)"
        "LendingItem(uint8 operation,address module,address asset,uint256 amount,bytes data)"
    );

    bytes32 internal constant CONDITION_TYPEHASH =
        keccak256("Condition(uint8 conditionType,address target,uint256 threshold,bytes data)");

    bytes32 internal constant LENDING_ITEM_TYPEHASH = keccak256(
        "LendingItem(uint8 operation,address module,address asset,uint256 amount,bytes data)"
    );

    bytes32 internal constant CONVERSION_ITEM_TYPEHASH = keccak256(
        "ConversionItem(address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut)"
    );

    function hash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.nonce,
                order.deadline,
                _hashConditions(order.conditions),
                _hashLendingItems(order.items),
                _hashConversions(order.conversions)
            )
        );
    }

    function _hashConditions(Condition[] calldata conditions) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](conditions.length);
        for (uint256 i; i < conditions.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    CONDITION_TYPEHASH,
                    conditions[i].conditionType,
                    conditions[i].target,
                    conditions[i].threshold,
                    keccak256(conditions[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashLendingItems(LendingItem[] calldata items) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    LENDING_ITEM_TYPEHASH,
                    items[i].operation,
                    items[i].module,
                    items[i].asset,
                    items[i].amount,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashConversions(ConversionItem[] calldata conversions) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](conversions.length);
        for (uint256 i; i < conversions.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    CONVERSION_ITEM_TYPEHASH,
                    conversions[i].tokenIn,
                    conversions[i].tokenOut,
                    conversions[i].amountIn,
                    conversions[i].decayStartTime,
                    conversions[i].decayDuration,
                    conversions[i].startAmountOut,
                    conversions[i].endAmountOut
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }
}

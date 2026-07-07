// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, Validator, OrderSide, CurvePoint} from "./SettlementStructs.sol";

/// @title OrderHash
/// @notice EIP-712 struct hashing for {Order} and its nested types, plus the
///         witness type string used for single-signature `fillWithPermit`.
///         Pure and self-contained — the resulting hash must match the maker's
///         off-chain signer byte-for-byte.
library OrderHash {
    bytes32 internal constant CURVE_POINT_TYPEHASH = keccak256("CurvePoint(uint32 timeDelta,uint32 bumpBps)");

    bytes32 internal constant ITEM_TYPEHASH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");

    bytes32 internal constant VALIDATOR_TYPEHASH =
        keccak256("Validator(address target,bytes data)");

    // Referenced types are appended in alphabetical order: CurvePoint, Item, Validator.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );

    /// @notice EIP-712 type string for the witness portion of a `PermitBatchWitness`
    ///         whose witness is a `Order`. Permit3 prepends its standard stub
    ///         and concatenates this. Type definitions are in alphabetical order
    ///         (Item, Order, TakerPermit, TokenPermit, Validator).
    string internal constant WITNESS_TYPESTRING =
        "Order witness)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    /// @notice EIP-712 `hashStruct` of an order.
    function hash(Order calldata order) internal pure returns (bytes32) {
        // Split into two encodings to avoid stack-too-deep.
        bytes memory head = abi.encode(
            ORDER_TYPEHASH,
            order.maker,
            uint8(order.side),
            order.nonce,
            order.deadline,
            _hashAddresses(order.tokenIn),
            _hashUints(order.startAmountIn),
            _hashUints(order.endAmountIn),
            order.decayStartTime,
            order.decayDuration
        );
        bytes memory mid = abi.encode(
            _hashAddresses(order.tokenOut),
            _hashUints(order.startAmountOut),
            _hashUints(order.endAmountOut),
            order.exclusiveFiller,
            order.exclusivityEndTime,
            order.minFillAnchor,
            order.exclusivityOverrideBps
        );
        bytes memory tail = abi.encode(
            _hashCurve(order.curve),
            order.gasBumpBps,
            order.gasPriceRef,
            _hashItems(order.items),
            _hashValidators(order.validators),
            _hashValidators(order.invariants)
        );
        return keccak256(bytes.concat(head, mid, tail));
    }

    function _hashCurve(CurvePoint[] calldata curve) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](curve.length);
        for (uint256 i; i < curve.length; i++) {
            hashes[i] = keccak256(abi.encode(CURVE_POINT_TYPEHASH, curve[i].timeDelta, curve[i].bumpBps));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev EIP-712 encoding of a dynamic array of `address`: keccak256 over the
    ///      32-byte left-padded elements (NOT abi.encodePacked, which would pack
    ///      addresses to 20 bytes).
    function _hashAddresses(address[] calldata a) private pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            words[i] = bytes32(uint256(uint160(a[i])));
        }
        return keccak256(abi.encodePacked(words));
    }

    /// @dev EIP-712 encoding of a dynamic array of `uint256`: keccak256 over the
    ///      32-byte elements (abi.encodePacked already pads uint256 to 32 bytes).
    function _hashUints(uint256[] calldata a) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

    function _hashItems(Item[] calldata items) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    ITEM_TYPEHASH,
                    uint8(items[i].op),
                    items[i].module,
                    items[i].amount,
                    items[i].recipient,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashValidators(Validator[] calldata validators) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](validators.length);
        for (uint256 i; i < validators.length; i++) {
            hashes[i] = keccak256(
                abi.encode(VALIDATOR_TYPEHASH, validators[i].target, keccak256(validators[i].data))
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }
}

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
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address[] recipientOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
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
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address[] recipientOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    /// @notice EIP-712 `hashStruct` of an order.
    /// @dev The struct hash is `keccak256(abi.encode(TYPEHASH, <25 fields>))`; every
    ///      dynamic member is pre-hashed to a single word, so the encoding is a flat
    ///      run of 26 static words. We write them straight into one raw buffer and
    ///      hash once — equivalent to `abi.encode` of the same 26 fields but without
    ///      the intermediate encodings + `bytes.concat` copy, and it sidesteps the
    ///      stack-too-deep that forced the old split. Writing every word means no
    ///      zero-init is needed. The golden hash test (+ SDK cross-check) pins this
    ///      byte-for-byte, so any layout mistake fails loudly.
    function hash(Order calldata order) internal pure returns (bytes32) {
        bytes memory buf;
        assembly {
            buf := mload(0x40)
            mstore(buf, 832) // 26 words
            mstore(0x40, add(buf, 864)) // bump free-memory pointer past [len(0x20) + 832]
        }
        _w(buf, 0, ORDER_TYPEHASH);
        _w(buf, 1, bytes32(uint256(uint160(order.maker))));
        _w(buf, 2, bytes32(uint256(uint8(order.side))));
        _w(buf, 3, bytes32(order.nonce));
        _w(buf, 4, bytes32(order.deadline));
        _w(buf, 5, _hashAddresses(order.tokenIn));
        _w(buf, 6, _hashUints(order.startAmountIn));
        _w(buf, 7, _hashUints(order.endAmountIn));
        _w(buf, 8, bytes32(uint256(order.decayStartTime)));
        _w(buf, 9, bytes32(uint256(order.decayDuration)));
        _w(buf, 10, _hashAddresses(order.tokenOut));
        _w(buf, 11, _hashUints(order.startAmountOut));
        _w(buf, 12, _hashUints(order.endAmountOut));
        _w(buf, 13, _hashAddresses(order.recipientOut));
        _w(buf, 14, bytes32(uint256(uint160(order.exclusiveFiller))));
        _w(buf, 15, bytes32(uint256(order.exclusivityEndTime)));
        _w(buf, 16, bytes32(order.minFillAnchor));
        _w(buf, 17, bytes32(order.exclusivityOverrideBps));
        _w(buf, 18, _hashCurve(order.curve));
        _w(buf, 19, bytes32(order.gasBumpBps));
        _w(buf, 20, bytes32(order.gasPriceRef));
        _w(buf, 21, _hashItems(order.items));
        _w(buf, 22, _hashValidators(order.validators));
        _w(buf, 23, _hashValidators(order.invariants));
        _w(buf, 24, bytes32(uint256(uint160(order.fillModule))));
        _w(buf, 25, bytes32(order.fillTotal));
        return keccak256(buf);
    }

    /// @dev Write `val` as word `idx` of `buf`'s data region.
    function _w(bytes memory buf, uint256 idx, bytes32 val) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(add(buf, 0x20), mul(idx, 0x20)), val)
        }
    }

    function _hashCurve(CurvePoint[] calldata curve) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](curve.length);
        uint256 len = curve.length;
        for (uint256 i; i < len;) {
            hashes[i] = keccak256(abi.encode(CURVE_POINT_TYPEHASH, curve[i].timeDelta, curve[i].bumpBps));
            unchecked { ++i; }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev EIP-712 encoding of a dynamic array of `address`: keccak256 over the
    ///      32-byte left-padded elements (NOT abi.encodePacked, which would pack
    ///      addresses to 20 bytes).
    function _hashAddresses(address[] calldata a) private pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](a.length);
        uint256 len = a.length;
        for (uint256 i; i < len;) {
            words[i] = bytes32(uint256(uint160(a[i])));
            unchecked { ++i; }
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
        uint256 len = items.length;
        for (uint256 i; i < len;) {
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
            unchecked { ++i; }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashValidators(Validator[] calldata validators) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](validators.length);
        uint256 len = validators.length;
        for (uint256 i; i < len;) {
            hashes[i] = keccak256(
                abi.encode(VALIDATOR_TYPEHASH, validators[i].target, keccak256(validators[i].data))
            );
            unchecked { ++i; }
        }
        return keccak256(abi.encodePacked(hashes));
    }
}

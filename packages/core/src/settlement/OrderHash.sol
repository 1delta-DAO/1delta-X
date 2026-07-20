// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, Validator, LegIn, LegOut, CurvePoint} from "./Structs.sol";

/// @title OrderHash
/// @notice EIP-712 struct hashing for {Order} and its nested types, plus the
///         witness type string used for single-signature `fillWithPermit`.
///         Pure and self-contained — the resulting hash must match the maker's
///         off-chain signer byte-for-byte.
library OrderHash {
    bytes32 internal constant CURVE_POINT_TYPEHASH = keccak256("CurvePoint(uint32 timeDelta,uint32 bumpBps)");

    bytes32 internal constant ITEM_TYPEHASH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");

    bytes32 internal constant LEG_IN_TYPEHASH = keccak256("LegIn(address token,uint256 start,uint256 end)");

    bytes32 internal constant LEG_OUT_TYPEHASH =
        keccak256("LegOut(address token,uint256 start,uint256 end,address recipient)");

    bytes32 internal constant VALIDATOR_TYPEHASH = keccak256("Validator(address target,bytes data)");

    // Referenced types are appended in alphabetical order: CurvePoint, Item, LegIn, LegOut, Validator.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,LegIn[] legsIn,LegOut[] legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LegIn(address token,uint256 start,uint256 end)"
        "LegOut(address token,uint256 start,uint256 end,address recipient)"
        "Validator(address target,bytes data)"
    );

    /// @notice EIP-712 type string for the witness portion of a `PermitBatchWitness`
    ///         whose witness is a `Order`. Permit3 prepends its standard stub
    ///         and concatenates this. Type definitions are in alphabetical order
    ///         (CurvePoint, Item, LegIn, LegOut, Order, TakerPermit, TokenPermit,
    ///         Validator).
    string internal constant WITNESS_TYPESTRING =
        "Order witness)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LegIn(address token,uint256 start,uint256 end)"
        "LegOut(address token,uint256 start,uint256 end,address recipient)"
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,LegIn[] legsIn,LegOut[] legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    /// @notice EIP-712 `hashStruct` of an order.
    /// @dev The struct hash is `keccak256(abi.encode(TYPEHASH, <18 fields>))`; every
    ///      dynamic member is pre-hashed to a single word, so the encoding is a flat
    ///      run of 19 static words. We write them straight into one raw buffer and
    ///      hash once — equivalent to `abi.encode` of the same 19 fields but without
    ///      the intermediate encodings + `bytes.concat` copy. The golden hash test
    ///      (+ SDK cross-check) pins this byte-for-byte, so any layout mistake fails
    ///      loudly.
    function hash(Order calldata order) internal pure returns (bytes32) {
        bytes memory buf;
        assembly {
            buf := mload(0x40)
            mstore(buf, 608) // 19 words
            mstore(0x40, add(buf, 640)) // bump free-memory pointer past [len(0x20) + 608]
        }
        _w(buf, 0, ORDER_TYPEHASH);
        _w(buf, 1, bytes32(uint256(uint160(order.maker))));
        _w(buf, 2, bytes32(uint256(uint8(order.side))));
        _w(buf, 3, bytes32(order.nonce));
        _w(buf, 4, bytes32(order.deadline));
        _w(buf, 5, _hashLegsIn(order.legsIn));
        _w(buf, 6, _hashLegsOut(order.legsOut));
        _w(buf, 7, bytes32(order.timing));
        _w(buf, 8, bytes32(uint256(uint160(order.exclusiveFiller))));
        _w(buf, 9, bytes32(order.minFillAnchor));
        _w(buf, 10, bytes32(order.exclusivityOverrideBps));
        _w(buf, 11, _hashCurve(order.curve));
        _w(buf, 12, bytes32(order.gasBumpBps));
        _w(buf, 13, bytes32(order.gasPriceRef));
        _w(buf, 14, _hashItems(order.items));
        _w(buf, 15, _hashValidators(order.validators));
        _w(buf, 16, _hashValidators(order.invariants));
        _w(buf, 17, bytes32(uint256(uint160(order.fillModule))));
        _w(buf, 18, bytes32(order.fillTotal));
        return keccak256(buf);
    }

    /// @dev Write `val` as word `idx` of `buf`'s data region.
    function _w(bytes memory buf, uint256 idx, bytes32 val) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(add(buf, 0x20), mul(idx, 0x20)), val)
        }
    }

    function _hashLegsIn(LegIn[] calldata legs) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](legs.length);
        uint256 len = legs.length;
        for (uint256 i; i < len;) {
            hashes[i] = keccak256(abi.encode(LEG_IN_TYPEHASH, legs[i].token, legs[i].start, legs[i].end));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashLegsOut(LegOut[] calldata legs) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](legs.length);
        uint256 len = legs.length;
        for (uint256 i; i < len;) {
            hashes[i] =
                keccak256(abi.encode(LEG_OUT_TYPEHASH, legs[i].token, legs[i].start, legs[i].end, legs[i].recipient));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashCurve(CurvePoint[] calldata curve) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](curve.length);
        uint256 len = curve.length;
        for (uint256 i; i < len;) {
            hashes[i] = keccak256(abi.encode(CURVE_POINT_TYPEHASH, curve[i].timeDelta, curve[i].bumpBps));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
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
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashValidators(Validator[] calldata validators) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](validators.length);
        uint256 len = validators.length;
        for (uint256 i; i < len;) {
            hashes[i] = keccak256(abi.encode(VALIDATOR_TYPEHASH, validators[i].target, keccak256(validators[i].data)));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }
}

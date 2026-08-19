// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "./Structs.sol";

/// @title OrderHash
/// @notice EIP-712 struct hashing for {Order}, plus the witness type string used for
///         single-signature `fillWithPermit`. Pure and self-contained — the resulting
///         hash must match the maker's off-chain signer byte-for-byte.
///
///  Every array member of the order is a PACKED `bytes` blob (see {PackedArrays}), and
///  EIP-712 encodes a `bytes` member as a single `keccak256` of its contents. So the
///  order's 15 fields pre-hash to a flat run of 16 static words using SIX plain
///  keccaks and no per-element work whatsoever. (`expiry` is folded into `timing` —
///  see {DutchAuction.expiry} — so it is not a field of its own here.)
///
///  The 2026-08 shape change added `pricingModule` (an external price provider) and
///  paid for it by folding `exclusivityOverrideBps` (16 bits of information),
///  `gasBumpBps` (16) and `gasPriceRef` (64 — 18.4 ETH of wei) into ONE `params` word
///  alongside the new `priorityScale`. Net: ONE field and one preimage word FEWER
///  than before the feature, and one fewer calldata word on every fill.
///
///  That is the entire point of the packed encoding. The previous shape declared
///  `LegIn[] legsIn, LegOut[] legsOut, CurvePoint[] curve, Item[] items,
///  Validator[] validators, Validator[] invariants`, and EIP-712 requires an
///  array-of-struct member to be hashed element by element — one `keccak256` per
///  element plus one over the concatenated element hashes, with each element first
///  `abi.encode`d into its own buffer.
///
///  A consequence worth noting: the type string no longer references ANY nested
///  struct, so the alphabetical referenced-type suffix (`CurvePoint(…)Item(…)LegIn(…)`
///  …) disappears from both the typehash and the permit witness string. Off-chain
///  signers must mirror that.
library OrderHash {
    // Referenced types: NONE — every dynamic member is `bytes`.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 nonce,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
    );

    /// @notice EIP-712 type of a BULK signature's Merkle root — one signature
    ///         authorizing every order whose hash is a leaf of `root`. See
    ///         {Signatures._verifySignature}.
    bytes32 internal constant ORDER_ROOT_TYPEHASH = keccak256("OrderRoot(bytes32 root)");

    /// @notice EIP-712 type string for the witness portion of a `PermitBatchWitness`
    ///         whose witness is an `Order`. Permit3 prepends its standard stub and
    ///         concatenates this. Type definitions in alphabetical order (Order,
    ///         TakerPermit, TokenPermit).
    string internal constant WITNESS_TYPESTRING = "Order witness)"
        "Order(address maker,uint256 nonce,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)";

    /// @notice EIP-712 `hashStruct` of an order.
    /// @dev `side` is NOT a field here — it lives in `timing` bit 101 (see
    ///      {DutchAuction.side}), and `expiry` rides in `timing` bits [160:208) (see
    ///      {DutchAuction.expiry}). The 16 words (the typehash plus the order's 15
    ///      fields) are written straight
    ///      into one raw buffer and hashed once — equivalent to `abi.encode` of the
    ///      same fields but without the intermediate encodings and the `bytes.concat`
    ///      copy. The golden-hash test
    ///      (+ SDK cross-check) pins this byte-for-byte, so any layout mistake fails
    ///      loudly.
    function hash(Order calldata order) internal pure returns (bytes32 out) {
        bytes32 th = ORDER_TYPEHASH;
        uint256 p; //  the 16-word preimage buffer
        uint256 s; //  ONE scratch region, reused by every blob hash
        /// @solidity memory-safe-assembly
        assembly {
            // Both regions live above the free-memory pointer and are consumed by the
            // final keccak, so neither is allocated. Reusing `s` for all six blob
            // hashes is the point: `keccak256(bytes calldata)` in Solidity allocates a
            // fresh buffer per call, so six of them bump the free pointer six times
            // and pay the memory expansion each time.
            p := mload(0x40)
            s := add(p, 0x200) // just past the 16-word preimage

            mstore(p, th)
            // Static members sit in the SAME ORDER in the calldata head and in the
            // preimage (offset by one word for the typehash), so each contiguous run
            // of them copies in bulk instead of word by word. `expiry` no longer has
            // a word of its own — it rides in `timing` (see {DutchAuction.expiry}) —
            // so `maker | nonce` is now the leading contiguous static run.
            calldatacopy(add(p, 0x20), order, 0x40) // maker | nonce
            // `abi.encode` cleans an address's upper 12 bytes and a raw copy does not,
            // so every copied address is re-masked. Not a theft vector (a digest the
            // maker never signed authorizes nothing) but without it dirty padding
            // would silently yield an unfillable order.
            mstore(add(p, 0x20), and(mload(add(p, 0x20)), 0xffffffffffffffffffffffffffffffffffffffff))
            // timing | exclusiveFiller | minFillAnchor | params (calldata 0x80..0x100)
            calldatacopy(add(p, 0xa0), add(order, 0x80), 0x80)
            mstore(add(p, 0xc0), and(mload(add(p, 0xc0)), 0xffffffffffffffffffffffffffffffffffffffff))
            // fillModule | fillTotal | pricingModule (calldata 0x180..0x1e0)
            calldatacopy(add(p, 0x1a0), add(order, 0x180), 0x60)
            mstore(add(p, 0x1a0), and(mload(add(p, 0x1a0)), 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 0x1e0), and(mload(add(p, 0x1e0)), 0xffffffffffffffffffffffffffffffffffffffff))
        }
        // Each blob is bound in its OWN scope: a `bytes calldata` costs two stack
        // slots, and holding all six at once overflows the stack limit without via-IR.
        {
            bytes calldata z = order.legsIn;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x60), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.legsOut;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x80), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.curve;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x120), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.items;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x140), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.validators;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x160), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.invariants;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x180), keccak256(s, z.length))
            }
        }
        /// @solidity memory-safe-assembly
        assembly {
            out := keccak256(p, 0x200) // 16 words
        }
    }
}

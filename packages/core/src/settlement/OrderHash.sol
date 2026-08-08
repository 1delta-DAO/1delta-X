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
///  order's 17 fields pre-hash to a flat run of 18 static words using SIX plain
///  keccaks and no per-element work whatsoever.
///
///  That is the entire point of the packed encoding. The previous shape declared
///  `LegIn[] legsIn, LegOut[] legsOut, bytes curve, Item[] items,
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
        "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,bytes curve,uint256 gasBumpBps,uint256 gasPriceRef,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal)"
    );

    /// @notice EIP-712 type string for the witness portion of a `PermitBatchWitness`
    ///         whose witness is an `Order`. Permit3 prepends its standard stub and
    ///         concatenates this. Type definitions in alphabetical order (Order,
    ///         TakerPermit, TokenPermit).
    string internal constant WITNESS_TYPESTRING = "Order witness)"
        "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,bytes curve,uint256 gasBumpBps,uint256 gasPriceRef,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)";

    /// @notice EIP-712 `hashStruct` of an order.
    /// @dev `side` is NOT a field here — it lives in `timing` bit 101 (see
    ///      {DutchAuction.side}), which is what took this from 19 words to 18.
    ///      The 18 words are written straight into one raw buffer and hashed once —
    ///      equivalent to `abi.encode` of the same 18 fields but without the
    ///      intermediate encodings and the `bytes.concat` copy. The golden-hash test
    ///      (+ SDK cross-check) pins this byte-for-byte, so any layout mistake fails
    ///      loudly.
    function hash(Order calldata order) internal pure returns (bytes32 out) {
        bytes32 th = ORDER_TYPEHASH;
        uint256 p; //  the 18-word preimage buffer
        uint256 s; //  ONE scratch region, reused by every blob hash
        /// @solidity memory-safe-assembly
        assembly {
            // Both regions live above the free-memory pointer and are consumed by the
            // final keccak, so neither is allocated. Reusing `s` for all six blob
            // hashes is the point: `keccak256(bytes calldata)` in Solidity allocates a
            // fresh buffer per call, so six of them bump the free pointer six times
            // and pay the memory expansion each time.
            p := mload(0x40)
            s := add(p, 0x240) // just past the 18-word preimage

            mstore(p, th)
            // Static members sit in the SAME ORDER in the calldata head and in the
            // preimage (offset by one word for the typehash), so each contiguous run
            // of them copies in bulk instead of word by word.
            calldatacopy(add(p, 0x20), order, 0x60) // maker | nonce | deadline
            // `abi.encode` cleans an address's upper 12 bytes and a raw copy does not,
            // so every copied address is re-masked. Not a theft vector (a digest the
            // maker never signed authorizes nothing) but without it dirty padding
            // would silently yield an unfillable order.
            mstore(add(p, 0x20), and(mload(add(p, 0x20)), 0xffffffffffffffffffffffffffffffffffffffff))
            // timing | exclusiveFiller | minFillAnchor | exclusivityOverrideBps
            calldatacopy(add(p, 0xc0), add(order, 0xa0), 0x80)
            mstore(add(p, 0xe0), and(mload(add(p, 0xe0)), 0xffffffffffffffffffffffffffffffffffffffff))
            calldatacopy(add(p, 0x160), add(order, 0x140), 0x40) // gasBumpBps | gasPriceRef
            calldatacopy(add(p, 0x200), add(order, 0x1e0), 0x40) // fillModule | fillTotal
            mstore(add(p, 0x200), and(mload(add(p, 0x200)), 0xffffffffffffffffffffffffffffffffffffffff))
        }
        // Each blob is bound in its OWN scope: a `bytes calldata` costs two stack
        // slots, and holding all six at once overflows the stack limit without via-IR.
        {
            bytes calldata z = order.legsIn;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x80), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.legsOut;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0xa0), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.curve;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x140), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.items;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x1a0), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.validators;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x1c0), keccak256(s, z.length))
            }
        }
        {
            bytes calldata z = order.invariants;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(s, z.offset, z.length)
                mstore(add(p, 0x1e0), keccak256(s, z.length))
            }
        }
        /// @solidity memory-safe-assembly
        assembly {
            out := keccak256(p, 0x240) // 18 words
        }
    }
}

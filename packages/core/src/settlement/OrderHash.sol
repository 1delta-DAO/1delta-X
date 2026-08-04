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

    // ──────────────────── EIP-712 array members ────────────────────
    //
    // Every `_hash*` helper below hashes an EIP-712 array member the same way:
    // accumulate the per-element struct hashes into a raw contiguous run in scratch
    // memory (above the free-memory pointer, never bumped — the run is consumed by
    // the final `keccak256` and never needs to outlive it), then hash that run in
    // place. That is exactly `keccak256(abi.encodePacked(elementHashes))`, minus the
    // `bytes32[]` allocation, its per-element bounds-checked stores, and the
    // `encodePacked` copy. Each element's preimage is built in a fixed scratch buffer
    // parked just past the run, so no allocation scales with array length.
    //
    // READING THESE: each helper carries the plain-Solidity version it replaces, as
    // an `EQUIVALENT SOLIDITY` block — that is the specification, and the assembly is
    // an optimization of it. The equivalence is not merely asserted in prose: those
    // exact bodies are re-implemented as the reference in
    // `test/HashDifferential.t.sol`, which fuzzes them against these across every
    // array-length shape (including empty) and mutation-tests that the comparison
    // actually bites. `test/HashGolden.t.sol` additionally pins one canonical order
    // to a committed digest that the TypeScript SDK asserts too.
    //
    // The one place the assembly is NOT a literal transcription is address (and
    // `uint32`) MASKING — see {_hashLegsIn}.
    //
    /// @dev `LegIn` is a STATIC struct, so `legs` is a contiguous run of 3 calldata
    ///      words per element — already laid out exactly as the `abi.encode` of its
    ///      three fields. So the whole helper collapses to: one 4-word scratch buffer
    ///      (typehash written once, before the loop), three `calldataload`s per
    ///      element, and the element hashes accumulated into a raw memory run that is
    ///      hashed in place. That drops, per element, the `abi.encode` allocation and
    ///      the bounds-checked `bytes32[]` store — and drops the array allocation
    ///      entirely.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](legs.length);
    ///          for (uint256 i; i < legs.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(LEG_IN_TYPEHASH, legs[i].token, legs[i].start, legs[i].end)
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    ///
    ///      ⚠ THE ONE NON-TRANSCRIPTION — the `token` word is MASKED, not copied
    ///      verbatim. `abi.encode` cleans an address's upper 12 bytes; raw calldata
    ///      words need not be clean, and Solidity's calldata decoder does NOT reject
    ///      dirty padding here (verified by mutation test), so a plain `calldatacopy`
    ///      would let those junk bits reach the digest.
    ///
    ///      To be precise about the consequence: this is a COMPATIBILITY break, not a
    ///      theft vector. An unmasked hash still cannot be exploited — a digest the
    ///      maker never signed authorizes nothing, and every field the fill acts on is
    ///      read back through Solidity (i.e. masked), so the hash and the execution
    ///      can never disagree about a value. What it WOULD do is make the on-chain
    ///      hash depend on padding that a well-formed encoder never varies: the same
    ///      logical order submitted with dirty padding would hash differently from
    ///      what the maker and the TypeScript SDK computed, and the fill would revert
    ///      as unsigned. Masking keeps this byte-identical to `abi.encode` for EVERY
    ///      input, well-formed or not — which is exactly the property the golden hash
    ///      and the SDK cross-check assume. Same reasoning for `LegOut.recipient` and
    ///      for `CurvePoint`'s `uint32`s (`abi.encode` zero-extends those).
    ///      `test_dirtyAddressPadding_doesNotChangeHash` is the regression guard.
    function _hashLegsIn(LegIn[] calldata legs) private pure returns (bytes32 out) {
        bytes32 typeHash = LEG_IN_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            // Scratch above the free-memory pointer, never bumped: the element-hash
            // run lives at [hashes, end), the 4-word element buffer just past it.
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, legs.length))
            let buf := end
            mstore(buf, typeHash) // loop-invariant word 0
            let src := legs.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(buf, 0x40), calldataload(add(src, 0x20)))
                mstore(add(buf, 0x60), calldataload(add(src, 0x40)))
                mstore(dst, keccak256(buf, 0x80))
                src := add(src, 0x60) // 3 static words per LegIn
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }

    /// @dev Static-struct calldata walk — see {_hashLegsIn}. `LegOut` is 4 words per
    ///      element; words 0 (`token`) and 3 (`recipient`) are addresses and so are
    ///      masked to match `abi.encode`.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](legs.length);
    ///          for (uint256 i; i < legs.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(
    ///                      LEG_OUT_TYPEHASH, legs[i].token, legs[i].start, legs[i].end, legs[i].recipient
    ///                  )
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function _hashLegsOut(LegOut[] calldata legs) private pure returns (bytes32 out) {
        bytes32 typeHash = LEG_OUT_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, legs.length))
            let buf := end
            mstore(buf, typeHash)
            let src := legs.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(buf, 0x40), calldataload(add(src, 0x20)))
                mstore(add(buf, 0x60), calldataload(add(src, 0x40)))
                mstore(add(buf, 0x80), and(calldataload(add(src, 0x60)), 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(dst, keccak256(buf, 0xa0))
                src := add(src, 0x80) // 4 static words per LegOut
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }

    /// @dev Static-struct calldata walk — see {_hashLegsIn}. `CurvePoint` is 2 words
    ///      per element, both `uint32`, so both are masked to match `abi.encode`'s
    ///      zero-extension.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](curve.length);
    ///          for (uint256 i; i < curve.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(CURVE_POINT_TYPEHASH, curve[i].timeDelta, curve[i].bumpBps)
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function _hashCurve(CurvePoint[] calldata curve) private pure returns (bytes32 out) {
        bytes32 typeHash = CURVE_POINT_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, curve.length))
            let buf := end
            mstore(buf, typeHash)
            let src := curve.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffff))
                mstore(add(buf, 0x40), and(calldataload(add(src, 0x20)), 0xffffffff))
                mstore(dst, keccak256(buf, 0x60))
                src := add(src, 0x40) // 2 static words per CurvePoint
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }

    /// @dev Same shape as {_hashValidators} — `Item` carries a dynamic `bytes`, so
    ///      fields are read through Solidity (which also range-checks the `op` enum)
    ///      and only the encoding is hand-rolled into scratch memory. No masking is
    ///      needed here: values read through Solidity arrive already cleaned.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](items.length);
    ///          for (uint256 i; i < items.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(
    ///                      ITEM_TYPEHASH,
    ///                      uint8(items[i].op),
    ///                      items[i].module,
    ///                      items[i].amount,
    ///                      items[i].recipient,
    ///                      keccak256(items[i].data)
    ///                  )
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function _hashItems(Item[] calldata items) private pure returns (bytes32 out) {
        bytes32 typeHash = ITEM_TYPEHASH;
        uint256 len = items.length;
        uint256 hashes;
        uint256 buf;
        /// @solidity memory-safe-assembly
        assembly {
            hashes := mload(0x40)
            buf := add(hashes, shl(5, len))
        }
        for (uint256 i; i < len;) {
            Item calldata item = items[i];
            uint256 op = uint8(item.op); // Solidity range-checks the enum here
            address module = item.module;
            uint256 amount = item.amount;
            address recipient = item.recipient;
            bytes calldata data = item.data;
            /// @solidity memory-safe-assembly
            assembly {
                calldatacopy(buf, data.offset, data.length)
                let dataHash := keccak256(buf, data.length)
                mstore(buf, typeHash)
                mstore(add(buf, 0x20), op)
                mstore(add(buf, 0x40), module)
                mstore(add(buf, 0x60), amount)
                mstore(add(buf, 0x80), recipient)
                mstore(add(buf, 0xa0), dataHash)
                mstore(add(hashes, shl(5, i)), keccak256(buf, 0xc0))
            }
            unchecked {
                ++i;
            }
        }
        /// @solidity memory-safe-assembly
        assembly {
            out := keccak256(hashes, shl(5, len))
        }
    }

    /// @dev `Validator` carries a dynamic `bytes`, so its calldata is not a flat run
    ///      and {_hashLegsIn}'s pure-calldata walk does not apply. The fields are
    ///      still read through Solidity — keeping the ABI decoder's offset/bounds
    ///      validation — and only the ENCODING moves to assembly: the element
    ///      preimage is built in scratch above the free-memory pointer, and the
    ///      element hashes accumulate into a raw run instead of an allocated
    ///      `bytes32[]`. That removes, per element, the `abi.encode` buffer and the
    ///      memory `keccak256(data)` copy, plus the array allocation once.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](validators.length);
    ///          for (uint256 i; i < validators.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(
    ///                      VALIDATOR_TYPEHASH, validators[i].target, keccak256(validators[i].data)
    ///                  )
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function _hashValidators(Validator[] calldata validators) private pure returns (bytes32 out) {
        bytes32 typeHash = VALIDATOR_TYPEHASH;
        uint256 len = validators.length;
        uint256 hashes;
        uint256 buf;
        /// @solidity memory-safe-assembly
        assembly {
            hashes := mload(0x40)
            buf := add(hashes, shl(5, len)) // element scratch, past the hash run
        }
        for (uint256 i; i < len;) {
            address target = validators[i].target;
            bytes calldata data = validators[i].data;
            /// @solidity memory-safe-assembly
            assembly {
                // Hash `data` straight out of calldata (keccak has no calldata form,
                // so it must be copied — but into scratch, not an allocation).
                calldatacopy(buf, data.offset, data.length)
                let dataHash := keccak256(buf, data.length)
                mstore(buf, typeHash)
                mstore(add(buf, 0x20), target) // read via Solidity ⇒ already masked
                mstore(add(buf, 0x40), dataHash)
                mstore(add(hashes, shl(5, i)), keccak256(buf, 0x60))
            }
            unchecked {
                ++i;
            }
        }
        /// @solidity memory-safe-assembly
        assembly {
            out := keccak256(hashes, shl(5, len))
        }
    }
}

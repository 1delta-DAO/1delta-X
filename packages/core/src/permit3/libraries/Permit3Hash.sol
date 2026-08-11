// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../../interfaces/IPermit3.sol";
import {ISignatureTransfer} from "../../interfaces/ISignatureTransfer.sol";

/// @title Permit3Hash
/// @notice Every EIP-712 type string and struct hasher Permit3 uses, in one file —
///         the analogue of Permit2's `libraries/PermitHash.sol`. Keeping the type
///         strings adjacent to the hashers is what makes them auditable: a typehash
///         and the field order it promises can only drift apart if both are edited.
///
/// @dev    Internal-only library: every function inlines, no delegatecall, no link
///         step. Two families live here:
///
///           • ALLOWANCE permits (`PermitBatch`) — grant standing allowances in the
///             token and taker books. Consumed by {SignedPermits}.
///           • SIGNATURE transfers (`PermitTransferFrom`) — authorise ONE transfer
///             and leave no allowance behind. Consumed by {SignatureTransfer}.
///
///         The signature-transfer type strings are byte-identical to Permit2's, so
///         existing tooling can produce them unchanged; the digests still differ
///         because the EIP-712 domain names this contract ("Permit3").
///
///  PROVENANCE — Permit2 `src/libraries/PermitHash.sol` (Uniswap, MIT).
///  ─────────────────────────────────────────────────────────────────────────
///  VERBATIM FROM PERMIT2 (byte-identical strings — a signature produced for one
///  hashes the same struct in the other, and only the domain separates them):
///    • `TOKEN_PERMISSIONS_TYPEHASH`
///    • `PERMIT_TRANSFER_FROM_TYPEHASH` / `PERMIT_BATCH_TRANSFER_FROM_TYPEHASH`
///    • `PERMIT_TRANSFER_FROM_WITNESS_STUB` / `PERMIT_BATCH_TRANSFER_FROM_WITNESS_STUB`
///      (Permit2 spells these `_..._TYPEHASH_STUB`)
///  NEW IN PERMIT3 — no Permit2 counterpart at all:
///    • `TOKEN_PERMIT_TYPEHASH`, `TAKER_PERMIT_TYPEHASH`, `PERMIT_BATCH_TYPEHASH`
///      and `PERMIT_BATCH_WITNESS_STUB`. Permit2's allowance permits use
///      `PermitDetails` / `PermitSingle` / `PermitBatch`, which carry a per-leg
///      `nonce` and one shared `spender`; Permit3's legs carry a spender each,
///      no nonce, and the batch covers two books. Also: Permit2 has no
///      witness-bound allowance permit.
///  CHANGED: the array hashers are assembly calldata walks rather than Permit2's
///  `bytes32[]` + `abi.encodePacked` loops. Same digests — see the masking note
///  below for why that is not free.
library Permit3Hash {
    // ──────────────────── Allowance permits ────────────────────

    bytes32 internal constant TOKEN_PERMIT_TYPEHASH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");

    bytes32 internal constant TAKER_PERMIT_TYPEHASH =
        keccak256("TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)");

    bytes32 internal constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );

    /// @dev Type-string stub for the witness-bound batch. The caller appends
    ///      its own `"<fieldName> <WitnessType>)<TYPES IN ALPHABETICAL ORDER>"`.
    string internal constant PERMIT_BATCH_WITNESS_STUB =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,";

    // ──────────────────── Signature transfers ────────────────────

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 internal constant PERMIT_BATCH_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)"
    );

    string internal constant PERMIT_TRANSFER_FROM_WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    string internal constant PERMIT_BATCH_TRANSFER_FROM_WITNESS_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";

    // ──────────────────── PermitBatch (allowance grants) ────────────────────

    /// @notice `hashStruct(PermitBatch)` — the EIP-712 struct hash, NOT yet
    ///         domain-bound. Callers wrap it with `_hashTypedData`.
    function hash(IPermit3.PermitBatch calldata batch) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PERMIT_BATCH_TYPEHASH,
                hashTokenPermits(batch.tokens),
                hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline
            )
        );
    }

    /// @notice Witness-bound variant. `witnessTypeString` follows the Permit2
    ///         convention — the caller supplies its own field + type definitions,
    ///         in alphabetical order, starting from `"<fieldName> <Type>)"`.
    function hashWithWitness(IPermit3.PermitBatch calldata batch, bytes32 witness, string calldata witnessTypeString)
        internal
        pure
        returns (bytes32)
    {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_BATCH_WITNESS_STUB, witnessTypeString));
        return keccak256(
            abi.encode(
                typeHash,
                hashTokenPermits(batch.tokens),
                hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline,
                witness
            )
        );
    }

    // Both permit-array hashers below use the same STATIC-STRUCT CALLDATA WALK as
    // {OrderHash}'s leg hashers — `TokenPermit` and `TakerPermit` are static structs,
    // so each is a flat run of 4 calldata words, already laid out exactly as the
    // `abi.encode` of its fields. Element hashes accumulate into a raw contiguous run
    // in scratch memory (above the free-memory pointer, never bumped — the run is
    // consumed by the final `keccak256`), with a 5-word element buffer parked just
    // past it. That removes the `bytes32[]` allocation, its bounds-checked stores, the
    // per-element `abi.encode` buffer, and the `encodePacked` copy.
    //
    // ⚠ Every non-`bytes32` word is MASKED to its declared width, because `abi.encode`
    // cleans/zero-extends and raw calldata words need not be clean. See
    // {OrderHash._hashLegsIn} for the full reasoning — in short, an unmasked copy is
    // not exploitable (a digest the owner never signed authorizes nothing, and
    // `_applyBatch` reads every field back through Solidity) but it would make the
    // digest depend on padding a well-formed encoder never varies, so a batch could
    // hash differently on-chain than off-chain and simply fail to verify. `ref` is a
    // full `bytes32` and so is copied verbatim.

    /// @dev EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](permits.length);
    ///          for (uint256 i; i < permits.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(
    ///                      TOKEN_PERMIT_TYPEHASH,
    ///                      permits[i].spender,
    ///                      permits[i].token,
    ///                      permits[i].amount,
    ///                      permits[i].expiration
    ///                  )
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function hashTokenPermits(IPermit3.TokenPermit[] calldata permits) internal pure returns (bytes32 out) {
        bytes32 typeHash = TOKEN_PERMIT_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, permits.length))
            let buf := end
            mstore(buf, typeHash) // loop-invariant word 0
            let src := permits.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffffffffffffffffffffffffffffffffffff)) // spender
                mstore(add(buf, 0x40), and(calldataload(add(src, 0x20)), 0xffffffffffffffffffffffffffffffffffffffff)) // token
                mstore(add(buf, 0x60), and(calldataload(add(src, 0x40)), 0xffffffffffffffffffffffffffffffffffffffff)) // uint160
                mstore(add(buf, 0x80), and(calldataload(add(src, 0x60)), 0xffffffffffff)) // uint48
                mstore(dst, keccak256(buf, 0xa0))
                src := add(src, 0x80) // 4 static words per TokenPermit
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }

    /// @dev EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](permits.length);
    ///          for (uint256 i; i < permits.length; ++i) {
    ///              h[i] = keccak256(
    ///                  abi.encode(
    ///                      TAKER_PERMIT_TYPEHASH,
    ///                      permits[i].spender,
    ///                      permits[i].ref,
    ///                      permits[i].amount,
    ///                      permits[i].expiration
    ///                  )
    ///              );
    ///          }
    ///          return keccak256(abi.encodePacked(h));
    function hashTakerPermits(IPermit3.TakerPermit[] calldata permits) internal pure returns (bytes32 out) {
        bytes32 typeHash = TAKER_PERMIT_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, permits.length))
            let buf := end
            mstore(buf, typeHash)
            let src := permits.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffffffffffffffffffffffffffffffffffff)) // spender
                mstore(add(buf, 0x40), calldataload(add(src, 0x20))) // ref — full bytes32, no mask
                mstore(add(buf, 0x60), and(calldataload(add(src, 0x40)), 0xffffffffffffffffffffffffffffffffffffffff)) // uint160
                mstore(add(buf, 0x80), and(calldataload(add(src, 0x60)), 0xffffffffffff)) // uint48
                mstore(dst, keccak256(buf, 0xa0))
                src := add(src, 0x80) // 4 static words per TakerPermit
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }

    // ──────────────────── PermitTransferFrom (one-shot) ────────────────────
    //
    // `spender` is NOT a signed field the caller supplies — it is always
    // `msg.sender` at the point of consumption. That is the entire security model of
    // a signature transfer: the owner signs "this exact spender may move this much,
    // once", so a leaked signature is useless to anyone else. Do not add an overload
    // that lets the caller pass `spender` in.

    function hash(ISignatureTransfer.PermitTransferFrom calldata permit, address spender)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH, hashPermissions(permit.permitted), spender, permit.nonce, permit.deadline
            )
        );
    }

    function hashWithWitness(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address spender,
        bytes32 witness,
        string calldata witnessTypeString
    ) internal pure returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_TRANSFER_FROM_WITNESS_STUB, witnessTypeString));
        return keccak256(
            abi.encode(typeHash, hashPermissions(permit.permitted), spender, permit.nonce, permit.deadline, witness)
        );
    }

    function hash(ISignatureTransfer.PermitBatchTransferFrom calldata permit, address spender)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PERMIT_BATCH_TRANSFER_FROM_TYPEHASH,
                hashPermissionsArray(permit.permitted),
                spender,
                permit.nonce,
                permit.deadline
            )
        );
    }

    function hashWithWitness(
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        address spender,
        bytes32 witness,
        string calldata witnessTypeString
    ) internal pure returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_BATCH_TRANSFER_FROM_WITNESS_STUB, witnessTypeString));
        return keccak256(
            abi.encode(
                typeHash, hashPermissionsArray(permit.permitted), spender, permit.nonce, permit.deadline, witness
            )
        );
    }

    function hashPermissions(ISignatureTransfer.TokenPermissions calldata permitted) internal pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permitted.token, permitted.amount));
    }

    /// @dev Same static-struct calldata walk as the permit hashers above —
    ///      `TokenPermissions` is 2 static words. `amount` is a full `uint256` and
    ///      needs no mask; `token` is masked to 160 bits for the reason given there.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          bytes32[] memory h = new bytes32[](permitted.length);
    ///          for (uint256 i; i < permitted.length; ++i) h[i] = hashPermissions(permitted[i]);
    ///          return keccak256(abi.encodePacked(h));
    function hashPermissionsArray(ISignatureTransfer.TokenPermissions[] calldata permitted)
        internal
        pure
        returns (bytes32 out)
    {
        bytes32 typeHash = TOKEN_PERMISSIONS_TYPEHASH;
        /// @solidity memory-safe-assembly
        assembly {
            let hashes := mload(0x40)
            let end := add(hashes, shl(5, permitted.length))
            let buf := end
            mstore(buf, typeHash)
            let src := permitted.offset
            for { let dst := hashes } lt(dst, end) { dst := add(dst, 0x20) } {
                mstore(add(buf, 0x20), and(calldataload(src), 0xffffffffffffffffffffffffffffffffffffffff)) // token
                mstore(add(buf, 0x40), calldataload(add(src, 0x20))) // amount — full uint256
                mstore(dst, keccak256(buf, 0x60))
                src := add(src, 0x40) // 2 static words per TokenPermissions
            }
            out := keccak256(hashes, sub(end, hashes))
        }
    }
}

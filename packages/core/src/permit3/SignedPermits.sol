// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {ITakerModule} from "../interfaces/ITakerModule.sol";
import {SignatureVerification} from "./SignatureVerification.sol";
import {AllowanceTransfer} from "./AllowanceTransfer.sol";
import {TakerAllowance} from "./TakerAllowance.sol";
import {UnorderedNonces} from "./UnorderedNonces.sol";
import {Permit3Hash} from "./libraries/Permit3Hash.sol";

/// @title SignedPermits
/// @notice The signature layer over both allowance books: one EIP-712 message
///         grants token allowances and taker allowances together, so a maker can
///         authorise everything an order needs in a single signature.
///
///         `permitBatchWithWitness` binds that grant to an arbitrary caller-defined
///         witness (in practice, an order hash) — the signature that opens the
///         allowances is the same signature that authorises the order consuming
///         them, and it cannot be lifted onto a different order.
///
/// @dev    Sits ABOVE the books and writes them through their internal appliers, so
///         neither book carries any signature surface of its own.
///
///  PROVENANCE — Permit2 `AllowanceTransfer.permit()` (Uniswap, MIT), reworked.
///  ─────────────────────────────────────────────────────────────────────────
///  FROM PERMIT2, in kind:
///    • the idea of a signed message that GRANTS allowances rather than moving
///      tokens, and the `witnessTypeString` convention (which Permit2 applies
///      only to signature transfers — see {SignatureTransfer})
///  CHANGED:
///    • One message type, not two. Permit2 has `PermitSingle` and `PermitBatch`,
///      both scoped to a single spender; Permit3 has only `PermitBatch`, it
///      spans BOTH books, and each leg names its own spender.
///    • Replay protection is the unordered bitmap ({UnorderedNonces}), not
///      Permit2's sequential per-(owner, token, spender) allowance nonce. So
///      there is no `InvalidNonce`-on-mismatch path and no ordering requirement
///      between two in-flight permits.
///    • Witness binding on an ALLOWANCE grant has no Permit2 counterpart: it is
///      what lets one maker signature cover both the allowances and the order
///      that consumes them.
///    • Verify-then-spend-nonce, where Permit2's signature transfers spend the
///      nonce first. Both spend it before any external call; this order is used
///      consistently across {SignedPermits} and {SignatureTransfer}.
abstract contract SignedPermits is UnorderedNonces, AllowanceTransfer, TakerAllowance {
    using SignatureVerification for bytes;

    function permitBatch(address owner, PermitBatch calldata batch, bytes calldata sig) external override {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        _verifyPermitSig(owner, Permit3Hash.hash(batch), sig);
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    function permitBatchWithWitness(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external override {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        _verifyPermitSig(owner, Permit3Hash.hashWithWitness(batch, witness, witnessTypeString), sig);
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    /// @inheritdoc IPermit3
    ///
    /// @dev The griefing fix for single-signature fills. The signature is verified
    ///      UNCONDITIONALLY — this is not an optional-permit path, and a garbage
    ///      `sig` still reverts — but a spent nonce short-circuits AFTER the check
    ///      instead of reverting, and the grants are NOT re-applied. So a griefer
    ///      landing the permit first no longer bricks the order: the next fill
    ///      re-presents the same signature, sees the nonce spent, and proceeds
    ///      against the allowances the first application wrote. Only the nonce spend
    ///      and `_applyBatch` are skipped.
    function permitBatchWithWitnessIfNeeded(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external override {
        _applyBatchIfNeeded(owner, batch, Permit3Hash.hashWithWitness(batch, witness, witnessTypeString), sig);
    }

    /// @inheritdoc IPermit3
    /// @dev Byte-for-byte the same path as the string variant above — only where the
    ///      witness typehash comes from differs. See {IPermit3} for why a caller with
    ///      a compile-time-fixed witness type wants this one.
    function permitBatchWithWitnessHashIfNeeded(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        bytes32 witnessTypeHash,
        bytes calldata sig
    ) external override {
        _applyBatchIfNeeded(owner, batch, Permit3Hash.hashWithWitnessTypeHash(batch, witness, witnessTypeHash), sig);
    }

    /// @dev Shared body of both `…IfNeeded` entrypoints.
    function _applyBatchIfNeeded(address owner, PermitBatch calldata batch, bytes32 hashStruct, bytes calldata sig)
        private
    {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        _verifyPermitSig(owner, hashStruct, sig);
        // Spent bit ⇒ apply NOTHING and return. The signature above is still proven,
        // so this is not an authorisation bypass — it is the S-1 remediation, without
        // which one front-run permanently bricks a gasless order.
        //
        // ⚠ DO NOT READ THIS AS "the grants were already applied". A bit is set by
        // {UnorderedNonces.invalidateUnorderedNonces} / {lockdownAll} just as much as
        // by a prior application, and in that case the grants were NEVER applied and
        // never will be. Either way the effect here is identical and fail-safe (less
        // authority, never more) — but the caller must not infer that the allowances
        // now exist. {Core.fillWithPermit} proceeds past this either way and succeeds
        // only if a standing allowance, or a direct ERC-20 approval via the
        // {Permit3TransferLib} fallback, independently funds the fill.
        //
        // Consequence a maker must not get wrong: invalidating a nonce KILLS THE
        // GRANTS, NOT THE ORDER. The cancellations that bind the order are
        // {OrderState.cancelOrder}, the order-nonce bitmap / `rollbackNonces`, and
        // the expiry. See {UnorderedNonces} and `docs/soft-cancel.md`.
        if (_isPermitNonceUsed(owner, batch.nonce)) return;
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    /// @inheritdoc IPermit3
    function lockdownAll(
        TokenSpenderPair[] calldata tokens,
        SpenderRefPair[] calldata takers,
        uint256[] calldata nonceWords,
        uint256[] calldata nonceMasks
    ) external override {
        address owner = msg.sender;
        _lockdownTokens(owner, tokens);
        _lockdownTakers(owner, takers);
        _invalidateNonces(owner, nonceWords, nonceMasks);
    }

    // ──────────────────── One-shot signed take ────────────────────

    /// @inheritdoc IPermit3
    function permitTake(
        IPermit3.PermitTake calldata permit,
        address owner,
        address receiver,
        bytes calldata data,
        bytes calldata sig
    ) external override nonReentrant {
        _permitTake(permit, owner, receiver, data, Permit3Hash.hashPermitTake(permit, msg.sender), sig);
    }

    /// @inheritdoc IPermit3
    function permitTakeWithWitness(
        IPermit3.PermitTake calldata permit,
        address owner,
        address receiver,
        bytes calldata data,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external override nonReentrant {
        // Compute the digest in a nested scope so `witness`/`witnessTypeString`
        // (four calldata stack slots) are dead before the `_permitTake` call —
        // otherwise the legacy (non-via-IR) codegen goes stack-too-deep.
        bytes32 hashStruct;
        {
            hashStruct = Permit3Hash.hashPermitTakeWithWitness(permit, msg.sender, witness, witnessTypeString);
        }
        _permitTake(permit, owner, receiver, data, hashStruct, sig);
    }

    /// @inheritdoc IPermit3
    /// @dev The typehash-taking twin of the above; identical digest and identical
    ///      verification, with the concatenation done by the caller at compile time.
    function permitTakeWithWitnessHash(
        IPermit3.PermitTake calldata permit,
        address owner,
        address receiver,
        bytes calldata data,
        bytes32 witness,
        bytes32 witnessTypeHash,
        bytes calldata sig
    ) external override nonReentrant {
        // Nested scope for the same stack reason as the string variant.
        bytes32 hashStruct;
        {
            hashStruct = Permit3Hash.hashPermitTakeWithWitnessTypeHash(permit, msg.sender, witness, witnessTypeHash);
        }
        _permitTake(permit, owner, receiver, data, hashStruct, sig);
    }

    // ──────────────────── Internal ────────────────────

    /// @dev Expiry, amount, ref-binding, signature, nonce, then dispatch. The
    ///      signed `spender` is `msg.sender` (folded into `hashStruct`), so a leaked
    ///      signature is useless to anyone else — exactly the {SignatureTransfer}
    ///      model, applied to the taker book. No allowance is written or read.
    function _permitTake(
        IPermit3.PermitTake calldata permit,
        address owner,
        address receiver,
        bytes calldata data,
        bytes32 hashStruct,
        bytes calldata sig
    ) private {
        if (block.timestamp > permit.deadline) revert PermitExpired();
        if (permit.amount == 0) revert ZeroAmount();
        // The signed `ref` must be the position the caller is actually dispatching,
        // so the maker authorises exact bytes — same guarantee the allowance book's
        // `ref = keccak256(data)` gives, enforced here for the one-shot path.
        if (keccak256(data) != permit.ref) revert RefMismatch();
        _verifyPermitSig(owner, hashStruct, sig);
        _usePermitNonce(owner, permit.nonce);
        emit Taken(owner, msg.sender, permit.ref, permit.module, permit.amount, receiver);
        ITakerModule(permit.module).takeOnBehalf(owner, permit.amount, receiver, data);
    }

    function _verifyPermitSig(address owner, bytes32 hashStruct, bytes calldata sig) internal view {
        // SignatureVerification handles EOA (65-byte & EIP-2098 compact),
        // EIP-1271 contract signatures, and EIP-7702 accounts (raw-key or
        // delegated-1271), and enforces length / signer checks.
        sig.verify(_hashTypedData(hashStruct), owner);
    }

    function _applyBatch(address owner, PermitBatch calldata batch) private {
        _applyTokenPermits(owner, batch.tokens);
        _applyTakerPermits(owner, batch.takers);
    }
}

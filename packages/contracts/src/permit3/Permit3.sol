// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {ITakerModule} from "../interfaces/ITakerModule.sol";
import {EIP712} from "./EIP712.sol";
import {SignatureVerification} from "./SignatureVerification.sol";

/// @title Permit3
/// @notice Unified allowance hub for ERC20 transfers *and* protocol taker ops
///         (borrow, withdraw, unstake, claim, …).
///
///  Design
///  ──────
///  Permit3 holds two allowance books:
///
///    • token book — keyed (user → spender → token). A spender calls
///      `transferFrom(user, to, token, amount)`; Permit3 decrements the
///      spender's allowance and calls the token's ERC20 transferFrom.
///      Permit2-equivalent.
///
///    • taker book — keyed (user → module → bytes32 ref). An arbitrary
///      caller invokes `take(module, user, amount, receiver, data)`;
///      Permit3 computes `ref = keccak256(data)`, decrements the user's
///      allowance on (module, ref), then invokes the module's
///      `takeOnBehalf`. The module performs the protocol-native call.
///
///  Permit3 knows nothing about lending/staking/vault protocols. Protocol
///  heterogeneity stays in modules. Single-operation modules keep blast
///  radius small: approvals on a borrow module cannot be used to withdraw,
///  and vice versa.
///
///  Both on-chain `approveX` flows and EIP-712 signed permits are
///  supported. Signed permits may bind an arbitrary witness (e.g. an order
///  hash) via `permitBatchWithWitness`, so a single signature can cover
///  both a batch of allowances and the order that will consume them.
contract Permit3 is IPermit3, EIP712 {
    using SignatureVerification for bytes;

    /// @dev user → spender → token → (amount, expiration, nonce)
    mapping(address => mapping(address => mapping(address => PackedAllowance))) private _tokenAllowance;

    /// @dev user → module → ref → (amount, expiration, nonce).
    ///      `ref` is opaque to Permit3 — a module-specific position key
    ///      (Morpho marketId, Comet address, Aave (asset, rateMode), LST
    ///      withdrawal NFT id, …).
    mapping(address => mapping(address => mapping(bytes32 => PackedAllowance))) private _takerAllowance;

    /// @notice Permit replay-protection: owner → wordIndex → bitmap of used nonces.
    mapping(address => mapping(uint256 => uint256)) public permitNonceBitmap;

    uint256 private _locked = 1;

    // ──────────────────── EIP-712 typehashes ────────────────────

    bytes32 private constant _TOKEN_PERMIT_TYPEHASH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");

    bytes32 private constant _TAKER_PERMIT_TYPEHASH =
        keccak256("TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)");

    bytes32 private constant _PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );

    /// @dev Type-string stub for the witness-bound batch. The caller appends
    ///      its own `"<fieldName> <WitnessType>)<TYPES IN ALPHABETICAL ORDER>"`.
    string private constant _PERMIT_BATCH_WITNESS_STUB =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,";

    /// @dev Resolves the diamond between IPermit3 (declares it) and EIP712
    ///      (implements it). Delegates to the EIP712 base.
    function DOMAIN_SEPARATOR() public view override(IPermit3, EIP712) returns (bytes32) {
        return EIP712.DOMAIN_SEPARATOR();
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ──────────────────── Token side ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external override {
        PackedAllowance storage a = _tokenAllowance[msg.sender][spender][token];
        a.amount = amount;
        a.expiration = expiration;
        emit TokenApproval(msg.sender, spender, token, amount, expiration);
    }

    function transferFrom(address user, address to, address token, uint160 amount) external override {
        _transferFrom(user, to, token, amount);
    }

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external override {
        unchecked {
            uint256 length = transferDetails.length;
            for (uint256 i; i < length; ++i) {
                AllowanceTransferDetails calldata d = transferDetails[i];
                _transferFrom(d.from, d.to, d.token, d.amount);
            }
        }
    }

    function tokenAllowance(address user, address spender, address token)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        PackedAllowance storage a = _tokenAllowance[user][spender][token];
        return (a.amount, a.expiration, a.nonce);
    }

    // ──────────────────── Taker side ────────────────────

    function approveTaker(address module, bytes32 ref, uint160 amount, uint48 expiration) external override {
        PackedAllowance storage a = _takerAllowance[msg.sender][module][ref];
        a.amount = amount;
        a.expiration = expiration;
        emit TakerApproval(msg.sender, module, ref, amount, expiration);
    }

    function take(address module, address user, uint160 amount, address receiver, bytes calldata data)
        external
        override
        nonReentrant
    {
        bytes32 ref = keccak256(data);
        _spend(_takerAllowance[user][module][ref], amount);
        ITakerModule(module).takeOnBehalf(user, amount, receiver, data);
    }

    function takerAllowance(address user, address module, bytes32 ref)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        PackedAllowance storage a = _takerAllowance[user][module][ref];
        return (a.amount, a.expiration, a.nonce);
    }

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external override {
        delete _tokenAllowance[msg.sender][spender][token];
        emit TokenApproval(msg.sender, spender, token, 0, 0);
    }

    function revokeTaker(address module, bytes32 ref) external override {
        delete _takerAllowance[msg.sender][module][ref];
        emit TakerApproval(msg.sender, module, ref, 0, 0);
    }

    /// @dev Token-book lockdown. Ported from Permit2's `lockdown`.
    function lockdown(TokenSpenderPair[] calldata approvals) external override {
        address owner = msg.sender;
        unchecked {
            uint256 length = approvals.length;
            for (uint256 i; i < length; ++i) {
                address token = approvals[i].token;
                address spender = approvals[i].spender;
                _tokenAllowance[owner][spender][token].amount = 0;
                emit Lockdown(owner, token, spender);
            }
        }
    }

    /// @dev Taker-book analogue of `lockdown` (Permit3 extension).
    function lockdownTakers(ModuleRefPair[] calldata approvals) external override {
        address owner = msg.sender;
        unchecked {
            uint256 length = approvals.length;
            for (uint256 i; i < length; ++i) {
                address module = approvals[i].module;
                bytes32 ref = approvals[i].ref;
                _takerAllowance[owner][module][ref].amount = 0;
                emit TakerLockdown(owner, module, ref);
            }
        }
    }

    // ──────────────────── Signed permits ────────────────────

    function permitBatch(address owner, PermitBatch calldata batch, bytes calldata sig) external override {
        if (block.timestamp > batch.deadline) revert PermitExpired();
        bytes32 hashStruct = keccak256(
            abi.encode(
                _PERMIT_BATCH_TYPEHASH,
                _hashTokenPermits(batch.tokens),
                _hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline
            )
        );
        _verifyPermitSig(owner, hashStruct, sig);
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
        bytes32 typeHash = keccak256(abi.encodePacked(_PERMIT_BATCH_WITNESS_STUB, witnessTypeString));
        bytes32 hashStruct = keccak256(
            abi.encode(
                typeHash,
                _hashTokenPermits(batch.tokens),
                _hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline,
                witness
            )
        );
        _verifyPermitSig(owner, hashStruct, sig);
        _usePermitNonce(owner, batch.nonce);
        _applyBatch(owner, batch);
        emit PermitBatchApplied(owner, batch.nonce);
    }

    function isPermitNonceUsed(address owner, uint256 nonce) external view override returns (bool) {
        return (permitNonceBitmap[owner][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }

    /// @dev Ported from Permit2's `invalidateUnorderedNonces`.
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external override {
        permitNonceBitmap[msg.sender][wordPos] |= mask;
        emit UnorderedNonceInvalidation(msg.sender, wordPos, mask);
    }

    // ──────────────────── Permit internals ────────────────────

    function _hashTokenPermits(TokenPermit[] calldata permits) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](permits.length);
        for (uint256 i; i < permits.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    _TOKEN_PERMIT_TYPEHASH,
                    permits[i].spender,
                    permits[i].token,
                    permits[i].amount,
                    permits[i].expiration
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashTakerPermits(TakerPermit[] calldata permits) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](permits.length);
        for (uint256 i; i < permits.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    _TAKER_PERMIT_TYPEHASH,
                    permits[i].module,
                    permits[i].ref,
                    permits[i].amount,
                    permits[i].expiration
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _verifyPermitSig(address owner, bytes32 hashStruct, bytes calldata sig) private view {
        // SignatureVerification (ported from Permit2) handles EOA (65-byte &
        // EIP-2098 compact) and EIP-1271 contract signatures, and enforces
        // length / signer checks.
        sig.verify(_hashTypedData(hashStruct), owner);
    }

    function _usePermitNonce(address owner, uint256 nonce) private {
        uint256 wordIndex = nonce >> 8;
        uint256 bitIndex = nonce & 0xff;
        uint256 mask = 1 << bitIndex;
        uint256 word = permitNonceBitmap[owner][wordIndex];
        if (word & mask != 0) revert PermitNonceUsed();
        permitNonceBitmap[owner][wordIndex] = word | mask;
    }

    function _applyBatch(address owner, PermitBatch calldata batch) private {
        for (uint256 i; i < batch.tokens.length; i++) {
            TokenPermit calldata p = batch.tokens[i];
            PackedAllowance storage a = _tokenAllowance[owner][p.spender][p.token];
            a.amount = p.amount;
            a.expiration = p.expiration;
            emit TokenApproval(owner, p.spender, p.token, p.amount, p.expiration);
        }
        for (uint256 i; i < batch.takers.length; i++) {
            TakerPermit calldata p = batch.takers[i];
            PackedAllowance storage a = _takerAllowance[owner][p.module][p.ref];
            a.amount = p.amount;
            a.expiration = p.expiration;
            emit TakerApproval(owner, p.module, p.ref, p.amount, p.expiration);
        }
    }

    // ──────────────────── Internal ────────────────────

    function _transferFrom(address from, address to, address token, uint160 amount) private {
        _spend(_tokenAllowance[from][msg.sender][token], amount);
        IERC20(token).transferFrom(from, to, amount);
    }

    function _spend(PackedAllowance storage a, uint160 amount) private {
        uint48 exp = a.expiration;
        // expiration == 0 means "no expiration" — matches Permit2 ergonomics
        if (exp != 0 && block.timestamp > exp) revert AllowanceExpired(exp);

        uint160 cur = a.amount;
        // type(uint160).max == "infinite, do not decrement"
        if (cur != type(uint160).max) {
            if (cur < amount) revert InsufficientAllowance(cur);
            unchecked {
                a.amount = cur - amount;
            }
        }
    }
}

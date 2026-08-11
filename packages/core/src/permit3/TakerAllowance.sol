// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {ITakerModule} from "../interfaces/ITakerModule.sol";
import {Permit3Base} from "./Permit3Base.sol";
import {Allowance} from "./libraries/Allowance.sol";

/// @title TakerAllowance
/// @notice Permit3's TAKER BOOK — the half that has no Permit2 analogue. Keyed
///         (user → spender → bytes32 ref), it gates position-pulling operations
///         (borrow, withdraw, unstake, claim, …) that do not fit the ERC20
///         `transferFrom` shape.
///
///         A spender calls `take(module, user, amount, receiver, data)`; Permit3
///         computes `ref = keccak256(data)`, decrements the (user, spender, ref)
///         allowance, then invokes the module's `takeOnBehalf`. The module
///         performs the protocol-native call. Permit3 itself knows nothing about
///         lending/staking/vault protocols — that heterogeneity stays in modules.
///
/// @dev    The consume-then-call ordering is enforced HERE, not in the module, so
///         a buggy module cannot bypass the allowance gate.
///
///  PROVENANCE — NEW IN PERMIT3. Nothing in Permit2 corresponds to this file.
///  ─────────────────────────────────────────────────────────────────────────
///  What is borrowed is the SHAPE, not the code: the book is keyed by spender
///  and gated the same way the token book is ({AllowanceTransfer}), and it
///  reuses the same `PackedAllowance` slot and {Allowance} primitives. The
///  third key is a `bytes32 ref = keccak256(data)` instead of a token address,
///  and spending dispatches to a module rather than calling `transferFrom`.
///  `take`, `approveTaker`, `revokeTaker` and `lockdownTakers` are all Permit3
///  additions — `lockdownTakers` mirrors Permit2's `lockdown` deliberately.
abstract contract TakerAllowance is Permit3Base {
    using Allowance for IPermit3.PackedAllowance;

    /// @dev user → spender → ref → (amount, expiration, nonce).
    ///      Keyed by `spender` (the caller of `take`, e.g. Settlement) — exactly
    ///      like the token book is keyed by `spender` — so only an approved
    ///      spender can consume a taker allowance. `ref = keccak256(data)` is the
    ///      opaque position key; the dispatched module is bound by the maker's
    ///      signed order, not by `ref`.
    mapping(address => mapping(address => mapping(bytes32 => PackedAllowance))) private _takerAllowance;

    /// @dev 1/2 flag rather than transient storage: some target chains have no
    ///      TSTORE. Guards `take` only — that is the sole outbound call.
    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ──────────────────── Grants ────────────────────

    function approveTaker(address spender, bytes32 ref, uint160 amount, uint48 expiration) external override {
        _takerAllowance[msg.sender][spender][ref].grant(amount, expiration);
        emit TakerApproval(msg.sender, spender, ref, amount, expiration);
    }

    // ──────────────────── Spending ────────────────────

    /// @notice Amount-gated taker dispatch. The allowance is keyed by
    ///         `(user, msg.sender, ref)` where `ref = keccak256(data)` — so only a
    ///         spender the user approved (e.g. Settlement) can consume it,
    ///         mirroring the token book. `receiver` is chosen by the (trusted,
    ///         approved) spender, just as `to` is on `transferFrom`. The dispatched
    ///         `module` is bound by the maker's signed order (Settlement only ever
    ///         calls the order's own `item.module`), so it need not enter `ref`.
    function take(address module, address user, uint160 amount, address receiver, bytes calldata data)
        external
        override
        nonReentrant
    {
        // Reject zero-amount dispatches. `spend(bucket, 0)` does not revert even
        // against an empty allowance, so without this an unauthorised caller could
        // reach `module.takeOnBehalf(user, 0, ...)` for any `user` — harmless for
        // today's modules (excess always sweeps to `onBehalfOf`, so a zero `amount`
        // nets the caller nothing) but a standing footgun for any future module
        // that keys off a non-zero `amount`. Settlement already skips zero slices
        // (`_executeItems`), so this is behaviour-preserving on the honest path.
        if (amount == 0) revert ZeroAmount();
        bytes32 ref = keccak256(data);
        _takerAllowance[user][msg.sender][ref].spend(amount);
        ITakerModule(module).takeOnBehalf(user, amount, receiver, data);
    }

    function takerAllowance(address user, address spender, bytes32 ref)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        PackedAllowance storage a = _takerAllowance[user][spender][ref];
        return (a.amount, a.expiration, a.nonce);
    }

    // ──────────────────── Revocation ────────────────────

    function revokeTaker(address spender, bytes32 ref) external override {
        delete _takerAllowance[msg.sender][spender][ref];
        emit TakerApproval(msg.sender, spender, ref, 0, 0);
    }

    /// @dev Taker-book analogue of `lockdown` (Permit3 extension).
    function lockdownTakers(SpenderRefPair[] calldata approvals) external override {
        address owner = msg.sender;
        unchecked {
            uint256 length = approvals.length;
            for (uint256 i; i < length; ++i) {
                address spender = approvals[i].spender;
                bytes32 ref = approvals[i].ref;
                _takerAllowance[owner][spender][ref].amount = 0;
                emit TakerLockdown(owner, spender, ref);
            }
        }
    }

    // ──────────────────── Internal ────────────────────

    /// @dev Applies the taker legs of a verified signed batch. Only
    ///      {SignedPermits} calls this, and only after the signature and the
    ///      nonce have been checked.
    function _applyTakerPermits(address owner, TakerPermit[] calldata permits) internal {
        uint256 length = permits.length;
        for (uint256 i; i < length;) {
            TakerPermit calldata p = permits[i];
            _takerAllowance[owner][p.spender][p.ref].grant(p.amount, p.expiration);
            emit TakerApproval(owner, p.spender, p.ref, p.amount, p.expiration);
            unchecked {
                ++i;
            }
        }
    }
}

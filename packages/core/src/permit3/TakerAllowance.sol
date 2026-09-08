// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {ITakerModule} from "../interfaces/ITakerModule.sol";
import {ITakerForModule} from "../interfaces/ITakerForModule.sol";
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

    /// @dev user → spender → module → ref → (amount, expiration, nonce).
    ///      Keyed by `spender` (the caller of `take`, e.g. Settlement) — exactly
    ///      like the token book is keyed by `spender` — so only an approved
    ///      spender can consume a taker allowance. `ref = keccak256(data)` is the
    ///      opaque position key.
    ///
    ///      `module` IS PART OF THE KEY. Earlier revisions keyed on `ref` alone, on
    ///      the reasoning that Settlement pins the module from the maker's signed
    ///      order. But the shipped module `data` layouts are deliberately minimal
    ///      (`abi.encode(comet)`, `abi.encode(cToken)`, a `MarketParams`), so two
    ///      distinct modules routinely share a `ref` — the containment was the
    ///      order signature, never the key. Naming the module in the key makes an
    ///      `approveTaker(borrowModule, …)` grant unusable to dispatch ANY other
    ///      module, whatever its data, and lets a wallet render the authorisation.
    mapping(address => mapping(address => mapping(address => mapping(bytes32 => PackedAllowance)))) private
        _takerAllowance;

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

    function approveTaker(address spender, address module, bytes32 ref, uint160 amount, uint48 expiration)
        external
        override
    {
        _takerAllowance[msg.sender][spender][module][ref].grant(amount, expiration);
        emit TakerApproval(msg.sender, spender, ref, module, amount, expiration);
    }

    // ──────────────────── Spending ────────────────────

    /// @notice Amount-gated taker dispatch. The allowance is keyed by
    ///         `(user, msg.sender, module, ref)` where `ref = keccak256(data)` — so
    ///         only a spender the user approved (e.g. Settlement) can consume it,
    ///         mirroring the token book. `receiver` is chosen by the (trusted,
    ///         approved) spender, just as `to` is on `transferFrom`.
    ///
    ///         ⚠ THE MODULE IS PART OF THE KEY, and this doc used to say the opposite
    ///         — that the module "need not enter `ref`" because the maker's signed
    ///         order pins it. That was true of the older three-part key and is stale:
    ///         the storage below is `[user][spender][module][ref]`, and the mapping's
    ///         own comment explains why (the shipped `data` layouts are minimal, so
    ///         two distinct modules routinely share a `ref`; the containment was the
    ///         order signature, never the key). Prose claiming LESS than the code
    ///         enforces still misleads a reader deciding what a grant covers.
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
        _takerAllowance[user][msg.sender][module][ref].spend(amount);
        emit Taken(user, msg.sender, ref, module, amount, receiver);
        ITakerModule(module).takeOnBehalf(user, amount, receiver, data);
    }

    /// @inheritdoc IPermit3
    /// @dev The COMPOSITE sibling of {take}, and deliberately a near-copy of it:
    ///      same book, same key, same `ref`, same consume-then-call ordering, same
    ///      reentrancy lock. The ONLY difference is the extra `forAmount` word
    ///      forwarded to the module — the value-IN side of a one-call
    ///      deposit+borrow / repay+withdraw.
    ///
    ///      `forAmount` is NOT gated here, and cannot be: it is a number the spender
    ///      computes per fill, so a second book keyed on it is not a grant a user
    ///      could meaningfully sign. The taker book bounds what LEAVES a user's
    ///      position; the funding leg moves value IN.
    ///
    ///      WHAT BOUNDS IT INSTEAD — and the correction that F27/C-1 forced. This
    ///      comment used to claim `forAmount` was "bounded by the user's token
    ///      allowance to the module". That is a PULL-module premise: it holds when
    ///      the module calls {transferFrom} to draw the funding leg out of the
    ///      user's wallet, where a self-granting caller can only rob themselves. A
    ///      PUSH module never calls `transferFrom` — it funds from its OWN balance —
    ///      so on that shape the premise is vacuous and `forAmount` was bounded by
    ///      nothing at all. Since {approveTaker} lets any caller name ITSELF spender,
    ///      one self-grant of a single unit drained a pre-funded singleton outright.
    ///
    ///      The bound now lives at the module, which is the only place that knows
    ///      its own funding shape: `msg.sender` is forwarded as `spender`, a pre-fund
    ///      module requires it to equal its pinned Settlement, and takes a balance
    ///      floor on top. `msg.sender == permit3` authorises NOTHING by itself —
    ///      this is a permissionless entrypoint.
    ///
    ///      A module reached through here implements {ITakerForModule}, NOT
    ///      {ITakerModule}: the selectors differ, so a plain taker module signed
    ///      into a `TAKE_FOR` item reverts on dispatch instead of being handed a
    ///      truncated call.
    function takeFor(
        address module,
        address user,
        uint160 amount,
        uint160 forAmount,
        address receiver,
        bytes calldata data
    ) external override nonReentrant {
        // Same zero-amount rejection as {take}, for the same reason: `spend(0)`
        // succeeds against an empty allowance, so without it an unapproved caller
        // could reach a module for any `user`. Settlement skips zero slices, so
        // this is behaviour-preserving on the honest path.
        if (amount == 0) revert ZeroAmount();
        bytes32 ref = keccak256(data);
        _takerAllowance[user][msg.sender][module][ref].spend(amount);
        // `forAmount` rides the log: it is the one quantity here nothing meters, so
        // this is its only protocol-level trace. See {IPermit3.TakenFor}.
        emit TakenFor(user, msg.sender, ref, module, amount, forAmount, receiver);
        // Forward the spender. `forAmount` is deliberately NOT metered here (see
        // below), so a PRE-FUND module — which funds from its OWN balance rather than
        // from the user's allowance — has no other way to tell a Settlement-
        // dispatched fill from a direct call by anyone (F27/C-1).
        ITakerForModule(module).takeForOnBehalf(msg.sender, user, amount, forAmount, receiver, data);
    }

    function takerAllowance(address user, address spender, address module, bytes32 ref)
        external
        view
        override
        returns (uint160 amount, uint48 expiration)
    {
        PackedAllowance storage a = _takerAllowance[user][spender][module][ref];
        return (a.amount, a.expiration);
    }

    /// @inheritdoc IPermit3
    function refFor(bytes calldata data) external pure override returns (bytes32) {
        return keccak256(data);
    }

    // ──────────────────── Revocation ────────────────────

    function revokeTaker(address spender, address module, bytes32 ref) external override {
        delete _takerAllowance[msg.sender][spender][module][ref];
        emit TakerApproval(msg.sender, spender, ref, module, 0, 0);
    }

    /// @dev Taker-book analogue of `lockdown` (Permit3 extension).
    function lockdownTakers(SpenderRefPair[] calldata approvals) external override {
        _lockdownTakers(msg.sender, approvals);
    }

    /// @dev Shared by `lockdownTakers` and the combined {SignedPermits.lockdownAll}.
    function _lockdownTakers(address owner, SpenderRefPair[] calldata approvals) internal {
        unchecked {
            uint256 length = approvals.length;
            for (uint256 i; i < length; ++i) {
                address spender = approvals[i].spender;
                address module = approvals[i].module;
                bytes32 ref = approvals[i].ref;
                _takerAllowance[owner][spender][module][ref].amount = 0;
                emit TakerLockdown(owner, spender, module, ref);
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
            _takerAllowance[owner][p.spender][p.module][p.ref].grant(p.amount, p.expiration);
            emit TakerApproval(owner, p.spender, p.ref, p.module, p.amount, p.expiration);
            unchecked {
                ++i;
            }
        }
    }
}

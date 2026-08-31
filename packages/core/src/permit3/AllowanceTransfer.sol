// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3Base} from "./Permit3Base.sol";
import {Allowance} from "./libraries/Allowance.sol";

/// @title AllowanceTransfer
/// @notice Permit3's TOKEN BOOK — the Permit2-equivalent half. Keyed
///         (user → spender → token): a spender calls
///         `transferFrom(user, to, token, amount)`, Permit3 decrements the
///         spender's allowance and performs the ERC20 `transferFrom`.
///
///         Grants arrive either on-chain (`approveToken`) or through a signed
///         batch ({SignedPermits}, via `_applyTokenPermits`). Revocation is
///         per-entry (`revokeToken`) or batched (`lockdown`).
///
/// @dev    Abstract: it owns the book and the rules over it, nothing else. The
///         signed-permit layer sits above it so that this contract has no
///         signature surface at all.
///
///  PROVENANCE — Permit2 `src/AllowanceTransfer.sol` (Uniswap, MIT), ported.
///  ─────────────────────────────────────────────────────────────────────────
///  FROM PERMIT2, semantics unchanged:
///    • `approve` → `approveToken`, `transferFrom` (single + batch), `lockdown`
///    • the `PackedAllowance` slot layout, `uint160.max` = infinite (not
///      decremented), and the expired/insufficient revert order in `_transfer`
///      (now {Allowance.spend})
///  CHANGED:
///    • KEY ORDER. Permit2 indexes `allowance[owner][token][spender]`; this book
///      is `[user][spender][token]`, matching the taker book so both read the
///      same way. Off-chain slot derivations do NOT carry over from Permit2.
///    • `expiration == 0` means NEVER EXPIRES here. In Permit2 it means the
///      opposite — `Allowance.updateAmountAndExpiration` rewrites 0 to
///      `block.timestamp`, so the grant dies at the end of the current block.
///      See {Allowance.spend}.
///    • No allowance-level nonce. Permit2 keeps a sequential per-(owner, token,
///      spender) nonce in the packed slot and gates `permit` on it; Permit3
///      replays are stopped by the unordered bitmap alone, so `grant` zeroes
///      that field instead of incrementing it. `invalidateNonces` /
///      `ExcessiveInvalidation` have no analogue.
///    • Signed grants live in {SignedPermits}, not here — Permit2 puts `permit`
///      and `permitBatch` directly on `AllowanceTransfer`, but a Permit3 batch
///      spans both books, so it cannot belong to either one.
///    • Transfers go through the repo's own `SafeTransferLib`, not solmate's.
abstract contract AllowanceTransfer is Permit3Base {
    using Allowance for IPermit3.PackedAllowance;

    /// @dev user → spender → token → (amount, expiration, nonce)
    mapping(address => mapping(address => mapping(address => PackedAllowance))) private _tokenAllowance;

    /// @dev user → strict mode. When set, {Permit3TransferLib}'s direct-approval
    ///      fallback is refused for this payer (see {setStrictMode}). Off by
    ///      default; the flag is read only when the Permit3 leg has already failed,
    ///      so it never touches the hot path for anyone who has not opted in.
    mapping(address => bool) private _strict;

    /// @dev user → token → strict mode, the per-token half of the same switch (see
    ///      {IPermit3.setStrictModeToken}). Read only after the global flag has come
    ///      back false, on an already-failed Permit3 leg, so opting in per token costs
    ///      nothing to anyone who has not.
    mapping(address => mapping(address => bool)) private _strictToken;

    // ──────────────────── Grants ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external override {
        _tokenAllowance[msg.sender][spender][token].grant(amount, expiration);
        emit TokenApproval(msg.sender, spender, token, amount, expiration);
    }

    // ──────────────────── Spending ────────────────────

    /// @dev DELIBERATELY NOT `nonReentrant`, and two consequences of that are worth
    ///      naming because neither is obvious from here.
    ///
    ///      1. THE TAKE LOCK IS ONE-DIRECTIONAL. {TakerAllowance.take} holds the guard
    ///         across its module dispatch, so a module cannot nest a `take` — but it
    ///         CAN call this, which is the whole point (every pull-funded module funds
    ///         its leg that way; see {ITakerModule}). The reverse edge is open too and
    ///         is NOT by design: `_transferFrom` below hands control to a maker-chosen
    ///         token, and a token with a transfer hook can call `take` from inside it,
    ///         since nothing here arms `_locked`. Reaching a victim that way still
    ///         needs a taker allowance keyed to the TOKEN CONTRACT as spender, which
    ///         no integration grants — so this is a gap in the lock's reach, not a
    ///         live path. Do not read `take`'s guard as a global "no takes in flight".
    ///
    ///      2. ADDING A GUARD HERE WOULD SILENTLY DEGRADE, NOT REVERT.
    ///         {Permit3TransferLib.transferFromWithFallback} probes this function with
    ///         a LOW-LEVEL call and treats ANY failure — including a `Reentrancy()`
    ///         revert — as "Permit3 has no grant, use the direct ERC20 approval". So a
    ///         guard bolted on here would not stop a re-entrant transfer; it would
    ///         route it through the payer's standing ERC20 allowance instead, which is
    ///         the broader authority. Anyone adding one must teach that library to
    ///         distinguish the two failures first.
    ///
    ///      What actually contains a re-entering caller is that this book is keyed by
    ///      `msg.sender` as the SPENDER, so a module re-entering wields exactly the
    ///      buckets it was granted itself. Pinned by the cross-function suite in
    ///      `test/Permit3.t.sol` ({CrossFunctionReentrantModule}).
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
        returns (uint160 amount, uint48 expiration)
    {
        PackedAllowance storage a = _tokenAllowance[user][spender][token];
        return (a.amount, a.expiration);
    }

    // ──────────────────── Strict mode ────────────────────

    /// @inheritdoc IPermit3
    function setStrictMode(bool enabled) external override {
        _strict[msg.sender] = enabled;
        emit StrictModeSet(msg.sender, enabled);
    }

    /// @inheritdoc IPermit3
    function strictMode(address user) external view override returns (bool) {
        return _strict[user];
    }

    /// @inheritdoc IPermit3
    function setStrictModeToken(address token, bool enabled) external override {
        _strictToken[msg.sender][token] = enabled;
        emit StrictModeTokenSet(msg.sender, token, enabled);
    }

    /// @inheritdoc IPermit3
    function strictModeToken(address user, address token) external view override returns (bool) {
        return _strictToken[user][token];
    }

    /// @inheritdoc IPermit3
    /// @dev The global flag is tested FIRST so a payer who took the portfolio-wide
    ///      option pays one warm slot and never touches the per-token map.
    function isStrict(address user, address token) external view override returns (bool) {
        return _strict[user] || _strictToken[user][token];
    }

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external override {
        delete _tokenAllowance[msg.sender][spender][token];
        emit TokenApproval(msg.sender, spender, token, 0, 0);
    }

    /// @dev Token-book lockdown. Ported from Permit2's `lockdown`.
    function lockdown(TokenSpenderPair[] calldata approvals) external override {
        _lockdownTokens(msg.sender, approvals);
    }

    /// @dev Shared by `lockdown` and the combined {SignedPermits.lockdownAll}.
    function _lockdownTokens(address owner, TokenSpenderPair[] calldata approvals) internal {
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

    // ──────────────────── Internal ────────────────────

    /// @dev Applies the token legs of a verified signed batch. Only
    ///      {SignedPermits} calls this, and only after the signature and the
    ///      nonce have been checked.
    function _applyTokenPermits(address owner, TokenPermit[] calldata permits) internal {
        uint256 length = permits.length;
        for (uint256 i; i < length;) {
            TokenPermit calldata p = permits[i];
            _tokenAllowance[owner][p.spender][p.token].grant(p.amount, p.expiration);
            emit TokenApproval(owner, p.spender, p.token, p.amount, p.expiration);
            unchecked {
                ++i;
            }
        }
    }

    function _transferFrom(address from, address to, address token, uint160 amount) private {
        // Reject zero-amount pulls. `spend(bucket, 0)` does not revert even against
        // an empty allowance, so without this ANY caller could make Permit3 issue
        // `token.transferFrom(from, to, 0)` from Permit3's own address for any
        // `from`/`token` — harmless for a plain ERC20 but a free way to trigger a
        // hook-bearing token, or a token whose `transferFrom` a contract gates on
        // `msg.sender == permit3`. Mirrors the identical guard on `take`. Honest
        // fills never move zero (Settlement zero-guards every leg upstream).
        if (amount == 0) revert ZeroAmount();
        _tokenAllowance[from][msg.sender][token].spend(amount);
        // Assembly safe-transfer: reverts on a `false` return or a no-code token,
        // and allocates no memory (previously a raw `IERC20.transferFrom` with no
        // success check).
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }
}

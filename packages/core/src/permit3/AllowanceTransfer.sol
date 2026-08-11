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

    // ──────────────────── Grants ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external override {
        _tokenAllowance[msg.sender][spender][token].grant(amount, expiration);
        emit TokenApproval(msg.sender, spender, token, amount, expiration);
    }

    // ──────────────────── Spending ────────────────────

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

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external override {
        delete _tokenAllowance[msg.sender][spender][token];
        emit TokenApproval(msg.sender, spender, token, 0, 0);
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
        _tokenAllowance[from][msg.sender][token].spend(amount);
        // Assembly safe-transfer: reverts on a `false` return or a no-code token,
        // and allocates no memory (previously a raw `IERC20.transferFrom` with no
        // success check).
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }
}

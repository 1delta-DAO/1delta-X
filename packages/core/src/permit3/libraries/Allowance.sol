// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../../interfaces/IPermit3.sol";

/// @title Allowance
/// @notice Packed-allowance primitives shared by both Permit3 books. Mirrors
///         Permit2's `libraries/Allowance.sol`: the storage layout and the
///         grant/spend rules live in one place, so the token book and the taker
///         book cannot drift apart.
///
/// @dev    Internal-only — every function inlines into the calling contract, so
///         there is no delegatecall and no external library to link.
///
///  PROVENANCE — Permit2 `src/libraries/Allowance.sol` (Uniswap, MIT), rewritten.
///  ─────────────────────────────────────────────────────────────────────────
///  FROM PERMIT2: the packed slot layout (`pack`: amount | expiration << 160 |
///  nonce << 208) and the single-`sstore` grant.
///  CHANGED:
///    • `grant` replaces `updateAll` + `updateAmountAndExpiration`. It neither
///      increments a nonce (Permit3 has no allowance-level nonce) nor rewrites
///      `expiration == 0` — see the deviation note on {spend}.
///    • `spend` has no Permit2 counterpart as a function: it is Permit2's
///      `AllowanceTransfer._transfer` gate, lifted out so both books share one
///      copy, and folded into a single SLOAD/SSTORE.
library Allowance {
    /// @dev Overwrite an allowance bucket with a fresh grant.
    ///
    ///      Single packed store (amount+expiration+nonce share one slot). The
    ///      allowance-level `nonce` is unused — replay of signed batches is guarded
    ///      by `permitNonceBitmap` — so writing 0 is behavior-preserving and costs
    ///      one SSTORE instead of two field-level read-modify-writes.
    ///
    ///      Written through the slot rather than field-by-field: a storage POINTER
    ///      cannot take a struct literal (`a = PackedAllowance(...)` would rebind the
    ///      pointer), and three field assignments compile to three read-modify-writes.
    ///
    ///      EQUIVALENT SOLIDITY (at the call site, where the mapping is in scope):
    ///
    ///          book[user][spender][key] = PackedAllowance({
    ///              amount: amount, expiration: expiration, nonce: 0
    ///          });
    function grant(IPermit3.PackedAllowance storage a, uint160 amount, uint48 expiration) internal {
        // Layout: amount [0,160) | expiration [160,208) | nonce [208,256) = 0.
        uint256 packed = uint256(amount) | (uint256(expiration) << 160);
        /// @solidity memory-safe-assembly
        assembly {
            sstore(a.slot, packed)
        }
    }

    /// @dev `amount`/`expiration`/`nonce` share ONE slot, so the whole allowance is
    ///      read with a single SLOAD and written back as a single word. Reading the
    ///      fields individually made solc emit one SLOAD per field plus a third for
    ///      the decrement's read-modify-write; the packed form is the same three
    ///      accesses collapsed into one load and one store.
    ///
    ///      EQUIVALENT SOLIDITY:
    ///
    ///          uint48 exp = a.expiration;
    ///          if (exp != 0 && block.timestamp > exp) revert AllowanceExpired(exp);
    ///          uint160 cur = a.amount;
    ///          if (cur != type(uint160).max) {
    ///              if (cur < amount) revert InsufficientAllowance(cur);
    ///              unchecked { a.amount = cur - amount; }
    ///          }
    ///
    ///      `nonce` is preserved verbatim by the masked write-back, so the field-level
    ///      form above and this one leave identical storage.
    function spend(IPermit3.PackedAllowance storage a, uint160 amount) internal {
        uint256 packed;
        /// @solidity memory-safe-assembly
        assembly {
            packed := sload(a.slot)
        }
        // Layout (see {IPermit3.PackedAllowance}): amount [0,160) | expiration
        // [160,208) | nonce [208,256).
        uint48 exp = uint48(packed >> 160);
        // `expiration == 0` means NO EXPIRATION.
        //
        // ⚠ THIS IS THE OPPOSITE OF PERMIT2, which has no zero-exemption in its
        // gate (`if (block.timestamp > allowed.expiration) revert`) and instead
        // rewrites a zero on the way IN — `Allowance.updateAmountAndExpiration`
        // stores `uint48(block.timestamp)`, making the grant die at the end of
        // the block it was created in. Under Permit2 semantics a 0 here would
        // mean "already expired"; under ours it means "never expires". Do not
        // port either side's expiry reasoning across without re-reading both.
        if (exp != 0 && block.timestamp > exp) revert IPermit3.AllowanceExpired(exp);

        uint160 cur = uint160(packed);
        // type(uint160).max == "infinite, do not decrement"
        if (cur != type(uint160).max) {
            if (cur < amount) revert IPermit3.InsufficientAllowance(cur);
            unchecked {
                // Replace the low 160 bits; expiration + nonce carry over untouched.
                uint256 next = (packed & ~uint256(type(uint160).max)) | uint256(cur - amount);
                /// @solidity memory-safe-assembly
                assembly {
                    sstore(a.slot, next)
                }
            }
        }
    }
}

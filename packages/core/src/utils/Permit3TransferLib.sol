// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {SafeTransferLib} from "./SafeTransferLib.sol";

/// @title Permit3TransferLib
/// @notice A regular token-book move with a direct-approval fallback, modelled on
///         Euler EVK's `SafeERC20Lib.safeTransferFrom`: try Permit3 first, and if
///         that fails — because `from` granted a plain ERC20 allowance to the
///         caller (the spender) instead of routing through Permit3 — fall back to
///         a direct `transferFrom`. Only the payer's own tokens move, and only to
///         the caller-chosen recipient, so the fallback adds no new authority.
///
///         Applies ONLY to regular transfers (e.g. `tokenOut` delivery, `tokenIn`
///         shortfall). It must NOT back the taker book (`take`): that dispatches
///         to a module (borrow/withdraw/…) and has no `transferFrom` analogue, so
///         that authority must stay Permit3-gated.
///
/// @dev    ⚠ CONSEQUENCE FOR PAYERS — a direct ERC20 approval to the spender
///         OVERRIDES every Permit3 control on that token. Because a failed Permit3
///         leg silently falls through, the direct allowance is consulted whenever
///         the Permit3 one is missing, too small, or expired. So for a payer
///         holding both:
///           • per-order Permit3 amount caps are not binding — the fallback pulls
///             the full amount anyway;
///           • `revokeToken` / `lockdown` / an expiry do NOT stop fills.
///         This is intended (a direct approval IS the broader grant, and the payer
///         made it deliberately), but it means REVOKING PERMIT3 IS NOT A KILL
///         SWITCH. To actually stop settlement from moving a token, the payer must
///         also zero the direct ERC20 allowance to the spender. Wallets and UIs
///         surfacing a "revoke" action MUST clear both.
///
///         The opt-in kill switch is STRICT MODE, and it comes at two granularities:
///         {IPermit3.setStrictMode} for the payer's whole portfolio, and
///         {IPermit3.setStrictModeToken} for a single token. Prefer the per-token one
///         unless the payer really means "never fall back for anything": a direct
///         ERC20 approval is per-token, so that is the granularity the exposure has,
///         and the portfolio-wide flag otherwise forces a payer who wants Permit3 to
///         bind on ONE token to surrender the fallback on every other token too. The
///         two OR together — see {IPermit3.isStrict}, which is what this library asks.
///
/// @dev    Internal functions inline into the caller, so `msg.sender` seen by
///         Permit3 (and by the ERC20 on the fallback) is the CALLING contract —
///         which must be the spender approved on Permit3. Do not convert these to
///         external/public without accounting for the resulting context change.
library Permit3TransferLib {
    /// @param permit3 the Permit3 hub the caller (spender) is approved on
    /// @param token   ERC20 to move
    /// @param from    payer
    /// @param to      recipient
    /// @param amount  exact amount to move
    function transferFromWithFallback(IPermit3 permit3, address token, address from, address to, uint256 amount)
        internal
    {
        // A zero move is a no-op that the Permit3 leg now REJECTS ({ZeroAmount});
        // returning early keeps behaviour identical for the honest zero-slice case
        // and avoids falling through to a direct `transferFrom(_, _, 0)`, which some
        // strict tokens reject. Settlement already zero-guards its call sites, so
        // this only hardens the library against a future caller that does not.
        if (amount == 0) return;
        bool ok;
        if (amount <= type(uint160).max) {
            // Low-level call so a Permit3 failure is caught rather than reverting,
            // exactly as Euler wraps the Permit2 leg. `transferFrom` is overloaded
            // on IPermit3, so the single-leg selector is pinned explicitly:
            // `transferFrom(address,address,address,uint160)` == 0x9fc0d7da.
            //
            // Built in scratch memory ABOVE the free-memory pointer WITHOUT bumping
            // it (permitted for memory-safe assembly — the bytes are consumed by the
            // CALL and never need to outlive it). The `abi.encodeWithSignature` this
            // replaces allocated a fresh 132-byte buffer on EVERY output delivery and
            // every input shortfall pull; this allocates nothing.
            //
            // EQUIVALENT SOLIDITY:
            //
            //     (ok,) = address(permit3).call(
            //         abi.encodeWithSignature(
            //             "transferFrom(address,address,address,uint160)",
            //             from, to, token, uint160(amount)
            //         )
            //     );
            //
            // (Return data is ignored in both forms — a successful call means the
            // transfer happened; see the `InvalidPermit3` constructor check that makes
            // "success with empty returndata" safe to trust.)
            /// @solidity memory-safe-assembly
            assembly {
                let p := mload(0x40)
                mstore(p, 0x9fc0d7da)
                mstore(add(p, 0x20), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(p, 0x40), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(p, 0x60), and(token, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(p, 0x80), amount) // already <= type(uint160).max
                // Selector occupies the LAST 4 bytes of the first word, so the
                // calldata starts at p+0x1c and runs 4 + 4*32 = 0x84 bytes.
                ok := call(gas(), permit3, 0, add(p, 0x1c), 0x84, 0x00, 0x00)
            }
        }
        if (!ok) {
            // STRICT MODE (opt-in, off by default): a payer can make the Permit3
            // allowance book the ONLY funding path for their tokens, so that
            // `revokeToken`/`lockdown`/an expiry actually stop settlement rather than
            // being silently overridden by a standing direct approval. The flag is
            // read only HERE, on the already-failed Permit3 leg, so a payer who never
            // opts in pays nothing.
            //
            // Asked PER (payer, token) — {IPermit3.isStrict} ORs the payer's global
            // flag with their per-token one. A direct ERC20 approval is itself a
            // per-token grant, so that is the granularity the exposure actually has;
            // the older portfolio-wide `strictMode(from)` forced a payer wanting
            // Permit3 to bind on ONE token to give up the direct-approval fallback on
            // every other token too. Still ONE staticcall on the failed leg either way.
            // See {IPermit3.setStrictMode} / {IPermit3.setStrictModeToken}.
            if (permit3.isStrict(from, token)) revert IPermit3.Permit3Denied();
            SafeTransferLib.safeTransferFrom(token, from, to, amount);
        }
    }
}

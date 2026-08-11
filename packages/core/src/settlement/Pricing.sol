// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, FillCtx, OrderSide} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {Proportional} from "./Proportional.sol";

/// @title Pricing
/// @notice The per-leg slice math for a single fill, factored into ONE place so
///         auditors read the input/output pricing rules once instead of diffing
///         the copies that used to live in `_deliverOutputs`, `_payInputsToSolver`,
///         and the batch pull/compute helpers. Arithmetic over the resolved
///         `FillCtx`; each function resolves the auction `bump` itself (`view`, via
///         `bumpBps()`) but ONLY for a decaying leg (`start != end`) — a fixed leg
///         never touches the decay tick, preserving the "no bump on a fixed order"
///         gas shape. `bumpBps()` is deterministic within a tx, so resolving it
///         per decaying leg is result-identical to the old once-per-side sentinel —
///         and, measured, also the CHEAPER shape; see the note above {outputAt}.
///
/// @dev    Behaviour is byte-for-byte the pre-refactor inline math:
///           • outputs — BUY legs are the fixed cumulative ceil slice (exact
///             output); SELL legs are auction-priced `ceil(delta · amountOutAt /
///             anchor)`, with the soft-exclusivity override applied ONLY to the
///             maker's own legs (a fee leg to a third party is untouched).
///           • inputs — an auctioned leg (`start != end`, and every BUY leg) is
///             `floor(delta · amountInAt / anchor)` with the override reducing the
///             maker's charge; a fixed leg is the cumulative floor slice (exact
///             input).
///         The auction `bump` is resolved here per leg — only when the leg
///         actually decays, so a fixed leg never touches `bumpBps` (preserving the
///         "no bump on a fixed order" gas shape). Callers use it via
///         `using Pricing for Order` → `order.outputAt(ctx, j)`.
library Pricing {
    using DutchAuction for Order;

    /// @dev ceil(a / b), b > 0.
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev MEASURED, do not "optimize" by memoizing the bump on the {FillCtx}. It
    ///      was tried (2026-08-09): one extra `uint256` field holding `bump + 1`, with
    ///      zero meaning unresolved, resolved lazily by a private helper and reused
    ///      across every leg and both sides of a fill. It is correct — the bump is a
    ///      pure function of `block.timestamp`/`block.basefee`, both fixed within a
    ///      tx — and it is SLOWER almost everywhere:
    ///        • +27 gas on EVERY fill, including all-fixed orders that never decay
    ///          at all, just for the extra word in the struct;
    ///        • +178 on a single-decaying-leg swap, +291..+392 on the curve tests —
    ///          the helper does not inline, so a one-leg order pays a JUMP, the
    ///          load/compare/store, and the ±1 to save a call it never repeats;
    ///        • it only pays off with TWO OR MORE decaying legs in one fill
    ///          (−1,158 on the multi-output shared-bump case), which is the rare
    ///          shape, not the common one.
    ///      Net across the suite: 266 tests worse, 6 better. The per-leg resolution
    ///      below is already the right shape for the dominant case.

    /// @notice The amount to deliver on output leg `j` (post-override), pool/solver
    ///         → recipient.
    function outputAt(Order calldata o, FillCtx memory ctx, uint256 j) internal view returns (uint256 amt) {
        // Decode the leg ONCE — all four fields in a single pass over the packed blob,
        // rather than re-deriving the element offset for every field.
        (, uint256 legStart, uint256 legEnd, address legRecipient) = PackedArrays.legOut(o.legsOut, j);
        if (o.side() == OrderSide.BUY) {
            // Fixed output — the exact-output guarantee; never overridden.
            amt = ctx.fullFill
                ? legStart
                : ceilDiv(legStart * ctx.newFilled, ctx.anchor) - ceilDiv(legStart * ctx.prevFilled, ctx.anchor);
        } else {
            uint256 bump = legEnd != 0 ? o.bumpBps() : 0;
            amt = ceilDiv((ctx.newFilled - ctx.prevFilled) * DutchAuction.outTick(legStart, legEnd, bump), ctx.anchor);
            // Soft-exclusivity override lifts ONLY the maker's own SELL legs — never
            // a fee leg to a third party (would leak the comp) — mirroring the input
            // side, where the override lowers only the maker's charge.
            if (amt != 0 && ctx.overrideBps != 0) {
                if (legRecipient == address(0) || legRecipient == o.maker) {
                    amt = ceilDiv(amt * (10_000 + ctx.overrideBps), 10_000);
                }
            }
        }
    }

    /// @notice The amount owed on input leg `i` (post-override), maker → pool/solver.
    ///         An auctioned leg (`end != 0`, and every BUY leg) rises with the tick;
    ///         a fixed leg (`end == 0`) is the exact cumulative slice of `start`.
    function inputOwed(Order calldata o, FillCtx memory ctx, uint256 i) internal view returns (uint256 owed) {
        (, uint256 startIn, uint256 endIn) = PackedArrays.legIn(o.legsIn, i); // decoded once
        // Balance-relative anchor ({Proportional}). The marker was already resolved
        // against the maker's live balance in {OrderGates.anchorTotal} and pinned in
        // `ctx.anchor`; returning that pin — rather than re-reading the balance — is
        // what guarantees the output pricing and this pull agree. Re-reading would
        // open a window in which an item crediting the maker mid-fill (a TAKE with
        // `recipient == maker`) makes the solver deliver against one balance and the
        // maker pay against a larger one.
        //
        // ⚠ MEASURED — KEEP THIS BRANCH INLINE HERE (2026-08-10). Moving the four
        // checks into a `private` helper and tail-calling it looks obviously better
        // and is obviously worse: `inputOwed` is reached from {Core}, {Batch} AND
        // {SettlementLens}, and a private library function is emitted per call site,
        // so the split cost **+2,430 bytes** of Settlement bytecode (23,134 →
        // 25,564, straight over EIP-170) and did not buy back one gas. Inline, the
        // whole feature is +31 bytes.
        //
        // ⚠ AND BEWARE THE PROFILE WHEN MEASURING THIS. Under the legacy `core`
        // profile that `make gas` uses, this one compare reads as +232 gas per fill
        // — a stack spill, not opcodes. Under `core-deploy` (via-IR), which is what
        // actually gets DEPLOYED, the same code costs **+40 gas**
        // (495,147 vs 495,107 on `test_plain_swap_full`). The snapshot will show the
        // larger number; production pays the smaller one. Do not "optimize" this
        // against the legacy figure.
        if (Proportional.isProportional(startIn)) {
            if (i != 0 || o.fillTotal != 0 || o.fillModule != address(0) || o.side() == OrderSide.BUY) {
                revert Proportional.InvalidProportionalLeg();
            }
            if (!ctx.fullFill) revert Proportional.ProportionalNeedsFullFill();
            owed = ctx.anchor;
        } else if (o.side() == OrderSide.BUY || endIn != 0) {
            uint256 bump = endIn != 0 ? o.bumpBps() : 0;
            owed = (ctx.newFilled - ctx.prevFilled) * DutchAuction.inTick(startIn, endIn, bump) / ctx.anchor;
            // Soft-exclusivity override: a non-exclusive in-window filler charges
            // LESS input (the auction leg moves toward the maker).
            if (ctx.overrideBps != 0) owed = owed * (10_000 - ctx.overrideBps) / 10_000;
        } else {
            // Fixed input — the exact-input guarantee; never overridden.
            owed = ctx.fullFill
                ? startIn
                : (startIn * ctx.newFilled) / ctx.anchor - (startIn * ctx.prevFilled) / ctx.anchor;
        }
    }

}

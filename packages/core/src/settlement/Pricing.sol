// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, FillCtx, OrderSide} from "./Structs.sol";
import {PackedArrays} from "./PackedArrays.sol";
import {DutchAuction} from "./DutchAuction.sol";

/// @title Pricing
/// @notice The per-leg slice math for a single fill, factored into ONE place so
///         auditors read the input/output pricing rules once instead of diffing
///         the copies that used to live in `_deliverOutputs`, `_payInputsToSolver`,
///         and the batch pull/compute helpers. Arithmetic over the resolved
///         `FillCtx`; each function resolves the auction `bump` itself (`view`, via
///         `bumpBps()`) but ONLY for a decaying leg (`start != end`) — a fixed leg
///         never touches the decay tick, preserving the "no bump on a fixed order"
///         gas shape. `bumpBps()` is deterministic within a tx, so resolving it
///         per decaying leg is result-identical to the old once-per-side sentinel.
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
        if (o.side() == OrderSide.BUY || endIn != 0) {
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

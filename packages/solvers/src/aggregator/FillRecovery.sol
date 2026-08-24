// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {Pricing} from "@core/settlement/Pricing.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {Settlement, Order, FillCtx, OrderSide} from "@core/settlement/Settlement.sol";

/// @title FillRecovery
/// @notice Reconstruct the amounts of the fill CURRENTLY IN FLIGHT, from inside a
///         solver's callback.
///
///  The problem it solves
///  ─────────────────────
///  `fillWithCallback` hands the callback nothing — no order, no amounts. That is
///  a size decision, not an oversight: passing them means Settlement carrying a
///  full-order ABI encoder, measured at ~1,300 bytes for the equivalent price
///  module interface, against a contract with tens of bytes of EIP-170 headroom.
///
///  It does not have to. The settlement's pricing math lives in INTERNAL
///  libraries ({DutchAuction}, {Pricing}), so a solver can inline the very same
///  code and recompute what Settlement just computed — bit-identical, no call,
///  no lens. All that is missing is the fill's own {FillCtx}, and every field of
///  it is recoverable from public state plus the arguments the solver already
///  chose. That is what this library assembles.
///
///  ⚠ THE LENS IS NOT AN OPTION HERE, and this is why the recovery is needed at
///  all. {OrderState._openFill} writes `filled[orderHash] = newFilled` BEFORE the
///  callback runs, so {SettlementLens.previewFill} called during a callback
///  prices the NEXT fill, not this one. The same hazard {IPriceModule} documents
///  for `prevFilled`.
///
///  ⚠ PROPORTIONAL LEGS UNDER `PostInputs`, and the one thing that must be
///  captured rather than derived. {OrderGates.anchorTotal} resolves a
///  {Proportional} marker against the maker's LIVE balance. Under
///  `CallbackMode.PreDelivery` nothing has moved yet, so the recomputation
///  matches. Under `PostInputs` the maker has already paid, so re-deriving yields
///  a DIFFERENT anchor than the fill used.
///
///  {anchorOf} is the answer: call it BEFORE `fill`, in the same transaction, and
///  pass the result to {ctxOfWithAnchor}. Nothing can move between the two — the
///  solver owns the transaction — so the captured value is exactly what the fill
///  will resolve. The plain {ctxOf} REJECTS the combination instead of guessing,
///  because a number that looks right and is not would silently mis-approve.
///
///  With that, the recovery is TOTAL: every input to {FillCtx} is either pure
///  order data, public post-fill state, an argument the solver chose, or a
///  pre-fill capture the solver can take in its own transaction.
library FillRecovery {
    /// @dev A proportional order recovered under `PostInputs` with no captured
    ///      anchor; see the ⚠ above and {anchorOf}.
    error ProportionalNotRecoverable();
    /// @dev A fill-module order's delta is whatever {IFillModule.resolveFill}
    ///      returned, which the caller never chose — so `newFilled - fillAmount`
    ///      is not this fill's `prevFilled` and every amount derived from it is
    ///      wrong. Use {ISettlementCallback} (a `*Typed` {CallbackMode}), which
    ///      carries the resolved `prevFilled`/`newFilled` directly, or
    ///      {SettlementLens.previewFillInFlight} with a captured `prevFilled`.
    error FillModuleNotRecoverable();
    /// @dev A fill-once order burns its nonce instead of writing `filled`, so the
    ///      counter reads zero forever and the subtraction below underflows or
    ///      silently prices the wrong fill. Same two alternatives as above.
    error NonceInvalidatorNotRecoverable();

    /// @notice The fill denominator this order will resolve to RIGHT NOW.
    ///         Call it immediately before `fill` to capture a proportional
    ///         anchor; for every other order shape it is a pure function of the
    ///         order and capturing is unnecessary.
    function anchorOf(Order calldata order) internal view returns (uint256) {
        return OrderGates.fillDenominator(order);
    }

    /// @notice Rebuild the in-flight {FillCtx}.
    ///
    ///  ⚠ THE DELTA IS ASSUMED HERE, NOT DISCOVERED, and that is the whole limit
    ///  of this library. `prevFilled` is recovered as `filled - fillAmount`, which
    ///  is true only where the settler's delta IS the caller's `fillAmount` — an
    ///  identity order on `fill`/`fillWithCallback`. The two shapes where it is
    ///  not are rejected outright rather than answered wrongly; both are named in
    ///  the errors above, and both have an exact alternative.
    /// @param  fillAmount the amount the solver passed to `fill`/`fillWithCallback`.
    ///         EXACT on those paths for an identity order: they revert {OverFill}
    ///         rather than clamping, so the delta really is `fillAmount` and
    ///         `prevFilled` follows by subtraction. `fillUpTo` clamps — and takes
    ///         no callback, so it cannot reach here.
    /// @param  postInputs true when recovering from a `PostInputs` callback, i.e.
    ///         the maker's inputs have already moved.
    /// @param  takerData the same blob the solver passed to the fill — a price
    ///         module reads it, so omitting it would re-price the order.
    function ctxOf(
        Settlement settlement,
        Order calldata order,
        uint256 fillAmount,
        address filler,
        bytes memory takerData,
        bool postInputs
    ) internal view returns (FillCtx memory ctx) {
        // A balance-relative anchor cannot be re-resolved once the maker has paid.
        if (postInputs && _isProportional(order)) revert ProportionalNotRecoverable();
        return ctxOfWithAnchor(settlement, order, fillAmount, filler, takerData, 0);
    }

    /// @notice {ctxOf} with the anchor supplied rather than re-derived.
    /// @param  anchorHint the value {anchorOf} returned before the fill, or `0` to
    ///         derive. Only a {Proportional} order needs it; passing a stale or
    ///         fabricated value simply mis-prices the SOLVER's own arithmetic —
    ///         the maker is unaffected, because Settlement prices the fill from
    ///         its own resolution regardless of what this returns.
    /// @dev    Rejects the two shapes whose delta is not `fillAmount` — see the ⚠
    ///         on {ctxOf}. The check lives HERE and not only in {ctxOf} because
    ///         this is the entrypoint a proportional-order solver is told to use,
    ///         so routing around {ctxOf} must not route around the guard.
    function ctxOfWithAnchor(
        Settlement settlement,
        Order calldata order,
        uint256 fillAmount,
        address filler,
        bytes memory takerData,
        uint256 anchorHint
    ) internal view returns (FillCtx memory ctx) {
        if (order.fillModule != address(0)) revert FillModuleNotRecoverable();
        if (DutchAuction.useNonceInvalidator(order)) revert NonceInvalidatorNotRecoverable();

        ctx.orderHash = OrderHash.hash(order);
        ctx.anchor = anchorHint != 0 ? anchorHint : OrderGates.fillDenominator(order);

        uint256 newFilled = settlement.filled(ctx.orderHash);
        ctx.newFilled = newFilled;
        ctx.prevFilled = newFilled - fillAmount;
        ctx.fullFill = ctx.prevFilled == 0 && newFilled == ctx.anchor;

        ctx.filler = filler;
        ctx.payTo = filler;
        ctx.overrideBps = OrderGates.exclusivityOverride(order, filler);
        // Re-runs the module / priority resolution the settler pinned. Same
        // arguments in, same answer out — the module is `view` and its address is
        // in the order the solver already holds.
        ctx.bump = DutchAuction.resolveBump(order, ctx.orderHash, ctx.anchor, filler, ctx.prevFilled, takerData);
    }

    /// @notice What this fill must deliver on output leg `j` — the number
    ///         {Pricing} is about to demand.
    function outputOwed(Order calldata order, FillCtx memory ctx, uint256 j) internal view returns (uint256) {
        return Pricing.outputAt(order, ctx, j);
    }

    /// @notice What this fill pays the solver on input leg `i`.
    function inputOwed(Order calldata order, FillCtx memory ctx, uint256 i) internal view returns (uint256) {
        return Pricing.inputOwed(order, ctx, i);
    }

    /// @notice Total owed across every output leg — what a just-in-time solver
    ///         has to have on hand when {Pricing} comes for it.
    function totalOutputOwed(Order calldata order, FillCtx memory ctx) internal view returns (uint256 total) {
        uint256 n = PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        for (uint256 j; j < n; ++j) {
            total += Pricing.outputAt(order, ctx, j);
        }
    }

    /// @dev Whether the anchor carries a {Proportional} marker. Only the SELL
    ///      side's leg 0 can — a BUY order's output anchor rejects markers
    ///      outright in {OrderGates.anchorTotal} — and it is exactly the leg whose
    ///      resolution depends on the maker's live balance.
    function _isProportional(Order calldata order) private pure returns (bool) {
        if (order.fillTotal != 0) return false; // module-denominated: no leg anchor
        if (DutchAuction.side(order) != OrderSide.SELL) return false;
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0) return false;
        (, uint256 start,) = PackedArrays.legIn(order.legsIn, 0);
        return Proportional.isProportional(start);
    }
}

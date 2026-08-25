// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISettlementCallback
/// @notice The typed callback shape, carrying the RESOLVED state of the fill in
///         flight. Opt-in: only the `*Typed` {CallbackMode}s call it, so the
///         untyped `(target, data)` callback is untouched.
///
///  Why a taker wants this
///  ──────────────────────
///  Every value below is already resolved in {FillCtx} before the callback runs,
///  and all of them are *technically* recoverable off public state — but doing so
///  is subtle enough to have been got wrong repeatedly in development:
///    • `prevFilled` is NOT `filled(orderHash) - fillAmount`. That holds for an
///      identity order only; a fill-module order's delta is whatever
///      {IFillModule.resolveFill} returned, which the caller never chose.
///    • `anchor` on a {Proportional} order resolves against the maker's LIVE
///      balance, which `PostInputs` has already changed by callback time.
///    • A fill-once order ({DutchAuction.useNonceInvalidator}) never writes
///      `filled`, so the counter reads zero forever.
///    • {SettlementLens.previewFill} cannot stand in: {OrderState._openFill}
///      advances `filled` BEFORE the callback, so it prices the NEXT fill.
///
///  Both sides are handed over — `pricedIn` AND `pricedOut` — because which one
///  carries the unknown depends on {OrderSide}: outputs auction on a SELL, inputs
///  rise on a BUY. A filler that sizes a swap needs the pair, not one of them.
///
///  ⚠ WHY THIS IS ADDITIVE AND NOT A REPLACEMENT. The untyped callback can invoke
///  ANY function on ANY contract, which is strictly more expressive and is itself
///  a tested property — the suite points it at Permit3 and at Settlement to prove
///  the allowance-less {SolverCallbackExecutor} makes that harmless. A typed
///  callback cannot express those. Both shapes stay.
///
///  ⚠ THE CALLBACK STILL HOLDS NO AUTHORITY. It is invoked through the EXECUTOR,
///  so `msg.sender` here is that trampoline and not the settlement. Authenticate
///  against it and gate on a flag your own entrypoint armed — receiving this
///  context does not make the call trusted.
interface ISettlementCallback {
    /// @param orderHash  the fill's order hash — no need to recompute it.
    /// @param prevFilled cumulative progress BEFORE this fill.
    /// @param newFilled  cumulative progress AFTER it. `newFilled - prevFilled` is
    ///                   this fill's delta for EVERY mechanism, including a
    ///                   fill-module order whose delta the caller never chose.
    /// @param anchor     the fill denominator, proportional markers resolved.
    /// @param pricedIn   what this fill PAYS the filler on each input leg, indexed
    ///                   1:1 with `legsIn` — the very numbers
    ///                   {Core._payInputsToSolver} is about to hand over.
    ///
    ///                   ⚠ THIS IS THE HALF A BUY (EXACT-OUTPUT) ORDER NEEDS. On a
    ///                   SELL the outputs are the auctioned side, so `pricedOut`
    ///                   carries the unknown and the inputs are the fixed amount the
    ///                   maker signed. A BUY inverts that exactly: the OUTPUT is the
    ///                   fixed basket and every INPUT leg RISES `start → end` on the
    ///                   clock, so `pricedOut` alone told a BUY filler only what it
    ///                   already knew and left the variable side — its own
    ///                   compensation — to be re-derived from the order, i.e. still
    ///                   needing the order, which is the thing this mode exists to
    ///                   avoid. The same applies to a SELL's relayer-fee leg
    ///                   (`legsIn[i].end != 0`), which rises for the same reason.
    ///
    ///                   ⚠ WHAT IS PAID, NOT WHAT IS HELD. Under a `PostInputs*`
    ///                   mode these have ALREADY been transferred when the callback
    ///                   runs; under a `PreDelivery*` mode they have not, and are a
    ///                   promise conditional on the rest of the fill succeeding. In
    ///                   both cases the destination is {FillCtx.payTo} — the filler
    ///                   on every classic path, but `fillUpTo`'s `recipient` when
    ///                   redirected — so a callback that reads its own balance must
    ///                   not assume it is the payee.
    /// @param pricedOut  what this fill must deliver on each output leg, indexed
    ///                   1:1 with `legsOut` — the very numbers {Pricing} is about
    ///                   to demand.
    ///
    ///                   ⚠ THE PRICED AMOUNTS, NOT `FillCtx.bump`. Passing the bump
    ///                   was tried and is useless for the DOMINANT order shape: a
    ///                   plain clock-priced order leaves `ctx.bump` at its
    ///                   "not pinned" sentinel of 0 and resolves the clock lazily
    ///                   per leg, so a taker handed the bump would still have to
    ///                   run the clock itself — i.e. still need the order, which is
    ///                   the thing this mode exists to avoid.
    /// @param userData   the taker's own blob, passed through untouched.
    function onSettlementFill(
        bytes32 orderHash,
        uint256 prevFilled,
        uint256 newFilled,
        uint256 anchor,
        uint256[] calldata pricedIn,
        uint256[] calldata pricedOut,
        bytes calldata userData
    ) external;
}

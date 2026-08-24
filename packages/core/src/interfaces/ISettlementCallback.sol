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
        uint256[] calldata pricedOut,
        bytes calldata userData
    ) external;
}

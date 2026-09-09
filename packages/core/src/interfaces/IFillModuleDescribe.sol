// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFillModuleDescribe
/// @notice OPTIONAL companion a {IFillModule} MAY implement so a filler can tell
///         what KIND of order it is looking at without keeping a hardcoded list of
///         deployed fill-module addresses.
///
///  Purely informational and off-chain; the settlement never calls it. A module
///  that does not implement it is unaffected — the call reverts and callers treat
///  a revert as "no description available", the same convention as
///  {ITakerModuleDescribe}.
///
///  ⚠ A SEPARATE FILE ON PURPOSE. {IFillModule} rides into `Settlement`'s
///  compilation unit ({OrderState} calls `resolveFill`), and declaring an unused
///  function there is not free — the same reason {IFundingSource} is split out of
///  {ITakerForModule}. Nothing the settler compiles may import this.
///
///  ⚠ AND MOST FILLERS DO NOT NEED IT. The probe-then-bound recipe works on every
///  module order without knowing which module it is:
///
///      (delta,,) = lens.previewFill(order, order.fillTotal, filler, takerData);
///      settlement.fillUpTo(order, sig, delta, ...);   // or fill(order, sig, delta)
///
///  `order.fillTotal` is a universal probe FOR THE PREVIEW — it can never bind,
///  because the core caps every module at `filled + delta <= fillTotal` anyway.
///  Re-submitting the returned `delta` is what bounds the filler to the size it
///  actually quoted.
///
///  ⚠ THE TWO CALLS TAKE DIFFERENT NUMBERS, AND ON THE NETTED PATH IT MATTERS.
///  `fillTotal` belongs in the PROBE; the quoted `delta` belongs in the FILL. In
///  {Batch.matchSettle} the per-order `p.fillAmounts[i]` reaches `resolveFill`
///  during PHASE 1, before any token moves — so passing the quoted `delta` there
///  makes a drifted size revert cheaply, at open, exactly like a proportional
///  order's clamp does. Passing `fillTotal` instead throws that away: the plan
///  proceeds with a size the solver never simulated and blows up later as
///  `BatchNotWhole` / `LegUnfunded` / a reverting venue call, after signatures,
///  venue reads and real withdraws have been paid for.
///
///  That bound is the ONLY one a netted solver has for this class of order.
///  A `MatchRaceGuard`-style `filled[hash]` equality check cannot substitute: a
///  lending index ticking, or a third party calling `supply(..., onBehalfOf =
///  maker)`, changes the resolved size WITHOUT touching `filled`. `dynamicSize`
///  below is the flag that says a plan built against this order can be
///  invalidated by state the guard does not track.
///
///  This interface is for the cases the recipe does not cover: rendering, and
///  strategy (declining one-shot orders, or re-quoting orders whose size moves).
interface IFillModuleDescribe {
    /// @return kind        a short human-readable identifier, e.g. `"POSITION_SIZED"`.
    ///         Rendered as a `bytes32` short string so it is legible in a trace.
    /// @return dynamicSize the resolved delta depends on LIVE CHAIN STATE, so a
    ///         quote can go stale between simulation and inclusion. A filler that
    ///         cares should re-quote close to submission and pass the quoted size
    ///         as `fillAmount`.
    /// @return oneShot     a successful fill closes the order for good, even if it
    ///         advanced less than `fillTotal`. Do not plan a follow-up fill, and do
    ///         not treat a partial-looking `delta` as "more available later".
    function describeFill() external view returns (bytes32 kind, bool dynamicSize, bool oneShot);
}

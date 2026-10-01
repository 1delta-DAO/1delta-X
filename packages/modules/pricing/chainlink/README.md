# `@1delta-x/modules-pricing-chainlink`

`ChainlinkPeggedPriceModule` — an [`IPriceModule`](../../../core/src/interfaces/IPriceModule.sol)
that prices a fill off a Chainlink feed instead of the dutch clock.

What it adds over reading a feed directly is the **plausibility band**. Staleness
alone does not make a price safe: a fresh feed can still report a depegged or
mis-scaled answer, and an order pegged to it would fill against that number. Each
instance therefore carries an absolute `[MIN_ANSWER, MAX_ANSWER]` sanity band
alongside `MAX_STALENESS`, and reverts rather than pricing outside it.

Whatever it returns is still **clamped by the core** to the maker's signed
`[start, end]` band — the module can move the price inside what the maker signed,
never past it.

Configuration lives in immutables (feed, staleness, band, `NUM`/`DEN` scale, side,
spread): one deployed instance per configuration, shared via CREATE2. `NUM == 0`
is rejected at construction; express a negative decimal exponent as a fraction
(`NUM = 1, DEN = 1e20`).

**What the peg is priced against.** The fair amount is computed against the
counterpart leg's whole-order amount — `legsIn[0].start` for a SELL (the resolved
live balance when that leg is a `Proportional` marker), `legsOut[0].start` for a
BUY — never against the fill denominator, so orders with a signed `fillTotal`
(e.g. `FullFillModule`'s `fillTotal = 1`) price at the peg. A SELL whose
`legsIn[0]` rises is solved jointly, so the realised rate `outTick/inTick` is the
peg. Other rising input legs (e.g. a fee leg in another token) move with the
oracle-derived bump; sign them fixed if that coupling is not wanted. (Audit
2026-09-30 PRICE-1 / PRICE-1.v3 / PRICE-9; regression tests in
`test/Audit20260930Pegged.t.sol`.)

```
make test-modules-pricing-chainlink
```

> Moved out of `packages/core/src/modules` on 2026-08-24. Nothing in
> `packages/core/src` imports it — a module is reached only through a signed
> order's `pricingModule` field — so it is a peripheral, not part of the baseline.
> Per-fill gas for this mode is still benchmarked in core's `PricingGasBench.t.sol`,
> where the cross-mode comparison lives.

See [docs/pricing-modes.md](../../../../docs/pricing-modes.md).

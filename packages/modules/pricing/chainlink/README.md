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
spread): one deployed instance per configuration, shared via CREATE2.

```
make test-modules-pricing-chainlink
```

> Moved out of `packages/core/src/modules` on 2026-08-24. Nothing in
> `packages/core/src` imports it — a module is reached only through a signed
> order's `pricingModule` field — so it is a peripheral, not part of the baseline.
> Per-fill gas for this mode is still benchmarked in core's `PricingGasBench.t.sol`,
> where the cross-mode comparison lives.

See [docs/pricing-modes.md](../../../../docs/pricing-modes.md).

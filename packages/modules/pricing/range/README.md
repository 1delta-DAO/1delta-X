# `@1delta-x/modules-pricing-range`

`RangePriceModule` — an [`IPriceModule`](../../../core/src/interfaces/IPriceModule.sol)
that prices along the **volume** axis instead of the clock: the bump interpolates
`START_BPS → END_BPS` over `prevFilled / total`. 1inch's `RangeAmountCalculator`; the
ladder.

Because it is measured on `prevFilled` rather than on time, a solver knows the exact
bump before submitting — no race against a block timestamp. Both directions work:
`END > START` climbs as the order fills, `END < START` gets better for the filler.

Whatever it answers is still clamped by the core to the maker's signed band.

```
make test-modules-pricing-range
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. Core's own module-dispatch tests now run against `ProgressBumpModule`, a
> local mock in `packages/core/test/shared/MockModules.sol`, so a core failure points
> at the core rather than at this curve.

See [docs/pricing-modes.md](../../../../docs/pricing-modes.md).

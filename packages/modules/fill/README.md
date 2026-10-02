# `@1delta-x/modules-fill`

[`IFillModule`](../../core/src/interfaces/IFillModule.sol) implementations — the seam
that decouples "how much does this fill advance the order?" from a fungible leg, so
one signed order can express any↔any intents.

| | |
|---|---|
| `FullFillModule` | all-or-nothing. Answers "the entire remaining denominator" whatever the filler asked for, so one fill completes the order and there is no second one. |
| `TwapFillModule` | a CoW-style TWAP/DCA with **no keeper**. `fillTotal` is cut into equal `minFillAnchor`-sized parts across the decay window — part k opens at exactly `start + ceil(k·duration/parts)` even when the window does not divide evenly, and an unset `decayStartTime == 0` reverts (audit 2026-09-30 PRICE-7); each fill releases only `partsOpen · partSize − prevFilled`, so nothing runs ahead of schedule. Catch-up after a missed part is allowed, and the core caps at `fillTotal`. Equal parts only — `fillTotal % partSize != 0` reverts rather than leaving a dust final part that would trip the core's `minFillAnchor` floor. |

**Fillers: pass `type(uint256).max` or the exact remainder.** The settlement treats
the filler's `fillAmount` as a ceiling on whatever delta a fill module returns
(audit 2026-09-30 CORE-FILLER-2: a module delta above the request reverts
`OverFill`), and resolves `type(uint256).max` to `fillTotal - filled` before the
module sees it (CORE-FILL-4). A `FullFillModule` order therefore fills with
`fill(o, sig, type(uint256).max)` or `fill(o, sig, fillTotal - filled)`; the old
`fill(o, sig, 1)` idiom now reverts. `TwapFillModule` releases at most the request,
so any request ≥ the open slice works.

```
make test-modules-fill
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. Core proves its own side of this seam — that it applies the returned delta
> and enforces the over-fill cap — against local mocks in
> `packages/core/test/shared/MockModules.sol`.

See [docs/fill-modules.md](../../../docs/fill-modules.md).

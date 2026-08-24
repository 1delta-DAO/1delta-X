# `@1delta-x/modules-fill`

[`IFillModule`](../../core/src/interfaces/IFillModule.sol) implementations — the seam
that decouples "how much does this fill advance the order?" from a fungible leg, so
one signed order can express any↔any intents.

| | |
|---|---|
| `FullFillModule` | all-or-nothing. Answers "the entire remaining denominator" whatever the filler asked for, so one fill completes the order and there is no second one. |
| `TwapFillModule` | a CoW-style TWAP/DCA with **no keeper**. `fillTotal` is cut into equal `minFillAnchor`-sized parts across the decay window; each fill releases only `partsOpen · partSize − prevFilled`, so nothing runs ahead of schedule. Catch-up after a missed part is allowed, and the core caps at `fillTotal`. Equal parts only — `fillTotal % partSize != 0` reverts rather than leaving a dust final part that would trip the core's `minFillAnchor` floor. |

```
make test-modules-fill
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. Core proves its own side of this seam — that it applies the returned delta
> and enforces the over-fill cap — against local mocks in
> `packages/core/test/shared/MockModules.sol`.

See [docs/fill-modules.md](../../../docs/fill-modules.md).

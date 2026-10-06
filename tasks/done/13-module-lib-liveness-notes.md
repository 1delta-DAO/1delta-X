# 13. Module library liveness notes (preflight, funnel grants, FullFillGuard × position fills)

- **Status:** done (2026-10-06)
- **Package:** `packages/lib`, `packages/periphery` (lens), `packages/modules/bridge`, docs
- **Severity:** low — all fail closed or are preview-only
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §8
- **Opened:** 2026-10-06

## Items

1. **`FundingPreflight.pullable` reads the maker's balance before the fill's own
   delivery.** For a PULL leg-reference the module pulls `outs[j]` AFTER
   `_deliverOutputs` landed it on the maker, so the lens's `available[j] >=
   required[j]` ("fills whole") under-reports a fillable order as unfunded. Fix in the
   lens (add `outs[j]` to `available` for pull leg-refs) or in the modules'
   `fundingSource`.
2. **`FunnelGrantModule` grants `_prorate(item.amount)`**, which no constant can match
   for an auctioned (BUY / rising) input leg — the fill reverts on allowance unless
   the standing allowance is infinite. Document the shape as fixed-input only, or
   size the grant from the leg. Also `approveTaker` overwrites a sibling order's
   byte-identical taker grant with `(slice, now)`, stalling it.
3. **Every `FullFillGuard`-protected item is unusable on a `PositionFillModule`
   order** (the slice is unknowable at signing): `ERC20PermitTransferModule`,
   `NftSettlementModule`, the 3-word `ProportionalSweepModule`, an Across deposit
   with `dstOrderHash != 0`, a sponsored LZ send. Correct; say so in
   `docs/position-sized-fills.md`.
4. **Pre-fund over-delivery under delta-verify strands below `floorOf`** (NatSpec
   corrected): nothing module-side can measure it; the typed callback's priced
   amounts are the guard. Note it in `docs/audit-2026-09-push-family.md`.

## Acceptance

- Item 1 has a lens test (pull leg-ref previews as funded); items 2–4 are documented
  where their readers look; `make docs-check` passes.

## Resolution (2026-10-06)

1. Fixed in the lens: `SettlementLensChecks._liftPullLegRef` — for a PULL leg
   reference (descriptor bits `100`) on the maker's own leg in the module's funding
   asset, when `available < required`, `available` is raised to
   `min(available + outs[j], Permit3 book (expiry-aware), ERC-20 approval to Permit3)`
   (only ever raised). Residual, fail-closed: a module whose permit tail creates the
   Permit3 approval at fill time with no standing approval is not lifted. NatSpec on
   `previewItemFunding` updated. Tests in
   `packages/periphery/test/Review20261006Lens.t.sol`: a maker with an empty wallet
   previews funded and the order then fills; book / lapsed book / ERC-20 approval
   caps still bind; another-token leg not lifted. (`core/test/items/TakeForItem.t.sol`
   `test_previewItemFunding_tracksTheGrantAndTheFillSucceeds` carries a comment saying
   the view does not foresee the delivery — now stale, left untouched because core
   must not change in this task; its assertions still pass.)
2. Documented: `FunnelGrantModule.makeOnBehalf` NatSpec (⚠ fixed-input shapes only;
   taker-grant overwrite of a byte-identical sibling key) and the bridge README
   ("Two liveness limits").
3. Documented in `docs/position-sized-fills.md` → Known edges.
4. Documented in `docs/audit-2026-09-push-family.md` → "What this does NOT establish".

`make docs-check` passes.

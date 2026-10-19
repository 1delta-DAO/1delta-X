# Review: "amount mismatches" in the zero-capital filling changes (2026-10-18)

Scope: branch `zero-capital-item-fills` at `a3cb82d` versus `main` — the solver v4
(`AggregatorFillSolver`: inventory, multi-input, receipts, remainder sentinel, race guard,
absolute item floor, WNATIVE next to native), `RouteSandbox` multicall, the new
`MatchFlashSolver`, the new pre-fund module branches (Euler, Fluid, Gearbox credit,
Dolomite, Compound v2 native, Midnight, River, Lista, bridge-out), the SDK plan builders
and the beta filler. Core (`packages/core`) and `packages/lib` are unchanged on the branch.

Trigger: an external comment that "amount mismatches are possible". Method, as in
`REVIEW-2026-10-05-amount-mismatch.md`: one direct trace of the solver, three independent
read-throughs (flash wrapper / off-chain / modules) briefed with the mismatch class
("the solver measures a delta and routes or pays it; the core charges the `owed` it
resolved; the two diverge when a token sits on both sides or PRESEND ≠ owed"), and a
Foundry test per concrete claim. Agent-run, not an external audit.

**Bottom line: no maker exposure and no fund loss found.** Every divergence is a revert,
an operator-side floor that is weaker than its documentation says, or value parked on the
operator's own contract. Four items are worth fixing before the next solver / filler
release; the rest are documentation.

Gate: solvers 1,031 / 1,031 (`FOUNDRY_PROFILE=solvers`, non-fork) + the 15 new probe
tests; MatchFlashSolver 32 / 32; modules non-fork: euler-v2 46, fluid 79, gearbox-v3 50,
dolomite 60, compound-v2 39, morpho-midnight 62, river 40, lista 70 + 3, bridge 213, maker
12, transfer 50; sdk 415, beta-filler 506. Fork suites not run.

Probe tests (untracked, keep or drop):
`packages/solvers/test/Review20261018Solver_AmountMismatch.t.sol` (P1–P5),
`packages/solvers/test/Review20261018Flash_Amounts.t.sol` (R1–R8),
`packages/modules/lending/lista/test/netted/Review20261018_SmartCoinIndex.t.sol`.

> `forge test` from inside `packages/solvers` compiles under the ROOT config and dies on
> `AcrossBridgeOutModule.sol:172` stack-too-deep (and the pipeline reports exit 0). Always
> `FOUNDRY_PROFILE=solvers` from the repo root.

---

## 0. Resolution (2026-10-18, same day)

| # | Outcome | Change | Pinned by |
| --- | --- | --- | --- |
| F-1 | **Refuted, no change.** A proportional order's output legs are FIXED at a full fill (`Pricing`: `legStart × anchor / anchor`), so a grown balance raises only the routed input, never what the core pulls; the filler's `maxPay = owed` (previewed) still covers it. Kept, as it is the stronger floor. | — | `Review20261018ProportionalMaxPayTest.test_F1_grownBalance_previewedMaxPayStillCoversTheFixedOutput` |
| F-2 | Fixed (filler) | `route.ts` `sentinelPlan(plan, source)`: the sentinel needs a patched input AND a non-Sushi source; `routeFiller.ts` threads the candidate source into `simulate` | `zeroCapitalShapes.test.ts` "F-2: …" |
| F-3 | Fixed (contract) | `MatchFlashSolver._hop` reverts `PartialSwap(consumed, amountIn)` unless the pool consumed exactly `amountIn`; SDK ABI carries the error | `test_R5_midPlanHop_partialConsumption_reverts` (was: 750 MID parked) |
| F-4 | Fixed (SDK) | `buildFlashMatchPlan` appends `PULL(0, j)` per input leg after the items (draws `owed − credit`: 0 normally, the rounding shortfall otherwise) | `matchFlash.test.ts`, filler M-3 test, `test_R7` + `test_R7b_trailingPull_isANoOpWhenItemsCreditInFull` |
| D-1 | Doc | contract note + `RoutePlan.inventory`: on DIRECT `maxPay` is ignored, `inventory` alone caps the top-up | P1 |
| D-2 / D-4 | Doc | `RoutePlan.amountInOffset` + `_minOut`: the word must be the amount routed; ceilings / owed-with-kept-fee lower the floor; `uint.max` reverts; empty route ⇒ `NO_PATCH` | P2, P3, P3b, P5 |
| D-3 | Doc | `RoutePlan.minOut`: not compared on a zero-output order (`maxPay` likewise) | P4 |
| D-5 | Doc | `FlashMatch.minProfit`: floors the swept balance, not the call's P&L | R4 |
| D-6 | Doc | `FlashSource.amount`: preview-sized, fee charged on unused principal; price the fee on the full amount | R2 |
| D-7 | Doc + filler | README row corrected (inert with the filler's floors); the cap is no longer attached to DIRECT plans (it could not draw and cost the typed callback, ~+6k gas) | `zeroCapitalShapes.test.ts` "D-7: …" |
| D-8 | Doc | README `NETTED_DELIVERY_FUNDED_ITEMS` row + `routeFiller.ts` comment: `receipts: []`, no `MULTI_ROUTE`, what happens to a receipt | — |

Gate after the fixes: solvers 1,140 / 1,140 non-fork (`FOUNDRY_PROFILE=solvers`, probes
included), sdk 415, beta-filler 508, both `tsc --noEmit` clean; `AggregatorFillSolver`
24,430 / 24,576 (doc-only change), `MatchFlashSolver` 18,769. Fork suites not run. The
SDK `dist/` was rebuilt (the filler resolves the SDK through it).

## 1. Worth fixing

| # | Where | What | Impact | Fix |
| --- | --- | --- | --- | --- |
| F-1 | `beta-filler/src/route.ts:552-559`, `routeFiller.ts:680` | Proportional ("sell my balance") orders are sent with the `max` sentinel AND `maxPay = owed` previewed at the maker's balance. A balance that GREW before inclusion makes the core pull more than the solver approved → `TransferFromFailed`, classed as "genuine" → strike/backoff. The solver's own proof of the sentinel on a grown balance uses `maxPay = 0`. | Reverted tx gas + backoff; maker unharmed | `maxPay = 0` (or `owed` at the signed cap) for `cls.proportional`; relax `validatePoolPlan` |
| F-2 | `beta-filler/src/routeFiller.ts:877`, `sushi.ts:184-194` | Sentinel on a Sushi route: the route carries its own absolute `amountOutMin`, which `_minOut` cannot scale, so a shrunk remainder reverts inside snwap (~150–250k gas) instead of at `OverFill` (~15k) | ~10× gas per lost race | exclude `source === "sushi"` from `sentinelOk` |
| F-3 | `MatchFlashSolver.sol:645-663` (`_hop`), `:698-730` (`_sweepSet`) | A mid-plan `onMatchStep` hop that stops at its price limit consumes less than `amountIn`; the unconsumed intermediate token is in no sweep set (only `job.swaps` paths are walked). test_R5: 750 of 1,500 MID parked on the solver, reported profit 0. | Operator funds parked (operator-only recovery via `extraSweep`); dormant — the filler sends `[]` mid-plan swaps | revert when consumed `< amountIn`, or add CALL-step path tokens to the sweep set |
| F-4 | `sdk/src/matchFlash.ts:296-310` | `buildFlashMatchPlan` emits no PULL step; an item that credits `owed − 1` (venue rounding) reverts `LegUnfunded`. test_R7: appending `PULL(0,0)` after the items draws exactly the 1 wei and fills. | Flash path unfillable on a venue that rounds down | append `PULL(0,0)` |

## 2. Contract behaviour that differs from its documentation (operator-side only)

| # | Where | Pinned by | Note |
| --- | --- | --- | --- |
| D-1 | `AggregatorFillSolver._topUp` | P1 | DIRECT inventory top-up ignores `maxPay`; the pull path with the same plan reverts. The `RoutePlan` docs say "`maxPay` still caps the total". The real cap on DIRECT is `inventory`. Fix the doc or check `mp` in `_topUp`. |
| D-2 | `_minOut` (pro-rata floor) | P2, P3, P3b | The quoted word at `amountInOffset` is read as "what the route was quoted for". If it is the whole `owed` while a same-token fee leg is kept back, or an exact-output `amountInMaximum` ceiling, the floor scales DOWN on a FULL fill (95 → 86 with a 10 % fee leg; 95 → 48 with a 2× ceiling). A `type(uint256).max` placeholder overflows and reverts. The filler is clean: it quotes `routeIn = received − kept` (`route.ts:411-428`) and never a loose ceiling. Document the contract rule: the word must be the amount the solver will route. |
| D-3 | `_payOutputs` | P4 | Zero-output orders (route-less fills, admitted since S-7) never compare `minOut` — there is no anchor output. `maxPay` likewise. Document. |
| D-4 | `_minOut` on an empty route | P5 | `amountInOffset < NO_PATCH` on an empty route reads `quoted = 0` (past the end of calldata) → no scaling. Harmless; document that `NO_PATCH` is expected. |
| D-5 | `MatchFlashSolver` `minProfit` | R4 | Floors the swept BALANCE, not the fill's P&L: 1 wei parked before the call satisfies it. Recipient still receives ≥ floor. |
| D-6 | `MatchFlashSolver`, Dutch decay | R2 | Flash sized at the t0 preview; the core prices lower at inclusion; the unused principal round-trips and the fee is paid on it (0.3 % × the decay). Filler already prices the fee on the full `owed`, so realised ≥ priced. Drift is always filler-favourable (outputs only fall, inputs only rise). |
| D-7 | `routeFiller.ts:847-867` | — | `ROUTE_INVENTORY_CAPS` is inert with the filler's own floor (`minOut = owed + cost`, `maxPay = owed`): `_cap` clamps to `owed` with or without inventory, and the direct exact-output route pays `owed` in full so `_topUp` never draws. A non-zero cap only switches a direct plan to the typed callback (+~6k gas). The README row promises more than the plans reach. |
| D-8 | `routeFiller.ts:880` | — | `receipts: []` always: with `ITEM_FILLS` + `NETTED_DELIVERY_FUNDED_ITEMS` on, a foreign ERC-20 receipt is retained (windfall) and an NFT receipt is forwarded to the sandbox and never sold (no `MULTI_ROUTE` is built). Flags default off. |

## 3. Modules: no mismatch

Every new pre-fund branch consumes exactly the core's ledger figure (`ctx.outs[j]`, never
`item.amount`), takes `PreFundGuard.floorOf` on the asset it moves before the venue call,
spends ≤ that under a scoped and cleared approval, and sweeps `balance − floor` to the
maker. Early scheduling fails closed in the core; fee legs cannot be referenced (bit 253).
Design notes, all pinned or documented: Lista `SmartSupplyCollateral` with `coinIndex ≥ 2`
and `minLpRate == 0` is a silent no-op (delivery back to the wallet, no LP; with a rate it
reverts) — same pattern as the pull sibling; Gearbox credit over-repay leaves the
remainder on the credit account rather than the wallet; Midnight `Lend` returns the
unspent delivery to the wallet when the offer is cheaper than the signed rate; bridge
`_fullFillGate` is a floor (excess bridged, refunded after `refundAfter`); Fluid literals
< 10,000 wei revert at the venue (fail closed).

## 4. Verified not a problem (one line each)

- Solver: multi-input PRESENDs every input token (`_schedule`), extras pushed at delta,
  swept back, `RouteOverspent` checked; receipts appended after the order's tokens so
  PRESEND indices are stable; `_splitSurplus` guards `bal <= before` so an inventory draw
  cannot underflow the split; `_cap` bounds the draw by `before[k]` on pull/netted.
- Solver S-7: WNATIVE as `legsIn[0]` is kept back (`LEGS_SAME`) and unwrapped from the
  maker's own input; as a later input it is `_inflow`, netted out of the floor.
- Solver S-3 class (2026-10-05): anchor-output floor still lifts by the pre-route inflow.
- Flash: principal = lens `paid[0]` previewed as the solver = `outputAt` (ceil); 1-wei
  under-flash → `TransferFailed`; stranded pool wei → `BatchNotWhole`, never a fill funded
  by it; repayment paid once, fee cannot be unpaid or double-paid; flash token on both
  sides measured against a post-DELIVER snapshot; `swaps[].minOut` is the pool's reported
  delta (a maker inflow in the flash token does not lift it); callbacks gated by
  FLASHING + payload hash + EXECUTOR.
- Filler: quoted word = routed amount for every admitted shape; sentinel only with a
  patched input, `fillModule == 0`, not direct/item, and when the book's figure is the
  on-chain remainder; item path `minOut = owed + cost ≥ maxPay = owed`, both in the
  anchor output token, gas converted RBTC→token at the higher of pool quote / USD price;
  `expectedFilled` read at `latest` before the first simulation and attached to the tx;
  `liveNonce` for fill-once (OCO) orders; `sweep.ts` keeps floors, never targets a solver,
  runs only when nothing is in flight.

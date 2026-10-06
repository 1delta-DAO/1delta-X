# Pre-ship review: "mismatching amounts" in the matching logic, and the rest of the beta surface (2026-10-05/06)

Scope: the Rootstock-beta fill path as it sits uncommitted on branch
`audit-fixes-2026-09-30` — `AggregatorFillSolver` (both entries: `executeFill`
through `fillWithCallback` and `executeItemFill` through a one-order `matchSettle`
plan), `RouteSandbox`, the core's netted engine (`packages/core/src/settlement/Batch.sol`)
and `Pricing`, and the off-chain filler that drives the solver (`packages/beta-filler`,
`packages/sdk/src/aggregator.ts`). Trigger: a reviewer of the matching logic
reported "mismatching amounts used in some scenarios" without naming them.

Method: one direct trace of every amount the solver measures against every amount
the core resolves, two independent adversarial review agents (on-chain and
off-chain, briefed without the first trace's conclusions), and a Foundry test per
scenario — every scenario below was reproduced numerically before being classed.
Not an external audit; agent-run, like `docs/audit-2026-09-30-full-tree.md`.

**Bottom line: validated, no funds at risk.** The mismatch is structural — the
solver always routes `balanceOf(tokens[0]) − before[0]`, the core always charges the
maker the `owed` it resolved at open — and the two diverge exactly when a token sits
on both sides of an order or when the core's PRESEND hands over something other than
`owed`. Every divergence either reverts or round-trips. One of them was a real gap
in the *solver's own* protection (`minOut`/`maxPay` keyed to the wrong token) and is
fixed; the rest are documented reverts. The beta filler's order filter
(`plainShape`: one input leg, one output leg, no items) admits none of the shapes
that trigger them.

Sections 1–4 answer the reviewer's comment. Sections 5–7 are the second question —
"anything else of that kind before we ship" — over the surface nobody had reviewed
yet: the app ↔ book ↔ filler configuration, the Cloudflare filler runtime, and the
deploy script. **One blocking finding there (§5): the app's market orders could not
be booked at all.** Fixed.

Gate after all changes (2026-10-06): `make test-ts` green (sdk 324, orderbook 133,
auction 78, orderbook-server 45, app 106, orderbook-worker 107, beta-filler 176,
filler-worker 35, both worker bundle checks), solvers 603 / 603 (non-fork, on the
tree with the parallel session's B-1 + typed callback) + the Rootstock fork suite
`RouteSandboxFork.t.sol` 31 / 31 (public RPC), all 29 non-fork module profiles
green (chainlink 26, venus 18, exactly 53, lista 72 after the §8 edits), `make
modules-check`, `make docs-check` and `make size-check` (now including the solver)
pass. The core suite was not re-run here after B-1 (the parallel session's
change). Nothing committed.

---

## 1. Fixed in the contract

### `minOut` / `maxPay` measured the wrong token (solver-protection gap)

`FillRoute.outAnchor` — the token the floor and the cap apply to — was simply
`legsOut[0]`'s token, measured as that token's whole-fill balance delta. Two shapes
break that:

| shape | before | now |
| --- | --- | --- |
| In-kind fee leg listed **first**: `legsIn = [A 100]`, `legsOut = [A 1 → originator, B 90 → maker]` | anchor = A: the floor/cap applied to the **input residue**, B — the actual proceeds — was approved in full with no floor and no cap | anchor = B, the first output token no input leg pays |
| Output token also a second **input** leg: `legsIn = [A 100, B 5]`, `legsOut = [B 90]`, route yields 96 B, `minOut = 100` | pull path **passed** (96 + the maker's own 5 ≥ 100); the netted path reverted (`PRESEND` keeps the 5 in the pool) — same order, opposite outcomes | both revert: the floor is lifted by the pre-route inflow of that token |

Change ([AggregatorFillSolver.sol](packages/solvers/src/aggregator/AggregatorFillSolver.sol)):
- `_plan` (the `anchored` loop at L897): `outAnchor` = the first output token NOT in
  `inMask`; only when every output token is also an input does `legsOut[0]`'s stand.
  On every plain order this is still `legsOut[0]`'s token.
- `_floor(r)` (L1013): the floor passed to `_approveOutputs` / `_pushOutputs` is
  `minOut` plus what the fill paid into the solver in the anchor output token
  *before* the route ran (read at callback entry — the maker's input leg on the pull
  path, the PRESEND on the netted path). Not for `tokens[0]` even when it is an
  output (a same-token order): `_route` pushes that inflow into the route, so the
  post-route delta is already "what the route left or produced". Folded into the
  floor rather than threaded as a seventh argument — that costs no stack word under
  the legacy profile this package compiles with.
- Cost: +46 gas on the pull benchmark, +206 on direct; +186 bytes.
- Pinned: `test_S3_feeLegFirst_minOutFloorsTheProceedsNotTheResidue`,
  `test_S3_outputTokenAlsoInput_makerInflowDoesNotSatisfyMinOut` (both fail against
  the old rule), `test_S3_maxPayIsPerToken`. All in
  [AggregatorAmountMismatch.t.sol](packages/solvers/test/AggregatorAmountMismatch.t.sol).

Classification: no maker exposure at any point (the signed band is the hard bound,
and zero inventory means the solver can only under-fund a delivery). What was false
was the documented operator guarantee "profit ≥ `minOut − maxPay` by construction".
The off-chain filler's own simulation would have caught an unprofitable fill, but the
contract-level guarantee is what an operator forwarding third-party routes relies on.

## 2. Documented reverts — SINCE CLOSED IN THE TREE (2026-10-06)

> Both items below were documented reverts when written. Later on 2026-10-06 a
> parallel session landed task 06 (typed callback `onSettlementFill`: the same-token
> leg is kept back, `amountOutOffset` patches the live price) and task 07 (core B-1:
> `_creditItemProceeds` accrues the crossing part of a credit into `outstanding`).
> The S1/S2 tests in `AggregatorAmountMismatch.t.sol` were flipped to the new
> behaviour (`test_S1_pullPath_patchedRouteKeepsTheFeeBack`,
> `test_S2_nettedPath_overProducingTakeRefundsMaker`); the text is kept as the record
> of what was found.

### S1 — an output leg in the anchor input token is routed differently by the two entries

`legsIn = [A 100]`, `legsOut = [B 90 → maker, A 1 → originator]` (an in-kind
sourcing fee).

- `executeFill`: the core pays the whole `owed` (100 A) to the solver before the
  callback; the solver pushes the whole delta to the sandbox and, with
  `amountInOffset` set, patches the route to swap all 100. Nothing is left for the
  1 A fee leg; the core's pull reverts `TransferFromFailed`.
- `executeItemFill`: `PRESEND` hands over `avail − outstanding[A]` = 99, the pool
  keeps 1 and `DELIVER` pays the fee. Same plan, fills.

So the routed amount is `owed` on the pull path and `owed − Σ same-token outputs`
on the netted path. On the pull path the operator must leave such an order
`NO_PATCH` and quote `received − Σ same-token outputs` (the lens `previewFill`
returns both per leg), use an exact-output route (its residue funds the leg), or
fill through `executeItemFill`. A hard refusal was rejected: patch + same-token
output is legitimate with an exact-output route, whose `amountInMaximum` is the
patched word. A cleaner fix later: net the typed callback's per-leg `priced[]` out
of the routed amount (needs `CallbackMode` bit 1 and a new `onFill` payload).

**Resolved 2026-10-06 (task 06):** `executeFill` now starts a typed callback when an
output leg is in the anchor token and keeps the leg's priced amount back, so the pull
path routes `owed − Σ same-token outputs` too; the first pin was renamed
`test_S1_pullPath_patchedRouteKeepsTheFeeBack` and fills.

Pinned: `test_S1_pullPath_patchedRouteKeepsTheFeeBack` (was `…SwapsTheFeeToo`),
`test_S1_pullPath_unpatchedQuoteMinusFeeFills`, `test_S1_nettedPath_patchedRouteNetsTheFee`.
Documented: contract "SUPPORTED SHAPES" note, `packages/solvers/README.md`.

### S2 — a TAKE item that over-produces its leg cannot fill on `executeItemFill`

`legsIn = [A 100]`, TAKE produces 105 A. The core credits 105, `PULL` draws 0,
`PRESEND` nets only the pool's *output* obligations (`outstanding`), not the
Phase-3 refund of `credit − owed` the maker is owed ([Batch.sol L853](packages/core/src/settlement/Batch.sol)'s
own ⚠ note, lead B-1), so all 105 reach the solver. Patched, the route swaps 105;
unpatched, 5 sit on the solver as residue — either way the Phase-3 refund
([`_matchReconcileInputs`](packages/core/src/settlement/Batch.sol)) finds an empty
pool and the plan reverts `TransferFailed`. The single-order path refunds the maker
(`test_S2_singleOrderPath_overProducingTakeRefundsMaker`). Under-production is fine
(`PULL` draws the shortfall).

Not fixed in the core on purpose: the B-1 change (accrue over-credit into
`outstanding` in `_creditItemProceeds`) touches the netted hot path of a contract at
the EIP-170 wall that the beta does not redeploy. Size TAKE items to the leg —
position-sized fills (`docs/position-sized-fills.md`) resolve both from the live
position — or fill such orders with inventory.

**Resolved 2026-10-06 (task 07):** core B-1 landed — `_creditItemProceeds` adds the
over-credit to `outstanding`, PRESEND nets it, the maker is refunded (+126 bytes of
Settlement). The pin was renamed `test_S2_nettedPath_overProducingTakeRefundsMaker`
and fills.

Pinned: `test_S2_nettedPath_overProducingTakeRefundsMaker` (was `…TakeReverts`). Documented at
`executeItemFill`.

### Smaller items (documented in the natspec)

- `maxPay` is **per token**: two legs in the anchor output token (maker 90 + fee 2)
  need `maxPay ≥ 92`; `maxPay = 90` reverts on both entries. The step list said
  "`legsOut[0]`'s" (`test_S3_maxPayIsPerToken`).
- `lateItems` flagging a TAKE that produces an *input-leg* token: `PULL` has
  already drawn the whole leg from the wallet, the late TAKE credits it again and
  Phase 3 refunds the duplicate — tokens round-trip but the maker's Permit3
  allowance is spent twice for one fill (the asymmetry `Batch._stepPull` documents).
  A late TAKE in a non-input token (borrow after the deposit) is fine. Operator's
  schedule choice on an `ItemPolicy.ANY` order; the maker can forbid it with
  ORDERED / CANONICAL (`test_S2_lateTakeOnInputToken_burnsTheMakerAllowance`: a
  maker with an exact allowance ends the fill at 0 allowance and an unchanged
  wallet).
- When `tokens[0]` is also an output token and the route under-consumes, the netted
  path pushes the unspent input residue to the pool with the outputs and the sweep
  returns it: two extra transfers, no accounting effect. Left as is — skipping the
  push would be wrong whenever `avail < outstanding` for that token.

## 3. Checked and found consistent (on-chain)

- `owed` / `outs` have one source: `_computeOwed` / `_batchComputeOutputs` call the
  same `Pricing.inputOwed` / `outputAt` as `_payInputsToSolver` /
  `_deliverOutputs`; `PULL` credits `owed − credit`, `DELIVER` moves `outs`, the
  reconciliation compares the same words. Pull and netted paths produce identical
  maker/solver numbers for plain SELL, BUY (rising input mid-decay), partial fills,
  a second input token (pre-sent and split as residue on both — AGG-2), same-token
  in/out, under-producing TAKE.
- `PRESEND` cannot reach pre-context pool balance or any order's undelivered
  outputs; a duplicate `PRESEND` sends 0; a stranded pool balance cannot fund a
  short push (`BatchNotWhole`).
- `_plan`'s token order equals `_collectTokens`'s for one order, so `PRESEND`
  indices line up; all Settlement approvals are cleared post-fill; `RouteOverspent`
  holds (no input token below its snapshot); every split is a delta against the
  pre-fill snapshot.
- Proportional anchor: resolved once at open, `owed[0] = ctx.anchor`, `PULL` draws
  the pin. Delta-verify + same-token shapes are refused by the core; `executeItemFill`
  refuses direct orders. FoT anchor + patch always reverts (documented, accepted).
- Rounding: SELL outputs per-fill ceil vs inputs floor can leave a tight partial 1
  wei short → revert on both entries (inherent, maker-favourable).

## 4. Off-chain (beta-filler, SDK)

### Hardened: route path refuses orders whose tick can move maker-ward after the preview

`classifyRoute` ([route.ts L107–111](packages/beta-filler/src/route.ts)) now refuses
priority auctions (timing bit 103 / `priorityScale`), gas-bump orders (`gasBumpBps`,
∝ basefee) and custom `curve`s. The plan's floor/cap (`maxPay`, `amountOut`,
`amountInMaximum`) is the *previewed* `owed`/`received`, `executeFill` →
`fillWithCallback` carries no `minBumpBps` (only `fillUpTo`, the inventory path,
does), and the lens preview is quoted at gasPrice 0 — the no-bid tick of a priority
order. A maker-ward move is a revert on pull and direct-SELL fills but a silent,
band-bounded margin erosion on a direct BUY. Four new tests in `route.test.ts`.

### Known, sized, not fixed: direct-path SELL forgoes the decay since the preview

On a delta-verify (direct) order the route is exact-output for the previewed
`owed`; at inclusion the core only requires `outputAt(block.timestamp)`, which on a
SELL falls with time. On the app's 60-second / 0.5 % market auctions one Rootstock
block (~30 s) is ≈ 0.25 % of notional — 2.5 USDT0 on a 1,000 USDT0 fill, more than
the whole gas + min-profit margin (≈ 2 USDT0) and far more than the 27k gas the
direct path saves. The maker keeps it as price improvement; a direct BUY captures
the rise (the input side is measured on-chain); the pull path captures the decay
as surplus. Fix needs either an `amountOut` priced at an assumed inclusion time
(`DeltaTooLow` if the block lands earlier) or an on-chain `amountOut` patch from the
live tick (solver change). Decision for the operators; sized in
`packages/beta-filler/README.md`.

### Liveness only
- The route size is the book's `fillableAmount`; the lens preview trims an oversized
  slice silently but `fillWithCallback` reverts `OverFill`, so a competing partial
  between the book read and our simulation is a skip + backoff, and one between the
  simulation and inclusion burns a revert's gas (open pull orders only).
- `delivered[0] > owed` guard in `routeFiller.ts` is unreachable (`maxPay` already
  caps the pull inside the same simulation) — harmless.

### Checked and consistent (off-chain)
`amountInOffset` for all four SwapRouter02 encoders and snwap, hand-decoded;
`patchAmountIn` round-trips; Sushi calldata validated fail-closed (`amountIn ==
received`, recipient = solver, tokens pinned, `amountOutMin ≥ owed + cost`); every
unit conversion (`keepIn`, `nativeToUsdToken`, `nativeToTokenAtQuote`, slippage
haircut, `grossUp` by `keepPpm`) in the right denomination; the gas re-price loop
sends exactly the last-simulated calldata at the gas it was priced for; `fillAmount`
sent == previewed; legacy `gasPrice` identical in call / estimate / send.

## 5. BLOCKING — app market orders could never be booked (TTL triangle)

Three shipped defaults share one number and nothing reconciled them:

| where | value | effect |
| --- | --- | --- |
| app `lib/plan.ts` `MARKET_TTL_SECONDS` | **60** | every market ticket signed `expiry = now + 60` |
| book `orderbook-worker/wrangler.toml` `MIN_TTL_SECONDS` | **120** | `admission.ts` refuses it: `422 expires in 60s (min 120s)` |
| filler `filler-worker/wrangler.toml` `EXPIRY_MARGIN_SECONDS` | **90** | `engine.ts` holds any order expiring within 90 s — a 60 s order for its whole life |

So the beta's headline flow — a market order from the app — was refused by the
book, and even if admitted would never have been quoted. Only LIMIT (24 h) and
TWAP tickets passed both gates. No funds involved; the feature simply did not work,
and no e2e harness signs the app's actual shape (both e2e scripts use 3,600 s TTLs
and fixed legs; staging inverts the triangle with `MIN_TTL 15 / margin 6`).

Fix (app side, the smallest coherent change): the order's LIFE and its AUCTION are
now two constants — `MARKET_DECAY_SECONDS = 60` (unchanged auction) and
`MARKET_TTL_SECONDS = 300`: the order decays to its floor over a minute, then rests
at the floor for four more, which is 300 − 90 = 210 s (≈ 7 Rootstock blocks) of
fill window after the book's gate. The crossed-limit ladder keeps its 60 s decay.
`OrderForm` says "5 minutes (1 minute auction, then rests at the minimum)".
Pinned by `test_audit_APP_TTL1_marketTtlClearsBookMinAndFillerMargin` in
`packages/app/test/crossComponent.audit.test.ts`, which reads both wrangler files
so the three numbers cannot drift apart silently again. Side effect worth knowing:
a direct fill that lands after the auction has reached its floor pays exactly
`end`, so the decay forgone in §4 applies only inside the first minute.

Alternatives, if the product wants a 60 s market order back: lower the book's
`MIN_TTL_SECONDS` to 60 and the filler's `EXPIRY_MARGIN_SECONDS` to 30 (one block
of margin — fragile with a 5 s tick plus quote + simulate + send).

## 6. Filler runtime (Cloudflare `filler-worker` + `beta-filler` engine)

No critical or high findings: the money paths — one outstanding tx, commit before
send, same-bytes re-broadcast, receipt settlement, reservation release, strikes —
are consistent and tested. Fixed, each with a test:

- **Alert cooldown consumed by a rate-limited alert** (`alerts.ts`): the per-key
  cooldown was stamped *before* the hourly-cap check, so a key first raised while
  the cap was saturated (an RPC brownout firing a dozen alerts, then `low:RBTC`)
  was silenced for a full cooldown after the cap cleared. Stamped only on a real
  send now (`monitor.test.ts` "alert cap × cooldown").
- **Gas budget double-charged on a same-hash re-send** (`policy.ts` `Budget.spend`):
  a tx dropped at 15 min and re-sent with identical bytes has the same hash, and
  stacked a second full-limit entry the receipt's `settle` never reached — the
  hourly RBTC budget could silently halve. A spend with an existing `(ref, token)`
  now replaces the entry (`policy.test.ts` "Budget reservations").
- **`/status` and `/tick` reasons bypassed `redact()`** (`do.ts`): strategy and
  rebalancer `reason` strings went out un-redacted while `errors`, logs and alerts
  were scrubbed of the keyed RPC URL. Admin-only surface; redacted now.
- **`toISOString()` could throw on an absurd expiry** (`guard.ts` `onRevert`): the
  5th strike's blacklist horizon is capped at the largest `Date`, so `/status` and
  `admit` cannot throw on an order from a book without `MAX_TTL`
  (`policy.test.ts` "backoff horizon"). Real expiries are unchanged.

Documented / accepted (not fixed): a receipt landing after `RECEIPT_TIMEOUT_MS`
leaves `gas_used` from the receipt and `gas_cost_wei` from the limit in the same
fills row (the e2e verifier flags that row; policy choice); a storage failure in
`guard.commit()` leaves an un-broadcast tx pending until the 60 s re-broadcast
(self-heals); a nonce consumed by a hand-replaced tx is only noticed at the 15 min
drop; README wording ("resumes where it stopped after an eviction", "same semantics
as the CLI" — same engine, different bounds). The orderbook-worker diff
(`clientIp.ts` trusts `cf-connecting-ip` only, constant-time binding-key compare,
body caps, rate-limit arithmetic) and the auction guard diff (comment-only) are
clean.

## 7. Deploy script and configuration consistency

Checked and consistent: `DeployAggregatorFill.s.sol` constructs and reads back every
immutable (operators, policy, `SANDBOX` + its `OWNER/SETTLEMENT/PERMIT3/EXECUTOR`),
refuses the removed `ROUTERS / STANDING / PRIME_TOKENS / ALLOW_OPEN`, bounds ppm
before the `uint32` cast, detects EIP-7702 operators; `[profile.solvers-deploy]` is
Cancun (Rootstock has no Prague); every Rootstock address has exactly one spelling
tree-wide (app, filler, book, fork fixtures); decimals (USDT0 6, the rest 18) and fee
tiers agree everywhere; every documented filler default equals the coded default and
the worker's `[vars]`; the app's signed shape passes `plainShape` / `classifyRoute`;
the SDK ABI selectors match the artifact; CI runs both renamed/new TS packages.

Small fixes: the deploy script now mirrors the constructor's `BadSurplusSplit` as
named env errors (ppm sum ≤ 1e6, `PROTOCOL_RECIPIENT` required with a protocol
share); `make size-check` runs `size-check-solvers` too (CI never gated the solver's
size); the SDK ABI gained `MalformedPackedArray()` (the one solver-side revert it
could not decode); `CHAIN_ID` added to the filler README's env table. Left as is:
the three gas figures quoted across READMEs (267k/290k, 247.9k/305.9k, 242.6k/277.6k)
are different measurements (fork net-of-refund vs execution vs unit) and should be
labelled as such.

## 8. Modules — does the claim apply to `packages/modules`? (2026-10-06)

Three independent reviews over every module package (lending A: Aave v2/v3/v4,
Compound v2/v3, Venus, Lista, Morpho Blue/Midnight; lending B: Euler, Dolomite,
Exactly, Fluid, Gearbox, Liquity, River, Silo, Teller, ERC-4626; non-lending: fill,
pricing, transfer, maker, nft, oco, redeem, bridge, plus the shared `packages/lib`
bases every module inherits), each briefed with the classes from §1–3 and the
core↔module amount contract (`Base._runItem` / `_forSlice`, `Core._payInputsToSolver`,
`Batch._creditItemProceeds` / `_stepPresend`). Baseline: all 29 non-fork module
profiles green (one Gearbox fork test needs an archive RPC), `make modules-check`
(16 seam rules) passes. None of these modules is on the beta's ship path — the app
signs `items = []`, `fillModule = pricingModule = 0`.

**Verdict: yes, the class exists in three places; none loses funds; two fixed, one
documented.** The modules are uniformly built on the pattern that defeats the
class — call the venue for exactly the slice on an exact-or-revert venue, or take
custody, measure a delta, `requireDelivered`, forward `min(received, amount)` and
sweep the surplus to the maker — and every `positionOf` reports in the asset the
leg is priced in. The exceptions:

| # | where | class | outcome |
| --- | --- | --- | --- |
| M1 | `ChainlinkPeggedPriceModule._band` read `legsOut[0]` BY INDEX as the maker's band (SELL) / anchor (BUY) — the exact §1 S3 shape: an in-kind fee leg listed first made the peg silently degrade to a fixed limit at the maker's ambition (SELL: fee leg fixed ⇒ `end == 0` ⇒ bump 0; BUY: fee-sized anchor ⇒ `fair ≪ start` ⇒ bump 0). Maker-favourable in direction; the order never tracks the oracle it was signed to track. | floor keyed to the wrong leg | **FIXED**: the band/anchor is the first maker-addressed output leg (`recipient == 0 ∨ == maker`), `NoBand` when none. `maker` is read from `msg.data` (selector-checked) because `bump`'s nine parameters leave no stack room to pass it under the legacy profile. `test/ReviewPeggedFeeFirst.t.sol` (4 tests, all fail on the old rule). |
| M2 | `VenusTakerModule` `Op.Borrow` was cap-only — measured the delta and forwarded `min(received, amount)` but, unlike both withdraw branches (G-VENUE_A-2), had no `requireDelivered`; its own comment said "fail closed" and it did not. A short borrow (fee-on-transfer underlying, capped market) was forwarded short and the core billed the gap to the **maker's wallet** while the maker kept the full debt. Gated by deployment assumption A1 ("no FoT reserve"), hence LOW. The shapes checker's rule 9 is whole-function, so the withdraw branches satisfied it. | TAKE under-production billed to the wallet | **FIXED**: one `requireDelivered` line; `test_review_venusBorrow_shortDelivery_reverts` / `_exactDelivery_forwards`. |
| M3 | `ListaSmartTakerModule`: `item.amount` is LP units, the delivery is coin units, the core prices `legsIn[0]` in coin — nothing ties `minOutRateE18` to the leg's `owed`. Under-delivery is billed to the wallet unless the maker signs `minOutRate · amount / 1e18 ≥ legsIn[0].start`; over-delivery (the normal case for a StableSwap one-coin removal) is refunded. No `IProceedsAsset` (the coin is `dex.coins(i)`, not in `data`), so the lens preflight is skipped for it. | unit split | **DOCUMENTED** in the byte-map header (the maker-side rule, the skipped preflight); task 11 — resolved 2026-10-06 (`proceedsAsset` via `provider.dex().coins(i)`, lens floor rule via `ITakeFloor`). |

Documented, no code change (all class (c) or venue-by-design):
- `ExactlyTakerModule` fixed-maturity withdraw legitimately pays `assetsDiscounted <
  amount` before maturity; the core bills the discount to the maker's wallet and the
  only bound is `minAssetsRequired`, which may be signed 0 (every existing test warps
  past maturity). Header now names it the maker's wallet-draw cap; task 12 — resolved 2026-10-06 (lens flags the zero floor, pre-maturity fork test, pull `repayAtMaturity` twin fixes).
- `PreFundGuard.floorOf` NatSpec claimed exactness "under delta-verify" — false
  (delta-verify is `>=`; a solver over-delivery to a pre-fund module strands below
  the floor). Corrected.
- `DustHandler.readAction` is untagged where `readBalanceMode` is tagged: an auth
  tail's first word can read as `Recycle`. Benign, maker-signed; documented, not
  re-encoded (BREAKING).
- `FundingPreflight.pullable` reads the maker's balance BEFORE the fill's own
  delivery, so the lens under-reports a pull-form leg reference as unfunded
  (fails closed in the preview only); task 13 — resolved 2026-10-06 (lens counts the fill's own delivery).
- `FunnelGrantModule` grants `_prorate(item.amount)`, which no constant can match
  for an auctioned (BUY / rising) input leg — fails closed; and `approveTaker`
  overwrites a sibling order's byte-identical grant. Task 13 — resolved 2026-10-06 (documented in the module NatSpec and bridge README).
- Every `FullFillGuard`-protected item is unusable on a `PositionFillModule` order
  (the slice is unknowable at signing) — correct, undocumented in
  `docs/position-sized-fills.md`; task 13 — resolved 2026-10-06 (documented).
- Shapes-checker gaps the reviews named: rule 9 is whole-function not per-branch
  (M2 slipped through); no rule can express "amount unit ≠ delivery unit" (M3) or
  "a venue that under-delivers by design must carry a non-zero maker floor"
  (Exactly). Task 14.

Checked and consistent (one line per package; the full per-op lists are in the
three agent reports): Aave v2/v3/v4 (lattice-aligned Full withdraw, repay clamps,
pre-fund floors), Compound v2/v3 (ceil'd cToken pull + `redeemUnderlying`, Comet
`WouldBorrow` on the same present-value read), Lista (broker literal-pull/refund,
native unwrap delta), Morpho Blue/Midnight (repay by shares vs assets exact,
`positionOf` collateral-only), ERC-4626 (two-phase redeem, `min(received, amount)`),
Teller, Silo, River (`RiverProceeds` direction-agnostic), Euler (repay clamps to
`debtOf`'s own `toAssetsUp`), Dolomite (Wei/Delta exact, `WouldBorrow`), Exactly
(beyond the two notes), Fluid (`_returnUnused`, native delta bound), Gearbox (pool
withdraw grossed up by fee), Liquity/Felix (`min(amount, entireDebt)`, fee linear in
the mint); lib (`ProratedBound` floors, `PreFundGuard.fundingToken` bit-identical to
the core's descriptor, `DustHandler` residues never reach the pool, `Narrow160` on
every data-derived pull, `PositionFillModule` three-amounts rule); fill (TWAP parts
exact), pricing (quote modules bind `prevFilled`, Chainlink joint solve verified
algebraically), transfer (`NativeUnwrapModule` unwraps exactly `ctx.outs[j]`,
`ProportionalSweep` sums to `min(B, cap)`), maker, nft, oco, redeem, bridge (inbox
`filled ≤ anchor ≤ credited − refunded`, bridge-out floors, LZ sponsorship debited at
the quote by design).

## 9. Files touched

- `packages/solvers/src/aggregator/AggregatorFillSolver.sol` — anchor rule, `_floor`,
  docs (S1, S2, `maxPay` per token, late TAKE).
- `packages/solvers/test/AggregatorAmountMismatch.t.sol` — new, 9 tests.
- `packages/solvers/README.md`, `packages/sdk/src/aggregator.ts` (RoutePlan docs).
- `packages/beta-filler/src/route.ts`, `test/route.test.ts`, `README.md`.
- §5: `packages/app/src/lib/plan.ts`, `src/components/OrderForm.tsx`, `README.md`,
  `test/crossComponent.audit.test.ts`.
- §6: `packages/filler-worker/src/{alerts,do}.ts`, `test/monitor.test.ts`;
  `packages/beta-filler/src/{policy,guard}.ts`, `test/policy.test.ts`.
- §7: `packages/solvers/script/DeployAggregatorFill.s.sol`, `Makefile`
  (`size-check`), `packages/sdk/src/aggregator.ts`, `packages/beta-filler/README.md`.
- §8: `packages/modules/pricing/chainlink/src/ChainlinkPeggedPriceModule.sol` +
  `test/ReviewPeggedFeeFirst.t.sol`; `packages/modules/lending/venus/src/VenusModules.sol`
  + `test/security/Audit20260930Venus.t.sol`; headers/NatSpec only in
  `packages/modules/lending/exactly/src/ExactlyModules.sol`,
  `packages/modules/lending/lista/src/ListaSmartModules.sol`,
  `packages/lib/src/{PreFundGuard,DustHandler}.sol`.

## 10. Follow-up candidates (not blocking)

1. Core B-1: accrue `credit − owed` into `outstanding` as it happens, making the
   `PRESEND` bound self-sufficient (unblocks over-producing TAKEs on the netted path).
2. Typed-callback `onFill`: net same-token output obligations out of the routed
   amount (closes S1 on the pull path) and patch a direct route's `amountOut` to
   the live tick (reclaims the decay in §4).
3. `fillWithCallback` has no `minBumpBps`; adding one would give the route path the
   same on-chain price floor the inventory path has, instead of refusing the shapes.
4. An e2e run that signs the app's real market shape (60 s decay, bit 104,
   `exclusiveFiller` = solver, production `MIN_TTL` / `EXPIRY_MARGIN`) — the only
   thing that would have caught §5 before a user did.
5. Filler runtime: settle gas on any receipt (also after the timeout), compare
   `getTransactionCount` with the pending nonce on the overdue path, roll back the
   in-memory pending on a failed `commit()`.

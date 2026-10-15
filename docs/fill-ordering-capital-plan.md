# Fill ordering and filler capital — analysis and plan (2026-10-14)

**Status:** analysis + plan. Generalises the native-out flaw in
[native-rbtc-delivery-plan.md](native-rbtc-delivery-plan.md). Task 31 tracks the build.

## 0. Verdict

- **The native-out flaw is one case of a general rule.** On the single-order path,
  items run only in the forward ordering, where the filler delivers outputs before
  the maker pays it. Any order with an item that **consumes a delivery** therefore
  needs filler capital (inventory, or a flash loan per output token). This covers
  native-out, **all 15 pre-funded lending modules** (swap→supply, swap→repay),
  **every SETTLE order** (OCO / TP-SL bracket legs, NFT and 1155 sales,
  proportional sweeps), and a future Uniswap v3 LP mint (one flash per token, so
  two).
- **The zero-capital engine already exists.** `matchSettle` runs a schedule the
  solver writes, and `AggregatorFillSolver.executeItemFill` already writes the
  right one: source items → pull inputs → presend → route → deliver → sink items.
  Two things block it: one shape guard in `Batch._assertMatchShape`, and one
  missing write of the delivery ledger in `_stepDeliver`. The core fix is about
  two lines and probably adds no bytes.
- **After the fix, only true cycles need capital.** A cycle is a borrow that needs
  the collateral this same fill delivers, or a withdraw that needs the repay this
  same fill delivers. These are leverage open and close at the LTV edge. They need
  **one** flash wrapped around the whole plan, or a counter-order to net against.
  Never two.

## 1. Where items can run today

| Entry | Order of steps | Items | Filler capital |
| --- | --- | --- | --- |
| `fill`, `fillUpTo`, `batchFill`, `fillWithPermit*`, `fillSelf` | deliver → items → pay inputs | yes | **always**: the filler pays the outputs before it receives anything |
| `fillWithCallback(PreDelivery*)` | callback → deliver → items → pay inputs | yes | **always**: the callback runs before any input arrives |
| `fillWithCallback(PostInputs*)` | pay inputs → callback → deliver | **refused** (`ReverseModeRequiresNoItems`) | none |
| `matchSettle` (one order or many) | the solver's schedule | pull MAKE, TAKE only. Refuses pre-funded MAKE, TAKE_FOR, SETTLE and delta-verify orders | none, **if the schedule has no cycle** |

A fill needs zero capital exactly when the maker's inputs can be paid before the
outputs are delivered. The single-order path offers that only to item-free orders.
`matchSettle` offers it to any order, but its shape guard refuses the items that
need it most.

The deployed beta filler calls only `executeFill`, so today **no order with an item
of any kind gets filled on Rootstock**.

## 2. The dependency model

Every item is a source, a sink, or both:

- **Source**: it produces value that pays the filler. TAKE (a withdraw or borrow
  whose proceeds are credited to input legs) and SETTLE (the maker's asset goes to
  the filler).
- **Sink**: it consumes what the fill delivered. A pre-funded MAKE (deposit, repay,
  unwrap, LP mint) or a pull MAKE (bridge-out, or a deposit taken from the wallet
  after delivery).
- **Both**: the TAKE_FOR composites (`AaveV3Fused`, `Dolomite`, `EulerV2`,
  `Fluid`), which deposit the delivered collateral and borrow in one call.

A zero-capital schedule exists exactly when this chain has no back edge:

```
sources → pull inputs → route (CALL) → deliver outputs → sinks
```

A back edge appears only when a source needs a sink to run first, which is a
health rule of the venue:

- **open leverage**: the borrow needs the deposit of the collateral the fill
  delivers;
- **close or deleverage**: the withdraw needs the repay the fill delivers;
- **collateral swap or debt swap**: a cycle only when the position has no headroom
  for the source to go first. With headroom they are acyclic and need no flash.

## 3. Blast radius

| Shape | Example | Item kind | Zero capital today | After §4 |
| --- | --- | --- | --- | --- |
| item-free swap | market / limit order | — | yes (`executeFill`) | yes |
| sell out of a position | withdraw aUSDC → sell | TAKE (source) | yes (`executeItemFill`, early item) | yes |
| swap, then a wallet-funded sink | swap → Across / CCTP / LZ bridge-out; pull-deposit | pull MAKE (late) | yes, but the maker must approve the module, through Permit3, for a token they may never have held | yes |
| **swap into a position** | swap → supply, swap → repay (15 pre-funded lending modules) | pre-funded MAKE | **no** | **yes** |
| **native out** | USD₮0 → RBTC | pre-funded MAKE (`NativeUnwrapModule`) | **no** (task 30 works around it) | **yes**, through the module as well |
| **LP mint** (no module yet) | USDC → v3 position | pre-funded MAKE over 2 legs | **no**: 2 flashes | **yes** |
| **TP / SL bracket leg** | OCO claim | SETTLE | **no** (PRICE-12) | **yes** (§4.2) |
| **NFT / 1155 sale** | sell an NFT for USDC | SETTLE | **no**: the filler fronts the payment | yes, if the solver can sell the asset in its CALL step |
| sell 100% of a balance | `ProportionalSweepModule` | SETTLE | **no** | after the module review (§4.2) |
| leverage open / close at the edge | the 4 composites | TAKE_FOR / cycle | no | **one** flash around the plan, or a counter-order |
| delta-verify (DIRECT) order with an item | — | any | no | no. This stays refused, because the recipient-delta attribution needs it |
| first fill of a single-signature permit order | `PermitBatchWitness` | — | no: that entry has no callback | no. Same class, tracked separately (§4.6) |

The pre-funded shapes exist to remove receive-side approvals: the maker approves
nothing for the token the fill delivers. They are exactly the shapes the
zero-capital path refuses. So today a maker can have either no extra approval or a
zero-capital fill, never both.

## 4. Plan

### 4.1 Core: admit delivery-funded items in `matchSettle` (one Settlement redeploy)

Two edits in `packages/core/src/settlement/Batch.sol`:

1. **`_stepDeliver`**: once the transfers are done, hand the order its delivery
   ledger, as `_settleForward` does (`ctx.outs = outs`):
   `st.fills[i].outs = amts;`
2. **`_assertMatchShape`**: drop `|| _isPreFundDesc(idata)` and admit `TAKE_FOR`
   (op 3). SETTLE stays refused until §4.2 is reviewed, or is admitted together
   with it.

Why this is enough (the argument the review has to check):

- **Delivery before the item is now enforced by the core, not left to the
  solver.** `Base._forSlice` already fails closed on an empty ledger
  (`j >= outs.length` → `ForLegInvalid`). An item scheduled before its order's
  DELIVER reverts. An item scheduled after it reads the amount actually delivered.
  The guard's own comment names this as the missing piece ("a scheduling
  obligation the netted engine does not currently enforce").
- **Residue.** The guard's other worry was that the item "would silently consume
  whatever residue was sitting there". That only happens when the item runs before
  delivery, which now reverts.
- **A shared singleton with interleaved orders** (DELIVER A, DELIVER B, then ITEM A
  on the same module). `PreFundGuard.floorOf` sets the floor at balance minus
  `forAmount`, and the module sweeps only what lies above it. So ITEM A spends
  exactly `a` and leaves B's delivery for ITEM B. **This must be tested on every
  pre-fund module.** The 13 modules that sweep their surplus are the ones where it
  matters.
- **Leg reuse.** `outsUsed` lives in `st.fills[i]`, which persists across steps,
  so a second claim on one delivered leg still reverts (`ForLegInvalid`).
- **Proceeds.** `_stepItem` already measures the whole token universe around every
  op. TAKE_FOR proceeds credit the input legs, and any other token goes back to
  the maker (`_creditItemProceeds`).
- **Cycles.** A TAKE_FOR leverage order still needs its DELIVER funded first. With
  no flash and no counter-order, the plan reverts `BatchNotWhole` /
  `LegUnfunded`. This is the same outcome as today on that path, so no new failure
  mode.

**Size.** Settlement is at 24,480 / 24,576 (96 B free, task 08). Removing the
guard frees bytes and the store costs a few, so expect a net change ≤ 0. Measure
from a wiped `out/core-deploy`.

### 4.2 SETTLE on the netted path (separate review, same redeploy)

Admit SETTLE. The filler is already `msg.sender` (`ctx.filler`). Review each
module:

- **`OcoGroupModule`: safe as is.** On the netted path validators run at OPEN,
  for every order, before any claim. So both legs of a group can pass the gate in
  one plan. The claim item itself reverts `GroupAlreadyClaimed`, which saves it.
  Checked in the code.
- **`NftSettlementModule` / `Erc1155SettlementModule`**: full-fill only, and they
  send to the filler. Safe. To fill with zero capital, the solver must be able to
  sell the asset in its CALL step.
- **`ProportionalSweepModule`**: sizes from the maker's balance. Under a free
  schedule, that balance can include deliveries from the same plan. Review it, and
  add a module-side guard if needed.
- **`LzOftBridgeOutModule.settle`**: review.

A rule to write into `deferred-match-settle.md`: **on the netted path, a module
whose safety depends on a validator seeing the effect of another order's item must
enforce that check in the item itself.**

### 4.3 Solver v3 (needed anyway, because `SETTLEMENT` is an immutable)

- `executeItemFill`: the schedule is already correct. Pre-funded items are flagged
  late.
- SETTLE receipts land on the solver, not the pool. The route must be able to sell
  them, and the delta-only rule covers them if the snapshot is taken before
  `matchSettle`.
- Multi-output routes (an LP mint has two output legs).
- Fold in task 30: `NativeBalance` unwrap-and-send remains the cheaper path for a
  plain native-out (~+20–25k, against the item plus the `matchSettle` overhead).
- Tasks 16 and 17 (`executeItemFill` ignores `amountOutOffset` / `minBumpBps`)
  start to matter once item fills carry traffic. Fix them in the same build.

### 4.4 Filler

- A shape classifier:
  - item-free → `executeFill`;
  - acyclic items → `executeItemFill`, with `lateItems` derived from each item's
    kind (sources early, sinks late);
  - a cycle → the flash family, or skip;
  - DIRECT with items → skip.
- Gas defaults learned per shape, including the `matchSettle` overhead.

### 4.5 The cyclic remainder

Wrap `matchSettle` in one flash (the `BaseFlashSolver` family), or use credit
from the venue itself. Because the plan nets, one flash in the cycle's token
covers it, never one per output leg. Which flash sources exist on Rootstock is
outside this plan.

### 4.6 Not recommended, or later

- **A third single-order `CallbackMode`** ("PostInputs with items": TAKE / SETTLE
  → inputs → callback → deliver → MAKE). It would avoid the `matchSettle`
  overhead: roughly +45k, from the solver unit suite's 293k vs 339k totals for the
  same item-free order (a rough figure, to be measured properly). But it costs
  Settlement bytes we do not have, and it duplicates `matchSettle`. Revisit only if
  the measured overhead on the busiest shapes matters.
- **A native sentinel in Settlement**: unnecessary once §4.1 and task 30 land.
- **The first fill of a single-signature permit order**: `matchSettle` verifies
  only order signatures. Same class (no callback, so capital first). Separate item.

## 5. Sequencing

1. **Now, no Settlement change:** task 30 (`NativeBalance`) for native-out. The
   app keeps hiding shapes no deployed filler can fill.
2. **With the audited rollout** (a new Settlement address, so every maker
   re-approves anyway): §4.1, plus §4.2 if its review passes, solver v3, and the
   filler classifier.

## 6. Acceptance

- **Core:**
  - a one-order `matchSettle` fills a pre-funded MAKE (Aave supply,
    `NativeUnwrapModule`) with zero solver capital;
  - the item scheduled before DELIVER reverts `ForLegInvalid`;
  - two orders interleaved on one module both settle exactly;
  - a second claim on one delivered leg still reverts;
  - an unfunded TAKE_FOR leverage plan reverts, and passes with a counter-order;
  - the `doMatchSettle` invariant walk gains pre-funded cells;
  - `make size-check` passes from a clean build.
- **Solver:** `executeItemFill` fills native-out through the module, swap→supply,
  and an OCO bracket leg, each with zero inventory.
- **Filler:** the classifier routes every row of §3 to its path, or refuses it with
  a reason.

## 7. What was built (2026-10-14, branch `zero-capital-item-fills`)

Everything in §4.1–§4.5 except the third callback mode (§4.6), which is assessed
separately. Three deviations from the plan, each forced by something found while
building it:

1. **The BALANCE-form `TAKE_FOR` stays refused on the netted path.** It reads
   `min(balanceOf(token, maker), cap)` when the item runs, so the schedule would decide
   whether this plan's deliveries are in the wallet at that moment. It loses nothing:
   the form exists for orders with no output leg, which the forward path already fills
   with zero capital. The refusal and the op-range check share one comparison
   (`op + bal > TAKE_FOR`).
2. **ORDERED and ATOMIC now carry the PULL rule (core).** The SDK signed CANONICAL by
   default for any order whose TAKE funds an input leg (ACCEPTED-PATTERNS-REVIEW B8).
   CANONICAL is the forward shape, so every "sell out of a position" order would still
   have needed capital. Under ORDERED/ATOMIC a `PULL` now waits for every non-MAKE item
   of its order (mask built in `_assertMatchShape`, stored per order at open), without
   waiting for the delivery. The SDK default moved to ORDERED; the lens flags only ANY.
   A borrow-to-wallet TAKE that must run after the delivery now needs ANY.
3. **No new `ItemPolicy` value.** A separate SAFE level (CANONICAL's two value rules
   per op, without the forward shape) measured +226 B. Settlement does not have that.

**Size.** Settlement 24,480 → **24,571 / 24,576** (clean `core-deploy` build), so 5 B
are left. `AggregatorFillSolver` 20,779 → 22,777 (after `sweepAll` and the 2026-10-15 hand-encoded `matchSettle` call).

**Built:**

- **Core** (`Batch.sol`): the shape guard admits SETTLE, pre-funded MAKE and
  TAKE_FOR; `_stepDeliver` writes the delivery ledger; the ORDERED/ATOMIC PULL rule.
- **Solver v3:**
  - `NativeBalance` delivery (`nativeDelivery()`);
  - tasks 16 and 17;
  - `GuardedMatchSolver` refuses SETTLE (`SettleUnsupported`), because it cannot move
    what a SETTLE item pays it.
- **Modules:** reviewed for the netted path; no fix needed (16 pre-fund modules,
  4 composites, the SETTLE modules). Two NatSpec notes added.
- **Off-chain:**
  - SDK: `nativeOutLeg`, `classifyItemFill`, ORDERED default;
  - filler: native direct path and the item-fill classifier, both behind config;
  - app: the RBTC entry signs the `NativeBalance` shape;
  - book: `NATIVE_BALANCE` allowlisting and misuse refusal.
- **Tests:**
  - core: `MatchSettleDeliveryFunded.t.sol`, ItemPolicy cases, refusal tests converted;
  - invariant walk: pre-funded orders on a shared module, a targeted
    item-before-delivery mutation, and a mutant check;
  - per-module netted tests;
  - solver: native, zero-capital item and guard tests, plus a Rootstock fork test of
    native delivery against the live Settlement.

**Independent security review (2026-10-14):** no critical, high or medium findings.

- **L-1, fixed.** Two different native views on one DIRECT order could both be
  satisfied by one send. The solver now refuses any other output leg to the native
  recipient (`test_native_secondLegToSameRecipientRefused`). The filler never signed or
  filled that shape anyway (it requires one input leg and one output leg).
- **I-1 and I-2, documented** on `ItemPolicy`: the PULL mask is keyed on the op, not on
  what an item produces.
- **I-3, already closed by the book.** The lens cannot recognise the view token. Pull
  or item-bearing NativeBalance orders always revert, and the worker's
  `nativeBalanceMisuse` keeps them out of the book.
- **I-4, open.** An early SETTLE receipt in the anchor token counts toward the
  operator's own `minOut`. It is operator-only and an odd shape.
- **I-5, open.** Netted interleaving tests exist only for the mock, `NativeUnwrapModule`
  and Aave v3. The other pre-fund modules were checked by reading their code.

**Not done / remaining:**

- deploy `NativeBalance` + solver v3 (task 30);
- the next Settlement version (task 31);
- the filler's solver address is still a single value, so v2→v3 migration is open;
- SETTLE receipts in a foreign token are retained on the solver, not routed;
- pool routes are single-output.

## 8. Assessment: the third callback mode (§4.6), measured 2026-10-14

**The mode.** `PostInputs` extended to admit items: non-MAKE items (TAKE, SETTLE) →
pay inputs → callback → deliver → MAKE items. It refuses ATOMIC and CANONICAL orders,
and refuses an ORDERED order whose MAKE is signed ahead of a non-MAKE item. It was
prototyped in a scratch copy, not in the tree. Measured on the deployed via-IR solver
bytecode; execution gas, one call per fresh test:

| Fill | Today | Third mode | Δ |
| --- | --- | --- | --- |
| item-free pull order, `executeFill` | 318,243 | 318,244 | +1 (hot path untouched) |
| item-free pull order, `executeItemFill` (netted) | 395,456 | — | the netted path's fixed overhead: **+77.2k** over `executeFill` |
| swap → supply (pre-funded MAKE) | 452,677 (`executeItemFill`) | 374,283 (`executeFill`) | **−78.4k (−17%)** |

The saving is real. It is the netted engine's fixed cost: the token-universe snapshot,
the per-item 2·|tokens| balance reads, the plan's memory, and the sweep. On Rootstock
that is roughly $0.15–0.20 per item fill.

**Bytecode.** The prototype costs **+470 B** of Settlement. 5 B are free. The
configuration lever is spent: `optimizer_runs` is already 100, and `runs = 1` measured
about −32 B on this tree. Putting both flows in one settle body measured worse
(+1,142 B). So the mode fits only if existing code goes. Removal candidates, each
measured on its own from a clean `core-deploy` build:

| Remove | Settlement | Freed |
| --- | --- | --- |
| nothing (current tree) | 24,571 | — |
| `fillWithPermitTake` | 24,457 | 114 |
| the 4-arg `batchFill` (keep the 6-arg overload with `minBumpBps` + `takerDatas`) | 24,148 | 423 |
| the 6-arg `batchFill` (keep the 4-arg) | 24,010 | 561 (drops the PERIPH-1.v3 per-order price floor — not acceptable) |
| **third mode + only the 6-arg `batchFill`** | **24,618** | 42 over |
| third mode (sharing the forward item loop) + only the 6-arg `batchFill` | 24,608 | **32 over** |

**Verdict: feasible, not free.** It needs two things:

1. A breaking ABI change: `batchFill` collapses to the 6-arg overload. Callers pass
   empty arrays and the length check allows them, which costs a few bytes back.
2. About 40 more bytes: `runs = 1` (which costs gas on every fill), another removal,
   or more shaving of the prototype.

It also needs its own audit. In this mode, maker-chosen module code (the non-MAKE
items) runs before the filler's callback. That is the same filler-side MEV class as
X-TOKENS-5, now reached through item code as well as token hooks. Delta-verify
attribution needs the recipient snapshot taken after those items; the prototype does
this.

**Recommendation:** do not add it to the audited rollout by default. `matchSettle`
already fills every acyclic shape with zero capital. Native-out, the busiest item shape,
avoids items entirely through `NativeBalance`. Revisit once item-bearing volume makes
about 78k gas per fill matter. At that point, decide the `batchFill` overload change
together with the audit scope.

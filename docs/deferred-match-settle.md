# Deferred match settle — order matching without inventory, without re-entrancy

> **Status: IMPLEMENTED** (`Settlement.matchSettle`, core **374 green**).
> Replaces `batchSettleItems`. Generalizes the per-order `sequence` into a **step
> schedule**, and moves every per-order check (input funding, invariants) into a
> single **deferred flush** at the end of the context. All bookkeeping lives in
> **memory**; no storage, no transient storage. The headline —
> `test_cycle_mutualLeverage_zeroCapital` in `core/test/swaps/MatchSettle.t.sol` —
> settles a mutually-dependent leverage pair that has **no valid order-granular
> ordering** with a solver holding nothing. Sections marked *(as built)* record
> where the shipped code differs from the original sketch.

## 1. The problem

Matching two orders against each other — rather than against a solver's balance
sheet — needs one order's execution to be *interrupted* by another's. The natural
implementations are both unavailable:

* **Callback re-entry.** `fillWithCallback` runs a solver hook mid-fill; the hook
  would call back into `fill` for the counter-order. `nonReentrant`
  ([Base.sol:114](../packages/core/src/settlement/Base.sol#L114)) blocks it — and
  should. Every accounting path in the settler is a **balance delta measured
  across a window** (`_snapshotInputs`, `_presendSurplus`, `_sweepSurplus`). A
  nested fill inside one of those windows makes another order's pooled inputs look
  like this order's proceeds. `_sweepSurplus` hands the entire positive delta to
  the caller; an inner sweep firing inside an outer batch's window would pay out
  the outer batch's pooled inputs. It reverts rather than steals, but the safety
  argument stops being checkable.

* **Solver inventory.** The fallback today: the solver fronts the transient peak.
  That is exactly the capital requirement CoW netting exists to remove.

`batchSettleItems` ([Batch.sol:485](../packages/core/src/settlement/Batch.sol#L485))
gets close — a shared pool, no solver capital — but its execution unit is the
**whole order**. [`_execOrderNetted`](../packages/core/src/settlement/Batch.sol#L642)
runs a fixed body:

```
deliver outputs → _executeItems → settle inputs → invariants
```

and `sequence` only permutes *orders*. So an order's items can never run before
its own delivery, and two orders that need to interleave — the mutual-leverage
cycle below — have **no valid `sequence`**:

```
A delivers WETH ← needs B's borrow ← needs B's USDC collateral
                                   ← needs A's borrow ← needs A's WETH collateral
```

## 2. The central decision: memory context ⟺ no external re-entry

EVC needs transient storage because its checks-deferred context must survive
across *arbitrary* external call frames — any vault, anywhere in the call tree,
calls back into `EVC.requireAccountStatusCheck`. The context is global mutable
state by necessity.

We do not need that, because **a settlement's participants are known at call
time.** If the solver declares the whole match in calldata, the entire deferred
context can be one `struct` in memory, threaded by pointer through internal
functions — never crossing a call boundary, never touching a storage slot.

| | EVC | here |
| --- | --- | --- |
| context lives in | transient storage (global) | **memory (one frame)** |
| participants known | discovered during execution | **declared in calldata** |
| re-entry | required, and made safe by the context | **forbidden; not needed** |
| cost of bookkeeping | ~100 gas per `tstore` | ~3 gas per word + quadratic term |

**This is the answer to "callbacks are unsafe for re-entering the order": we do
not re-enter.** The interleaving that a re-entrant callback would express becomes
a *step schedule* executed inside a single frame. `nonReentrant` stays exactly as
it is — the strongest possible statement — and the composition it used to forbid
is now expressible without it.

The cost is a real limitation, stated once here and not softened: **the plan must
be computable off-chain.** Anything that needs on-chain discovery (an amount only
known after a swap lands) must be over-declared, or expressed through a
`fillModule`. That is the same bargain `pullMask`/`sequence` already made.

## 3. Shape

One new entry point. The single-order hot path in
[Core.sol](../packages/core/src/settlement/Core.sol) is untouched.

```solidity
struct MatchPlan {
    Order[]   orders;
    bytes[]   sigs;
    uint256[] fillAmounts;
    bytes[]   takerDatas;          // per-order blob → validators + invariants ("" allowed)
    uint256[] schedule;            // packed steps, executed verbatim in order
    address[] callTargets;         // optional solver interactions, selected by a CALL step
    bytes[]   callDatas;
}

function matchSettle(MatchPlan calldata p) external nonReentrant returns (uint256[][] memory outs);
```

Three phases:

```
PHASE 1  OPEN      per order: gates → _openFill (writes `filled`) → compute outputs
                   derive token universe, snapshot balances, seed `outstanding`
PHASE 2  SCHEDULE  execute the solver's steps verbatim (the only ordered part)
PHASE 3  FLUSH     deferred: completeness → input reconciliation → invariants
                   → pool whole-check → sweep
```

Phase 1 and Phase 3 are contract-owned loops over every order — no solver input,
so nothing can be skipped. Phase 2 is the only solver-controlled region, and it
can only move money the two contract-owned phases account for.

## 4. The memory context

```solidity
/// Whole deferred context: one memory pointer threaded through every helper.
/// Nothing here is ever written to storage or transient storage.
struct MatchCtx {
    // token universe — deduped union of every order's legsIn/legsOut (_collectTokens)
    address[] tokens;        // m
    uint256[] beforeBal;     // m — pre-context balance snapshot
    uint256[] outstanding;   // m — output obligations not yet delivered

    // per order (n)
    FillCtx[]   fills;       // resolved fill context (from _openFill)
    uint256[][] outs;        // n × legsOut — output amounts, computed at open
    uint256[][] credit;      // n × legsIn  — value credited to each input leg
    uint256[]   done;        // n — packed progress mask (below)
}
```

`done[i]` packs progress into one word per order *(as built)*:

```
bits [  0, 255)   item k executed
bit  255          outputs delivered   (DELIVERED_BIT)
```

An order carrying more than 255 items reverts `LengthMismatch` at open
(`_assertMatchShape`), so the two ranges can never collide and the Phase-3
completeness mask `((1 << items.length) - 1) | DELIVERED_BIT` stays exact.

**Memory cost.** For a 4-order match with 6 tokens and ~2 legs / 2 items per
order: `tokens`+`beforeBal`+`outstanding` ≈ 21 words, `fills` ≈ 37, `outs` ≈ 17,
`credit` ≈ 17, `done` ≈ 5 → **≈ 100 words**. Orders themselves stay in calldata
(never ABI-decoded into memory). Memory expansion at 300 total words is
`3·300 + 300²/512 ≈ 1.1k gas`; at 1000 words ≈ 5k. Against a settlement that
already spends 6-figure gas on transfers and module calls, the context is free.

Equivalent transient-storage bookkeeping would be ~2–4 `tstore` per step
(100 gas each) plus reads — comparable at best, unavailable on some targets, and
it would reintroduce cross-frame state. Real storage is 20k/2.9k per slot and
never a candidate.

## 5. Step encoding

One `uint256` per step. Field extraction is two shifts and a mask — the smallest
possible decode, which matters because bytecode is the binding constraint (§9).

```
bits [  0,   8)   kind
bits [  8,  24)   a     (order index, or token index for PRESEND, or call index)
bits [ 24,  40)   b     (leg index / item index)
```

| kind | step | effect |
| --- | --- | --- |
| 0 | `PULL(i, j)` | maker → pool for order `i` input leg `j`; credits `owed` |
| 1 | `DELIVER(i)` | pool → recipients for every output leg of order `i` |
| 2 | `ITEM(i, k)` | execute order `i` item `k`; credit its proceeds |
| 3 | `PRESEND(t)` | hand token `t`'s *currently unencumbered* surplus to the solver |
| 4 | `CALL(x)` | `EXECUTOR.execute(callTargets[x], callDatas[x])` |

An unknown kind or out-of-range index reverts `PlanBadStep(stepIndex)`.

### 5.1 `PULL(i, j)`

*(as built — the credit is the MEASURED delta, per the §13.4 decision, not the
nominal `owed`: it keeps the whole ledger on one footing and makes a
fee-on-transfer input fail as `LegUnfunded(i, j)` at the leg that came up short
rather than surfacing later as a puzzling `BatchNotWhole`.)*

```solidity
uint256 owed = order.inputOwed(st.fills[i], j);           // shared Pricing, unchanged
if (owed != 0) {
    uint256 pre = SafeTransferLib.balanceOf(token, address(this));
    Permit3TransferLib.transferFromWithFallback(PERMIT3, token, order.maker, address(this), owed);
    st.credit[i][j] += SafeTransferLib.balanceOf(token, address(this)) - pre;
}
```

No completeness bit is spent on `PULL`. A duplicate pull is **self-correcting**:
the extra lands in `credit`, and Phase 3 returns `credit − owed` to the maker. It
wastes the solver's gas, never the maker's money.

Making the pull a *step* (rather than the phase-1 `pullMask` it is today) is a
genuine generalization: a maker whose input arrives from an earlier order's
delivery — a chained match — can now be pulled after that delivery.

### 5.2 `DELIVER(i)`

```solidity
uint256 bit = 1 << 128;
if (ctx.done[i] & bit != 0) revert PlanBadStep(s);        // load-bearing: a second
ctx.done[i] |= bit;                                       // delivery drains the pool
_batchDeliverStored(order, ctx.outs[i]);                  // reused verbatim
for each leg j: ctx.outstanding[tokenIdx(j)] -= ctx.outs[i][j];
```

Delivery stays all-legs-at-once. Leg-granular delivery buys nothing known: a MAKE
item needs the *whole* collateral before it can deposit.

An order with no output legs (a pure gasless deposit) has its delivered bit set at
open, so the schedule need not carry a no-op step.

### 5.3 `ITEM(i, k)`

```solidity
uint256 bit = 1 << k;
if (ctx.done[i] & bit != 0) revert PlanBadStep(s);        // load-bearing: a second
ctx.done[i] |= bit;                                       // item = a second borrow

// TAKE produces; MAKE only consumes the maker's own funds → no snapshot needed.
if (item.op == ItemOp.TAKE) {
    uint256[] memory pre = _snapshotInputs(order.legsIn);
    _executeItem(order, ctx.fills[i], k);                 // body split out of _executeItems
    for (uint256 j; j < order.legsIn.length; ++j)
        ctx.credit[i][j] += balanceOf(legsIn[j].token) - pre[j];
} else {
    _executeItem(order, ctx.fills[i], k);
}
```

**This is the accounting improvement that makes interleaving sound.** Today
proceeds are attributed by a balance delta over a *whole order's* window
([Batch.sol:650](../packages/core/src/settlement/Batch.sol#L650)), which is only
correct because nothing else runs inside it. A per-**call** window is atomic with
respect to the schedule, so attribution stays exact no matter how the solver
interleaves orders. The window gets strictly *tighter*, not looser.

Cost: `2 × legsIn.length` `balanceOf` per TAKE item, warm (~100 gas each) after
the first touch.

`_executeItems` is refactored into `_executeItem(order, ctx, k)` (one item) with
the existing loop kept as a thin wrapper, so the single-order path is
byte-identical.

### 5.4 `PRESEND(t)`

```solidity
uint256 avail = balanceOf(tokens[t]) - ctx.beforeBal[t];  // this context's funds only
if (avail > ctx.outstanding[t])
    SafeTransferLib.safeTransfer(tokens[t], msg.sender, avail - ctx.outstanding[t]);
```

Strictly safer than today's [`_presendSurplus`](../packages/core/src/settlement/Batch.sol#L203),
which nets against *all* output obligations before any delivery has happened.
Netting against `outstanding` — obligations **not yet discharged** — is correct at
any point in the schedule, so the pre-send becomes schedulable rather than a fixed
phase.

### 5.5 `CALL(x)`

`EXECUTOR.execute(callTargets[x], callDatas[x])` — the allowance-less trampoline,
unchanged. Now *multiple* interactions at solver-chosen points instead of one
fixed slot. Re-entry into Settlement from here remains blocked by `nonReentrant`.

## 6. Phase 3 — the deferred flush

Contract-owned, over every order, no solver input:

```solidity
for (uint256 i; i < n; ++i) {
    // 1. completeness — every unit the plan was obliged to run, ran exactly once
    uint256 full = (1 << order.items.length) - 1 | (1 << 128);
    if (ctx.done[i] != full) revert PlanIncomplete(i);

    // 2. input reconciliation — ONE rule, pulled and item-funded legs alike
    for (uint256 j; j < order.legsIn.length; ++j) {
        uint256 owed = order.inputOwed(ctx.fills[i], j);
        uint256 have = ctx.credit[i][j];
        if (have < owed) revert LegUnfunded(i, j);
        if (have > owed) SafeTransferLib.safeTransfer(token, order.maker, have - owed);
        // `owed` stays pooled — it funds the other orders' deliveries
    }

    // 3. the deferred check — the EVC account-status-check analogue
    _runInvariants(order, msg.sender, p.takerDatas[i]);
    emit OrderFilled(ctx.fills[i].orderHash, order.maker, msg.sender);
}

_sweepSurplus(ctx.tokens, ctx.beforeBal);   // whole-check + residual → solver, reused verbatim
```

Two things collapse here that are separate today:

* **`pullMask` disappears from the ABI.** The self-funded / item-funded
  distinction was only ever needed because the two were reconciled by different
  rules. With an explicit credit ledger there is one rule — `credit ≥ owed` — and
  the mask is redundant. `_settleInputsToPool`'s mask branching goes away.
* **`invariants` become genuinely deferred.** Today they run at the order's own
  step; here they run after the whole context has settled, so an invariant broken
  by order *i* and restored by order *j* now passes — a same-maker migration
  (withdraw from Aave in one order, deposit to Euler in another) becomes
  batchable. This is the direct analogue of EVC's deferred account status check,
  and it costs nothing once the flush loop exists.

`validators` stay at open. They are pre-gates — deferring them would mean
executing a fill whose precondition was never true.

## 6.1 Maker-controlled item ordering (`ItemPolicy`)

Step granularity hands the solver a real new power: it picks the order a maker's
items run in. For most orders that is harmless — a bad order reverts — but a maker
whose lender checks health *inside* the borrow needs deposit-then-borrow, and one
participating in a cycle needs the opposite. So the maker says which.

**It costs no signed field.** `Order.timing` packs three `uint32` clocks into bits
[0:96) and every accessor masks to `uint32`, so bits [96:256) were dead space in a
word the maker already signs. The policy lives at [96:100):

| value | policy | rule |
| --- | --- | --- |
| 0 | `ANY` | any order, any interleaving — **the default, and what every order signed before this existed means** |
| 1 | `ORDERED` | items in signed index order; other steps may still interleave |
| 2 | `ATOMIC` | signed order **and** back-to-back, no foreign step between them |
| 3 | `CANONICAL` | `ATOMIC`, **and** the item group runs after this order's `DELIVER` and before any `PULL` of its input legs |

No `Order` change, no EIP-712 typehash change, **no golden-hash break**, and
existing orders read back `ANY` — exactly the behaviour they were signed under.

`ORDERED` is one mask test against `done[i]` (every lower item bit must already be
set). `ATOMIC` adds one memory word, `ctx.lastItem`, written by the dispatcher after
an `ITEM` step and cleared by every other kind — which is what makes "back-to-back"
checkable without a scan. Violations revert `ItemPolicyViolated(order, item)`.

The single-order path (`fill`, `fillUpTo`, `batchFill`) runs items in signed order
by construction, so it satisfies every policy and pays nothing for this.

**Why `CANONICAL` exists, when `ATOMIC` already pins the items.** `ATOMIC`
constrains the items relative to *each other*; it says nothing about where the group
sits relative to the **delivery** that funds it, or to the **pull** that draws the
order's inputs. Both of those change the *value that moves*, not merely the
intermediate state:

* **item before `DELIVER`.** For a swap-and-deposit or a leverage loop the delivery
  *is* the deposit's funding. Hoisted ahead of it, the item draws whatever the maker
  already holds — spending their wallet and their standing Permit3 allowance — and
  the delivery then lands in that wallet and stays there. With a module that sizes
  itself from live state (`min(amount, debt)`, a full-balance withdraw, an "all"
  sentinel) the amount that moves is simply a *different number* from either
  position.
* **`PULL` before the item.** `_stepPull` draws `owed − credit`, so a pull scheduled
  ahead of the `TAKE` that was going to credit that leg makes the maker front the
  whole leg from their wallet. Phase 3 refunds the tokens; nothing refunds the
  allowance they were moved with, and `matchSettle` is permissionless.

`CANONICAL` is exactly the single-order path's fixed shape — deliver → items → pay
inputs — so an order signed with it settles the same way through `fill` and through
a match. The cost is to the solver, not the maker: this order's inputs arrive last,
so the plan must fund its deliveries from elsewhere (another order's pull, a
`PRESEND`, a `CALL`). Both rules revert `ItemPolicyViolated(order, item)` — for a
refused pull, `item` is the input-leg index.

**When to reach for it, and when not.** `ATOMIC` is the right answer for a
multi-item order on a non-deferring lender. But if the pair can be **fused into one
module call** ([settlement-modules.md §8](settlement-modules.md)), that is better
still — the ordering becomes internal, no policy is needed, and it is ~10k cheaper.
Use the policy where fusion is not available: three-or-more-item orders, and
cross-protocol combinations.

## 7. Safety

The existing properties, restated against the new engine. S1 and S8 are the only
ones whose mechanism changes.

| # | property | mechanism |
| --- | --- | --- |
| S1 | no maker under-delivered | each leg transfer succeeds in full or reverts, **plus** the delivered bit is asserted set in Phase 3 — the schedule cannot silently omit an order |
| S2 | no maker overcharged | `owed` from the shared `Pricing`; excess credit returned in Phase 3 |
| S3 | items act only under maker authority | `_executeItem` body unchanged; `filled` written in Phase 1 before any external call |
| S4 | pool wholeness | `balanceOf(T) ≥ before[T]` ∀T, unchanged end-state check |
| S5 | bounded solver payout | pre-send bounded by `balance − before − outstanding`; sweep by `balance − before`; `before[T]` unreachable |
| S6 | no re-entrancy | `nonReentrant` unchanged and now *sufficient*, because the context never leaves the frame |
| S7 | scheduling is liveness-only | S1/S4/S8 are order-independent → any schedule yields a correct settlement or a revert |
| S8 | **exactly-once execution** | set-and-check bits on DELIVER and ITEM. Double-delivery drains the pool; a double item is a second borrow against the maker. Both must fail *at the step*, not at the end — a mask compared only in Phase 3 would still read "complete" after two executions |
| S9 | no stranded value | `outstanding` reaching 0 is implied by S1; the sweep floors every touched token at `before[T]` |
| S10 | **the counterparty cannot reprice a maker** | `Pricing` has no cross-order term — `outs[i]`/`owed[i]` are resolved in Phase 1 from order `i`'s own calldata and its own `FillCtx`. The only cross-order coupling is conservation (`outstanding`, `before[T]`, the sweep), which can refuse a settlement but never reprice one. Consequence: the maker-favourable rounding is charged to `msg.sender`, so grinding a match into dust pays the maker **more** and costs the grinder more. Assessed and swept over every matchable shape in [match-combinations.md](match-combinations.md) |

The load-bearing new check is **S8**, and it is the one an audit should stare at:
the guards must be *set-and-check at execution time*, never a completeness compare
in Phase 3 alone.

Retained guards from the item path: SETTLE items rejected
(`BatchItemsSettleUnsupported` — it routes to the filler, not the pool), duplicate
input tokens rejected (`BatchItemsDuplicateInput` — item proceeds are still
attributed per token within a step window), and the documented constraint that a
TAKE's proceeds token must be an input leg.

No `Order` field changes → **the golden order hash is untouched** and existing
signed orders are matchable as-is.

## 8. Worked traces

### 8.1 The mutual-leverage cycle (impossible today)

Order A: WETH collateral / USDC debt — `legsIn=[USDC]`, `legsOut=[WETH]`,
`items=[MAKE deposit WETH, TAKE borrow USDC]`. Order B is its mirror in the
opposite pair. Both makers on a lender that defers its own health check (Euler via
EVC — see [track A](#10-composition-with-evc)).

```
PHASE 1  open A, open B (filled written); outs = {A: 1 WETH, B: 2000 USDC}
         outstanding = {WETH: 1, USDC: 2000}
PHASE 2  ITEM(A,1)   A borrows 2000 USDC → pool     credit[A][USDC] = 2000
         ITEM(B,1)   B borrows 1 WETH    → pool     credit[B][WETH] = 1
         DELIVER(A)  pool → A: 1 WETH                outstanding[WETH] = 0
         ITEM(A,0)   A deposits 1 WETH as collateral
         DELIVER(B)  pool → B: 2000 USDC             outstanding[USDC] = 0
         ITEM(B,0)   B deposits 2000 USDC as collateral
PHASE 3  A: credit[USDC] 2000 ≥ owed 2000 ✓ ; B: credit[WETH] 1 ≥ owed 1 ✓
         invariants ✓ ; whole-check: both tokens back to `before` ✓ ; sweep 0
```

**Zero solver capital, zero flash, no callback, no re-entrancy.** The two
uncollateralized borrows are what a flash loan pays for today.

### 8.2 What it does *not* fix

The uncollateralized borrows in 8.1 only succeed if the **lender** defers its
health check. Aave, Comet and Morpho Blue check inside the borrow call, so those
cycles still need the existing `*FlashSolver` family. The engine is
protocol-agnostic — a lender that refuses simply reverts, which is S7 working as
designed — but the *unlock* is Euler-shaped.

## 9. Bytecode budget — the binding constraint *(measured)*

Settlement was at **23,269 / 24,576 bytes** before this work (via-IR already
required), leaving 1,307 bytes. The engine does not fit as an addition — it had to
*replace*. `matchSettle` is a strict generalization of `batchSettleItems`: the old
`sequence` is the schedule `[PULL…, CALL(0), (DELIVER(i), ITEM(i,0..k))…]`.

| step | action | measured |
| --- | --- | --- |
| 1 | delete `batchSettleItems`, `_batchSettleItems`, `_openAndPullAll`, `_openItemOrder`, `_pullMaskedInputs`, `_execSequence`, `_execOrderNetted`, `_settleInputsToPool`; add the engine | **24,655** — 79 over |
| 1b | dedup the authorization sequence into `_openGated` (zero-fill, deadline, signature, exclusivity, nonce, validators, `_openFill`), so it exists and is audited once | **24,592** — 16 over |
| 1c | `_tokenIndex` reverts on its unreachable fall-through instead of returning a `type(uint256).max` sentinel (also strictly safer) | **24,575** — **fits, by 1 byte** |
| 2 | **taken** — also fold `batchSettle` into the engine: item-free CoW is the schedule `[PULL…, PRESEND…, CALL, DELIVER…]`, so `batchSettle` ×2, `_batchSettle`, `_batchOpenAll`, `_batchComputeAllOutputs`, `_presendSurplus`, `_owedForToken`, `_batchDeliverAll`, `_batchOpenAndPull`, `_batchPullInputs`, `_batchDeliverStored`, `_td`, `BatchState` and the `BatchSettleNoItems` error all go | **22,423** — **2,153 free** |

Step 1c technically passed the gate, but **one byte is not a shippable margin** —
the next change to Settlement would have broken the build. Step 2 was taken: one
engine now serves both shapes, and Settlement has real headroom again. Step 3
(lowering `optimizer_runs` on `core-deploy` only) stays unused in reserve; it would
have widened the existing divergence between the gas snapshot (profile `core`) and
the deployed artifact.

**Gas** (against the committed baseline, `make gas`):

| path | before | after | delta |
| --- | --- | --- | --- |
| item match (spot funds leverage) | 723,381 | 729,269 | **+5,888 (+0.81%)** |
| balanced CoW, 2 orders | 656,977 | 670,067 | **+13,090 (+1.99%)** |
| imbalanced, solver fronts residual | 1,401,667 | 1,409,466 | +7,799 (+0.56%) |
| imbalanced, zero-capital pre-send | 1,621,418 | 1,633,743 | +12,325 (+0.76%) |
| **346 unchanged tests, net** | | | **−7,525** |
| deployment | 23,269 B | 22,423 B | **−846 B (≈ −169k gas)** |

Routing item-free netting through the general engine costs ~12k gas per
settlement: the schedule decode, the `credit`/`outstanding` allocations, and the
resolved-amount ledger.

**Four hot-path patterns were subsequently back-ported** (§5.1, §6, §9.1), which
is where the earlier per-PULL `balanceOf` measurement and the duplicated
`inputOwed` went. Net effect, measured: pulled-leg-heavy plans got **cheaper**
(a balanced CoW −3.1k, a 3-order partial/full match −6.0k), fully item-funded
plans got marginally dearer (the mutual-leverage cycle +1.9k — it pulls no legs,
so resolving `owed` up front adds a computation instead of replacing one), and the
both-sides return costs a flat **~1.6k** on top.

### 9.1 Hot-path patterns back-ported

Four places where the engine had drifted from the single-order path's own
conventions, since corrected:

| # | divergence | resolution |
| --- | --- | --- |
| 1 | `outs` was resolved once at open; `owed` was computed twice — in `_stepPull` and again in `_matchReconcileInputs` | **`owed[i][j]` resolved at open beside `outs[i][j]`.** Both sides now have a single source, so the amount charged and the amount checked are the same word rather than two computations an auditor must prove equal |
| 2 | `_stepPull` measured a balance delta | **Credits the nominal `owed`**, matching `_payInputsToSolver`. Core skips measurement precisely where nothing can have been produced; a pull moves a known amount. Measurement stays in `_stepItem`, where a module produces an amount the settler cannot predict. Cost: a fee-on-transfer input now reverts `BatchNotWhole` rather than `LegUnfunded` — both revert, and such tokens are already out of scope on this path |
| 3 | the sweep always paid `msg.sender`, so a contract filler needed a second transfer per token to forward it | **`MatchPlan.profitRecipient`** (0 = `msg.sender`), the `fillUpTo` `recipient` pattern with the same destination-only-never-authority argument. `PRESEND` deliberately still pays `msg.sender` — that is working capital a `CALL` step must spend |
| 4 | returned only what makers received; the filler's own P&L needed a `balanceOf` diff | **Returns `(outs, tokens, swept)`**, mirroring `fillUpTo`'s `(delta, received, paid)` |

Cost: 208 bytes (22,423 → 22,631, leaving 1,945 free).

### 9.2 Cross-flow efficiency pass

A later review asked whether the deferred work taxes the flows that do not need it.
It does not — but it surfaced two redundancies that did:

| | before | after | |
| --- | --- | --- | --- |
| `fillUpTo`, 1 fixed leg | 251,293 | 250,552 | **−741** |
| `fillUpTo`, BUY mid-decay | 263,405 | 260,759 | **−2,646** |
| `fillUpTo`, 2 legs incl. rising | 334,314 | 330,679 | **−3,635** |
| netted CoW | 668,696 | 668,198 | −498 |
| 3-order partial/full match | 1,013,053 | 1,012,131 | −922 |
| plain swap / dutch / TWAP | 516,694 | 516,710 | +16 |

1. **`fillUpTo` derived its receipts twice.** `_payInputsToSolver` priced each input
   leg to pay it, then `_receivedOf` priced them all again to build the return. The
   old comment justified this as safe — which it was — but measuring the second pass
   put it at 795 gas for one fixed leg and 3,583 for a two-leg order with a rising
   leg, because the call overhead and calldata reads dominate, not the arithmetic.
   The payout now records what it pays into `FillCtx.receipts` and `fillUpTo`
   returns that. `_receivedOf` is gone.

   Two measurements shaped the final form. Allocating the ledger unconditionally
   cost **+453** on every ordinary fill — more than it saved on a simple aggregator
   fill — so it is behind a `wantReceipts` flag only `fillUpTo` sets. And naming
   `receipts` in `_openFill`'s struct literal forced a `new uint256[](0)` on every
   fill, worth another **+124**; assigning the context field-by-field lets
   zero-initialisation point it at the canonical empty slot for free. What remains
   on the hot path is +16, one extra struct word.

2. **`_collectTokens` allocated twice.** It deduped into a `maxLen` buffer, then
   allocated a right-sized array and copied. The survivors are already contiguous at
   the front, so the copy was pure overhead — truncating the buffer's length in place
   replaces `count` iterations plus an allocation with one word write.

Net: **−15 bytes** of Settlement (deleting `_receivedOf` more than paid for the flag
and the truncation).

**The single-order hot path got slightly CHEAPER**, which was not the goal: a plain
`fill` is −24 gas, `fillWithPermit` −29, and `batchFill` −608 (it pays dispatch
four times over via `fillSelf`). Three external selectors left the ABI
(`batchSettle` ×2, `batchSettleItems`) and one arrived, so Solidity's selector
dispatcher shrank. 110 tests are byte-identical, 171 cheaper, 65 dearer by a median
of 18 gas — all of it dispatcher placement, no execution path changed.

## 10. Composition with EVC

Orthogonal and stacking. A solver contract enters EVC's checks-deferred context
and calls `matchSettle` from inside it:

```solidity
EVC.batch([BatchItem({targetContract: address(this), onBehalfOfAccount: address(this),
                      value: 0, data: abi.encodeCall(this.runMatch, (plan))})]);
// EVC → solver (msg.sender == EVC), solver → Settlement (msg.sender == solver) ✓
```

Verified against `EthereumVaultConnector.sol`: `executionContext` is one global
word; `requireAccountStatusCheck` (L696) consults it regardless of caller;
`restoreExecutionContext` (L916) runs the checks **only** in the outermost frame,
so the modules' own nested `EVC.batch`
([EulerV2Modules.sol:317](../packages/modules/lending/euler-v2/src/EulerV2Modules.sol#L317))
composes; and `callWithAuthenticationInternal` skips authentication when
`targetContract == msg.sender`, so the entry costs no operator grant.

Do **not** point the EVC batch item at Settlement directly — `msg.sender` would be
the EVC and the sweep would pay the EVC contract.

## 11. Off-chain

The solver builds the schedule as a topological sort over a produce/consume graph:
nodes are steps, edges are "token producer before consumer" (`ITEM(TAKE)` and
`PULL` produce; `DELIVER` and `ITEM(MAKE)` consume). The old `sequence` builder
generalizes — it already sorts the same graph at order granularity. An infeasible
graph reverts; nothing unsafe can be scheduled.

**The recommended filler shape is [filler-strategy.md](filler-strategy.md)** —
guard the `filled` counters before touching the plan (a contested loss drops from
34.3k to 3.9k gas), guard on exact equality rather than remaining room (a netted
plan is stale the moment `prevFilled` moves, because the rounding shifts), and
classify reverts from the typed error surface instead of re-simulating. Reference
implementation in `packages/solvers/src/match/`.

Still open: a `SettlementLens.validatePlan` view mirroring the on-chain Phase-3
rules (completeness, per-leg funding), so a solver catches a bad plan without
burning a transaction.

## 12. Tests *(as built)*

`packages/core/test/swaps/MatchSettle.t.sol` — 15 tests, all green:

| test | asserts |
| --- | --- |
| `test_cycle_mutualLeverage_zeroCapital` | §8.1 — the headline. Both makers borrow uncollateralized, then deliver and deposit; solver holds nothing start to finish, pool ends flat |
| `test_doubleDeliver_reverts` / `test_doubleItem_reverts` | S8, both exactly-once guards, each naming the offending step index |
| `test_omittedDeliver_reverts` / `test_omittedItem_reverts` | S8 completeness in the flush, naming the order |
| `test_badStep_reverts` | unknown kind, item index past the order, order index past the plan |
| `test_itemUnderproduces_legUnfunded` | `LegUnfunded(0, 0)` — the exact obligation that came up short |
| `test_duplicatePull_returnsSurplusToMaker` | the self-correcting path: the over-pull goes back to the MAKER, not the solver |
| `test_presend_boundedByOutstanding` | a mid-schedule pre-send on a balanced match hands the solver nothing |
| `test_donatedBalance_untouched` | S4/S5 against a pre-seeded pool |
| `test_deferredInvariant_restoredByLaterOrder` | the deferred check itself — an invariant restored by a later order passes |
| `test_settleItem_reverts` / `test_duplicateInput_reverts` / `test_lengthMismatch_reverts` | shape and arity guards |
| `test_spotFundsLeverage_zeroSolverCapital` | parity: the old `batchSettleItems` headline as a schedule |

Still outstanding: a **fork test in `modules-euler-v2`** proving an uncollateralized
`borrow` succeeds inside `EVC.batch` and that the account check fires at the
outermost frame. The core suite proves the mechanism with a mock TAKE module that
defers by construction; the fork test proves a real vault does the same.

## 13. Impact analysis — what else changes

Surveyed across the monorepo. The headline result: **the blast radius is almost
entirely inside `packages/core`.** Nothing outside core calls the batch paths in
code — every external reference is a comment or a doc.

### 13.1 Code that must change

| file | change | size |
| --- | --- | --- |
| [Batch.sol](../packages/core/src/settlement/Batch.sol) | delete `batchSettleItems`, `_batchSettleItems`, `_openAndPullAll`, `_openItemOrder`, `_pullMaskedInputs`, `_execSequence`, `_execOrderNetted`, `_settleInputsToPool`; add the engine | ~230 of 690 lines out |
| [Structs.sol](../packages/core/src/settlement/Structs.sol) | `ItemsBatch` → `MatchPlan`; `FillCtx` untouched | ~10 lines |
| [Base.sol](../packages/core/src/settlement/Base.sol) | split `_executeItems` → `_executeItem(order, ctx, k)` with the loop as a thin wrapper; retire `BatchItemsBadSequence` / `BatchItemsInputUnfunded`, add `PlanBadStep` / `PlanIncomplete` / `LegUnfunded` | ~30 lines |
| [Settlement.sol](../packages/core/src/settlement/Settlement.sol) | re-export list + the `{Batch}` layer doc | ~5 lines |
| `BatchSettleItems.t.sol` → [MatchSettle.t.sol](../packages/core/test/swaps/MatchSettle.t.sol) | full rewrite against the new plan shape | 307 lines out, 15 tests in |
| `.gas-snapshot` | 12 batch entries move; `make gas` regeneration | — |

Reused **verbatim**, which is most of what the engine needs: `_collectTokens`,
`_appendToken`, `_snapshotBalances`, `_snapshotInputs`, `_sweepSurplus`,
`_batchComputeOutputs`, `_batchDeliverStored`, `_assertItemBatchShape`,
`_openFill`, `_verifySignature`, `_exclusivity`, `_runValidators`,
`_runInvariants`, and all of `Pricing`.

`ItemsBatch`'s only consumer outside the settlement sources is that one test file.

### 13.2 Security arguments that name the entry points

These are prose, but they are load-bearing prose and go stale silently:

* [SECURITY.md:304](../SECURITY.md#L304) — the netting argument cites the pre-send
  bound and `sequence`. Must be restated for the `outstanding`-bounded pre-send
  (§5.4) and the new S8 exactly-once guard.
* [PositionFunnel.sol:182-189](../packages/modules/bridge/src/funnel/PositionFunnel.sol#L182-L189)
  (uncommitted bridge package) — the funnel's authority argument **enumerates
  every entry point** that calls `_verifySignature` before reaching
  `_executeItems`. `matchSettle` joins that list (it does verify, in Phase 1), but
  the enumeration has to be re-checked, not assumed.
* [settlement/README.md:133-145](../packages/core/src/settlement/README.md#L133-L145)
  — entry-point map and the `batchSettle` signature block.
* [settlement/README.md:227-228](../packages/core/src/settlement/README.md#L227-L228)
  — the FoT/rebasing exclusion for `balanceOf`-delta netting. Still applies, and
  §13.4 sharpens it.
* [docs/README.md:40-49](README.md#L40-L49) index; mark
  [item-aware-netted-settle.md](item-aware-netted-settle.md) superseded.

### 13.3 Verified as *not* affected

Checked rather than assumed:

* **Permit3 taker allowances are order-independent.** `take` keys on
  `ref = keccak256(data)` and `_spend`s a decrementing bucket
  ([Permit3.sol:146](../packages/core/src/permit3/Permit3.sol#L146)). Two TAKE
  items sharing `data` share one bucket and consume the same total in any order,
  so step reordering cannot change what a maker pays. Its `nonReentrant` is a
  per-call modifier and the engine calls it sequentially, never nested.
* **`SolverCallbackExecutor` is stateless and pinned to its Settlement**, so
  multiple `CALL` steps are safe — it holds no funds or approvals between calls.
* **Fill modules** already resolve during the all-orders-first open phase in
  `batchSettleItems`; Phase 1 preserves that exactly.
* **Storage layout is unchanged** — the context is memory-only, so no new slots,
  and `NonceManager`/`OrderState` are untouched.
* **Golden order hash unchanged** — no `Order` field moves.
* **The hot path** (`Core.sol`), `Pricing`, `DutchAuction`, `OrderHash`,
  `Signatures`, all validators, and every module package: untouched.
* **Native ETH** stays a per-order periphery concern (`NativeSettler`,
  `NativeForwarderFactory` have no batch surface today and gain none) — not a
  regression, but matching remains ERC20-only.
* **`DustHandler`** residuals route to the *user*, never to Settlement, so module
  dust never enters the pool ledger.

### 13.4 Semantic changes that need a decision, not just a port *(resolved)*

Three behaviours genuinely change. All three are now settled: (1) accepted and
tested (`test_deferredInvariant_restoredByLaterOrder`) and documented in the
settlement README; (2) **taken** — `PULL` credits the measured delta (§5.1); (3)
accepted as-is.

1. **Deferred invariants assert a later state.** `MinBalanceInvariant` and
   `OwnershipInvariants` move from end-of-*order* to end-of-*context*. Where one
   maker appears in two orders of a match, an invariant that passes today at its
   own step can now fail — and vice versa. This is the feature (it's what makes
   same-maker migrations batchable) and arguably the more correct assertion, since
   it checks what the maker actually ends the transaction with. But it is a
   behaviour change on a maker-facing safety primitive and should be called out,
   not slipped in.

2. **`PULL` should credit a *measured* delta, not `owed`.** The draft in §5.1
   credits the nominal `owed`. Measuring `balanceOf` around the pull instead makes
   the whole ledger uniformly measured, and a fee-on-transfer input then fails
   with `LegUnfunded(i, j)` — pointing at the actual leg — instead of surfacing
   later as a confusing `BatchNotWhole`. Today's `_batchPullInputs` has the same
   nominal assumption, so this is an improvement rather than a regression; the
   cost is 2 extra `balanceOf` per pulled leg (warm, ~200 gas). **Recommend
   measured.**

3. **`OrderFilled` now emits in Phase 3**, so every fill event follows every
   transfer rather than interleaving. The event is deliberately data-less and
   correlation is by `orderHash` within a transaction, so indexers should be
   unaffected — but anything reconstructing per-order transfer groups by event
   *position* would break.

### 13.5 Additive surface — new work, not migration

Worth stating because it changes the estimate: **there is nothing to migrate
off-chain.**

* **SDK** ([packages/sdk/src](../packages/sdk/src)) has *no* batch surface —
  no `batchSettle`/`batchSettleItems` encoder exists. A `buildMatchPlan` +
  schedule topological sort is entirely new code with no deprecation path.
* **`SettlementLens`** is per-order throughout (`previewFill`,
  `getOrderRelevantState(s)`, `validateOrder`) — a `validatePlan` view mirroring
  Phase 3 is new.
* **`packages/solvers`** contains no batch caller at all; every solver is
  single-order flash/inventory. An EVC-context match solver (§10) is new.
* **`orderbook-server`** exposes only `fillUpTo` quotes. A matcher that *produces*
  plans is the natural next component and has no existing shape to preserve.

### 13.6 Deployment

`_buildDomainSeparator` binds `address(this)`
([Signatures.sol:51](../packages/core/src/settlement/Signatures.sol#L51)), and
Permit3 allowances key on `spender = Settlement`. Settlement has no proxy and no
admin, so any change means a new address: existing signatures stop validating
(safe — they cannot be replayed) and **every maker's standing Permit3 allowances
must be re-granted.**

That cost is identical for *any* Settlement change, so it is not an argument
against this one — but it does argue for batching this with anything else pending.
No `broadcast/` or `deployments/` artifacts exist in the repo, so whether there
are live deployments to migrate is an open question for the team.

## 14. Open questions

1. ~~**Fold `batchSettle` too?**~~ *Resolved: folded* (§9 step 2). One engine, 2,153
   bytes of headroom; a plain CoW pays +1.9% gas for it.
2. **Leg-granular delivery.** Deferred until a case needs it; the step encoding
   already reserves the `b` field.
3. **Dedup of identical deferred invariants** across orders in one context (EVC
   dedups its check set). Cheap to add later — an O(n²) compare over
   `(target, data)` — and worth nothing until orders commonly share invariants.
4. **Partial-fill interaction with the credit ledger.** Slices are pro-rata as
   today; the ledger is per-context, so nothing accumulates across transactions.
   Believed fully covered by reusing `Pricing`; wants an explicit fuzz test.

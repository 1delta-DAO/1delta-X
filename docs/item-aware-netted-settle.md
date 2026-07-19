# Item-aware netted settle — leverage ⋈ spot coincidence of wants

> **Status: IMPLEMENTED** (`UniversalSettlement.batchSettleItems`, core 299 green).
> Extends [`batchSettle`](batch-settle.md) to admit item-bearing orders (MAKE/TAKE
> lending legs) into the netted pool, so a spot order's liquidity funds a leverage
> order's conversion **inventory-free, callback-free, and — in the match case —
> flash-free.** Proven by `core/test/swaps/BatchSettleItems.t.sol`
> (`test_spotFundsLeverage_zeroSolverCapital`: a spot `SELL 1 WETH → 2000 USDC`
> funds a leverage `MAKE deposit 1 WETH / TAKE borrow 2000 USDC` with a solver
> holding **nothing**). This note fixes the token-accounting invariant and the
> ordering/safety model; the "Execution model" and "Open questions" sections record
> what shipped.

## The problem this solves

A leverage order's solver-side is a swap: the solver *delivers the collateral
asset and receives the borrowed asset* (see
[docs README](README.md#generalizing-beyond-fungible-swaps) and the
`DualConversionLeverage` order — `tokenIn=[USDC borrowed, DAI equity]`,
`tokenOut=[WETH collateral]`, `items=[MAKE deposit WETH, TAKE borrow USDC]`). A
plain spot order that **sells WETH for USDC** is its exact mirror.

But you **cannot** match them inventory-free *and* callback-free with the fill
primitives that exist:

* `fill` / `batchFill` settle each order **fully against the solver** —
  `_settleForward` delivers the output *from* the solver and pays the input *to*
  the solver. To route the spot order's WETH into the leverage delivery, the WETH
  must pass **through the solver's balance sheet**: it either holds it (inventory)
  or routes it in a callback. There is no third option.
* `batchSettle` is the only construct with a **shared pool** (one order's input
  funds another's output with no solver in the middle) — but it is **item-free**
  (`BatchSettleNoItems`), so the leverage order can't enter it.

So the one mechanism that removes both inventory and callback structurally
excludes the order we want to match. Closing that is **the** requirement — not a
convenience.

## The enabling observation

`_executeItems` operates on the **maker**, never the solver:

* **MAKE** — `module.makeOnBehalf(maker, slice, data)`; the module pulls the
  funding token *from the maker* (Permit3) and deposits/repays.
* **TAKE** — `PERMIT3.take(module, maker, slice, recipient, data)`; borrows/
  withdraws on the maker's credit, proceeds → `recipient` (default = Settlement).

Because items touch only the maker's assets and positions, they **compose with
pool-sourced delivery unchanged**. Trace the match through a pool:

```
Phase 1  pull spot A's WETH → pool                       A supplies the bootstrap collateral
Phase 2  run leverage B against the pool:
           deliver B's WETH   ← pool (A's WETH)          no solver inventory, no callback
           MAKE deposit       pull B's WETH → Aave        collateral now exists on-chain
           TAKE borrow USDC   → pool                      borrow against that collateral
         deliver spot A's USDC ← pool (B's borrow)        funded by B, not the solver
Phase 3  net / whole-check / sweep
```

The forward flow **delivers-and-deposits the collateral before the borrow**, so
the spot order's pooled WETH *is* the bootstrap that solver inventory (or a flash)
provides today. In the match case there is **no flash** — the two orders fund each
other through the pool.

## Token-accounting invariant (with items)

Per touched token `T` (the on-chain-derived union of every order's legs *and* the
tokens its items move — see [Open questions](#open-questions) on deriving the
item token set), define the batch's flows:

**Credits into the pool**

| term | source |
| --- | --- |
| `Pself[T]`  | self-funded maker inputs pulled in T (spot sells, equity margin) → pool |
| `Ptake[T]`  | TAKE-item proceeds in T (borrow / withdraw) → pool |
| `Psolver[T]`| solver deposits in T during the interaction (residual conversions) |

**Debits from the pool**

| term | sink |
| --- | --- |
| `Dout[T]`    | output legs delivered in T → makers / fee recipients |
| `Dpresend[T]`| net surplus pre-sent to the solver in T |
| `Dreturn[T]` | over-provision returned to makers in T (e.g. over-borrow) |
| `Dsweep[T]`  | final residual swept to the solver in T |

**MAKE items are not a separate debit.** A MAKE pulls its funding token *from the
maker*, and the maker received that token from a delivery (`Dout`). So a deposit
is downstream of `Dout` — counting `Dout` once already captures it. No double
count.

**Conservation.** The pool creates and destroys nothing; `before[T]` (the
pre-batch balance) is the untouchable baseline:

```
balanceOf_end[T] = before[T]
                 + Pself[T] + Ptake[T] + Psolver[T]      (credits)
                 - Dout[T]  - Dpresend[T] - Dreturn[T] - Dsweep[T]   (debits)
```

Define the **pre-sweep residual** `R[T] = (credits) − (Dout+Dpresend+Dreturn)`.
The batch is settled by enforcing and sweeping:

```
require  R[T] ≥ 0            for every touched T        → else BatchNotWhole(T)
set      Dsweep[T] = R[T]    (= balanceOf(T) − before[T]) → balanceOf_end[T] = before[T]
```

**The whole-ness check is invariant to items.** `R[T]` is a pure balance-delta
(`balanceOf(T) − before[T]`); the `Ptake` credit is captured automatically by the
balance read. Items change the *intermediate* flows, not the *end-state* form — so
the safety check is byte-identical to item-free `batchSettle`. That is the crux
result: **admitting items does not complicate the invariant.**

### Worked example (balanced spot ⋈ single-conversion leverage)

Spot A: sell 1 WETH → 2000 USDC. Leverage B: borrow 2000 USDC, receive 1 WETH
collateral (single conversion; equity supplied as WETH elsewhere, omitted).

| T | before | Pself | Ptake | Psolver | Dout | Dpresend | Dreturn | R = end−before |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WETH | 0 | 1 (A) | 0 | 0 | 1 (→B) | 0 | 0 | **0** |
| USDC | 0 | 0 | 2000 (B borrow) | 0 | 2000 (→A) | 0 | 0 | **0** |

`R[T] = 0` for both → whole, nothing swept, **zero solver capital**, no flash. The
DAI/equity leg of a *dual*-conversion order is the only piece needing a
counterparty or the interaction (`Psolver`), exactly as pre-send handles an
imbalance today.

### Maker-fairness invariant (separate from pool wholeness)

Netting changes *who the counterparty is*, never *what a maker gets*:

* Every maker's delivered output = its signed auction amount, **exact or the tx
  reverts** (per-transfer atomicity).
* Every maker's charged input = its signed slice (`proceeds`-first, shortfall
  pulled from the maker, over-provision returned) — the **same math** as a single
  fill; only the destination is the pool.

So each maker is treated identically to a `fill`; the batch is transparent to
them.

## Ordering & the safety model

The mutual dependency (A needs B's USDC, B needs A's WETH) means there is **no
"pull all → deliver all"** order — deliveries interleave with item execution. The
design **splits liveness from safety**:

### Liveness is the solver's job

The pool must hold token `T` when `T` is delivered. That is an ordering
constraint — a topological sort of the produce/consume graph (a TAKE *produces*;
a delivery *consumes*). **The contract does not compute the order; the solver
supplies it, and an infeasible order simply reverts** (a delivery finds the pool
short). Concretely the solver submits, alongside the orders:

* a **pull-set** — which input legs to pull into the pool up front (the seeds:
  self-funded spot inputs and equity margins), and
* an **execution sequence** — the order in which to run each order's
  deliver-outputs + items.

Both are *hints the contract executes verbatim*; neither can make an unsafe
settlement succeed (below). Scheduling moves off-chain where it belongs; the
solver already runs a solver.

### Safety is the contract's job

| # | property | mechanism |
| --- | --- | --- |
| S1 | **No maker under-delivered** | each output leg is a transfer that succeeds in full or reverts the tx |
| S2 | **No maker overcharged** | input owed = the signed slice; netting changes only the sink, not the amount |
| S3 | **Items act only under maker authority** | `_executeItems` unchanged: module bound to `msg.sender==Settlement`, acts under the maker's signature + the maker's own Permit3 allowances; `filled` SSTORE precedes items |
| S4 | **Pool wholeness** | `balanceOf(T) ≥ before[T]` ∀T at the end → no donated/pre-existing balance consumed |
| S5 | **Bounded solver payout** | solver receives only the pre-send (≤ batch surplus, bounded to `balanceOf−before`) and the final sweep (`= balanceOf−before`); it can never reach `before[T]` |
| S6 | **No reentrancy** | `nonReentrant` spans the batch; item modules are external but maker-trusted and the pool never approves them, so a module cannot move the pool |
| S7 | **Ordering is liveness-only** | S1 (per-transfer) and S4 (end-state) are **order-independent**, so any solver ordering yields either a *correct* settlement or a *revert* — never a wrong-but-successful one |

S7 is the linchpin: because correctness is enforced by per-transfer success and a
final balance-delta check — neither of which depends on execution order — the
solver is free to choose *any* pull-set and sequence. A mistake costs the solver a
reverted tx, never a maker their funds.

## Execution model (as shipped)

A **new** entry point (the single-order hot path and item-free `batchSettle` stay
untouched and cheap). One `ItemsBatch` calldata struct bundles the inputs — seven
dynamic params would overflow the no-via-IR ABI decoder:

```solidity
struct ItemsBatch {
    Order[]   orders;
    bytes[]   sigs;
    uint256[] fillAmounts;
    uint256[] pullMask;   // bit j of [i] ⇒ pull order i's input leg j up front (the seeds)
    uint256[] sequence;   // execution order — a permutation of [0, n)
    address   interactionTarget;   // optional (0 = skip) solver seed call
    bytes     interactionData;
}
function batchSettleItems(ItemsBatch calldata b) external nonReentrant returns (uint256[][] memory outs)
```

```
1. snapshot before[T] over the derived token universe (_collectTokens)
2. PHASE 1  open every order (gates + _openFill, writes `filled`) +
            pull the `pullMask` legs → pool                    (_openAndPullAll)
3. PHASE 2  optional interaction: solver seeds any residual it must front
            (e.g. a dual-conversion equity leg) via the allowance-less EXECUTOR
4. PHASE 3  execute in `sequence` (validated permutation of [0,n)):  (_execSequence)
              deliver outputs      pool → maker/recipient          (_batchDeliverStored)
              _executeItems        maker-side; TAKE proceeds → pool (UNCHANGED)
              settle inputs → pool self-funded legs already pooled; item-funded
                                   legs keep `owed` from proceeds, surplus → maker,
                                   under-produce ⇒ BatchItemsInputUnfunded  (_settleInputsToPool)
5. PHASE 4  whole-check (balanceOf(T) ≥ before[T] ∀T, BatchNotWhole else)
            + sweep residual → solver                          (_sweepSurplus, reused)
```

Phases 3 reuses `_executeItems`, `_openFill`, `_batchComputeOutputs`,
`_batchDeliverStored`, `_snapshotInputs`, and the `_sweepSurplus` whole-check
**verbatim**. The only genuinely new logic is **`_settleInputsToPool`** (a
`_payInputsToSolver` variant that keeps `owed` in the pool instead of forwarding it
to the solver, still returning over-provision to the maker) and the shared
**`_inputOwed`** slice helper. The interaction sits *before* Phase 3, so the solver
can seed a bootstrap where the batch is short; the match case needs no interaction.

> **Deferred vs. the design sketch:** no in-batch **pre-send** (item-free
> `batchSettle` keeps it; the item match is internally funded, so it isn't needed
> here) and no `takerDatas` overload yet — Phase-3 validators/invariants see an
> empty blob. Both are mechanical follow-ons.

## Scope

* **MAKE / TAKE only.** These are the lending legs the leverage/repay/migrate
  orders use, and they act on the maker — so they compose with the pool. **SETTLE
  is deferred**: it routes the maker's asset to `ctx.filler` (the solver), a
  filler-aware exchange whose place in a shared pool needs its own thought.
* **Single-conversion leverage nets cleanly**; a **dual-conversion** order's
  equity leg (e.g. DAI → collateral) needs either a second matching spot order in
  the batch or the interaction/DEX (`Psolver`) — the same fallback pre-send uses
  for any imbalance.
* **Partial fills** carry through — item slices stay pro-rata (`item.amount ·
  fillAmount / total`), and the pool netting is over the sliced amounts.
* **Per-order `takerData`** via the same overload shape as `batchSettle`.
* **No module whitelist** — authority stays with the maker's signature, as
  everywhere else in the protocol.

## Open questions — resolutions

1. **Classifying inputs (self-funded vs item-funded).** *Resolved: solver-declared
   `pullMask`* (bit `j` of `pullMask[i]` ⇒ pull order `i` leg `j`). Safe by
   S1/S4/S7 — pulling a leg the maker can't fund reverts; omitting a needed seed
   makes a later delivery revert; an item-funded leg the mask leaves unset must be
   covered by that order's proceeds or `BatchItemsInputUnfunded` fires. The
   contract needs no knowledge of what a TAKE produces, and no signed `Order` field
   (golden hash untouched). The `inputFundingMask`-on-the-order alternative (Lens-
   validatable offline) stays available if a self-describing order is later wanted.
2. **Deriving the token universe with items.** *Resolved: `_collectTokens` (the
   `tokenIn`/`tokenOut` union) suffices for leverage/repay/migrate* — a TAKE's
   output token is the input leg it funds, and a MAKE's funding token is the
   delivered output, so both are in the union. **Documented scope limit:** an item
   moving a token *outside* the leg universe is out of scope (it would be
   unswept/unchecked); such orders must not be batched here. Not a theft vector —
   the pool never approves modules — but a stranding risk, so excluded.
3. **Over-provision returns with netting.** *Resolved:* `_settleInputsToPool`
   returns `proceeds − owed` to the maker before the sweep, so an over-borrow is a
   maker credit, never solver surplus.
4. **Gas / stack.** *Resolved:* `BatchState` bundling + per-phase helpers +
   `ItemsBatch` calldata struct keep it under the no-via-IR limit. This deliberate
   path is not stack-golfed; item modules add pay-per-use CALLs.
5. **Atomicity of a half-run leverage mid-batch.** *Covered by* `nonReentrant` +
   full-tx revert on any short transfer (`test_wrongSequence_reverts`,
   `test_itemLeg_underfunded_reverts` assert a mid-sequence failure unwinds the
   whole batch). A reverting-lender fork test belongs in the modules package.

## Remaining follow-ons (not blocking)

* **`takerDatas` overload** — thread a per-order blob into Phase-3 validators/
  invariants (mechanical, mirrors `batchSettle`).
* **In-batch pre-send** for item batches — only helps imbalanced item batches; the
  pure match is internally funded.
* **SETTLE in the pool** — a filler-aware exchange inside a shared pool needs its
  own design (deferred).
* **Real-lender integration test** — the core suite proves the mechanism with mock
  MAKE/TAKE modules; an Aave `leverage ⋈ spot` fork test belongs in
  `modules/lending/aave-v3`.

## Security audit (2026-07-19)

Independent adversarial review of `batchSettleItems` and its helpers (plus the
reused single-order helpers, the allowance-less EXECUTOR, and the Permit3 transfer
libs). **No Critical/High.** The master backstop — the per-token whole-check
`balanceOf(T) ≥ before[T]` over the on-chain-derived universe, given that *every*
pool outflow is a universe token and *no* module ever holds a Settlement approval —
closes every theft-from-innocent-party vector probed (S1–S7 all verified sound:
mandatory reverting deliveries, per-signed-slice charging, `filled`-before-items,
donated-fund protection, and pullMask/sequence as liveness-only).

Findings and dispositions:

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | Low | Duplicate `tokenIn` tokens corrupt `_settleInputsToPool`'s per-leg proceeds delta (over-refunds the maker; backstopped to revert-or-solver-self-harm, never innocent-party loss) | **Fixed** — `_assertItemBatchShape` rejects repeated input tokens (`BatchItemsDuplicateInput`); `test_duplicateInput_reverts` |
| F2 | Low | `SETTLE` items silently executed despite the doc declaring them out of scope (unenforced scope claim on an untested path) | **Fixed** — `_assertItemBatchShape` rejects SETTLE (`BatchItemsSettleUnsupported`); `test_settleItem_reverts` |
| F3 | Low/Info | A TAKE producing a token that is *not* an input leg routes to the solver, not the maker (maker misconfig; unreachable for well-formed leverage/repay/migrate) | Documented constraint: a TAKE's proceeds token must be an input leg |
| F4 | Info | Whole-check completeness rests on "item tokens ⊆ leg universe", which holds only because Settlement grants no approvals | Documented; an "asserts-no-approvals" invariant test is a cheap future guard |
| F5 | Info/gas | `_inputOwed` recomputes `bumpBps()` per auctioned leg (vs the cached single-order compute) — correct, just wasteful | Accepted on this deliberate (non-hot) CoW path |

The two code fixes are enforced in `_openItemOrder` (once per order at open) and add
no `Order` field — golden hash unchanged.

## Relationship

This is the **item-aware generalization of [`batchSettle`](batch-settle.md)** —
same pool, same whole-ness invariant, same pre-send, extended to run maker-side
items in a solver-ordered sequence. It is the concrete form of the "hybrid
item-aware netted settle" flagged as `batchSettle`'s V2, and it is what makes
**leverage-native coincidence of wants** — pricing a leverage position's
conversion against a live spot limit order, with no AMM and no solver capital —
expressible on-chain. Nothing in the swap-only market (CoW / Fusion / UniswapX)
can express it, because none of them settle lending intents at all.

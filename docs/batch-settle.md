# Batch settle — coincidence-of-wants netting

> **Status: SUPERSEDED** by [`matchSettle`](deferred-match-settle.md). The
> `batchSettle` entry point no longer exists: its five fixed phases are now the
> schedule `[PULL…, PRESEND…, CALL, DELIVER…]`, executed by the same engine that
> runs item-bearing matches. Everything below about the **netting invariant**, the
> **pre-send bound**, and the **whole-ness guard** still holds verbatim — the
> engine reuses that machinery unchanged, and `core/test/swaps/MatchSettleCoW.t.sol`
> carries the same six behaviours over. Two refinements came with the move: the
> pre-send is netted against obligations **not yet delivered** (so it is correct at
> any point in the schedule, not only before delivery), and it is a step the solver
> places rather than a fixed phase. Read this for the *why*; read
> [deferred-match-settle.md](deferred-match-settle.md) for the current *how*.

`batchSettle` was a **dedicated fill entry point** that clears N orders as one
netted batch, matching opposing intents against each other instead of against a
single solver's inventory. It is the coincidence-of-wants (CoW) primitive: two
mirror orders — `sell WETH → USDC` and `sell USDC → WETH` — settle against each
other with **no AMM touched** and **zero solver capital** — even when the batch is
*imbalanced*, because the solver is handed the net surplus up front and swaps it
into the deficit it owes (the **surplus pre-send**, below).

It is a *separate* method by design. The single-order hot path (`fill` →
`_fillCore` → `_settleForward`) is untouched, so ordinary solver fills pay
nothing for this feature — no new SLOAD, CALL, or branch on the common path.

## Why a new method (vs. `batchFill`)

`batchFill` runs each order as an **independent** fill against the solver: it
delivers order `i`'s output *before* it takes order `i`'s input
(`_settleForward` order). So even when the batch nets to zero, the solver must
**front the transient peak** — it pays maker A before maker B repays it.

`batchSettle` nets through the **Settlement contract's** balance sheet, the way
CoW's settlement does:

```
Phase 1  pull every order's inputs           makers → Settlement
         + compute (not deliver) outputs
Phase 2  PRE-SEND net surplus                Settlement → solver   (bounded to this batch)
Phase 3  one solver interaction              solver swaps surplus → deposits deficit
Phase 4  deliver every order's outputs       Settlement → makers/recipients
Phase 5  whole-check + sweep any residual    Settlement → solver
```

Because all inputs are pooled before any output is delivered, the solver's
capital requirement drops from the **peak flow** to the **net residual**; and
because the net surplus is *pre-sent* to the solver before the interaction, even
that residual needs no solver inventory — the solver simply swaps the surplus it
was handed into the deficit it must return. A balanced CoW pre-sends nothing and
the solver fronts nothing (`test_balancedCoW_zeroInventory`); an imbalanced batch
is settled by a solver holding **zero** of either token
(`test_imbalanced_zeroCapital_presend`).

## Fund flow & the netting invariant

Per touched token `T` (the union of every order's `legsIn`/`legsOut`, derived
on-chain — never solver-declared, so the safety check below can't be dodged):

```
before[T]                         = Settlement's balance snapshot pre-batch
pulledIn[T]                       = Σ maker inputs in T           (Phase 1)
owedOut[T]                        = Σ maker outputs in T          (computed Phase 1)
preSent[T]  = max(0, pulledIn[T] - owedOut[T])   → solver         (Phase 2)
deposited[T]                      = solver deposits in T          (Phase 3)

deltaT = balanceOf(T) - before[T] = pulledIn[T] - preSent[T] + deposited[T] - owedOut[T]
```

* **The pre-send is bounded to this batch's own inputs.** `preSent[T]` is measured
  as `balanceOf(T) - before[T]` (the batch's pooled amount) minus `owedOut[T]`, so
  it can *never* release a pre-existing / donated balance — `before[T]` is off
  limits by construction.
* **Deliveries are plain `transfer`s from Settlement.** If the pool is short a
  token (solver under-deposited), the Phase-4 transfer reverts — atomic, the
  maker is never short-changed. A pre-sent surplus is unwound by the same revert.
* **`deltaT ≥ 0` is enforced** for every touched token in Phase 5. A negative
  delta means the batch drew down a donated balance — the solver failed to
  return the deficit — and the whole tx reverts (`BatchNotWhole`). After a clean
  pre-send + interaction, `deltaT` is ~0 (all surplus pre-sent, all deficit
  returned); any residual is swept to the solver, never `before[T]`.
* **The surplus is the solver's compensation.** For a matched CoW it is the price
  spread the makers left on the table; the solver receives it (via the pre-send,
  then the sweep of any residual), exactly as it keeps surplus on a single-order
  fill. Per-maker pricing is unchanged — each maker is charged/paid its *own*
  signed auction curve (`_batchPullInputs` / `_batchComputeOutputs` reuse the
  identical slice math as the single-order path); the batch only changes *who the
  counterparty is* (the pool), not what any maker receives.

## Safety

* **`nonReentrant`** is held across the whole batch; neither the pre-send nor the
  interaction can re-enter any fill. All `filled[orderHash]` writes happen in
  Phase 1 (before both), so fills are recorded before any value leaves.
* **The interaction runs through the allowance-less `EXECUTOR`** — identical to
  `fillWithCallback`. It can *deposit into* Settlement but can never move
  Settlement's pooled funds (no Permit3 spender status, no approval). The solver
  returns the deficit funded by swapping the pre-sent surplus — no inventory, or
  a flash loan wrapping the call if it prefers.
* **Every per-order gate still runs**: signature/`approveOrder`, deadline, nonce,
  `_exclusivity`, validators (Phase 1) and invariants (Phase 4) — the same checks
  `_fillCore` runs, per order, with the per-order `takerData` threaded in.
* **The maker's charge/credit is byte-identical to a single fill** — the pull and
  compute/deliver helpers duplicate the audited slice formulas verbatim; only the
  transfer endpoint differs (`address(this)` instead of the solver).

## Scope

* **Item-free only** (`BatchSettleNoItems` otherwise) — MAKE/TAKE/SETTLE items
  have deposit/borrow ordering dependencies that assume the single-order forward
  flow, the same reason `PostInputs` is item-free. Fee legs (a `LegOut`
  addressed to a third party) are **supported** — they are just output legs.
* **Fill-module orders are supported** (e.g. a TWAP part), because `_openFill`
  resolves the delta generically; the pull/deliver math keys off `ctx`, not the
  raw `fillAmount`.
* **Per-order `takerData` is supported** via the `batchSettle(..., bytes[]
  takerDatas, ...)` overload — `takerDatas[i]` threads into order `i`'s
  validators, invariants, and (for a fill-module order) `resolveFill`. The blob is
  unsigned/adversarial, so a validator must independently verify what it reads
  (same rule as single-order `fill`). The no-`takerData` overload passes an empty
  blob (`test_takerData_threadsToValidator`).
* **Golden order hash unchanged** — `batchSettle` adds no `Order` field.

## Not built (deliberate)

* **Uniform clearing price / price-improvement to makers** — surplus flows to
  the solver, not competed back to makers via a batch-uniform price. That is an
  off-chain batch-auction / solver-competition property (CoW's actual moat), not
  a settlement-contract feature. The contract can host it (over-deliver +
  invariant), but enforcing/competing it is off-chain.

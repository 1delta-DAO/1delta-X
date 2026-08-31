# Filler strategy — the recommended shape for a `matchSettle` solver

> **This is the recommended way to build a filler.** Reference implementation:
> [`GuardedMatchSolver`](../packages/solvers/src/match/GuardedMatchSolver.sol) +
> [`MatchRaceGuard`](../packages/solvers/src/base/MatchRaceGuard.sol), pinned by
> `packages/solvers/test/MatchRaceGuard.t.sol`.
>
> Filling a *single* order from a router or aggregator is a different job with a
> different entry point — see
> [INTEGRATION.md](../packages/core/src/settlement/INTEGRATION.md) and use
> `fillUpTo`, which clamps to the remaining size instead of reverting and takes
> a `minBumpBps` price floor (quoted via `SettlementLens.previewBump`).

## The shape

```solidity
function settleMatch(
    bytes32[] calldata orderHashes,     // known off-chain
    uint256[] calldata expectedFilled,  // `filled` as observed when simulating
    MatchPlan calldata plan             // LAST, and calldata
) external returns (uint256[][] memory outs, address[] memory tokens, uint256[] memory swept) {
    _requireUntouched(orderHashes, expectedFilled);   // ← bail here
    return SETTLEMENT.matchSettle(plan);              // profit goes straight to plan.profitRecipient
}
```

Four rules, in order of how much they matter:

1. **Guard first.** One `SLOAD` per order, before anything else.
2. **Plan last, and `calldata`.** When the guard fires the plan is never copied to
   memory or walked.
3. **Guard on EXACT equality**, not "is there room left" (§3).
4. **Set `plan.profitRecipient`.** The settlement's residual is paid there
   directly, so your contract never holds it and never forwards it — one transfer
   per token saved, and no balance for the next caller to sweep. Leave it `0` and
   the residual lands in whatever called `matchSettle`; `GuardedMatchSolver`
   rejects that outright (`ProfitStranded`) rather than let a plan strand its own
   profit.

`matchSettle` returns `(outs, tokens, swept)` — makers' deliveries, the
on-chain-derived token universe, and your realised P&L per token — so a settlement
accounts for both sides without a `balanceOf` diff. Ignoring the return is free;
forwarding it costs ~1.6k and ~190 bytes of code.

## 1. Why the guard is the first thing you write

A profitable match is visible to every solver at once, so several land a
transaction for it in the same block. One wins; the rest revert — and reverting is
not free.

Nothing tells `matchSettle` the race is over until the end of its approach. It
derives the token universe, takes a `balanceOf` snapshot per token, hashes the
first order (keccak over the full struct *and* every dynamic sub-array),
`ecrecover`s its signature, runs its validators — and *only then* reads `filled`
and reverts `OverFill`. Every one of those steps is wasted work.

The losing condition, though, is knowable from **one storage slot per order**, and
you already know every order hash off-chain. So read that first.

Measured on the *smallest* contested plan — two item-free orders, no validators:

| race loss | gas |
| --- | --- |
| unguarded (`matchSettle` direct) | 34,679 |
| guarded | **3,641** |
| saved | 31,038 (**−89%**) |

That is the floor of the benefit. Guarded cost grows by one `SLOAD` per order;
unguarded cost grows with plan size, item count, and validator work — an order
carrying a Chainlink read or an attestation recovery widens the gap considerably.

## 2. Building the plan

Off-chain, in this order:

| step | tool |
| --- | --- |
| Filter to fillable orders | `SettlementLens.getOrderRelevantStates` — one call for the whole book (signature, nonce, deadline, remaining size, maker balance/allowance caps) |
| Reject malformed orders | `SettlementLens.validateOrder` |
| Price a candidate | `SettlementLens.previewFill` — the same {Pricing} math the fill runs |
| Get the hashes for the guard | `SettlementLens.hashOrder` (or compute the EIP-712 hash yourself) |
| Snapshot `filled` | `Settlement.filled(hash)` for each order — **these are the `expectedFilled` values** |
| Read each order's item policy | `Order.timing` bits [96:100) — `ANY` (0) may be interleaved freely, `ORDERED` (1) must keep signed sequence, `ATOMIC` (2) must additionally be emitted back-to-back, `CANONICAL` (3) must additionally run its items after that order's `DELIVER` and before any `PULL` of its input legs (i.e. schedule it exactly as `fill` would: deliver → items → pull) |
| Order the steps | topological sort of the produce/consume graph: `PULL` and `ITEM(TAKE)` produce; `DELIVER` and `ITEM(MAKE)` consume — subject to the policy above |

The schedule is the only part the contract does not derive for you — see
[deferred-match-settle.md](deferred-match-settle.md) for the step encoding and the
phase model. An infeasible schedule reverts; it can never mis-settle.

## 3. Guard on exact equality, not on remaining room

This is the non-obvious part.

A netted plan is balanced against a **specific chain state**. `Pricing.inputOwed`
computes a fixed leg as

```
owed = amt·newFilled/anchor − amt·prevFilled/anchor
```

so `prevFilled` moving shifts the owed amount by a rounding unit **even when
plenty of room remains**. A plan that is off by one wei no longer nets: the pool
comes up short and the settlement reverts `BatchNotWhole`, or a sliver is swept
that your economics did not account for.

So "does the order still have room" is the wrong question. "Is the state I
simulated against still the state on chain" is the right one — and it is also the
cheaper check, one `EQ` instead of an add-and-compare.

A competitor taking 25% of an order trips the guard even though 75% remains. That
is correct, not over-strict: your plan was built for the other 100%.

A cancelled order reads `type(uint256).max`, so a stale non-max expectation
catches cancellation too, with no extra branch.

**Exception:** a filler running *independent single-order* fills (not a jointly
balanced plan) has looser requirements and should write its own predicate —
"remaining ≥ my size" is fine there, because nothing else depends on the exact
amount.

## 4. Classify failures without re-simulating

Every revert reason falls into one of three buckets, and only one of them is worth
an alert.

**Routine — you lost, or the order moved. Drop it and move on.**

| error | meaning |
| --- | --- |
| `OrderTaken(index, expected, actual)` | the guard fired: order `index` moved between simulation and inclusion |
| `OverFill()` | unguarded equivalent — the order had no room left |
| `OrderCancelled()` / `NonceCancelled()` | the maker withdrew it |
| `OrderExpired()` | the deadline passed while you were in flight |
| `NotExclusiveFiller()` | still inside someone else's exclusivity window |

**Your bug — fix the plan builder. These should never reach chain.**

| error | meaning |
| --- | --- |
| `PlanBadStep(index)` | unknown step kind, out-of-range index, or a repeated `DELIVER`/`ITEM` |
| `PlanIncomplete(index)` | order `index` was not fully scheduled (a delivery or an item was never emitted) |
| `LegUnfunded(order, leg)` | that input leg ended the context under-covered — the schedule never funded it |
| `BatchNotWhole(token)` | the plan does not net in `token`; the pool would have ended below its baseline |
| `LengthMismatch()` / `ZeroFill()` / `FillTooSmall()` | arity, or a fill below the maker's `minFillAnchor` |
| `MatchSettleItemUnsupported()` / `MatchDuplicateInput()` / `OutputToSettlement()` | the order is not eligible for a netted match — filter it out at build time. The last one is an output leg addressed at Settlement itself: on the single-order path that is a maker self-burn, but the netted path cannot burn it (a pool→pool self-transfer would leave the amount above the pre-context floor and sweep it to *you*), so it is refused rather than paid. `SettlementLens.validateOrder` reports all three, and it is much cheaper to ask it |
| `ItemPolicyViolated(order, item)` | the schedule ran that item somewhere the MAKER did not permit — out of signed sequence under `ItemPolicy.ORDERED`, with a foreign step wedged in under `ATOMIC`, or (under `CANONICAL`) an item ahead of that order's delivery / a `PULL` ahead of its items, in which case `item` is the input-leg index. The order is fillable, just not that way: read `timing` bits [96:100) at build time and route accordingly |

**Maker-side — the order is not fillable right now; re-check before retrying.**

| error | meaning |
| --- | --- |
| `ValidationFailed(index)` | a maker-signed pre-gate said no (oracle stale, attestation missing, predicate false) |
| `InvariantFailed(index)` | a maker post-condition failed on the end state — note this is now judged on the end of the **whole context**, so a plan mixing two of the same maker's orders can trip it |
| `InsufficientAllowance` / `AllowanceExpired` (Permit3) | the maker's allowance is gone or lapsed |
| `TransferFailed` / `TransferFromFailed` | the maker is under-funded, or the token is fee-on-transfer (not supported on the netted path) |
| `InvalidSigner` / `InvalidSignatureLength` / `InvalidContractSignature` / `OrderNotApproved` | the order's authorization does not hold |
| `ItemTargetHasNoCode()` | a MAKE or SETTLE item names a module with no code at that address — a malformed maker-signed item, so it will never fill on any path and no retry helps. Blacklist the order. (The check is explicit rather than solc's, because `Base._callWithTail` hand-encodes the item calls; without it the funding step would silently no-op and the fill would settle around the hole) |
| `MalformedPackedArray()` | a packed blob is internally inconsistent — a declared length running past the end, or an `Item.op` outside `{MAKE, TAKE, SETTLE}`. Same verdict: never fillable, blacklist |

The point of the typed `OrderTaken` is that bucket one costs you a cheap revert and
needs no investigation — you can tell it apart from bucket two at the log level,
without re-running anything.

## 5. What the guard does not do

* **It does not save calldata.** The EVM charges for calldata whether or not it is
  read, so a loser still pays ~16 gas per nonzero byte of the plan it submitted.
  Keep guard parameters small and put them first; avoiding the plan's calldata
  entirely means not submitting, which is a bundle-level concern, not a contract
  one.
* **It does not make you win.** It makes losing cheap, which changes which matches
  are worth contesting at the margin — not who lands first.
* **It is not a privilege.** `GuardedMatchSolver` holds no funds between calls, has
  no owner, grants no approvals, and is never a Permit3 spender. It is a calldata
  shape. The security boundary is exactly what it is when you call `matchSettle`
  directly: the makers' signed orders and their own Permit3 allowances.
  *Corollary:* tokens donated to it are swept by whoever calls next — do not park
  inventory there.

## 6. If your plan needs external liquidity

An imbalanced match needs someone to cover the net deficit. Two ways, both
schedulable:

* **`PRESEND(token)` then `CALL(x)`** — the settler hands you the token's
  unencumbered surplus, you convert it and deposit the deficit. Zero capital: you
  never front anything. See `test_imbalanced_zeroCapital_presend`.
* **`CALL(x)` alone** — you front the residual from inventory and keep the surplus
  at the final sweep. Simpler, needs capital.

Point the `CALL` step at whatever contract you like; `GuardedMatchSolver`
deliberately exposes no callback surface, so there is nothing to authenticate.

## 7. Every maker-supplied target is gas-unbounded

An order names up to five addresses the settler will call **on the maker's behalf,
with your gas**, and none of them carries a gas cap:

| Surface | Call kind | What a hostile maker can do |
| --- | --- | --- |
| `validators` | `STATICCALL`, return capped at one word | burn gas, revert |
| `invariants` | `STATICCALL`, return capped at one word | burn gas, revert — *after* the fill's transfers |
| `pricingModule` | `STATICCALL`, return capped at one word | burn gas, revert |
| `fillModule` | `STATICCALL` (the interface is `view`) | burn gas, revert, mis-size the delta *within* the core's cap |
| `items[].module` | ordinary `CALL` | burn gas, revert, and make arbitrary state changes **under the maker's own Permit3 authority** |

The four static surfaces cannot move funds and cannot bomb your memory — the return
is read into scratch and capped at 32 bytes — so their damage ceiling is burnt gas.
Item modules are real calls, but they act with the *maker's* authority: a module can
only touch what that maker approved it for, never your inventory and never another
maker's funds. `fillModule` chooses only the fill fraction; the denominator, the
over-fill cap and the uniform per-leg scaling stay in the core.

So the residual risk is economic, not custodial: **you can be made to pay for
computation that then reverts.** This is the accepted posture across the whole
protocol class — 1inch acknowledged it at L11, UniswapX at M-01 — and the mitigation
is the same everywhere:

* **Simulate against the exact block you intend to land in.** A validator reading a
  price feed or a timestamp can be true at quote time and false at inclusion.
* **Budget by shape, not by hope.** An order with several items and several
  invariants has a wide gas profile; price that into your margin or skip it.
* **Treat a revert from an unfamiliar module address as an order to blacklist, not
  a race to re-enter.** Repeated reverts from the same maker are a griefing pattern.
* **`minBumpBps` protects your price, not your gas.** It reverts the fill when the
  tick moved against you — which still costs you the gas spent reaching the check.

See [reference-audits.md §C9](reference-audits.md#c9--one-side-spends-the-other-sides-gas)
for the audit precedent this posture is inherited from.

## Related

* [deferred-match-settle.md](deferred-match-settle.md) — the engine: step encoding,
  phase model, and the safety properties your schedule cannot violate.
* [INTEGRATION.md](../packages/core/src/settlement/INTEGRATION.md) — filling a
  single order from a router/aggregator (`fillUpTo`).
* [packages/solvers/README.md](../packages/solvers/README.md) — the flash-solver
  family, for leverage orders filled against a flash provider rather than netted.

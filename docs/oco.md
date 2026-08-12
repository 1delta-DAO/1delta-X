# One-cancels-other and brackets

A **bracket** is a set of a maker's own orders of which at most one may ever
fill: a take-profit paired with a stop-loss, sometimes with a trailing leg or a
time-out leg alongside. Filling any one of them has to retire the rest, or the
maker ends up selling the same position twice.

This is the one order type in common use that the settlement had no expression
for. Everything else a limit-order venue offers — stop, take-profit, scheduled
execution, TWAP, DCA, gas-gated triggers — is already a validator or a fill
module over a single order. A bracket is different because its defining property
is a relationship *between* orders, and every gate the settlement runs is scoped
to the order being filled.

Two mechanisms cover it. Neither changes the core, and neither changes the order
hash.

| | shared nonce | `OcoGroupModule` |
|---|---|---|
| contracts | none | one, per chain |
| gas per fill | zero | ~1 CALL + 1 SSTORE |
| partial fills | ✗ whole-fill only | ✓ |
| enforced by | the settlement's nonce gate | a maker-signed validator + claim item |
| legs share a nonce | yes (that *is* the mechanism) | no — each keeps its own |

---

## 1. Shared nonce — the bracket that needs no contract

Sign every leg with the **same nonce** and set the fill-once bit (`timing` bit
100, [`DutchAuction.useNonceInvalidator`](../packages/core/src/settlement/DutchAuction.sol)).
A fill-once order records its progress by consuming its nonce rather than by
writing a per-order counter, so the first full fill of *any* leg burns the shared
nonce, and every sibling then fails the nonce gate that
[`Core.sol`](../packages/core/src/settlement/Core.sol) already runs on every
fill:

```
fill(takeProfit)  → …fills… → _cancelNonce(maker, 7)
fill(stopLoss)    → NonceCancelled          ← the gate, not a new check
```

```ts
import { ocoNonceGroup } from "@1delta-x/sdk";
const [takeProfit, stopLoss] = ocoNonceGroup([tp, sl], 7n);
```

This is free in the strictest sense: no deployment, no extra item, no extra
validator, no gas beyond a fill that was going to burn the nonce anyway. It is
also the *cheaper* fill — the fill-once path writes a warm shared slot instead of
a fresh 22,100-gas per-order counter.

**The limit is real and not a detail.** Fill-once rejects a partial outright
(`FillOnceMustBeFull`), because a partial would burn the nonce and strand the
remainder. So this mechanism only expresses brackets that close a whole position
in one fill. That covers most retail brackets and almost no market-maker ones.

A second consequence worth knowing: the shared nonce is also a shared **kill
switch**. `cancelOrders([7])` retires the entire bracket in one transaction,
which is usually exactly what you want — and is a reason not to reuse that nonce
for anything outside the group.

---

## 2. `OcoGroupModule` — the bracket that survives partial fills

[`OcoGroupModule.sol`](../packages/core/src/modules/OcoGroupModule.sol) is a
registry, a validator and a claim-writer in one contract — the same shape as
[`FillerWhitelistValidator`](../packages/core/src/validators/FillerWhitelistValidator.sol).
No owner, no admin: every record is keyed by the order's own maker.

### Why a validator alone cannot do it

Validators are `staticcall`. They can **read** that a sibling already went; they
can never **write** that fact. The write has to be an item, because items are
ordinary CALLs — and the settlement runs every validator **before** any item.
That ordering is precisely what OCO needs:

```
fill A:  validators → group unclaimed → PASS → items → claim the group
fill B:  validators → group claimed by A → FAIL (ValidationFailed)
```

So each leg carries both halves:

```ts
import { ocoGroup } from "@1delta-x/sdk";
const legs = ocoGroup([takeProfit, stopLoss, timeOut], OCO_MODULE, groupId);
// each leg gains:
//   validators += Validator(OCO_MODULE, abi.encode(groupId))
//   items      += Item(SETTLE, OCO_MODULE, anchor, 0, abi.encode(groupId, nonce))
```

Both are inside the EIP-712 hash, so a solver can neither drop the validator
(which would let it fill a retired leg) nor drop the item (which would let it
fill one leg and leave the others live). A leg missing either half is simply a
different order the maker never signed.

### Why the claim records the nonce

The obvious `claimed[maker][groupId] = true` retires the **winner** as well: its
own second partial fill runs the validator again, sees the group claimed, and
reverts. So the claim records *which* order took the group — `nonce + 1`, the
`+1` reserving zero for "unclaimed" — and the validator passes for the claimant
as well as for an untouched group.

The winner therefore fills to completion in as many slices as it likes, while
every sibling is dead from the winner's **first** fill. That is the standard OCO
semantic. Sizing the survivor down to the predecessor's unfilled remainder is
*not* expressible in a single-signature model and is not attempted.

### Why the claim is a SETTLE item

Item amounts are sliced pro-rata, and
[`Base._runItem`](../packages/core/src/settlement/Base.sol) **skips** a MAKE or
TAKE item whose slice floors to zero. A claim signed as a MAKE with `amount = 0`
— the intuitive encoding, since the claim is not a quantity — would therefore
never run, the siblings would never be retired, and the whole bracket would
quietly become fillable. The fill succeeds; nothing reverts; the guarantee is
just gone.

`SETTLE` is the one op that **reverts** on a zero slice (`SettleSliceZero`). It
converts that silent break into a loud one: a misconfigured bracket does not fill
at all. The SDK sizes the item at the order's **anchor**, which makes the slice
exactly this fill's delta and therefore non-zero for every admissible fill,
including the smallest partial.

This is a deliberate trade of one wasted CALL argument for a fail-closed posture,
and it is the right way round for a safety mechanism.

### Composition

`ocoGroupLeg` **appends** to `validators`, so a bracket leg keeps its own
trigger. The AND-composition reads exactly as the bracket semantic does:

> fire when my stop is hit **and** my take-profit has not already gone.

```ts
const stopLoss = ocoGroupLeg(
  { ...order, validators: [chainlinkPriceLte(feed, floor)] },
  OCO_MODULE,
  groupId,
);
```

Groups are isolated (a random 256-bit `groupId` keeps a maker's unrelated
brackets apart) and maker-scoped (one maker's bracket cannot retire another's).
`isRetiredFor(maker, groupId, nonce)` is the exact predicate an off-chain book
needs to evict a sibling, and the `GroupClaimed` event lets an indexer do it the
moment the winner lands rather than after a failed fill proves it.

---

### Group ids are single-use

A claim is never cleared. Once `(maker, groupId)` has been taken, it stays taken
forever, so **a maker must draw a fresh `groupId` for every bracket**. Reusing one
is fail-closed rather than dangerous — the new legs read the old claim, do not
match their own nonce, and simply never fill — but it is a footgun, and it is the
reason a bracket pays a *cold* SSTORE (~22.1k of the ~33.5k claim cost) every
time rather than amortizing a warm slot across a maker's quote cycle. Draw
`groupId` at random per bracket; do not derive it from anything stable like a
market or a pair.

## What this does not do

- **It does not resize the survivor.** A 30% take-profit leaves a 100% stop-loss
  dead, not a 70% one.
- **It is not a substitute for cancellation.** A retired sibling is unfillable,
  but it still sits in books until they notice. Pair with a
  [soft cancel](soft-cancel.md), or let the `GroupClaimed` event drive eviction.
- **It does not span makers.** Claims are keyed by the order's maker, by
  construction.

Tests: [`OcoGroupModule.t.sol`](../packages/core/test/modules/OcoGroupModule.t.sol)
(14 cases, including both degenerate half-signed shapes and the zero-slice
posture), [`oco.test.ts`](../packages/sdk/test/oco.test.ts).

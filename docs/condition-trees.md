# Condition trees — `OR` and `NOT` inside one order

[`ConditionTreeValidator`](../packages/validators/src/ConditionTreeValidator.sol)
is one ordinary entry in `order.validators` whose `data` happens to be a whole
boolean expression. It evaluates each leaf by staticcalling it exactly as
[`Base._runValidators`](../packages/core/src/settlement/Base.sol) would.

**No core change.** Settlement's bytecode is untouched; this is a deployed
validator like `TimestampValidator` or the Chainlink gates.

---

## First: you may not need it

OR across **whole orders** is already free — sign two orders sharing a `nonce`
**and the fill-once bit** (`timing` bit 100, SDK `ocoNonceGroup`), and whichever
fills first cancels the other. Without the fill-once bit a partial of one branch
does NOT burn the shared nonce, so both stay live; with it, each branch is
whole-fill only. Use `OcoGroupModule` for partially fillable branches (see
[oco.md](oco.md)); the SDK's `assertNonceSiblingsFillOnce` lints hand-built sets
(2026-09-30 G-TS_SIGN-8). That covers the most common
disjunction by far ("limit **or** stop-loss") for no extra gas, and each branch
can carry its own prices, items and amounts, which one order cannot.

Reach for a tree only when the disjunction is over conditions on **one** fill:
`(oracle OR timeout) AND whitelisted`, where both branches must share the same
amounts, items and nonce.

## Encoding — disjunctive normal form

```
groupCount(1) ‖ group*
group := leafCount(1) ‖ leaf*
leaf  := flags(1) ‖ target(20) ‖ dataLen(2) ‖ data

flags bit 0  NEGATE — invert this leaf
flags bit 1  TRY    — treat a reverting leaf as `false` instead of aborting
```

The expression is `(l₁ AND l₂ …) OR (l₃ AND l₄ …) OR …`. With negated literals,
DNF is complete — every boolean formula has such a form, so nothing is lost
against an arbitrary tree.

A disjunction that isn't already at the top gets distributed:

```
(price ≥ X OR elapsed > T) AND whitelisted
    ⇣
(price ≥ X AND whitelisted) OR (elapsed > T AND whitelisted)
```

The whitelist leaf appears twice, but only **one** group is ever evaluated to
completion, so the duplication costs calldata, not gas.

### Why not a node graph with child indices

That is the shape Kyber's `ConditionTree` uses, and its own doc concedes
*"invalid tree structures could lead to revert, or invalid results"* — cycles,
out-of-range children and unbounded recursion are the caller's problem. DNF makes
those unrepresentable rather than merely checked:

| | |
|---|---|
| cycles / dangling children | impossible — there are no indices |
| recursion | none at all; evaluation is two flat loops, so there is no depth limit to pick and no call-stack exhaustion to reason about |
| short-circuit | both ways — a false leaf abandons its group, a satisfied group skips every later group |
| well-formedness | exact: parsing must consume precisely `data.length` |
| empty expression / empty group | rejected, not silently vacuous |

That last row matters more than it looks. An empty conjunction is vacuously
**true** and an empty disjunction vacuously **false**; either would turn a
malformed condition into an *unconditional answer*. Both revert `MalformedTree`.
So does an unknown flag bit — a builder that sets one believes it asked for
something, and dropping it silently would change the condition's meaning without
changing the order's hash.

## A reverting leaf is an error, not `false`

[`OrderGates.gatePasses`](../packages/core/src/settlement/OrderGates.sol) folds a
reverting validator into `false`. Under a flat AND-list that is harmless — false
aborts the fill either way. Once `OR` and `NOT` exist it stops being harmless:

> `NOT(staleOracleLeaf)` — the leaf reverts, reads as `false`, and NEGATE turns it
> **TRUE**. "Fill unless the price is above X" would fill precisely when the feed
> is broken.

So here a leaf that reverts, or returns fewer than 32 bytes, aborts the fill with
`ConditionErrored` — the same outcome a maker already gets from a reverting
top-level validator. NEGATE can then only ever invert a clean boolean **returned by
the leaf** — which is safe only for leaves that REVERT on failure rather than
answering `false` (corrected 2026-09-30, VAL-2). A leaf that turns its own failure
into `false` (a broken feed read as "not above X") is laundered past this rule and
NEGATE flips it. The shipped leaves are safe to negate: the Chainlink gates and
`MocPriceBandValidator` revert on a bad feed (zero price, reversed band),
`PredicateStaticCall` now reverts `PredicateFailed` on a reverting, codeless or
short-returning target, and `TimestampValidator` / `FillerWhitelistValidator`
answer a clean boolean. A third-party leaf must be vetted for this before it is
negated.

**Out-of-gas is never `false`, even under TRY.** The filler chooses the gas, so a
sub-call starved by a 63/64 cut could otherwise be forced to "revert" and read as
false (and NEGATE then as true). The tree validator, `PredicateStaticCall` and the
`FillerAttestationValidator` 1271 path detect a starved sub-call and consume all
remaining gas (`invalid()`), so the out-of-gas propagates instead.

`TRY` is the explicit per-leaf opt-out, for the case where fallback really is the
intent:

```
"price ≥ X, or if the feed is down, fall back to the timeout"
    →  group 1: [TRY] price ≥ X
       group 2:       elapsed > T
```

The choice is visible in the signed order rather than being the silent default.

> `TRY | NEGATE` on one leaf means "reverted **or** false ⇒ true". Coherent, but
> rarely what anyone means — prefer a leaf that returns a clean boolean.

`FillerAttestationValidator` returns `false` (it no longer reverts) on a foreign or
malformed `takerData` envelope (2026-09-30 VAL-6), so it composes in OR groups with
other `takerData`-consuming leaves without needing TRY.

## Cost

Each leaf costs the same staticcall Settlement would have made anyway. The
overhead is one extra hop into the tree validator plus the parse — and only for
orders that use one. Short-circuiting means an oracle read that cannot change the
answer is never paid for.

## Testing

[`ConditionTreeValidator.t.sol`](../packages/validators/test/ConditionTreeValidator.t.sol)
— 25 tests. The short-circuit ones are proven rather than asserted: a leaf that
**reverts if called** is placed in the position that must be skipped, so reaching
it would fail the test.

| Test | Property |
|---|---|
| `test_or_satisfiedByEitherGroup` | the disjunction itself |
| `test_shortCircuit_falseLeafSkipsRestOfGroup` | a false leaf abandons its group |
| `test_shortCircuit_satisfiedGroupSkipsLaterGroups` | a satisfied group skips the rest |
| `test_skippedGroupIsStillParsed` | skipping does not skip validation |
| `test_negatedRevertingLeaf_doesNotBecomeTrue` | the footgun this design exists to prevent |
| `test_try_enablesOracleFallback` | the documented fallback shape |
| `test_emptyGroup_reverts` / `test_zeroGroups_reverts` | vacuous truth/falsity rejected |
| `test_e2e_orSatisfiedBySecondBranch_fills` | it gates a real fill through Settlement |

## SDK

[`packages/sdk/src/conditions.ts`](../packages/sdk/src/conditions.ts):

```ts
import { conditionValidator, FLAG_TRY } from "@1delta-x/sdk";

// (price >= X, tolerating a dead feed) OR (timeout elapsed)
order.validators = [
  conditionValidator(TREE_VALIDATOR, [
    [{ target: chainlinkGte, data: priceCfg, flags: FLAG_TRY }],
    [{ target: timestampValidator, data: afterCfg }],
  ]),
];
```

`encodeConditions` rejects the same shapes the contract does — an empty
expression, an empty group, unknown flag bits — so a malformed condition fails at
build time rather than at fill time.

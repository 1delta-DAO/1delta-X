# Matching combinations — and who pays the rounding

Every division in [`Pricing`](../packages/core/src/settlement/Pricing.sol) rounds
toward the **maker**: auctioned outputs `ceilDiv` up, auctioned inputs floor down,
fixed legs cumulate so they land exactly on the signed total. On the single-order
path that posture is easy to defend — the only counterparty is the filler, and the
filler chooses the slice size, so the wei it costs is self-inflicted. That argument
is written down in [pricing-modes.md § Rounding](pricing-modes.md#rounding-who-pays-the-wei)
and pinned by
[`RoundingDirection.t.sol`](../packages/core/test/swaps/RoundingDirection.t.sol).

`matchSettle` ([deferred-match-settle.md](deferred-match-settle.md)) changes the
shape of the question, and the argument does not automatically carry:

- two makers now clear against a shared **pool** rather than against a solver's
  balance sheet;
- the wholeness check (`BatchNotWhole`) only asserts the pool ends level **across
  all participants**, never that any individual maker's rounding went the right
  way;
- and the filler both authors the schedule **and may have signed one of the
  orders**.

So the natural attack is: sign a counterparty order engineered to sit opposite a
victim's, slice the match into dust, and try to make the victim's own
maker-favourable rounding pay out **of the victim** instead of out of the filler.
This note is the assessment of that attack, and the combination matrix that says it
was checked for every shape rather than for the one pair somebody happened to think
about.

---

## 1. The verdict

**It cannot work.** The reason is structural rather than numerical, which matters:
a numerical argument would have to be redone for every new leg type, and a
structural one does not.

**Price has no cross-order term.** [`Batch._matchOpenAll`](../packages/core/src/settlement/Batch.sol)
resolves `outs[i]` and `owed[i]` for every order at OPEN, before a single token
moves, from that order's own calldata and its own `FillCtx`.
`Pricing.outputAt` and `Pricing.inputOwed` take `(Order calldata o, FillCtx ctx,
uint256 leg)` and nothing else — neither reads another participant, the schedule,
or the pool. The only cross-order coupling in the whole netted path is
**conservation** (`outstanding`, `beforeBal`, `_sweepSurplus`), and conservation
can refuse a settlement but cannot reprice one.

**The slack is charged to `msg.sender`.** Every rounding step favours the order's
own maker, so the residual lands in the pool balance — which is floored at its
pre-context value by `BatchNotWhole` and drained to `msg.sender` by
`_sweepSurplus`. Grinding a match into N dust slices multiplies the per-fill
`ceilDiv` on the victim's output leg, so a finer grind pays the victim **more** and
costs the grinder more. The rounding is a tax on grinding, not a leak through it.

**And surplus never routes to the filler.** `_matchReconcileInputs` returns any
over-credit — an over-producing item, a duplicated pull — to the **maker**, closing
the one route by which a clever schedule could redirect a victim's own money to the
counterparty.

> **What this does *not* say.** These are claims about the *netted* path relative to
> the single-order one. A rounding error inside `Pricing` itself would appear in
> both and is out of scope here — that is
> [`RoundingDirection.t.sol`](../packages/core/test/swaps/RoundingDirection.t.sol)'s
> job, and the division of labour is deliberate: one file pins the direction of the
> arithmetic, the other pins that matching cannot change it.

---

## 2. What can be matched

`matchSettle` accepts any order the single-order path accepts, minus four shapes it
refuses outright. The catalogue below is the **row and column set** of the matrix in
[§3](#3-the-matrix), and each row is a real `Shape` in
[`MatchComboMatrix.t.sol`](../packages/core/test/swaps/MatchComboMatrix.t.sol).

| Shape | Legs | Side | Why it is interesting |
| --- | --- | --- | --- |
| `FIXED` | fixed in → fixed out | SELL | the baseline; both sides cumulate exactly |
| `DECAY_OUT` | fixed in → **decaying** out | SELL | the auctioned output — `ceilDiv` **per fill**, does not cumulate |
| `FEE_OUT` | fixed in → maker leg + third-party fee leg | SELL | an output the maker does not receive; the override must not lift it |
| `MULTI_IN` | two fixed ins → fixed out | SELL | a second input token that no output ever returns |
| `RISING_IN` | fixed in + **rising** second in → fixed out | SELL | the sourcing-fee shape: floored per fill, priced off the same clock |
| `PROPORTIONAL` | balance-relative in → fixed out | SELL | the anchor is a live `balanceOf`, resolved once at open |
| `BUY_FIXED` | fixed in → fixed out | **BUY** | the denominator moves to `legsOut[0]`; outputs cumulate, inputs floor |
| `BUY_RISING` | **rising** in → fixed out | **BUY** | both the auction and the exact-output guarantee at once |

### The four refusals

Not rows, because the settler rejects them before any of this applies. Each is
pinned in [`MatchSettle.t.sol`](../packages/core/test/swaps/MatchSettle.t.sol) /
[`MatchSettleGates.t.sol`](../packages/core/test/swaps/MatchSettleGates.t.sol)
rather than duplicated in the matrix.

| Refused | Error | Why |
| --- | --- | --- |
| a `SETTLE` item | `MatchSettleItemUnsupported` | routes the maker's asset to the **filler**, not the pool — the netted accounting has no entry for it |
| a `TAKE_FOR` item | `MatchSettleItemUnsupported` | its funding leg is an output the order must already have **received**; a solver-chosen schedule cannot guarantee that ordering |
| a repeated input token in one order | `MatchDuplicateInput` | item proceeds are attributed per token per step window, so a duplicate leg would double-count one arrival |
| delta-verified outputs | `DeltaVerifyNotBatchable` | needs a per-order callback and a recipient snapshot the PRESEND/DELIVER flow does not have — refused rather than delivered nominally |

Two more bounds are structural rather than shape-based: at most **256 orders** per
plan (`LengthMismatch`) and at most **255 items** per order, so an item's progress
bit can never collide with `DELIVERED_BIT`. And an output leg addressed at
Settlement itself is refused mid-schedule (`OutputToSettlement`) — on the netted
path it would be a self-transfer that discharges the obligation while leaving the
money above the pre-context floor, i.e. a gift to the filler.

`PROPORTIONAL` is matchable but **full-fill only**
(`ProportionalNeedsFullFill`): a balance-derived denominator moves between fills,
so partial fills and a proportional anchor cannot both be correct. See
[proportional-legs.md](proportional-legs.md).

---

## 3. The matrix

Eight shapes on each side of a match, mirrored so each shape is exercised **both**
as the order that gives `tA` and as the order that gives `tB`:

|  | FIXED | DECAY_OUT | FEE_OUT | MULTI_IN | RISING_IN | PROPORTIONAL | BUY_FIXED | BUY_RISING |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **FIXED** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **DECAY_OUT** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **FEE_OUT** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **MULTI_IN** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **RISING_IN** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **PROPORTIONAL** | ● | ● | ● | ● | ● | ● | ● | ● |
| **BUY_FIXED** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **BUY_RISING** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |

**●** settled whole · **◐** settled in three slices · a `PROPORTIONAL` row or column
carries no **◐** because the shape reverts on anything but a full fill.

64 full-fill cells and 49 sliced cells, all swept by two tests:

- `MatchComboMatrix:test_matrix_fullFill_everyCombination`
- `MatchComboMatrix:test_matrix_sliced_everyCombination`

Both run against a **padding filler** that pushes a generous amount of every
tracked token into the pool mid-schedule, so no cell can pass merely because it
reverted on `BatchNotWhole`. The pad's remainder is swept straight back, so
over-padding cannot flatter the accounting either — the filler contract's balance
delta *is* its realised P&L.

### What each cell asserts

**1. Ledger equality with the single-order path.** The same two shapes are built
twice: once settled *alone* through `fill`, against an ordinary solver holding
inventory, and once settled *against each other* through `matchSettle` — same fill
amounts, same `block.timestamp`, so every auction tick is identical. Each maker's
realised balance delta across all three tokens must be **the same number** either
way, as must the fee recipient's.

That is the precise statement of *the counterparty cannot touch your price*, and
it is the property a drain would have to break first. It is asserted against the
settler itself rather than against a re-implementation of `Pricing` in the test, so
the check cannot drift into agreeing with a bug in both places.

**2. Two absolute bounds, derived from the signed legs.** These need no baseline at
all, and are computed generically from the packed legs so they keep holding for
shapes added to the enum later:

- no input leg may charge the maker more than `max(start, end)` — the worst tick
  they signed (`end` on a rising leg, `start` on a fixed one, the **cap** on a
  proportional one);
- at full fill, no maker output leg may deliver less than `min(start, end)` — the
  floor they signed. Fee legs are excluded, because that is not the maker's money.

**3. A donated pool balance stays unreachable.** Settlement is seeded with a
standing balance in all three tokens before the sweep begins, and every cell
re-checks that it never fell. `_sweepSurplus` floors each token at its pre-context
value, so a donation is not the filler's to take on *any* schedule.

**4. Non-vacuity.** Two identical ledgers are only evidence if something moved. Each
cell asserts the maker's delta is non-zero before comparing it, so a fill amount
that silently resolved to zero fails loudly instead of satisfying every other
assertion for free.

### The negative control

The matrix was verified to bite. Injecting a one-wei under-delivery into
`Batch._batchComputeOutputs` — a netted-path-only drain, invisible to
`BatchNotWhole` and to `LegUnfunded` — fails **both** sweeps immediately:

```
[FAIL: maker: netted ledger differs from the single-order path: 3000000000000000000 != 3000000000000000001]
```

That is the failure mode this file exists to catch, and it is worth re-running the
mutation after any change to the netted pricing or the schedule.

---

## 4. The item sub-matrices

The matrix above holds both sides item-free, and items are exactly the feature
that makes a netted match interesting. A `PULL` moves a **known** amount; a `TAKE`
**produces** value into the pool mid-schedule, so the settler cannot price it in
advance and has to *measure* it — `_creditItemProceeds` snapshots the whole token
universe around that one call and attributes the gain. Measurement, not pricing,
is where a netted-only leak would live, and it is a different question from §3.

Five configurations, each attachable to any shape
([`MatchItemMatrix.t.sol`](../packages/core/test/swaps/MatchItemMatrix.t.sol)):

| Config | Items | What it exercises |
| --- | --- | --- |
| `NONE` | — | the control row and column |
| `TAKE_LEG` | one `TAKE` producing into the order's **own** `legsIn[0]` token | the leverage shape: the borrow funds the order's own input, so `_stepPull` draws only the shortfall |
| `TAKE_STRAY` | one `TAKE` producing a token in the **universe** but not in this order's `legsIn` | the refund hazard — see [§4.2](#42-the-one-deliberate-divergence) |
| `MAKE` | one `MAKE` pulling the maker's funds into their position | value leaving the wallet under the maker's own signature |
| `MAKE_THEN_TAKE` | both | the per-item progress bits, and a schedule that runs item 1 before item 0 |

`SETTLE` and `TAKE_FOR` are not configurations because `matchSettle` refuses them
([§2](#the-four-refusals)).

### N1 — item configuration × order shape

One side carries the items, the other is the plain fixed/fixed control, so a
failure names the shape rather than a pair.

| | FIXED | DECAY_OUT | FEE_OUT | MULTI_IN | RISING_IN | PROPORTIONAL | BUY_FIXED | BUY_RISING |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **NONE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **TAKE_LEG** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **TAKE_STRAY** | ✕●◐ | ✕●◐ | ✕●◐ | ✕●◐ | ✕●◐ | ✕● | ✕●◐ | ✕●◐ |
| **MAKE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |
| **MAKE_THEN_TAKE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ | ● | ●◐ | ●◐ |

**●** settled whole · **◐** settled in three slices · **✕** a *must-not* the settler
handles by REFUNDING rather than reverting, so the cell is live and carries its own
expected value ([§4.2](#42-the-one-deliberate-divergence)). The `PROPORTIONAL`
column carries no **◐**: the shape reverts on anything but a full fill.

`MatchItemMatrix:test_itemMatrix_shapes_fullFill` and `..._sliced`.

### N2 — item configuration × item configuration

**Both** sides carry items, shapes held at `FIXED`. This is the attribution
question: two orders producing into one pool in one context, with the filler
choosing the interleaving. `_creditItemProceeds` measures each item's window
individually, so order A's borrow must never land on order B's leg however the
steps are arranged.

| | NONE | TAKE_LEG | TAKE_STRAY | MAKE | MAKE_THEN_TAKE |
| --- | --- | --- | --- | --- | --- |
| **NONE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ |
| **TAKE_LEG** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ |
| **TAKE_STRAY** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ |
| **MAKE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ |
| **MAKE_THEN_TAKE** | ●◐ | ●◐ | ●◐ | ●◐ | ●◐ |

`MatchItemMatrix:test_itemMatrix_crossOrder_fullFill` and `..._sliced`.

### 4.1 The ledger has to widen

A `MAKE` moves value out of the maker's wallet and into their position, so a
wallet-only ledger reads a deposit as a loss and the signed output floor fails on
every `MAKE` cell for no reason at all. The sweeps therefore compare the maker's
**economic** position — wallet **plus their own deposit module** — and each side of
a match gets its **own** module instance so the attribution stays exact when both
makers deposit in the same context. The taker module is deliberately *outside* that
boundary: it is the lender, not the maker.

The schedule is generic and derived from the configuration:

```
every TAKE  →  every PULL  →  pad  →  both DELIVERs  →  every MAKE
```

`TAKE`s run first because their proceeds credit an input leg and `_stepPull` draws
only the shortfall — pulling first would move the maker's own tokens for value the
item was about to produce. `MAKE`s run last because a deposit spends what the
delivery just paid.

### 4.2 The one deliberate divergence

`TAKE_STRAY` is the only cell in either matrix where the two paths legitimately
produce **different** ledgers, and it is scored that way rather than skipped:

- the single-order `fill` path **strands** the proceeds in Settlement. Nothing
  sweeps there, so they are lost to everyone — what `Base._executeItems`
  documents;
- `matchSettle` **refunds** them to the maker, and must. The netted path floors
  every touched token at its *pre-context* balance, so proceeds arriving mid-context
  sit above that floor and `_sweepSurplus` would otherwise hand a mis-authored
  order's money to the **filler** — who then has positive-EV reason to hunt such
  orders and bundle them with anything touching the same token.

So the netted ledger for this cell is the baseline **plus** the strayed amount, and
that is asserted as an equality, not a bound, so a regression in either direction
fails. The proceeds token is chosen to be in the match's token *universe* (it is the
counterparty's input leg) but not in this order's `legsIn` — the only configuration
in which the hazard is reachable at all.

### 4.3 The negative control

Rerouting that refund to the filler — `_creditItemProceeds` sending `gain` to
`msg.sender` instead of `order.maker`, which is precisely the bug the code exists
to prevent — fails **all four** item sweeps, each short by exactly the strayed
amount:

```
[FAIL: maker: netted item ledger differs from the single-order path: 3000000000000000001 != 3060000000000000001]
```

---

## 5. The direct attack, tested end to end

The matrix proves matching does not *reprice*. A separate file plays the attack out
economically, with the attacker owning **both** the counterparty order and the
filler, scored as one balance sheet:
[`MatchSettleRoundingAttack.t.sol`](../packages/core/test/swaps/MatchSettleRoundingAttack.t.sol).

| Test | Claim |
| --- | --- |
| `test_victimPricing_isIndependentOfCounterparty` | the victim's ledger for a given fill amount is identical through `fill` and through `matchSettle` against a hostile counter-order of a different size, rate and direction |
| `testFuzz_grinding_cannotDrainTheVictim` | under **any** dust schedule, with the victim on `minFillAnchor = 0`: the victim pays *exactly* the input they signed and never more, receives at least the output they signed, and every wei they gain comes out of the attacker |
| `test_grinding_costsTheGrinder` | 16 slices cost the attacker strictly more than one shot — the tax, measured |
| `test_buySideDustFill_chargesTheMakerNothing` | the residual below |

The attacker's counter-order in the fuzz is priced as the exact **mirror** of the
victim's, which is the most aggressive rate the pool will carry: anything better
makes the attacker's own leg unfundable rather than profitable.

---

## 6. The residual — and which way it points

"Rounds toward the maker" is not merely a tie-break, and there is one shape where
it rounds all the way to zero.

`Pricing.inputOwed` prices a BUY input as `floor(delta · inTick / anchor)` with
`anchor = legsOut[0]`. When the output leg is numerically **larger** than the input
leg — any order buying a token with a smaller unit value, which is most of them — a
one-unit `delta` floors the charge to **nothing**, while `outputAt`'s cumulative
ceil still owes one unit out. The filler funds it.

This is real, and it is the honest edge of the posture. It is not the drain this
note is about, for three reasons:

1. **It points at the filler, not at a maker.** On `matchSettle` the filler is
   `msg.sender`, who authored the schedule and chose the slice — exactly the
   self-inflicted case pricing-modes.md already claims.
2. **It is bounded at one unit of the output token per fill**, against a whole
   transaction of gas. Uneconomic wherever a unit is not itself valuable.
3. **The maker can switch it off.** A signed `minFillAnchor` is the anti-dust floor
   and removes the shape outright; `test_buySideDustFill_chargesTheMakerNothing`
   asserts both halves — the zero charge, and the `FillTooSmall` revert once a floor
   is signed.

It is pinned so that a future change to the BUY-side rounding cannot widen it
quietly.

---

## 7. Where this sits

- [pricing-modes.md § Rounding](pricing-modes.md#rounding-who-pays-the-wei) — the
  per-leg formulas and the single-order posture this note extends.
- [deferred-match-settle.md](deferred-match-settle.md) — the netted engine itself:
  phases, step encoding, and the deferred flush.
- [edge-case-matrix.md](edge-case-matrix.md) — the crossed-axes matrix for the
  protocol as a whole. This note is the same method applied to one axis pair
  (*order shape* × *order shape*, under matching) at full depth.
- [reference-audits.md § C7](reference-audits.md#c7--rounding-direction-and-split-fill-dust)
  — the external failure class this belongs to.

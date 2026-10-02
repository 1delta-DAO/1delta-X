# Proportional legs — balance-relative order amounts

*Signing "sell 100% of whatever I hold" without knowing the amount at signing
time, in a field that already exists.*

Encoding and resolution live in
[`Proportional.sol`](../packages/core/src/settlement/Proportional.sol); the
anchor resolution in
[`OrderGates.anchorTotal`](../packages/core/src/settlement/OrderGates.sol) and
the charge in
[`Pricing.inputOwed`](../packages/core/src/settlement/Pricing.sol).

---

## The problem

`LegIn.start` is an absolute token amount, fixed the moment the order is signed.
That makes a whole class of orders unsignable:

- a gasless full sweep of a wallet to stable;
- an exit whose size depends on interest accruing between signing and filling;
- a position close where the exact balance is not knowable in advance.

The maker would have to guess, sign slightly low to be safe (leaving dust), and
re-sign whenever the balance moved.

## The encoding

Rather than add a field — which changes the EIP-712 typehash and invalidates
every order already signed — the bps live in the **top of the existing `start`
word**, in a range no real token amount can reach:

```
start = type(uint256).max - (BPS - bps)        for bps in 1..10000
```

So `bps == 10000` (100%) is `type(uint256).max`, and `bps == 1` (0.01%) is
`type(uint256).max - 9999`. Anything strictly above `SENTINEL_FLOOR`
(`max - 10000`, about 1.15e77) is a marker; everything at or below it — which is
every amount expressible in any real token — is an ordinary absolute amount and
decodes exactly as before.

`bps == 0` maps *onto* the floor and is therefore deliberately **not** a marker: a
zero-size leg is expressible as a plain `0` and does not need a second spelling.

**The order typehash and the golden hash are unchanged.** This is a value
encoding inside a field that already exists — no re-signing, no SDK migration for
orders that don't use it.

Borrowed from 0x-Settler's `Permit2PaymentTakerSubmitted._permitToSellAmount`,
which overloads the Permit2 permitted-amount word the same way and for the same
reason.

## Where a marker may appear

**Only on `legsIn[0]` of a SELL order — the anchor leg.** Not on output legs (the
solver delivers those; an obligation measured against the *payer's* balance is
meaningless on the counterparty's side), not on a `fillTotal` or `fillModule`
order, and not on `legsIn[1..n]`.

The last restriction is about cost, not soundness — see
[multi-token sweeps](#multi-token-sweeps) below.

## Full-fill only

The anchor is the fill **denominator**, and `filled[orderHash]` counts in anchor
units. A denominator derived from a live balance *moves between fills*, so a
partially-filled proportional order would measure its own progress against a
ruler that shrinks as it fills — sell 40% of 1000, and the second fill sees a
balance of 600 and believes the order is 400/600 done. Partial fills and a
balance-relative anchor cannot both be correct.

So a proportional order is **whole-fill only**, which is also the semantics the
maker asked for: "sell everything I have" is an all-or-nothing instruction, and a
solver taking 30% and leaving the rest is a different order, not a smaller
version of the same one.

One consequence worth stating: such an order is **one-shot by construction**. After
a sweep, `filled` is non-zero, so any later fill fails the whole-fill assert — new
tokens arriving cannot re-arm it. (`useNonceInvalidator` orders are blocked by the
nonce gate instead.)

## `end` is the cap, and it is mandatory

A proportional order always fills fully, so the fill fraction is exactly 1 and
every **output** leg pays its full signed amount — `ceil(anchor · start / anchor)
== start` — regardless of what the anchor resolved to. The maker therefore
receives the *same* output whether their balance came in at half the expected
size or at triple it:

| | outcome |
|---|---|
| balance ≤ cap | sell the balance, receive the full output — **maker gains** |
| balance > cap | sell exactly the cap, receive the full output — **identical to the absolute order** |

Without a cap, that second row is unbounded: the maker sells three times as much
for the same money. And this is not merely an accident case — **a maker's balance
is not under their sole control.** Anyone can raise it by transferring tokens to
them, so an uncapped sweep is a standing offer to buy the maker's entire holding
at a price fixed for a much smaller one.

So on a proportional leg `end` is repurposed — not a decay endpoint (a
balance-relative amount has nothing to ramp toward) but an **absolute cap**, and
`end == 0` reverts `ProportionalNeedsCap`. `0` is what an unset field holds, so
the dangerous mode would otherwise have been the default.

A genuinely unbounded sweep remains expressible as `end = SENTINEL_FLOOR`, the
largest value that is not itself a marker. Requiring a cap costs no
expressiveness, only deliberateness. The SDK defaults it to the quoted amount,
which makes the order exactly as good as the absolute one it replaces and never
worse.

`minFillAnchor` is the matching **floor** — "do not bother unless I hold at least
X" — and needs no new machinery, since the anti-dust check already runs against
the resolved delta.

## Sizing the fill: exact, or `type(uint256).max`

The whole-fill rule is enforced where the marker is *consumed*, in
`Pricing.inputOwed`. Nothing in `OrderState._openFill` knows the order is
proportional, and that is a measured choice: threading a flag back to force
`delta = total` there cost **+253 gas on every plain fill**, which this codebase
does not spend on a feature most orders never use.

The consequence for callers is that a fill must name **exactly** the resolved
anchor — which a solver cannot know if the balance moves between simulation and
inclusion, i.e. the very drift this encoding exists to absorb — or opt into
"whatever it resolves to" explicitly:

- **`fill` / `fillUpTo` with the quoted size.** If the balance moved either way
  since the quote, the fill reverts. Up: the request is below the anchor, a partial
  fill, refused `ProportionalNeedsFullFill`. Down: `fillUpTo` does **not** trim a
  proportional request to the smaller anchor, so it reverts `OverFill` exactly as
  plain `fill` does (`test_prop_fillUpTo_shrunkBalance_quotedSize_reverts`). The
  solver never trades a size it did not price, in either direction.
- **`fillUpTo` or `fillWithCallback` with `type(uint256).max`** — "the whole
  remaining anchor, whatever it is", which for an unfilled proportional order *is*
  the freshly resolved anchor (`test_prop_fillUpTo_clampsToResolvedAnchor`,
  `test_prop_fillWithCallback_maxSentinel_fillsResolvedAnchor`). Only for a caller
  that has priced **any** size up to the cap.

### Who should pass the sentinel

The sentinel moves the shrink risk onto the filler, so it is right for a filler
whose output is **funded by the input it actually received** and wrong for one that
pays the output from inventory:

| Filler | Pass | Why |
| --- | --- | --- |
| `AggregatorFillSolver` (routed swap, amount patched from the measured input) | `type(uint256).max` | A shrunk balance swaps less and cannot pay the fixed output — the fill reverts, the solver loses only gas (`test_sentinel_shrunkBalance_revertsAndTheSolverLosesNothing`). A grown one is a bigger swap. The 1-wei donation grief stops working (`test_sentinel_oneWeiDonation_noLongerRevertsTheFill`). |
| Inventory / RFQ filler (pays the output from its own balance) | the exact quoted size | A shrunk balance would be paid the full output — the loss the no-trim rule exists to prevent. |
| ERC-7683 solver (through `DestinationSettler7683`) | the sentinel is SAFE | The destination enforces the quoted per-unit price against `fillUpTo`'s return: a drained balance reverts `BoundExceeded`, a donation fills (2026-09-30 PERIPH-3, `test_audit_PERIPH_3_sentinelFrontRun_reverts`, `test_audit_PERIPH_3_sentinelDonation_stillFills`). |

⚠ **Sweep-item proceeds are maker-controllable** (2026-09-30 X-DIFF-CORE-2): a
`ProportionalSweepModule` item pays the filler whatever the maker's balance is at
fill time, so price it at zero unless you check what arrived after the fill.

**Fees still work, and scale with the real size.** An aggregator-routed fill takes
fees three ways, none of which needs the quoted size: the `SurplusPolicy` shares
(maker improvement and a protocol fee, as parts-per-million of the measured
spread), the per-call originator carve-out, and any maker-signed fee leg, which is
paid out of the same route as the maker's output
(`test_sentinel_grownBalance_fillsAndFeesScaleWithTheRealSize`,
`test_sentinel_makerSignedFeeLegIsPaid`). An aggregator's own integrator fee inside
its calldata is just part of the route's cost. A fee the MAKER did not sign can only
ever come out of the spread — the maker's output is fixed.

Why no trim: a proportional fill is whole, so every output pays its full signed
amount however small the anchor resolved. `fillUpTo` used to cut an oversized
request down to the live balance, which charged the solver its full quoted output
for whatever was left — a maker who moved out all but 1 wei just before inclusion
was paid in full for dust (re-audit 2026-09-29). A non-proportional order keeps the
ordinary clamp.

## On the netted path: name `type(uint256).max`

`matchSettle` prices a plan on exact `fillAmounts[i]` and has no clamp — so a
proportional anchor in a plan was reverted, plan and all, by any stranger's 1-wei
transfer to the maker between plan construction and inclusion (F29 finding 5).
`Batch._openGated` now honours the same sentinel `fillUpTo` does: `fillAmounts[i]
= type(uint256).max` means "the whole remaining anchor", resolved at the gate.
Every other amount is still taken literally — on both paths the sentinel is the
one way to say "whatever it is".

The inventory caveat above applies here too (2026-09-30 X-DIFF-CORE-1.v1): a plan
that FRONTS a residual from inventory through a `CALL` step pays the full output for
a shrunk anchor. Such a plan must pin the exact anchor it quoted, or bound what it
expects swept — `GuardedMatchSolver.settleMatchChecked` reverts `AnchorShrunk` /
`SweptShort` (see [filler-strategy.md](filler-strategy.md) §3).

## Consistency: one balance read

The anchor is resolved **once**, in `OrderGates.anchorTotal` (which is `view`
rather than `pure` for this reason), before any funds move — and pinned in
`FillCtx.anchor`. `Pricing.inputOwed` returns that pin rather than re-reading.

That is what makes the output pricing and the maker's payment provably agree. A
second read would open a window in which an item crediting the maker mid-fill (a
TAKE with `recipient == maker`) has the solver delivering against one balance and
the maker paying against a larger one.

## Validators and price modules that read the anchor

A module that reads `legsIn[0].start` raw sees the MARKER, not an amount (F8).
`ChainlinkPeggedPriceModule` uses the resolved `total` the core passes it.
`ChainlinkTickFloorValidator` prices a Proportional `legsIn[0]` at its signed
**cap** (`end`) — sound in both the validator and the invariant position, and
stricter than the live rate when the balance is below the cap — and reverts
`UncappedProportional` for an uncapped (`SENTINEL_FLOOR`) or zero cap (2026-09-30
X-ARITH-1.v1, `test_audit_X_ARITH_1_v1_tickFloor_pricesAtCap_andRefusesUncapped`).

## Multi-token sweeps

Markers on `legsIn[1..n]` — *"take all my USDC **and** all my USDT"* — are sound.
Nothing but the charge itself consumes a non-anchor leg's amount (output pricing
and the fill counter both key off the anchor alone), so reading the balance at the
moment the leg is charged is self-consistent. It was fully implemented and tested.

It is **not in the core**, for a measured reason: `Proportional.resolve` carries a
`balanceOf` staticcall and inlines at every `inputOwed` site, costing **+2,106
bytes** and putting Settlement over EIP-170. It can be bought back by lowering
`optimizer_runs` to 2,000, but that setting lives in `[profile.default]` and would
charge **+4,307 gas to every fill of every order** — including the single-token
orders that are the overwhelming majority.

Use
[`ProportionalSweepModule`](../packages/modules/transfer/src/ProportionalSweepModule.sol)
instead: a `SETTLE` item (only `settle` is filler-aware — the swept tokens must
reach whoever fills, an address the maker cannot know at signing time). Zero
settler bytes, gas only on the orders that use it.

```
legsIn[0]  = { USDC, start: Proportional.encode(10_000), end: usdcCap }
legsOut[0] = { WETH, start: minOut, ... }
items      = [{ SETTLE, sweepModule, amount: usdtCap, recipient: 0,
                data: abi.encode(USDT, Proportional.encode(10_000)) }]
```

The item's signed `amount` **is** the cap, exactly as `end` is on a leg — reusing
a field the maker already signs rather than inventing a second place to put it.

⚠ **A FRACTIONAL sweep (bps < 10,000) must use the three-word form
`abi.encode(token, marker, total)` and is full-fill only** (2026-09-30 MISC-MOD-1,
**BREAKING**). The bps used to be re-applied to the POST-sweep balance on every
partial fill, so a split fill swept toward the cap: two half fills of "50% of my
USDT" took 75%. The two-word form is accepted only for 100%, where a split is
harmless (Σ min(Bₖ, sliceₖ) = min(B, cap)). So a sweep leg and a sweep item do NOT
always agree on a split fill — the earlier "can never disagree" claim here was
wrong; a fractional item is whole-fill precisely so that they do.

⚠ **Who can fill it.** The sweep is paid to `ctx.filler`, so a SETTLE sweep (or tip)
order must be filled by an EOA or by a contract that forwards arbitrary tokens. The
flash-solver family refuses SETTLE items (`SettleItemsUnsupported`), and the
ERC-7683 adapters do not carry them (`SettleItemUnsupported`).

### Why a standing Permit3 allowance to that shared module is safe

This is the question that sank `GenericCallModule` (2026-08 audit, CRITICAL-1), so
it deserves an explicit answer. That module executed an arbitrary
`(target, callData)` from its own identity; since anyone may sign an order naming
*themselves* as maker, an attacker could point it at Permit3 and drain every user
who had approved it.

`ProportionalSweepModule` performs exactly one operation, and its payer is not
attacker-controlled:

```solidity
permit3.transferFrom(maker, filler, token, amount)
```

`maker` is supplied by **Settlement** as `order.maker`, and the order hash is
maker-bound and signature-verified before any item runs. An attacker cannot name a
victim as the payer; signing their own order lets them sweep only themselves.
Nothing in `data` can redirect the source — and the absence of any spec-supplied
address on the `from` side of a transfer is the guard against regression.

## Cost

| | |
|---|---|
| Settlement bytecode | **+55 bytes** |
| Plain fill (via-IR, deployed) | **+40 gas** |
| Plain fill (legacy `core`, what `make gas` reports) | +232 gas |
| Order typehash / golden hash | unchanged |

The legacy figure is a stack spill, not opcodes. Do not tune against it.

## SDK

[`packages/sdk/src/proportional.ts`](../packages/sdk/src/proportional.ts):

| | |
|---|---|
| `encodeProportional(bps)` | build a marker (throws outside 1..10000) |
| `isProportional(start)` / `proportionalBps(start)` | detect / decode |
| `resolveProportional(balance, start, cap)` | mirror of the on-chain resolve, cap mandatory |
| `resolveProportionalOrder(order, makerBalance)` | returns a copy with the marker replaced by its resolved amount |
| `validateProportional(order)` | mirrors the settler's position rules exactly |

`anchorTotal` **throws** on an unresolved marker rather than pricing ~1.15e77 and
returning a preview that silently means nothing. Off-chain systems — orderbook,
quoting, solvers — must call `resolveProportionalOrder` first.

## Testing

[`ProportionalLeg.t.sol`](../packages/core/test/swaps/ProportionalLeg.t.sol) — 23
tests covering the sweep, both drift directions, the cap, the sentinel boundary
(that `SENTINEL_FLOOR` itself is absolute and one above it is 1bp), every
rejected position, and a fuzz test that ordinary absolute amounts are unaffected.
[`ProportionalSweepModule.t.sol`](../packages/modules/transfer/test/ProportionalSweepModule.t.sol)
— 9 more, including `test_attackerOrderCannotNameAVictimAsPayer`.

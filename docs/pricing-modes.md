# Pricing modes — the clock, the bid, and the module

How an order decides **where between its signed endpoints a fill prices**. Every
mode below produces the same thing: one shared normalized `bump ∈ [0, 10000]`,
where 0 is the `start` price (best for the maker) and 10000 the `end` price. Each
leg then maps that bump through its own signed bounds
([`DutchAuction.outTick`/`inTick`](../packages/core/src/settlement/DutchAuction.sol)).

That indirection is the whole safety story. **No pricing mode can move a fill
outside the band the maker signed** — the band is enforced by the same arithmetic
for an oracle-priced order as for a plain dutch one.

| Mode | Selected by | Bump comes from |
|---|---|---|
| linear / piecewise decay (default) | `timing` clocks + `curve` | elapsed time |
| **block clock** | `timing` bit **102** | elapsed BLOCKS |
| **priority auction** | `timing` bit **103** | the filler's priority fee |
| **external module** | `pricingModule != 0` | whatever the module says (clamped) |

Precedence: a price module wins; otherwise a priority auction; otherwise the
clock. The lens rejects orders that set contradictory combinations
(`validateOrder`).

---

## The clock, on blocks instead of seconds

`timing` bit 102 makes `decayStartTime`, `decayDuration` and every
`CurvePoint.timeDelta` count **block numbers**. Nothing else changes.

Why it exists: on a chain with 250ms blocks, a one-second timestamp tick is eight
blocks of resolution — coarser than the interval solvers actually compete over,
so the auction cannot price it. UniswapX moved its V3 reactor to a block clock for
the same reason. `uint32` holds any L2 block number for centuries.

Cost: **+17 gas** on a fill (measured; see below).

---

## The priority auction

`timing` bit 103. For chains whose sequencer orders transactions by priority fee
(OP-stack, Arbitrum timeboost) — the parity feature with UniswapX's
`PriorityOrderReactor`.

One deliberate difference from that reactor: theirs scales the output up with **no
ceiling**, so the gas auction runs to the filler's break-even and the surplus above
the maker's ask is burned as tip to the sequencer. Ours walks a **signed band** —
`end` (the guaranteed floor) up to `start` (the ambition) — so bidding past `start`
buys nothing, the filler keeps the residual edge, and less value leaks out of the
trade. It also bounds the filler's exposure to basefee drift (see the ⚠ under
"Quoting" below), which an uncapped scale does not.

The maker signs the band **the other way round**:

```
legsOut[j].start = the ambitious price     ← what a large bid buys
legsOut[j].end   = the GUARANTEED FLOOR    ← what a zero-bid fill clears at

bump = BPS − min(BPS, bid · BPS / params.priorityScale)
bid   = tx.gasprice − block.basefee − params.baselinePriorityFeeWei  (clamped at 0)
```

So an unbid fill clears at `end`, every wei of priority fee moves the tick toward
`start`, and the sequencer's own ordering picks the winner — losers revert on the
`filled` guard they already run ([filler-strategy.md](filler-strategy.md)).

Three consequences worth signing deliberately:

- **`params.priorityScale` is mandatory** here (`InvalidAuctionParams` otherwise):
  it is the wei of priority fee that buys a *full* bump.
- **The basefee gas bump cannot run** in this mode — it moves the tick toward the
  floor as gas rises, which is precisely backwards when the filler is bidding gas to
  move it the other way. Signing one anyway is an outright `InvalidAuctionParams`
  rather than a silently dropped parameter.
- **`params.baselinePriorityFeeWei`** (bits [160:208)) is the tip that does *not*
  count as a bid — UniswapX's field of the same name. Without it the chain's
  inclusion tip reads as a bid: the maker collects an improvement nobody chose to
  offer, and `priorityScale` stops being a pure economic parameter because it has to
  be re-tuned per chain and per congestion regime. `0` = every wei of tip bids.

  It has **bits of its own** rather than borrowing `gasPriceRef`, which is dead space
  here and was tempting. One signed field with two meanings, selected by a bit in a
  *different* word, would have meant any order already signed with an inert
  `gasPriceRef` quietly starting to bid against a baseline its maker never chose —
  same bytes, same valid signature, different price. Bits [160:256) were free and
  every order ever signed has zeros there, so a pre-existing priority order reads a
  baseline of `0` and prices exactly as before. `uint48` reaches 281,474 gwei; bits
  [208:256) stay free.
- **`decayStartTime` keeps its meaning** as a "not before" gate (a start BLOCK when
  combined with bit 102) — "let the book see this first, then let solvers bid".

### It is only an auction where the sequencer sells ordering

Signing bit 103 is a **per-chain** decision, and the chain has to cooperate:

- **Priority-ordered sequencer** (OP-stack, Arbitrum timeboost) — works as designed.
- **FCFS / arrival-ordered sequencer** — bit 103 is not an auction at all. Priority
  fee buys no ordering, so the "bid" decides only the price the winner pays, and
  which solver wins is decided by network latency. A maker signing bit 103 there is
  paying an auction's complexity for a latency race, and would do better on the
  clock (or the block clock, which is what fast blocks actually want).
- **Private-mempool / builder-auction chains** — the bid is legible to the builder
  before inclusion, which is a different game again.

Nothing on-chain can detect this: the settler cannot know how its chain sequences.
It belongs in deployment config, and it is worth checking before enabling the mode
on a new chain rather than after.

### What a lost race costs

A priority auction is a gas auction, so every solver but one lands and reverts —
and a reverted transaction still pays for the gas it burned, at *that bidder's own
priority fee*. The loser's bill is `gasUsed × (basefee + its bid)`, which is the tax
the mechanism charges for competing, and it is the number to minimise.

`filled[orderHash] >= total` **is** the "you lost" signal, so `Settlement` asks it
first, and it asks it before it *arms the reentrancy guard* — the gate is the order
hash, one `SLOAD` and the denominator resolve, none of which can hand control to
another contract, so nothing can be re-entered while they run (`Base._enter` states
the rule, `OrderState._gateFillState` is the gate). A loser therefore pays for the
answer and nothing else — not the guard's `SLOAD`+`SSTORE`, not the maker's nonce
word, not the validator `STATICCALL`s:

| lost-race revert | before | gate first | + guard after the gate |
|---|---|---|---|
| plain order | 11,244 | 9,237 | **5,616** |
| order carrying two validators | 21,176 | 9,292 | **5,671** |

The +55 between the two final rows is the larger calldata, not the validators — they
never run, so a loser's cost no longer depends on how much policy the order carries.
A real (cold-slot) losing transaction saves more still: it skips the maker's nonce
word and the guard slot's cold access, ~2,100 each. `PriorityRaceGasBench.t.sol`
prints the table and pins the ordering with a validator that reverts if it is ever
reached; `SettlementGuards.t.sol` pins that every hand-armed entry still rejects
re-entry and still releases.

The winner pays **+110** for both steps (56,140 → 56,250 on the clock baseline) —
one gas auction with two bidders repays that several times over — and Settlement got
**123 bytes smaller**, because folding three inlined copies of the gate into one
shared sequence gave back more than the reordering cost.

### Why there is no "compact calldata" entry

The other half of a loser's bill is the transaction's intrinsic calldata cost, which
is charged in full before the revert. It is smaller than the byte count suggests: a
plain fill is 1,252 bytes but **1,062 of them are zero** (ABI padding, priced at 4
gas against a non-zero byte's 16), so it costs 7,288 gas, and a hand-packed encoding
of the same order — no padding, empty fields omitted, addresses at 20 bytes — floors
at 361 bytes, saving roughly 3,600.

That saving is not reachable. Every function in the fill path takes `Order calldata`,
and a struct's calldata representation *is* its ABI encoding, so a compressed blob
would have to be decoded into memory and re-encoded through the `onlySelf`
`Core.fillSelf` trampoline. `batchFill` already performs exactly that bounce, and a
one-order batch prices it at **9,069 gas** — more than twice what the compact form
could ever save, before writing a single line of decoder. `CalldataSizeBench.t.sol`
measures both halves; run it before anyone proposes this again.

Cost: **−91 gas** versus the clock — it skips the curve check and the elapsed
arithmetic, and pays back part of that for the baseline subtraction.

---

## External price modules

`Order.pricingModule` delegates the bump to an [`IPriceModule`](../packages/core/src/interfaces/IPriceModule.sol).
This is the 1inch `IAmountGetter` class of orders — oracle-pegged, range, quoted —
with one deliberate difference.

**A module returns a bump, never an amount.** 1inch's getter returns the making /
taking amount, so it *is* the price and is trusted absolutely. Here the core
clamps the answer into `[0, BPS]` and maps it through the maker's own signed
endpoints. A hostile, buggy or stale module can move the price anywhere inside
that band and **nowhere outside it**. That is what makes it safe to wire an oracle
into pricing without the oracle becoming custodian of the maker's terms.

### Shape and wiring

```solidity
function bump(
    bytes32 orderHash, address maker, address filler,
    uint256 prevFilled, uint256 total, uint256 orderTiming,
    bytes legsIn, bytes legsOut, bytes takerData
) external view returns (uint256 bps);
```

- **`orderTiming` carries the side.** Bit 101 of the maker-signed `timing` word is
  the order side; a side-oriented module (the oracle module) reads it to reject a
  config/side mismatch instead of pricing the wrong band. Bits `[0:96)` are the
  clocks, available to a future hybrid clock+oracle module.
- **Read progress from the arguments, not storage.** `prevFilled`/`total` are the
  progress axis. A module must NOT read `SETTLEMENT.filled()` live: the settler has
  already written this fill's progress before the module runs, while the lens
  preview passes the pre-fill value, so a live read would desync the `minBumpBps`
  floor quote from the price.
- **No per-order config blob.** A `bytes pricing {target, data}` member measured
  ~1,000 bytes of Settlement (a seventh dynamic `Order` member grows the ABI
  decoder at every entry point). A module instead carries its configuration in its
  own **immutables** — one instance per configuration, identical configs sharing a
  CREATE2 address — and the maker's signature over the address IS the commitment
  to that configuration.
- **Resolved once per fill**, in [`OrderState._openFill`](../packages/core/src/settlement/OrderState.sol),
  and pinned in `FillCtx.bump`. A multi-leg order pays one `STATICCALL`, not one
  per decaying leg.
- **`takerData` is adversarial.** A module that reads it must verify it against
  `orderHash` and against a signer it is configured with.
- **Previews.** The lens resolves the module with whatever the caller supplied; a
  book quoting an order usually has no filler and no taker blob, so a module MUST
  NOT revert on `filler == address(0)` with empty `takerData` — return the best
  quote it can, or the order looks unpriceable and gets dropped.
- **Failures are opaque by design.** The core reads a bool plus one word from the
  staticcall, so a module that reverts surfaces as
  `DutchAuction.PriceModuleFailed`. Simulate the module directly for its own
  reason.
- **The clock fields don't co-exist with a module.** A module pins the bump, so a
  signed `curve`, `decayDuration`, or `gasBumpBps` would silently never apply;
  `SettlementLens.validateOrder` rejects those combinations as signing mistakes.
  `decayStartTime` is the exception — it stays live as the "not before" gate, and
  the fill enforces it (`AuctionNotStarted` before the start). The context-free
  per-leg views `previewAmountOut`/`previewAmountIn` cannot resolve a module (no
  filler/progress/taker blob) and revert `PricingNeedsContext` — quote a module
  order through `previewFill`/`previewBump`.

### Shipped modules

| Module | Bump from | Notes |
|---|---|---|
| [`ChainlinkPeggedPriceModule`](../packages/modules/pricing/chainlink/src/ChainlinkPeggedPriceModule.sol) | a Chainlink feed | staleness **and** an absolute `[MIN, MAX]` plausibility band — a fresh-but-wrong feed (depeg, decimals misconfiguration) reverts the fill instead of pricing against it. Configured per (feed, staleness, band, scale, side, spread). |
| [`RangePriceModule`](../packages/modules/pricing/range/src/RangePriceModule.sol) | `prevFilled / total` | the ladder: price varies along the VOLUME axis (1inch `RangeAmountCalculator`). Measured on `prevFilled`, so a solver knows the exact bump before submitting. |
| [`CosignedQuotePriceModule`](../packages/modules/pricing/quotes/src/CosignedQuotePriceModule.sol) | an EIP-712 quote signed by a named cosigner | UniswapX's cosigner without the trusted party: the cosigner is an immutable of the instance, any maker may deploy one, any filler may present a quote, and the quote can only improve *within* the band. `takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig`. **`FALLBACK_BPS` is not maker protection** — `takerData` is filler-controlled and a pinned bump replaces the clock, so an unquoted fill clears at `FALLBACK_BPS` immediately with no decay ramp. Use `0` (unquoted → `start`, quote required to improve — the adversarial-safe UniswapX shape) unless you specifically intend `end` to be the price a filler can always take. |
| [`ClockFlooredQuoteModule`](../packages/modules/pricing/quotes/src/ClockFlooredQuoteModule.sol) | the same quote, **floored by the dutch clock** | `min(quotedBump, clockBump)`, so a quote can only ever *improve* on plain dutch and never undercut it. Removes the `FALLBACK_BPS` footgun structurally — there is no fallback to misconfigure, because `min(anything, clock)` is the clock — and makes the cosigner safe to point at a third party the maker does not fully trust: absent, buggy, compromised and colluding all degrade to an ordinary dutch fill. Reads a **single linear segment** from `timing` (a module never receives `curve`/`params`, both of which are already inert under any `pricingModule`). ⚠ `decayDuration == 0` ⇒ ceiling 0 ⇒ no quote can extract anything; sign a window. |

---

## Delta-verify delivery (`timing` bit 104)

Orthogonal to every mode above. Those decide **what** the price is; this decides
**how the priced amount is delivered** — and it is the fee-on-transfer answer.

Normally the settler *pushes* the computed amount from the filler to the leg's
recipient. Those are nominal amounts: for a fee-on-transfer or rebasing `tokenOut`
the recipient nets less than the number the maker signed, silently. With bit 104
set the settler instead **snapshots each output recipient at fill start and, after
the filler has delivered, requires**

```
balanceOf(recipient) after  −  balanceOf(recipient) before   ≥   outputAt(leg)
```

The required amount is still `outputAt`, i.e. whatever the clock / priority bid /
price module produced for this fill, pro-rated for a partial. So the primitive
composes with every mode by construction — a dutch order's floor decays with the
tick, a module order's tracks the oracle — and the maker's signed output becomes a
**net-of-fee floor** instead of a pre-fee nominal.

The filler delivers out-of-band, inside its own fill callback: pool → recipient
directly, or from an aggregator, or from inventory. For a FoT token that direct hop
also means the fee is paid **once** rather than once per intermediate hop.

**How to use it, and the rules:**

- **Callback-only.** Nothing in the settler delivers these legs, so the order is
  fillable only through `fillWithCallback`. Plain `fill`/`fillUpTo`/`batchFill`
  reach the check with nothing delivered and revert `DeltaTooLow`; the netted
  `matchSettle` path rejects the order up front (`DeltaVerifyNotBatchable`) because
  it has no per-order callback to deliver from. Delivery must happen *during* the
  fill — a pre-transfer lands under the snapshot and does not count.
- **Shape restrictions, enforced on-chain.** No two output legs may share a
  `(token, recipient)` (`DeltaVerifyDuplicateLeg`), and a maker-bound output token
  may not also be an input token (`DeltaVerifySameToken`). A per-leg balance delta
  only measures that leg when the leg alone moves the balance; both shapes would
  otherwise let one delivery satisfy two checks, or measure net instead of gross.
  Multiple legs in different tokens, and one token to different recipients (the
  maker leg + a fee leg), are sound and supported.
- **Prefer plain fee-on-transfer tokens.** The check counts *any* balance increase
  across the fill, not specifically "sent by the filler". That is exactly right for
  an ordinary FoT token, but a reflection token that credits holders on every
  transfer — or an upward rebase mid-fill — can move the balance on its own, and a
  filler can lean on that to deliver less. Same trust posture as
  `MinBalanceInvariant`: the maker chose the token.

The SDK sets the bit with `withDeltaVerifyOutputs(timing)`
(`DELTA_VERIFY_OUTPUTS_BIT`). Unmarked orders are unaffected — delivery stays
nominal and the hot path pays only a bit test.

---

## Quoting and protecting a fill

A filler that quotes an order and submits a moment later is exposed to the tick
moving underneath it — more so with a module, whose input (an oracle, a quote)
can change independently of the clock. Two paired views close that:

- **`SettlementLens.previewBump(order, filler, takerData)`** returns the bump a
  fill by that filler would price at right now, resolved exactly as the fill does
  (the pinned path for a module / priority order, the clock otherwise).
- **`Settlement.fillUpTo(..., minBumpBps, ...)`** takes that value as a floor and
  reverts `BumpTooLow` if the fill would price worse.

⚠ For a **priority auction** the bump is derived from `tx.gasprice`, so a default
`eth_call` (gas price 0) quotes the *no-bid* bump — higher than any bid fill's.
Quote with the gas price you will actually send.

And **do pass the floor on a priority order** — the bid is
`tx.gasprice − block.basefee − baseline`, and only the first term is yours. Name a
gas price expecting to bid the difference over the current basefee, and you bid
*more* than that if the basefee drops before your transaction lands. The maker's
signed `start` caps how far that can go (an uncapped design has no such bound), but
`minBumpBps` is what holds your actual quote.

---

## Cost

Fill-only, same order shape, warm state
([`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol)):

| Mode | fill gas | Δ vs the clock |
|---|---|---|
| clock (linear decay) | 56,250 | — |
| block clock | 56,266 | +16 |
| priority auction | 56,159 | −91 |
| price module: range | 58,737 | +2,487 |
| price module: oracle-pegged | 61,819 | +5,569 |
| price module: cosigned quote | 63,683 | +7,433 |

A module costs one cold `STATICCALL` (~2.3k) plus whatever it does inside. Orders
that use none of this pay a single calldata compare.

---

## Writing one

1. Decide what the bump is a function of, and make sure it is **monotone in the
   direction the maker expects** — `bps` up means worse for the maker.
2. Put every parameter in immutables; validate them in the constructor.
3. Handle the preview shape (`filler == 0`, empty `takerData`) without reverting.
4. Read the legs with [`PackedArrays`](../packages/core/src/settlement/PackedArrays.sol) —
   the same readers the settler uses.
5. Remember the clamp is a backstop, not a licence: returning a wrong-but-in-band
   bump still prices a real fill.

Related: [fill-modules.md](fill-modules.md) (the fill *denominator*, a different
axis), [relayer-fees.md](relayer-fees.md) (rising input legs),
[lop-parity.md](lop-parity.md) §4–5 (why the shape is what it is, and
what it cost).

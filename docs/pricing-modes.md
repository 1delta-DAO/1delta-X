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

The maker signs the band **the other way round**:

```
legsOut[j].start = the ambitious price     ← what a large bid buys
legsOut[j].end   = the GUARANTEED FLOOR    ← what a zero-bid fill clears at

bump = BPS − min(BPS, priorityFee · BPS / params.priorityScale)
priorityFee = tx.gasprice − block.basefee          (0 if it underflows)
```

So an unbid fill clears at `end`, every wei of priority fee moves the tick toward
`start`, and the sequencer's own ordering picks the winner — losers revert on the
`filled` guard they already run ([filler-strategy.md](filler-strategy.md)).

Three consequences worth signing deliberately:

- **`params.priorityScale` is mandatory** here (`InvalidAuctionParams` otherwise):
  it is the wei of priority fee that buys a *full* bump.
- **The basefee gas bump is ignored** in this mode. It moves the tick toward the
  floor as gas rises, which is precisely backwards when the filler is bidding gas
  to move it the other way.
- **`decayStartTime` keeps its meaning** as a "not before" gate (a start BLOCK when
  combined with bit 102) — "let the book see this first, then let solvers bid".

Cost: **−217 gas** versus the clock (it skips the curve check and the elapsed
arithmetic).

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
| [`ChainlinkPeggedPriceModule`](../packages/core/src/modules/ChainlinkPeggedPriceModule.sol) | a Chainlink feed | staleness **and** an absolute `[MIN, MAX]` plausibility band — a fresh-but-wrong feed (depeg, decimals misconfiguration) reverts the fill instead of pricing against it. Configured per (feed, staleness, band, scale, side, spread). |
| [`RangePriceModule`](../packages/core/src/modules/RangePriceModule.sol) | `prevFilled / total` | the ladder: price varies along the VOLUME axis (1inch `RangeAmountCalculator`). Measured on `prevFilled`, so a solver knows the exact bump before submitting. |
| [`CosignedQuotePriceModule`](../packages/core/src/modules/CosignedQuotePriceModule.sol) | an EIP-712 quote signed by a named cosigner | UniswapX's cosigner without the trusted party: the cosigner is an immutable of the instance, any maker may deploy one, any filler may present a quote, and the quote can only improve *within* the band. `takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig`. **`FALLBACK_BPS` is not maker protection** — `takerData` is filler-controlled and a pinned bump replaces the clock, so an unquoted fill clears at `FALLBACK_BPS` immediately with no decay ramp. Use `0` (unquoted → `start`, quote required to improve — the adversarial-safe UniswapX shape) unless you specifically intend `end` to be the price a filler can always take. |

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
Quote with the gas price you will actually send, or skip the floor there: that
bump is your own bid, not a race.

---

## Cost

Fill-only, same order shape, warm state
([`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol)):

| Mode | fill gas | Δ vs the clock |
|---|---|---|
| clock (linear decay) | 56,140 | — |
| block clock | 56,157 | +17 |
| priority auction | 55,923 | −217 |
| price module: range | 58,455 | +2,315 |
| price module: oracle-pegged | 61,413 | +5,273 |
| price module: cosigned quote | 63,429 | +7,289 |

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
[lop-parity-plan.md](lop-parity-plan.md) §7–8 (why the shape is what it is, and
what it cost).

# Limit-order parity — the gaps and how they closed

Written 2026-08-12 after a feature diff against 1inch LOP v4 / Fusion+, UniswapX
(V2 / V3 / Priority reactors), CoW's ComposableCoW, and ERC-7683 / OIF.

**Status: SHIPPED, same day.** All five items below are implemented, tested and
building. What the plan got wrong is recorded inline — the byte budget in §7 was
optimistic by an order of magnitude, and §1's `bytes pricing` field had to become
an `address pricingModule` for exactly that reason. Read §7 before adding
anything else to the settler.

| Item | Where it landed |
|---|---|
| order shape (`params`, `pricingModule`) | [`Structs.sol`](../packages/core/src/settlement/Structs.sol), [`OrderHash.sol`](../packages/core/src/settlement/OrderHash.sol) |
| block clock + priority auction | [`DutchAuction.sol`](../packages/core/src/settlement/DutchAuction.sol) (`timing` bits 102/103) |
| external pricing | [`IPriceModule.sol`](../packages/core/src/interfaces/IPriceModule.sol) + three reference modules |
| Merkle bulk signing | [`Signatures.sol`](../packages/core/src/settlement/Signatures.sol) |
| ERC-7683 | [`OriginSettler7683.sol`](../packages/core/src/periphery/OriginSettler7683.sol), [`DestinationSettler7683.sol`](../packages/core/src/periphery/DestinationSettler7683.sol) |

Tests: [`PricingModes.t.sol`](../packages/core/test/swaps/PricingModes.t.sol),
[`BulkSignature.t.sol`](../packages/core/test/swaps/BulkSignature.t.sol),
[`Erc7683.t.sol`](../packages/core/test/periphery/Erc7683.t.sol),
[`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol).

**This document is the RATIONALE — the diff, the trade-offs, and what everything
cost.** The reference documentation for what shipped lives in
[pricing-modes.md](pricing-modes.md) and [bulk-signatures.md](bulk-signatures.md);
the order-shape change is in [SECURITY.md](../SECURITY.md)'s breaking-change
section.

## Scope

In:

1. **External pricing** — oracle-pegged and fill-progress (range) pricing, the
   1inch `IAmountGetter` class of orders. §3.
2. **Block-number decay clock** — UniswapX V3's reason: 250ms L2 blocks make a
   1-second timestamp tick too coarse. §2.
3. **Priority-fee auction** — UniswapX `PriorityOrderReactor` parity, for
   OP-stack / Arbitrum chains where the sequencer orders by priority fee. §2.
4. **Merkle bulk signing** — one signature over N orders (Seaport bulk orders,
   ComposableCoW's O(1) root, Fusion+'s Merkle-of-secrets). §4.
5. **Cosigner-improvable price** — UniswapX's cosigner, minus the trusted
   party: falls out of §3 as a price module, no core support of its own.
6. **ERC-7683 endpoint** — periphery adapter so existing 7683 solver fleets can
   fill our orders. §5.

Out:

- **Clear signing / ERC-7730.** The packed `bytes` blobs in the typehash are a
  deliberate trade (six keccaks, no per-element hashing); the readability cost
  is accepted. `FEATURES.md` §5's claim that the wallet prompt shows "a plain
  amount + recipient" is stale post-packing and should be corrected there, but
  no code changes.
- **Fusion+-style hashlock escrow for cross-chain.** Its safety model leans on a
  resolver whitelist and staked safety deposits; ours is permissionless by
  construction. Cross-chain gets its own design track — the 7683 adapter in §5
  is a *compatibility surface*, not that redesign.

## 1. The binding constraint, and the one-time shape change

`make size-check`, 2026-08-12:

```
Settlement (core-deploy) runtime  24172 / 24576      → 404 bytes free
```

Everything below is priced against those 404 bytes. Two levers:

- `optimizer_runs` 20000 → 15000 buys ~300 bytes for ~48 gas per fill
  (measured; see the note in [`foundry.toml`](../foundry.toml)).
- **The order shape itself.** Since §3 needs a new signed field and the
  typehash breaks anyway, fold three narrow fields into one word in the same
  break:

```
  REMOVE  uint256 exclusivityOverrideBps    (16 bits of information)
  REMOVE  uint256 gasBumpBps                (16 bits)
  REMOVE  uint256 gasPriceRef               (fits in 64 bits — 18.4 ETH of wei)
  ADD     uint256 params
            bits [  0: 16)  exclusivityOverrideBps
            bits [ 16: 32)  gasBumpBps
            bits [ 32: 96)  gasPriceRef            (wei)
            bits [ 96:160)  priorityScale          (§2; wei of priority fee per full bump)
            bits [160:256)  free
  ADD     bytes   pricing                   (§3; packed {address target, bytes data})
```

Field count 17 → 16, so the hash preimage goes **18 words → 17** and
[`OrderHash.hash`](../packages/core/src/settlement/OrderHash.sol) gets *cheaper*
than today while gaining a feature. Calldata drops one word per fill.

One break, one re-cut of the golden hash, one SDK release. Do §1–§4 behind a
single order-shape change; do not stagger them.

## 2. Clock modes — inline, in free `timing` bits

`timing` bits [102:256) are free ([`DutchAuction`](../packages/core/src/settlement/DutchAuction.sol)
documents [100:256) as free; 100 and 101 are now taken).

```
  bit 102  BLOCK_CLOCK       decayStartTime / decayDuration are BLOCKS, not seconds
  bit 103  PRIORITY_AUCTION  the bump is bid in priority fee, not elapsed time
```

Both are two-line branches inside `bumpBps`, which is the single place the whole
system resolves decay — `Pricing`, `Core`, `Batch` and `SettlementLens` all
inherit them for free.

**BLOCK_CLOCK.** `block.number` replaces `block.timestamp` in both the linear
and the piecewise branch; `CurvePoint.timeDelta` becomes a block delta. Nothing
else changes — `uint32` holds any L2 block number for the next few centuries.

**PRIORITY_AUCTION.** The existing tick math already does the work if the maker
signs the band the other way round:

```
  legsOut[j]: start = the ambitious price, end = the guaranteed floor
  bump = BPS - min(BPS, priorityFee * BPS / priorityScale)
  priorityFee = tx.gasprice - block.basefee     (0 if it underflows)
```

No bid ⇒ `bump == BPS` ⇒ the maker receives `end`, the signed floor, which is
exactly the guarantee `PriorityOrderReactor` gives. Every gwei of priority fee
moves the tick toward `start`, and the sequencer's own ordering picks the
highest bidder — losers revert on the `filled` guard they already run. The
maker's floor is the *same* absolute bound the core enforces today, so this mode
adds no new way to price outside the signed band.

`PRIORITY_AUCTION` **ignores the basefee gas bump** (it would push the tick the
wrong way) and returns before it; `priorityScale == 0` reverts
`InvalidAuctionParams`. Composing it with `BLOCK_CLOCK` is legal and is the
expected shape: "not fillable before block N, then bid".

Estimated cost: ~150–250 bytes, ~20 gas on orders that use them, 0 on those that
don't.

## 3. `pricing` — a bounded external bump provider

```solidity
interface IPriceModule {
    /// @return bps  the shared decay bump, [0, 10000]; the CORE clamps.
    function bump(
        Order calldata order,
        address filler,
        uint256 prevFilled,
        bytes calldata takerData,   // adversarial, filler-supplied
        bytes calldata data         // maker-signed, from order.pricing
    ) external view returns (uint256 bps);
}
```

Resolved in `bumpBps`, behind `order.pricing.length == 0` — one `STATICCALL`,
only for orders that ask for it, zero change to every existing order.

**Why this is safer than 1inch's amount getters.** `IAmountGetter` returns an
*amount*: whatever it says is what the maker pays or receives, so the getter is
fully trusted. This returns a *bump*, which the core clamps to `[0, BPS]` and
then maps through the maker's own signed `start`/`end` per leg. A hostile or
broken module can move the price anywhere **inside the band the maker signed and
nowhere outside it**. The band stays the hard bound it is today.

Reference modules — all periphery, **zero settlement bytes**:

| Module | Bump derived from | Parity with |
|---|---|---|
| `ChainlinkPeggedPriceModule` | oracle rate mapped into `[start, end]`, with staleness *and* a maker-signed `[min, max]` plausibility band | 1inch oracle-pegged orders — and it closes the known "freshness but not plausibility" gap in the validator set |
| `RangePriceModule` | `prevFilled / fillTotal` — price improves along the volume axis | 1inch `RangeAmountCalculator`; ladder / range orders |
| `CosignedQuotePriceModule` | an EIP-712 quote signed by a cosigner named in the maker-signed `data`, carried in `takerData` | UniswapX cosigner — but permissionless: the cosigner can only improve within the band, any filler may present the quote, and a maker who names no cosigner is unaffected |
| `CurveShapeModule` | anything else (vol-indexed, TWAP-of-oracle, …) | the open-ended case |

Note the composition rule: `pricing` replaces the *time* bump, so an order sets
either a curve or a price module, not both. `SettlementLens.previewFill` picks
it up automatically because it calls the same `bumpBps`.

Estimated cost: ~300–400 bytes core; ~2.6k gas per fill **only** on orders that
set it.

## 4. Merkle bulk signing

Envelope-only — no `Order` field, no typehash change, entirely inside
[`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol):

```
  sig = abi.encodePacked(innerSig(65), bytes32[] proof, bytes1(0xB0))
```

The trailing marker plus the length congruence (`len % 32 == 2` and
`len >= 98`) disambiguates it from both a plain ECDSA signature (64/65) and the
existing 20-byte delegate envelope, which is the same style of collision
argument that branch already makes. Verification:

```
  root   = fold(orderHash, proof)                 // sorted-pair keccak
  digest = _hashTypedData(hashStruct(OrderRoot{root}))
  → then the ordinary signer set: EOA / delegate / EIP-1271
```

`OrderRoot(bytes32 root)` is a new EIP-712 type in the Settlement domain, so a
bulk signature is deployment-bound exactly like a soft cancel. The
`filled[orderHash] != 0` first-fill skip is unchanged, and so is every
cancellation primitive — a root does not weaken `cancelOrder`, the nonce
bitmap, or the deadline.

What it buys: a 50-slice ladder, an N-way bracket, or a market maker's quote
refresh becomes **one wallet prompt**. Off-chain, the SDK builds the tree and
emits per-order `(order, sig+proof)` pairs; the orderbook verifies locally in
layer 1 with no extra RPC.

Estimated cost: ~250–350 bytes core, ~100 gas per proof level, 0 for
non-bulk signatures.

## 5. ERC-7683 adapter (periphery, zero core bytes)

By 2026 Across, UniswapX, CoW and Eco all expose 7683 endpoints and ~88% of
Across volume arrives that way. The value here is **distribution** — existing
solver fleets can route to us without a bespoke integration.

```
OriginSettler7683
  openFor(GaslessCrossChainOrder, signature, originFillerData)   → our signed Order + fill
  open(OnchainCrossChainOrder)                                   → maps onto approveOrder (sigless path)
  resolveFor / resolve → ResolvedCrossChainOrder
      user          = order.maker
      orderId       = the Settlement order hash        (already unique, already cancellable)
      minReceived   = legsIn  at the current tick      (what the filler collects here)
      maxSpent      = legsOut at the current tick      (what the filler owes there)
      fillInstructions = destinationChainId, destinationSettler, originData
  orderDataType = ORDER_TYPEHASH, orderData = the encoded Order

DestinationSettler7683
  fill(orderId, originData, fillerData) → Settlement.fill on the destination chain
```

**The mismatch to design around, honestly.** 7683 assumes the user's funds are
escrowed at `open` and the solver is repaid after proving the destination fill.
We have no escrow: funds are pulled from the maker via Permit3 *at fill time*,
which is the property that makes the system admin-free. So the adapter must
present one of:

- **fill-time settlement** (preferred, escrow-free): the origin `open` is a
  no-op registration and the origin fill *is* the settlement, with the existing
  `BridgedOrderInbox` full-funding invariant carrying the destination side. 7683
  solvers see a conventional order; the escrow is simply empty because there is
  nothing to escrow until someone fills.
- **opt-in escrow** for solvers who require the standard's ordering, built as a
  module, never as a core requirement.

Refunds and failure stay what they are today: permissionless `settle` after the
deadline, no privileged party. Decide this against the cross-chain track before
building — the interfaces are stable either way, the fund flow is not.

## 6. Sequencing

| Phase | Work | Breaks |
|---|---|---|
| 0 | Order shape: `params` packing + `bytes pricing`; re-cut typehash, `OrderHash.hash`, golden test, SDK `packOrder`/`eip712`/`pricing`, orderbook wire format | typehash, golden hash, SDK, book |
| 1 | `BLOCK_CLOCK` + `PRIORITY_AUCTION` in `bumpBps`; lens + SDK `pricing.ts` mirror | nothing further |
| 2 | `IPriceModule` seam + the four reference modules + fork tests | nothing further |
| 3 | Merkle envelope in `_verifySignature`, `OrderRoot` type, SDK tree builder, book verifier | nothing further |
| 4 | 7683 adapters + a solver-side integration test | nothing further |

Phases 1–3 each need a `make size-check` and a `make gas` diff; the budget below
is the acceptance criterion.

## 7. Byte budget — what actually happened

The estimates above were wrong by roughly 5×, and the reason is worth writing
down because it will govern the next core feature too.

**Settlement is inlined, and `bumpBps` is inlined the most.** At
`optimizer_runs = 20000` the optimizer inlines `Pricing` (and through it
`bumpBps`) at every delivery / payout / pull site across `Core`, `Batch` and the
lens — roughly eight copies. The first cut branched the two new clock modes and
the price hook INSIDE `bumpBps`, so every byte was paid eight times:

```
baseline                                                  24,172   (404 free)
+ shape change + clocks + price hook inside bumpBps        27,254   (2,678 OVER)
```

Three restructurings brought it back, all behaviour-preserving:

| Change | Returned |
|---|---|
| move the cold modes out of `bumpBps` into a once-per-fill `resolveBump` (pinned in `FillCtx.bump`) | **1,343** |
| verify a bulk signature by SWAPPING THE DIGEST into the existing signer set, instead of a second copy of `recoverCalldata`/`verify` | **~1,000** |
| `bytes pricing {target,data}` → `address pricingModule` (a 7th dynamic member grows the `Order` decoder at EVERY external entry point) | **~1,000** |

Final, and the size/`optimizer_runs` curve for the deployed profile:

```
runs      Settlement runtime      free
20,000         26,547            −1,971   FAIL
5,000          25,705            −1,129   FAIL
3,000          25,033              −457   FAIL
1,500          24,522                54   fits, no margin
800            23,479             1,097   ← [profile.core-deploy]
```

Note the curve is NOT monotonic in `runs` — the pristine baseline measures 24,172
at 20,000 but 26,149 at 6,000. Inlining decisions move in steps, so a size
regression must always be measured, never predicted.

`optimizer_runs = 800` therefore lives in `[profile.core-deploy]` alone: the
deployed artifact shrinks, and `[profile.default]` (which every other package and
the whole gas baseline uses) is untouched at 20,000.

## 8. What it costs to run

Two measurements, because they answer different questions.

**A. What every existing order now pays.** `.gas-snapshot` diff, 533 comparable
tests (`[profile.core]`):

| Group | n | median Δ | range |
|---|---|---|---|
| single fills (`swaps/*`) | 132 | **+387** | −38 … +1,576 |
| batch / `matchSettle` | 59 | **+854** | −258 … +3,206 |
| items / modules | 41 | +442 | −22 … +1,759 |
| validators / lens | 72 | +102 | −97 … +1,713 |
| signatures / nonces | 23 | +144 | −121 … +639 |
| **all** | **533** | **+283** | median **+0.09%** on tests above 50k |

The canonical hot path, `test_plain_swap_full`, went **504,223 → 504,592
(+369, +0.07%)**. That is the whole feature set: one more `FillCtx` word, the
`resolveBump` call, and the `pricing`/`priority` compares. `matchSettle` pays the
most because the extra context word is per ORDER in a plan.

Two outliers of +7.5k (`SettlementGuards` re-entrancy tests) are **not** a
settlement regression: those tests `new` a mock that ABI-encodes an `Order[]`, and
the changed struct grew the mock by ~37 bytes — at 200 gas per deployed byte that
is the entire delta. Same explanation as the 45 dearer tests in the 2026-08-09
`optimizer_runs` pass.

**B. What each new mode costs when you use it.** Fill-only, measured with
`gasleft()` around the call so no setup or deployment is counted, same order shape
(one fixed input leg, one decaying output leg, whole fill), warm state —
[`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol):

| Mode | fill gas | Δ vs the clock |
|---|---|---|
| clock (linear decay) — reference | 56,140 | — |
| **block clock** | 56,157 | **+17** |
| **priority auction** | 55,923 | **−217** (it skips the curve check and the elapsed math) |
| **price module: range** | 58,455 | **+2,315** |
| **price module: oracle-pegged** | 61,413 | **+5,273** |
| **price module: cosigned quote** | 63,429 | **+7,289** |
| **bulk signature, 2 proof levels** | — | **+1,368** vs a single signature |

So the two clock modes are free, and a price module costs one cold `STATICCALL`
(~2.3k) plus whatever it does inside — an oracle read is ~3k more, an `ecrecover`
over a quote ~5k more. Pinning is why that is paid ONCE and not per decaying leg.

⚠ Both tables are `[profile.core]` (legacy codegen, `optimizer_runs = 20000`).
Production runs `[profile.core-deploy]` (via-IR, 400) and additionally pays
whatever that optimizer step costs, which is **not measured** — a via-IR test run
needs a profile that excludes the ~900KB `LenderRegistry` data contract. Build it
before quoting production gas.

**Three lessons for the next core feature.** (1) Anything reachable from
`Pricing`/`bumpBps` is multiplied ~8×; put cold paths behind a single call site.
(2) A new DYNAMIC `Order` member is ~1,000 bytes before it does anything —
prefer a static field and push configuration into the module's immutables.
(3) A second verifier copy costs as much as the feature; reuse the existing tail
by changing its inputs.

# Limit-order parity — what shipped, and what it cost

A reference for the 2026-08 feature set that closed the gap against 1inch LOP v4 /
Fusion+, UniswapX (V2 / V3 / Priority reactors), CoW's ComposableCoW, and
ERC-7683 / OIF — and for the size and gas economics that shaped it.

**This document is the RATIONALE and the COST RECORD**: why each feature has the
shape it has, what it displaced, and what it measures. The how-to references live
in [pricing-modes.md](pricing-modes.md) and [bulk-signatures.md](bulk-signatures.md);
the order-shape break is in [SECURITY.md](../SECURITY.md)'s breaking-change section.

Read §4 before adding anything else to the settler — the byte budget is the
binding constraint on this contract, and the estimates that preceded it were wrong
by roughly 5×.

## What exists

| Feature | Where |
|---|---|
| order shape (`params` word, `pricingModule`) | [`Structs.sol`](../packages/core/src/settlement/Structs.sol), [`OrderHash.sol`](../packages/core/src/settlement/OrderHash.sol) |
| block clock, priority auction, delta-verify delivery | [`DutchAuction.sol`](../packages/core/src/settlement/DutchAuction.sol) (`timing` bits 102 / 103 / 104) |
| external pricing | [`IPriceModule.sol`](../packages/core/src/interfaces/IPriceModule.sol) + three modules |
| Merkle bulk signing | [`Signatures.sol`](../packages/core/src/settlement/Signatures.sol) |
| ERC-7683 | [`OriginSettler7683.sol`](../packages/periphery/src/OriginSettler7683.sol), [`DestinationSettler7683.sol`](../packages/periphery/src/DestinationSettler7683.sol) |

Tests: [`PricingModes.t.sol`](../packages/core/test/swaps/PricingModes.t.sol),
[`BulkSignature.t.sol`](../packages/core/test/swaps/BulkSignature.t.sol),
[`Erc7683.t.sol`](../packages/periphery/test/Erc7683.t.sol),
[`DeltaVerifyDelivery.t.sol`](../packages/core/test/swaps/DeltaVerifyDelivery.t.sol),
[`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol).

**Deliberately not built.** *Clear signing / ERC-7730* — the packed `bytes` blobs
in the typehash are a deliberate trade (six keccaks, no per-element hashing) and
the readability cost is accepted. *Fusion+-style hashlock escrow* — its safety
model leans on a resolver whitelist and staked safety deposits; ours is
permissionless by construction, so cross-chain gets its own design track. The 7683
adapter (§3) is a compatibility surface, not that redesign.

## 1. The order shape

The external-pricing feature needed a new signed field, which breaks the typehash.
Three narrow fields were folded into one word in the same break, so there was one
break rather than two:

```
  REMOVED  uint256 exclusivityOverrideBps    (16 bits of information)
  REMOVED  uint256 gasBumpBps                (16 bits)
  REMOVED  uint256 gasPriceRef               (fits in 64 bits — 18.4 ETH of wei)
  ADDED    uint256 params
             bits [  0: 16)  exclusivityOverrideBps
             bits [ 16: 32)  gasBumpBps
             bits [ 32: 96)  gasPriceRef            (wei)
             bits [ 96:160)  priorityScale          (wei of priority fee per full bump)
             bits [160:256)  free
  ADDED    address pricingModule
```

Field count went 17 → 16, so the hash preimage is **17 words** and
[`OrderHash.hash`](../packages/core/src/settlement/OrderHash.sol) is *cheaper* than
before while carrying more features. Calldata drops one word per fill.

`pricingModule` is a plain `address`, not the `bytes pricing {target, data}` blob
originally designed: a seventh **dynamic** `Order` member grows the ABI decoder at
every external entry point and measured ~1,000 bytes of Settlement before doing
anything. Module configuration lives in the module's own immutables instead — one
CREATE2 instance per configuration, and the maker's signature over the address is
the commitment to it.

## 2. `timing` modes

`timing` bits [105:256) remain free (bits 100 and 101 are the fill-once opt-in and
the order side).

```
  bit 102  BLOCK_CLOCK          decayStartTime / decayDuration are BLOCKS, not seconds
  bit 103  PRIORITY_AUCTION     the bump is bid in priority fee, not elapsed time
  bit 104  DELTA_VERIFY_OUTPUTS outputs are VERIFIED by the recipient's balance delta
                                (>= the leg's priced amount) instead of pushed nominally
```

The two clock modes are resolved once per fill by `resolveBump` and pinned in
`FillCtx.bump`, so `Pricing`, `Core`, `Batch` and `SettlementLens` all inherit them
without their own branches. Bit 104 is not a clock — it changes how the priced
amount is *delivered*, so it composes with whichever mode set the price.

**BLOCK_CLOCK.** `block.number` replaces `block.timestamp` in both the linear and
the piecewise branch; `CurvePoint.timeDelta` becomes a block delta. `uint32` holds
any L2 block number for centuries. UniswapX moved its V3 reactor to a block clock
for the same reason: on a 250ms-block chain a one-second tick is eight blocks of
resolution, coarser than the interval solvers compete over.

**PRIORITY_AUCTION.** The existing tick math does the work once the maker signs the
band the other way round:

```
  legsOut[j]: start = the ambitious price, end = the guaranteed floor
  bump = BPS - min(BPS, priorityFee * BPS / priorityScale)
  priorityFee = tx.gasprice - block.basefee     (0 if it would underflow)
```

No bid ⇒ `bump == BPS` ⇒ the maker receives `end`, its signed floor — exactly the
guarantee `PriorityOrderReactor` gives. Every gwei moves the tick toward `start`,
the sequencer's ordering picks the winner, and losers revert on the `filled` guard
they already run. The floor is the same absolute bound every other order has, so
the mode adds no way to price outside the signed band. It ignores the basefee gas
bump (which would push the tick the wrong way) and reverts `InvalidAuctionParams`
on `priorityScale == 0`. Composing it with `BLOCK_CLOCK` is the expected shape:
"not fillable before block N, then bid".

**DELTA_VERIFY_OUTPUTS.** The fee-on-transfer-safe delivery mode: the settler
snapshots each output recipient at fill start and requires the measured balance
increase to be at least the leg's priced amount, instead of pushing that amount
from the filler. The filler delivers out-of-band in its callback. Full semantics,
shape restrictions and caveats: [pricing-modes.md](pricing-modes.md).

## 3. External pricing, bulk signing, ERC-7683

**`IPriceModule`** — the 1inch `IAmountGetter` class of orders, with one deliberate
difference: a module returns a **bump**, never an amount.

```solidity
function bump(
    bytes32 orderHash, address maker, address filler,
    uint256 prevFilled, uint256 total, uint256 orderTiming,
    bytes legsIn, bytes legsOut, bytes takerData
) external view returns (uint256 bps);
```

`IAmountGetter` returns the making/taking amount, so the getter *is* the price and
is trusted absolutely. This returns the shared decay bump, which the core clamps to
`[0, BPS]` and maps through each leg's own signed `start`/`end`. A hostile, buggy
or stale module can move the price anywhere **inside the band the maker signed and
nowhere outside it**. The arguments are the packed leg blobs plus flat scalars
rather than `Order calldata` — a full-order encoder for this call site measured
~1,300 bytes. Three modules ship: `ChainlinkPeggedPriceModule` (oracle-pegged, with
staleness *and* an absolute plausibility band), `RangePriceModule` (the volume axis
— 1inch `RangeAmountCalculator`), and `CosignedQuotePriceModule` (UniswapX's
cosigner, minus the trusted party). A module replaces the time bump, so an order
signs either a curve or a module, not both; `SettlementLens.previewBump` resolves
it the same way a fill does.

**Merkle bulk signing** — envelope-only: no `Order` field, no typehash change,
entirely inside [`Signatures._verifySignature`](../packages/core/src/settlement/Signatures.sol).

```
  sig    = abi.encodePacked(innerSig(65), bytes32[] proof, bytes1(0xB0))
  root   = fold(orderHash, proof)                 // sorted-pair keccak
  digest = _hashTypedData(hashStruct(OrderRoot{root}))
  → then the ordinary signer set: EOA / delegate / EIP-1271
```

The trailing marker plus the length congruence (`len >= 98`, `(len - 66) % 32 == 0`)
disambiguates it from a plain ECDSA signature and from the 20-byte delegate
envelope. `OrderRoot(bytes32 root)` is an EIP-712 type in the Settlement domain, so
a bulk signature is deployment-bound like a soft cancel. Cancellation is untouched:
a root does not weaken `cancelOrder`, the nonce bitmap, or the deadline. What it
buys is one wallet prompt for a 50-slice ladder or a quote refresh.

**ERC-7683** — periphery adapters, zero core bytes. By 2026 Across, UniswapX, CoW
and Eco all expose 7683 endpoints, so the value is **distribution**: existing solver
fleets route to us with no bespoke integration. `orderId` is the Settlement order
hash (already unique, already cancellable) and `minReceived`/`maxSpent` come from
the same `previewFill` a fill prices with.

The standard assumes the user's funds are escrowed at `open`; ours are pulled from
the maker via Permit3 **at fill time**, which is the property that keeps the system
admin- and custody-free. The adapters therefore present the **escrow-free** shape:
`open`/`openFor` verify liveness and authorization and emit the standard `Open`
event, and an order is fillable before, during and after by anyone. There is
nothing to refund and no non-performance to punish — a filler that walks away costs
the maker nothing. Solvers that require the standard's escrow ordering can wrap
this in one of the bridge package's inboxes; that stays opt-in, never a core
requirement.

## 4. The byte budget

**Settlement does not fit under the legacy optimizer.** Measured on the current
source: legacy `[profile.core]` produces **33,209 bytes** against EIP-170's 24,576
— 8,633 over, and the build fails. Only `[profile.core-deploy]` (via-IR,
`optimizer_runs = 400`) yields a deployable artifact. via-IR is a requirement, not
a preference, and every gas figure in `.gas-snapshot` is therefore a *conservative
legacy* number rather than what deploys.

**Why the first cut blew up.** At `optimizer_runs = 20000` the optimizer inlines
`Pricing` (and through it `bumpBps`) at every delivery / payout / pull site across
`Core`, `Batch` and the lens — roughly eight copies. Branching the new modes
*inside* `bumpBps` meant paying every byte eight times:

```
baseline                                                  24,172   (404 free)
+ shape change + clocks + price hook inside bumpBps        27,254   (2,678 OVER)
```

Three behaviour-preserving restructurings brought it back:

| Change | Returned |
|---|---|
| move the cold modes out of `bumpBps` into a once-per-fill `resolveBump` (pinned in `FillCtx.bump`) | **1,343** |
| verify a bulk signature by SWAPPING THE DIGEST into the existing signer set, instead of a second copy of `recoverCalldata`/`verify` | **~1,000** |
| `bytes pricing {target,data}` → `address pricingModule` (a 7th dynamic member grows the `Order` decoder at EVERY external entry point) | **~1,000** |

The same trap recurred later, and the fix is the same shape: the delta-verify guards
first cost **1,201 bytes** because the duplicate-leg scan added a second
`PackedArrays.legOut` inline site; caching the decoded pairs into memory arrays gave
one decode site and returned **958** of them.

**The `optimizer_runs` curve is not a free lever.** Recorded in
[`foundry.toml`](../foundry.toml) for `[profile.core-deploy]`:

```
runs      Settlement runtime      free
20,000        (over cap)         FAIL
1,500          24,522                54   fits, but one PR from failing
800            24,331               245
400            24,186               390   ← [profile.core-deploy]
200            24,179               397   floor; nothing below 400 buys more
```

The curve is **not monotonic in either direction** — a pristine source measured
24,172 at 20,000 but 26,149 at 6,000, because `runs` moves inlining decisions in
steps. A size change must always be measured, never predicted; and because the
curve is flat below 400, lowering `runs` is not a way out of a size regression.
`400` lives in `[profile.core-deploy]` alone, so `[profile.default]` — which every
other package and the whole gas baseline uses — stays at 20,000.

## 5. What it costs to run

Two measurements, because they answer different questions.

**A. What every existing order pays for the feature set.** `.gas-snapshot` diff at
the time the features landed, 533 comparable tests (`[profile.core]`):

| Group | n | median Δ | range |
|---|---|---|---|
| single fills (`swaps/*`) | 132 | **+387** | −38 … +1,576 |
| batch / `matchSettle` | 59 | **+854** | −258 … +3,206 |
| items / modules | 41 | +442 | −22 … +1,759 |
| validators / lens | 72 | +102 | −97 … +1,713 |
| signatures / nonces | 23 | +144 | −121 … +639 |
| **all** | **533** | **+283** | median **+0.09%** on tests above 50k |

The canonical hot path, `test_plain_swap_full`, went **504,223 → 504,592 (+369,
+0.07%)** for the whole feature set: one more `FillCtx` word, the `resolveBump`
call, and the mode compares. `matchSettle` pays most because the extra context word
is per ORDER in a plan. Two +7.5k outliers in `SettlementGuards` are not a
settlement regression — those tests `new` a mock that ABI-encodes an `Order[]`, and
the changed struct grew the mock by ~37 bytes at 200 gas per deployed byte.

**B. What each mode costs when an order uses it.** Fill-only, `gasleft()` around
the call so no setup or deployment is counted, same order shape (one fixed input
leg, one decaying output leg, whole fill), warm state —
[`PricingGasBench.t.sol`](../packages/core/test/swaps/PricingGasBench.t.sol):

| Mode | fill gas | Δ vs the clock |
|---|---|---|
| clock (linear decay) — reference | 56,140 | — |
| **block clock** | 56,157 | **+17** |
| **priority auction** | 55,923 | **−217** (skips the curve check and the elapsed math) |
| **price module: range** | 58,455 | **+2,315** |
| **price module: oracle-pegged** | 61,413 | **+5,273** |
| **price module: cosigned quote** | 63,429 | **+7,289** |
| **bulk signature, 2 proof levels** | — | **+1,368** vs a single signature |

So the two clock modes are effectively free, and a price module costs one cold
`STATICCALL` (~2.3k) plus whatever it does inside — an oracle read ~3k more, an
`ecrecover` over a quote ~5k more. Pinning is why that is paid once per fill rather
than per decaying leg.

⚠ Both tables are `[profile.core]` (legacy codegen, `optimizer_runs = 20000`).
Production runs `[profile.core-deploy]` (via-IR, 400), where the same code measures
materially cheaper — the recorded example is a `Pricing` branch costing +232 gas
under legacy and **+40** under via-IR. Treat legacy figures as an upper bound, and
do not tune against them.

## Three rules for the next core feature

1. **Anything reachable from `Pricing`/`bumpBps` is multiplied ~8×.** Put cold
   paths behind a single call site — that is what `resolveBump` is.
2. **A new DYNAMIC `Order` member costs ~1,000 bytes before it does anything.**
   Prefer a static field, a free `timing` bit, or configuration pushed into a
   module's immutables.
3. **Internal library calls inline per call site.** A second decode or a second
   verifier copy costs as much as the feature; reuse the existing tail by changing
   its inputs, or cache the decoded values.

---
title: The signed order
slug: order-model
eyebrow: Model
description: One EIP-712 struct carries the legs, the venue actions, the conditions, the price curve and the fill unit. Everything a filler is permitted to do is a consequence of what is inside that hash.
---

Everything the protocol does is a consequence of one struct. If a byte of it
changes, the signature no longer verifies and the allowance it keys no longer
matches — so the entire permission model reduces to *what the maker signed*.

## The fields

| Field group | Carries |
|---|---|
| `legsIn[]` / `legsOut[]` | Multi-asset baskets on both sides. A leg is `(token, start, end)`; output legs additionally carry their own `recipient`. |
| `side` (SELL / BUY) | SELL = fixed inputs, decaying outputs, anchored on `legsIn[0]`. BUY = fixed outputs, rising inputs, anchored on `legsOut[0]`. Lives in `timing` bit 101. |
| `items[]` | Ordered maker-signed module calls: `MAKE`, `TAKE`, `SETTLE`. |
| `timing` | Three `uint32` clocks in one word (decay start, decay duration, exclusivity end) plus the item-ordering policy and the mode bits: fill-once (100), side (101), block clock (102), priority auction (103), delta-verify delivery (104). |
| `curve` | Optional piecewise-linear decay shape — `(timeDelta, bumpBps)` points. Empty means one linear segment. |
| `params` | One word with the four auction scalars: soft-exclusivity bps, gas-bump bps, gas price reference, priority-fee scale. |
| `pricingModule` | Optional external price provider. `0x0` = the built-in clock. |
| `exclusiveFiller` | Hard exclusivity — only that filler until the exclusivity deadline. |
| `minFillAnchor` | Anti-dust floor per fill. |
| `validators[]` / `invariants[]` | AND-composed pre-execution triggers and post-execution invariants. `staticcall` only. |
| `fillModule` / `fillTotal` | The fill denominator, decoupled from any fungible leg. |
| `nonce` / `deadline` | Bitmap nonce (256 per storage slot) and expiry. |
| `maker` | The account whose signature, delegates, allowances and positions the whole order is scoped to. |

`legsIn`, `legsOut`, `items`, `validators`, `invariants` and `curve` are packed
count-prefixed `bytes` blobs rather than struct arrays — materially cheaper to
hash and to access. See [Optimization](/optimization/#packed-order-arrays) for
what that bought and what it cost.

## Uniform leg pricing

Every leg on both sides obeys one rule:

- `end == 0` is the **fixed sentinel** — the leg transfers `start` on every fill.
- Otherwise the leg is auctioned on the order's shared clock. **Inputs may only rise, outputs may only fall**; a falling input reverts `InvalidAuctionParams`.

A fixed-price OTC order is therefore simply `end == 0` on every leg — no flag, no
separate order type. A gasless deposit is an order whose only input leg *rises*:
the filler is paid by that leg, and the first filler for whom the tick covers gas
plus margin takes it. Nothing about "relayer fee" exists in the contract; it
falls out of uniform leg pricing.

The signed `end` is an **absolute bound**. No clock, oracle, priority bid, price
module or filler can produce a fill outside `[start, end]`.

## Single-fraction partial fills

```
fraction      = fillAmount / total           total = fillTotal, else the anchor leg
fillAmountOut = fillAmountIn × currentAmountOut / total     (ceil, maker-favourable)
itemSlice     = item.amount × fillAmount / total            (cumulative)
```

One scalar scales every leg and every item slice. A filler cannot size legs
independently; repeated partial fills accumulate exactly to the signed totals;
and items stay in sync with the auction across fills.

Rounding is uniformly maker-favourable: fixed legs are exact and cumulative,
auctioned legs round toward the maker per fill. Splitting a fill therefore costs
the *filler* up to one wei per leg per fill, and `minFillAnchor` bounds how far
that can be ground.

## Items — acting on the maker's own position

Three ops, one uniform trust rule.

| Op | Scope | Moves | Filler-aware | Cost |
|---|---|---|---|---|
| `MAKE` | maker deposits / repays | maker's funding token → protocol | no | 1 CALL |
| `TAKE` | maker borrows / withdraws | maker's position → `recipient` | no | 1 CALL via Permit3 |
| `SETTLE` | generic solver ↔ maker exchange | maker's asset → filler, or filler's → maker | **yes** | 1 CALL, pay-per-use |
| `fillModule` | the fill denominator (a scalar) | nothing (view) | no | 1 STATICCALL, or 0 |

**`data` is opaque and signed.** Each module decodes its own protocol-specific
parameters from `item.data`. That blob is inside the EIP-712 hash *and* is the
Permit3 taker-allowance preimage (`ref = keccak256(data)`), so a filler can never
repoint the pool, the market, the rate mode or the receiver.

**Items chain.** A TAKE item's `recipient` defaults to Settlement, so its
proceeds pay the filler. Signing `recipient = maker` instead routes the proceeds
into a following MAKE item — which is how a migration or a leverage entry
composes with no intermediate solver capital.

**Ordering policy.** `ANY` (default), `ORDERED` (signed index order) or `ATOMIC`
(signed order, back-to-back, nothing interleaved — for venues that check health
inside each call). A single-order fill satisfies all three by construction and
pays nothing for the choice; only the netted path can violate one.

## Conditions

Validators run before any item executes; invariants run after everything. Both
are `staticcall`, and both have their `target` and `data` inside the typehash, so
a filler can neither weaken nor swap one. `staticcall` forbids state change, logs
and re-entrancy — a broken condition can do nothing worse than return the wrong
boolean.

| Contract | Passes when |
|---|---|
| `ChainlinkPriceGte` / `ChainlinkPriceLte` | a fresh feed price is ≥ / ≤ the signed threshold |
| `ChainlinkTickFloorValidator` | the signed tick is within tolerance of the live oracle rate |
| `TimestampValidator` | `notBefore ≤ block.timestamp ≤ notAfter` |
| `PredicateStaticCall` | an arbitrary staticcall returns non-zero |
| `FillerWhitelistValidator` | the filler is on a curator's list |
| `FillerAttestationValidator` | the filler presents a valid off-chain attestation bound to the order |
| `ConditionTreeValidator` | a maker-signed boolean expression over other validators holds — `OR` and `NOT` in disjunctive normal form |
| `MinBalanceInvariant` | the account ends the fill holding ≥ a floor |
| `Erc721OwnerInvariant` / `Erc1155BalanceInvariant` | the maker ends the fill owning the NFT / ≥ N units |

Validators are **filler-aware** — they receive the fill's `msg.sender` — which is
what makes per-order solver whitelists and attestation gating expressible. They
also receive a filler-supplied `takerData` blob, which is **unsigned and
adversarial**: a validator must independently verify anything it reads from it.

The worst `takerData` can do to a maker is move a fill to a different point
*inside* the signed band, or size the fraction it advances. It can never price
outside the band, redirect a leg or introduce a token — the three consumers are a
read-only gate, a fill fraction under the over-fill cap, and a bump the core
clamps.

## Pricing modes

Four modes produce the one shared bump, and every mode maps it through each leg's
own signed bounds.

| Mode | The bump comes from | Use for |
|---|---|---|
| Time clock (default) | elapsed seconds since `decayStart` | ordinary dutch decay |
| Block clock (`timing` bit 102) | elapsed **blocks** | chains whose blocks are faster than a one-second tick |
| Priority auction (bit 103) | the transaction's priority fee × `params.priorityScale` | chains whose sequencer orders by priority fee |
| Price module (`pricingModule`) | an `IPriceModule` staticcall | oracle-pegged, fill-progress ladders, cosigner-quoted RFQ |

Shipped price modules: `ChainlinkPeggedPriceModule` (feed + staleness + an
absolute plausibility band), `RangePriceModule` (prices off fill progress) and
`CosignedQuotePriceModule` (an EIP-712 quote from a maker-named cosigner carried
in `takerData`).

A module is resolved **once per fill** and pinned, so a multi-leg order pays one
staticcall, and an order that uses none pays a single calldata compare. Measured,
fill-only, against a 56,140-gas clock-priced fill: block clock **+17**, priority
auction **−217**, range module **+2,315**, oracle-pegged **+5,273**, cosigned
quote **+7,289**.

Two more knobs ride on the same tick: a **gas-indexed bump** (`gasBumpBps` /
`gasPriceRef`) widens the filler's margin automatically when the network is
expensive, and **soft exclusivity** requires any filler other than the named one
to improve the maker's leg by N bps — applied only to legs delivered to the
maker, so a third-party fee leg is never inflated.

### Delta-verify delivery

`timing` bit 104 is not a pricing mode but a **delivery** mode: instead of
pushing the computed amount from the filler, the settler verifies the
**recipient's measured balance delta** against the leg's priced amount. That
makes a fee-on-transfer output safe — the maker's signed amount becomes a
net-of-fee floor — and it is the generic outcome-based primitive: the filler
sources liquidity however it likes inside its callback and the core checks only
the result. Callback-only, and refused on the netted path.

## Balance-relative legs

`legsIn[0].start` on a SELL order may carry a **proportional marker** instead of
an absolute amount: "sell N bps of whatever I hold when this fills". The bps live
in the top of the existing word, above any reachable token amount, so the
typehash and the golden order hash are unchanged and no order needs re-signing.

Two properties follow and both are enforced:

- **Whole-fill only** — a live-balance denominator cannot measure partial progress.
- **`end` is a mandatory cap.** A maker's balance is not under their sole control (anyone may raise it by sending tokens), so an uncapped sweep would be a standing offer to buy the maker's entire holding at a small order's price. `end == 0` on a marker leg reverts `ProportionalNeedsCap` — the dangerous mode must not be what an unset field means.

Multi-token sweeps are a module (`ProportionalSweepModule`), not a leg — see
[Optimization](/optimization/#what-the-byte-budget-refused) for why.

## Who may authorize an order

There are exactly three sources of authority, and no fourth. In particular there
is **no protocol-level operator**: no admin-set address can sign for a user, and
no role exists that could be granted one.

1. **The maker's own signature** — EOA, EIP-2098 compact, EIP-1271 (Safe, multisig, contract makers), EIP-7702.
2. **A key the maker itself nominated** via `setOrderSigner(signer, expiry)`, or via a relayed EIP-712 nomination permit for a maker with no gas. The registry is keyed by `msg.sender` on write and by the **order's own maker** on read — so nobody can nominate a signer for someone else, a delegate can author nothing its nominator could not have authored itself, and delegates cannot appoint further delegates.
3. **An on-chain record the maker itself wrote** — `approveOrder`, with a batch `approveOrders` so a multisig authorizes a whole ladder in one queued action.

**Bulk (Merkle) signatures** let one signature authorize N orders: the maker
signs `OrderRoot(bytes32 root)` and each order carries its inclusion proof in the
signature envelope (`innerSig(65) ‖ proof ‖ 0xB0`). A 50-slice ladder, an N-way
bracket or a quote refresh becomes one wallet prompt. A root does not outrank any
cancellation primitive.

## Cancellation

Five granularities — four authoritative, one free.

| Primitive | Scope | Binds a filler? |
|---|---|---|
| `cancelOrder(order)` | exactly one order, **by hash** — nonce siblings stay fillable | yes |
| `cancelOrders(nonces[])` | every order carrying any of those nonces | yes |
| `invalidateNonceWord(word)` | 256 nonces in one SSTORE | yes |
| `rollbackNonces(minValid)` | everything below a watermark, one SSTORE | yes |
| signed `SoftCancel` | any set of hashes, **zero gas** | no — advisory, evicts from books |

`cancelOrder` costs the hot path nothing: it parks the `filled` counter at a
sentinel, a slot every fill already reads, so the check is one compare. The soft
cancel is EIP-712 in the Settlement domain — deployment-bound, batchable, and
verified under the same signer set an order is.

**Brackets and one-cancels-other** are expressible two ways, neither touching the
core: a **shared nonce** with the fill-once bit (free, whole-fill only), or
`OcoGroupModule` — a validator that *reads* a group claim plus a `SETTLE` item
that *writes* it, which works because validators run before items.

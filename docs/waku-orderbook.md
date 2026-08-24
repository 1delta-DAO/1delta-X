# Waku Order Distribution (P2P Orderbook)

> **Status: transport seam + centralized fill implemented; Waku transport
> pending.** The transport-agnostic order-distribution layer this note calls for
> now exists as [`@1delta-x/orderbook`](../packages/orderbook) (protobuf message
> types, the L1+L2 verification pipeline, and the `Book`), with a centralized
> demo backend in [`@1delta-x/orderbook-server`](../packages/orderbook-server)
> running that `Book` over an in-memory transport. Waku is the remaining piece: a
> second `Transport` implementation, dropped in with no change to `Book`,
> verification, or the wire format. Nothing here is on the critical path of the
> settlement contract — the chain stays the source of truth; this is purely how
> an order travels from maker to filler.

The settlement contract has **no on-chain orderbook**. Orders live entirely
off-chain as a signed `(Order, sig)` tuple (see the SDK [`Order`](../packages/sdk/src/types.ts)
type and [`Structs`](../packages/core/src/settlement/Structs.sol)),
and nothing in the protocol specifies how that tuple gets from the maker to a
filler. Today that slot is open — the README just says "signed off-chain orders,
like Fusion / CoW". A centralized relayer/API is the obvious fill; this note is
the decentralized alternative: gossip the orders over [Waku](https://waku.org)
and let each filler reconstruct its own book.

---

## Why gossip works here

The property that makes a trustless transport possible — and that most systems
lack — you already have: **every order is self-authenticating.** An `Order` plus
its EIP-712 `sig` can be verified by *anyone* against
`Settlement.DOMAIN_SEPARATOR()` with zero trust in whoever relayed it.

So the transport does not need to be trusted, only the signature does. A
centralized CoW-style orderbook gives you authenticity *by being a trusted
server*; Waku gives you the same *by being verifiable instead*. The message
payload is exactly what the SDK already produces:

- an `Order` + its `signOrder` output, **or**
- the empty-sig + on-chain [`approveOrder`](../packages/core/src/settlement/OrderState.sol)
  path for makers that cannot sign (multisigs without EIP-1271), **or**
- optionally a witness-bound Permit3 `PermitBatch` for the single-signature
  `fillWithPermit` flow.

Waku is **transport only** — it does not match, sequence, or hold "the" book.
Each participant reconstructs its own view; the chain (`filled[orderHash]`, the
`OverFill` revert, the nonce gate) resolves any disagreement.

---

## Roles and Waku protocols

| Role | Waku protocols | What it does |
|---|---|---|
| **Maker dApp** (browser/wallet) | **Light Push** to send, **Filter** to watch own orders | Signs via the SDK, light-pushes an `OrderAnnounce`. Cannot run a full relay reliably. |
| **Solver / filler** (always-on) | **Relay** (gossip mesh) + **Store** (backfill on boot) | Subscribes to order topics, verifies, keeps a local book, submits `fill` / `batchFill` on Rootstock. |
| **Infra node** (you run ≥1–2) | **Relay** + **Store** | Persists recent messages so a solver that just booted — or a dApp rendering the book — can query history. |

Why **Store** matters: Waku Relay is **ephemeral** — messages live in the
gossip mesh for seconds, not forever. The "orderbook" is therefore
`Store history + live Relay stream`, each message run through the verification
pipeline below. There is no canonical book object and no consensus needed — it
is eventually-consistent, and the chain is the tiebreaker.

---

## Content topics and message types

Waku namespaces messages by **content topic**
(`/{app}/{version}/{name}/{encoding}`). Bind the topic to the **domain** the
order is signed against, so a message cannot be confused across chains or
deployments:

```
/1delta/1/orders-30-{settlementAddr}/proto     # new orders, Rootstock mainnet (chainId 30)
/1delta/1/cancels-30-{settlementAddr}/proto     # soft-cancels
/1delta/1/rfq-30-{settlementAddr}/proto         # quote requests (exclusive / RFQ flow)
```

One order topic per `chain + settlement` is the sweet spot. Per-token-pair
topics fragment the mesh; let fillers filter locally instead — Rootstock volume
does not justify sharding yet. Payloads are protobuf (`proto`).

Message types:

1. **`OrderAnnounce`** — `{ order, sig, permitBatch?, sigless? }`. The whole payload.
2. **`SoftCancel`** — `{ maker, orderHashes[], issuedAt, expiry, sig }`, signed
   as EIP-712 in the **Settlement domain**. The *hard* cancel is on-chain
   ([`cancelOrders` / `rollbackNonces` / `invalidateNonceWord`](../packages/core/src/settlement/NonceManager.sol),
   plus per-hash [`cancelOrder`](../packages/core/src/settlement/OrderState.sol)),
   but that costs a Rootstock tx and a block. A signed soft-cancel lets fillers
   drop orders from their books instantly — one signature for a whole quote set —
   while still treating the on-chain nonce as ground truth. Full spec:
   [soft-cancel.md](soft-cancel.md).
3. **`OrderReplace`** — `{ cancel, announce, replaces }`. Cancel-and-replace as
   one message, so a re-price is one event rather than a remove racing an add.
   Both halves are independently signed; a node that cannot verify either applies
   neither.
3. **`FillNotice`** *(optional)* — a filler hints "I'm taking this" to reduce
   wasted races. Purely advisory; `filled[orderHash]` on-chain is authoritative.
4. **`RFQ`** — a taker/maker requests a quote, for the `exclusiveFiller` path.
   Can be encrypted to a specific filler's public key (see privacy note).

---

## The verification pipeline

This is what turns raw gossip into a book. Every inbound `OrderAnnounce` runs
the gauntlet and exits at the first failure. Cost climbs down the list, so the
cheap layers kill the bulk — see [spam & DoS](#spam--dos-the-unbacked-order-problem)
for the threat model this is built against.

**Layer 1 — local drops, zero RPC (microseconds):**

- ECDSA recover → `order.maker` mismatch ⇒ drop.
- `deadline <= now` ⇒ drop.
- Structural sanity: leg arrays align, amounts non-zero, `chainId` / settlement
  address match the content topic the message arrived on.
- **Dedup by `orderHash`** against a seen-set ⇒ drop replays.

**Layer 2 — on-chain state, one batched multicall (cached):**

| Check | Source | Catches |
|---|---|---|
| nonce live | [`isNonceCancelled`](../packages/core/src/settlement/NonceManager.sol) / `nonceBitmap` word | dead / cancelled / used nonce |
| order not hash-cancelled | `filled[orderHash] == type(uint256).max` sentinel | maker cancelled this one order |
| Permit3 taker/token permit exists | Permit3 allowance book (spender = Settlement) | **never approved Permit3** |
| ERC20 → Permit3 allowance | `token.allowance(maker, PERMIT3)` | approved Settlement but not the underlying |
| balance | `balanceOf(maker)` | **no funds** |
| empty-sig orders | `orderApproved[maker][hash]` | unauthorized sig-less order |
| contract makers | `isValidSignature` eth_call (EIP-1271) | Safe / multisig / 7702 forgery |

Contract-signer support (Safe / multisig / EIP-7702) is why the signature check
is an `eth_call` to Rootstock, not just a local `ecrecover`.

The book is the set of orders that pass both layers, keyed by `orderHash`, with
expiry and cancel eviction.

---

## Spam & DoS: the unbacked-order problem

Signing an order is **free, off-chain, and produces a cryptographically valid
`(Order, sig)`** even when the maker has no funds, no Permit3 approval, or a
dead nonce. The attacker's cost per junk order ≈ one `secp256k1` sign. The whole
defense is about **restoring asymmetry**: making each junk order cheaper to
reject than to create, and ensuring it never touches anything scarce — capital,
gas, or a rate-limited slot — before it is dropped.

Two facts work in your favor before any filtering:

- **The fill is safe regardless.** A junk order that slips every filter just
  makes `fill()` revert (`NonceCancelled`, `OverFill`, or a Permit3/balance
  failure). Fillers `eth_call`-simulate before broadcasting, so they don't even
  spend gas. **Worst case of a junk order = wasted verification bandwidth, never
  lost capital.** The on-chain settlement is the real backstop and is already
  correct.
- **On-chain state is cheap to read and cache.** All of the Layer-2 reads batch
  into one multicall and cache per maker.

### Defense layers, cheapest first

**Layer 0 — transport rate-limit (RLN-Relay).** The one that actually caps a
*flood*, and it is Waku-native. RLN (Rate-Limiting Nullifiers) forces every
publisher to prove zk membership and limits them to *N* messages/epoch; exceed
it and the key's nullifier is revealed and the publisher is slashed/removed.
"Infinite free spam" becomes "rate-limited spam, one bucket per identity, Sybils
cost a membership each." Layered on top, gossipsub **peer scoring** (built into
libp2p Relay) independently down-scores and prunes peers that forward garbage.
Adopt RLN from day one rather than retrofitting.

**Layer 1 & 2 — the [verification pipeline](#the-verification-pipeline) above.**
Local drops kill malformed/expired/replayed spam for free; the batched multicall
catches *no funds* / *no approval* / *dead nonce*.

**Layer 3 — solver-side capital protection.** Even a junk order that passes
every filter cannot cost capital — the fill reverts and simulation means no gas
is spent. This is the property that makes the whole design robust.

### What makes Layer 2 O(1) instead of O(orders)

The naïve version does one multicall per order, and an attacker simply makes you
spend RPC. The fix is **caching keyed by `(maker, token, spender)` + a negative
cache**:

- Approval/balance only change when the *maker transacts*. Subscribe to
  `Transfer` / `Approval` (and Permit3) events for makers in the book and
  invalidate on change — don't re-poll per order.
- **Cancellation events to subscribe to** (all on Settlement). Miss one and you
  keep serving orders the maker has already killed:
  `OrdersCancelled`, `NoncesRolledBack`, **`NonceWordInvalidated`**,
  `OrderCancelledByHash`, and `OrderApprovalRevoked` (sig-less orders only).
  `NonceWordInvalidated` was added in the 2026-07 audit — `invalidateNonceWord`
  cancels 256 nonces in one write and previously emitted nothing at all, so an
  indexer watching only the other two would silently miss a bulk cancel.
- The first unbacked order from an address costs **one** multicall, then tags
  the address **negative**. Every later order from it is a hashmap lookup ⇒
  dropped, until an on-chain event for that address clears the tag. So an
  attacker spamming from one key costs **1 RPC total, not 1-per-order.** Forcing
  more RPCs means more fresh, funded-looking identities — exactly what RLN's
  per-identity Sybil cost and gossip peer-scoring already tax.
- **Self-healing:** a maker who later funds/approves emits a `Transfer` /
  `Approval`, which evicts the negative tag and re-admits their orders
  automatically.

Net: the attacker's cost to force one unit of real defender work (an RPC) rises
from "one signature" to "one fresh identity that survives RLN + peer scoring +
the negative cache."

### The two named cases

- **Hasn't approved Permit3** → caught at Layer 2 (`token.allowance(maker,
  PERMIT3)` and the Permit3 book both empty). First occurrence: one batched RPC;
  address negative-cached; re-admitted when an `Approval` to Permit3 is observed.
- **Has no funds** → same multicall, `balanceOf` leg; same negative-cache +
  self-heal on the next incoming `Transfer`.

Neither ever reaches a filler's capital, and neither costs more than O(1)
amortized.

### Two subtleties

- **TOCTOU is unavoidable and fine.** A maker can pass verification, then pull
  funds/approval before a filler acts (griefing, or just churn). You cannot
  prevent this off-chain — which is *why* Layer 3 exists: the filler
  re-simulates immediately before broadcast and the on-chain fill reverts
  harmlessly. Layer 2 is a **prioritization/spam filter, not a guarantee**; the
  guarantee is the contract.
- **Stale-book drift.** A book that only polls learns about a cancellation up to
  a full sweep period late, and pays O(book) view gas per sweep to do it. The
  chain already broadcasts the fact: `OrderCancelledByHash`, `OrdersCancelled`,
  `NoncesRolledBack` and `NonceWordInvalidated` each carry the maker plus exactly
  which orders died, so a watcher evicts them with **no view call at all**, and
  `OcoGroupModule.GroupClaimed` retires every other leg of a bracket from a single
  log. `OrderFilled` is the one that still needs a follow-up read — it says an
  order moved, not how far — so it only marks that order for a targeted re-check.
  The sweep stays, scoped to what no log can announce: a maker's balance or
  allowance falling away underneath a still-valid order. It must also be
  **chunked** — an unchunked `getOrderRelevantStates` over a growing book
  eventually exceeds the provider's `eth_call` gas cap and reverts wholesale,
  which would read as "every order is un-fillable" and evict the entire book.
- **Soft-cancel spoofing.** Two independent checks, both required. The EIP-712
  signature says WHO signed (EOA locally, delegate or EIP-1271 maker via one
  `eth_call`); the book then evicts a hash only if the order it holds names THAT
  maker. Without the second check a valid signature over somebody else's order
  hash would evict it. The Settlement domain also binds the message to one chain
  and one deployment, so a cancel cannot be replayed across them. The hard cancel
  (nonce, or per-hash) is ground truth regardless.

### Policy: strict vs optimistic ingest

For Rootstock's volume, prefer **strict ingest**: an order enters the book only
after passing Layer 2 (one batched, cached RPC). Simpler, clean book, bounded
RPC. The **optimistic** alternative (admit on Layer 1, verify async, evict +
negative-cache failures) buys lower ingest latency but briefly holds junk —
worth it only if volume ever outgrows a per-order multicall, which on Rootstock
it will not for a long time.

---

## Rootstock notes

- **chainId 30 (mainnet) / 31 (testnet)** — baked into the content topic *and*
  the EIP-712 domain, so a cross-chain replay is rejected twice.
- **~30s blocks, low throughput, gas in RBTC** — this is *why* you want Waku: an
  on-chain orderbook is a non-starter on Rootstock. Off-chain gossip + on-chain
  settlement-only is the right split, and matches how the USDRIF work already
  thinks about it.
- Verification RPCs hit a Rootstock node; batch the nonce/allowance/balance reads
  into one multicall to keep ingest latency down.

---

## Privacy: the exclusive / RFQ path

Public limit orders are broadcast in the clear (that is their nature). But the
`exclusiveFiller` / RFQ flow can use Waku's **asymmetric encryption**: encrypt an
`OrderAnnounce` to a specific filler's public key so only they see it during the
`exclusivityEndTime` window, with a public fallback after it expires. This
dovetails with the filler-aware validators (`FillerWhitelist` / `Attestation`)
and the `takerData` channel.

---

## Where it lives, and open questions

This shipped as [`@1delta-x/orderbook`](../packages/orderbook), depending on
[`@1delta-x/sdk`](../packages/sdk) for the `Order` type + hashing/verification.
It exports exactly what this note called for:

- `OrderbookClient.publishOrder` / `subscribeOrders` — thin wrappers over a
  `Transport` (today an `HttpTransport`; a Light Push / Relay + Filter transport
  slots in unchanged).
- the protobuf schema + codec for the message types above (`proto/orderbook.proto`),
- a `Book` class: Store backfill → live subscription → the Layer 1–2 pipeline →
  an in-memory map keyed by `orderHash`, with expiry / signed-cancel eviction and
  a periodic on-chain re-check.

The one deviation from the sketch: **Layer 2 is a single view call**, not a hand-
rolled multicall — [`SettlementLens.getOrderRelevantStates`](../packages/periphery/src/SettlementLens.sol)
already returns status + live-fillable + signature validity (incl. EIP-1271/7702)
+ validators for a whole batch. The per-maker negative cache + event invalidation
remain the noted optimization, deferred.

The SDK covers everything on-chain-facing; `@1delta-x/orderbook` is *only* the
transport + book-reconstruction layer, and `@1delta-x/orderbook-server` is a
centralized `Transport` + a REST/WebSocket access layer on top. Adding
`@waku/sdk` (js-waku) as a `WakuTransport` is the remaining step.

**Open questions before building:**

1. **Filler topology** — always-on Relay nodes (assumed here), or thin clients
   leaning on Light Push / Filter against your infra? Changes how much
   Store/relay infra you have to run.
2. **RLN membership model** — who issues memberships, and is the Sybil cost a
   stake, a fee, or an allowlist for the first deployment?
3. **First-cut scope** — a minimal prototype (protobuf schema + publish/subscribe
   + a `Book` verifying against a Rootstock testnet fork), or stay at design
   level for now?

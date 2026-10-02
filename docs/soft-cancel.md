# Cancellation: five granularities, one of them free

Cancelling is the operation a signed-order system is worst at and does most
often. A market maker re-prices its book continuously; a user drags a limit
price; a UI expires a quote. Each of those is a cancel, and in a permissionless
system the honest answer to "make this order un-fillable" is a transaction —
because the order is fillable by anyone, so the only place that fact can live
where everyone will see it is on-chain.

That answer is correct and also unaffordable at quoting frequency. So there are
five primitives, four authoritative and one free, and the skill is picking the
narrowest one that expresses the intent.

| | scope | cost | binds a filler? |
|---|---|---|---|
| `cancelOrder(order)` | exactly one order, by hash | 1 tx, 1 SSTORE | ✓ |
| `cancelOrders(nonces[])` | every order carrying those nonces | 1 tx, 1 SSTORE/nonce | ✓ |
| `invalidateNonceWord(word)` | 256 nonces | 1 tx, 1 SSTORE | ✓ |
| `rollbackNonces(minValid)` | every nonce below a watermark | 1 tx, 1 SSTORE | ✓ |
| **signed `SoftCancel`** | any set of hashes | **free** | ✗ **advisory** |

The first four live in
[`OrderState.sol`](../packages/core/src/settlement/OrderState.sol) and
[`NonceManager.sol`](../packages/core/src/settlement/NonceManager.sol). The fifth
is an off-chain message, specified here.

## By hash vs. by nonce

Worth stating plainly because it is easy to reach for the wrong one:

- **`cancelOrder(order)`** is the 0x-style per-hash cancel. It parks the order's
  `filled` counter at the `type(uint256).max` sentinel — a slot the fill path
  already `SLOAD`s — so the check costs the hot path a single compare and no
  extra read. Orders that happen to share the cancelled order's nonce stay
  fillable. Works on a partially-filled order; the remainder becomes unfillable.
- **`cancelOrders(nonces[])`** is bulk by construction. A nonce may be shared by
  several orders — that is exactly how the [shared-nonce bracket](oco.md) works —
  so cancelling one retires all of them. Right for a bracket, wrong for a single
  re-price.

## The signed soft cancel

A maker-authenticated instruction to every book holding an order to drop it.

```
SoftCancel(address maker,bytes32[] orderHashes,uint256 issuedAt,uint256 expiry)
```

signed as **EIP-712 in the Settlement domain** — the same `name` / `version` /
`chainId` / `verifyingContract` an `Order` is signed under.

### Why EIP-712 and not `personal_sign` over the hash

The previous shape was an EIP-191 signature over the raw 32-byte order hash. It
worked, and it gave up four things worth having:

1. **Deployment binding.** The domain pins the message to one chain and one
   settlement, so a cancel signed on a testnet cannot be replayed against
   mainnet. A bare hash signature carries no such scope.
2. **A readable prompt.** The wallet renders named fields instead of an opaque
   blob. A maker asked to sign 32 unexplained bytes learns nothing from the
   prompt, which is the failure mode EIP-712 exists to fix.
3. **The full signer set.** Verification is now the same three-step resolution
   the settlement applies to an order signature — EOA, then a maker-nominated
   delegate, then EIP-1271 / EIP-7702. Previously a contract maker simply could
   not soft-cancel; a session key that could *sign* a maker's orders could not
   *retract* them, which is a strictly worse position for the maker.
4. **Batching and freshness.** One signature retires a whole quote set;
   `issuedAt` orders a maker's own cancels (which is what makes
   [cancel-and-replace](#cancel-and-replace) coherent) and `expiry` bounds how
   long a leaked message stays actionable.

### Verification, in two independent halves

Both are load-bearing, and conflating them is the bug:

- **Who signed this** — [`CancelVerifier`](../packages/orderbook/src/cancels.ts).
  A 65-byte signature recovers locally with **zero RPC**, which keeps the
  overwhelmingly common case free and means a dead RPC cannot stop an EOA maker
  retracting its quotes. Only a delegate or a contract maker costs one
  `eth_call`.
- **What they may retract** — `evictableHashes`. A node evicts a hash only if the
  order it holds names *this* maker. Without this, a perfectly valid signature
  over somebody else's order hash would evict it.

Hashes the node has never seen leave a **maker-bound pending tombstone**, keyed by
`(hash, maker)` (2026-09-30 G-TS_FILLER-2): when the order arrives later, it is
dropped only if its maker is the one who signed the cancel, so a squatter cannot
pre-empt somebody else's order. Pending tombstones are capped per maker (1024),
live no longer than the admission `maxTtlSeconds`, and are evicted before real
tombstones once the book passes `maxTombstones`, so a flood of cancels for unseen
hashes cannot flush a real one. Store backfill replays **cancels, then orders,
then replaces**, so a restarted node does not relist a cancelled or replaced order
(G-TS_FILLER-3; see [waku-orderbook.md](waku-orderbook.md)).

`CancelVerifier` accepts: a 65- or 64-byte (EIP-2098) ECDSA signature from the
maker or an ECDSA delegate, a contract-delegate envelope, and a direct EIP-1271
signature from a contract maker. It does **not** accept ERC-6492 / ERC-8010
wrapped signatures or a bulk (Merkle) root.

### What it does not do

A soft cancel **does not stop a filler that already holds the signed order and
chooses to submit it**, and no off-chain message can. It stops the order being
*served*. That is enough for the hundreds of routine retractions and not enough
for the one that matters — for which the on-chain cancels above are the answer,
and the reason all five primitives exist rather than one.

**Frontend guidance** (2026-09-30 G-TS_SIGN-4). A UI must require the maker's
signature for a soft cancel and must never evict an order locally on an unsigned
"cancel" click. After a soft cancel it should keep the order listed as **hidden but
still fillable until expiry**, and offer the on-chain cancel (`cancelOrders` /
`cancelOrder`) right next to it.

```ts
import { softCancelOrders } from "@1delta-x/sdk";
const { cancel, sig } = await softCancelOrders(wallet, maker, [h1, h2, h3], deployment);
await client.cancelOrder({ cancel, sig });
```

## Cancel-and-replace

An "amend" is not an edit: a signed order is immutable, so changing a price
changes the hash. What a UI wants is nonetheless one gesture, and the honest
primitive underneath it is *sign the replacement, retract the predecessor, keep
the two associated*.

```ts
import { amendOrder } from "@1delta-x/sdk";
const { order, sig, replaces, cancel, cancelSig } = await amendOrder(
  wallet, prevOrder, nextNonce, { legsOut: repriced }, deployment,
);
await client.replaceOrder({ announce: { order, sig }, cancel: { cancel, sig: cancelSig }, replaces });
```

`Book.ingestReplace` admits the replacement **first** and applies the retraction
only if it verified, so the book never passes through a state where the maker has
neither order live. A failed replacement leaves the predecessor exactly where it
was.

**An ordinary replacement carries a fresh nonce, and the SDK enforces it**
(`patchOrder` / `amendOrder` throw on a same-nonce replacement, 2026-09-30 PRICE-5).
Reusing the predecessor's is tempting — one on-chain cancel would then retire both —
and it is wrong: nonce cancellation is retroactive and total, so cancelling the
amended order would also invalidate fills the partially-filled predecessor is still
owed. A fresh nonce keeps them independent, which is what "replace" means everywhere
else.

**A fill-once (shared-nonce) replacement KEEPS the predecessor's nonce**
(G-TS_SIGN-2): that is what keeps it in the bracket, so the first full fill of any
member retires the rest on-chain. Leaving the group needs `{leaveNonceGroup: true}`.

The consequence is stated rather than hidden: after an amend, the old order is
retracted only from books that honour the soft cancel. When that is not
acceptable — a real re-price in a fast market — pair the amend with an on-chain
`encodeCancelOrder(prev)`, which retires exactly that one order and leaves any
nonce siblings alone.

**An [OCO group](oco.md) is NOT a substitute here** (corrected 2026-09-30,
PRICE-13). OCO bounds HOW MANY of the orders execute, not WHICH: a filler holding
the stale predecessor — exactly what a re-price in a fast market makes profitable —
fills it first, and the group then retires the REPLACEMENT. When the predecessor
must not fill, use `cancelOrder(prev)`.

⚠ An OCO leg's claim item names the order's nonce a second time, and the
contract binds the two (`OcoGroupModule.validate` fails unless the item encodes
`order.nonce`). `patchOrder` re-homes the claim item to the new nonce for you;
if you re-nonce an OCO leg by hand, call `renonceOcoItems`. Before that binding
existed, a replacement that copied the predecessor's item claimed the group FOR
the predecessor — the soft-cancelled order then filled in full while the
replacement and its sibling died (F29 finding 3).

Two signature prompts, not one. Collapsing them would mean asking the maker to
authorize an order and a retraction under a single opaque digest.

## Wire format

`SoftCancel` and `OrderReplace` are protobuf messages in
[`orderbook.proto`](../packages/orderbook/src/proto/orderbook.proto). Order
hashes are fixed 32 bytes on the wire — never minimized, unlike the `uint256`
fields — because minimizing one would silently change which order a cancel names.

Server routes: `POST /cancels`, `POST /replaces`. The WebSocket stream gained a
`REPLACE` kind so a thin client sees a re-price as one event rather than a remove
racing an add.

Tests: [`softcancel.test.ts`](../packages/sdk/test/softcancel.test.ts),
[`book.test.ts`](../packages/orderbook/test/book.test.ts).

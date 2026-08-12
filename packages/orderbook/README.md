# @1delta-x/orderbook

Transport-agnostic **order distribution** for `Settlement`. The settlement
contract has no on-chain orderbook — orders travel off-chain as
self-authenticating `(Order, sig)` tuples that anyone can verify against the
Settlement EIP-712 domain (see [`docs/waku-orderbook.md`](../../docs/waku-orderbook.md)).
This package is that off-chain layer: protobuf message types, a
verification pipeline, and an in-memory `Book` — sitting on top of a single
`Transport` seam.

**The seam is the whole point.** A centralized demo backend runs the `Book` over
an `InMemoryTransport`; a filler runs the *same* `Book` over an `HttpTransport`
against that backend; and a future Waku deployment runs it over a `WakuTransport`
— with `Book`, verification, and the protobuf wire all unchanged.

```
maker/filler ── HttpTransport ──▶ demo backend ── InMemoryTransport ──▶ Book
   (later) ──── WakuTransport ───────────────────────────────────────▶ Book
```

## What's here

| Module | Exports |
|---|---|
| `proto/codec` | `encode/decodeOrderAnnounce`, `…SoftCancel`, `…OrderReplace`, `…FillNotice`, `…OrderList`, `…StreamMessage`, `orderToProto`/`protoToOrder` — all `uint256`→`bytes`, `address`→20 bytes (order hashes stay fixed-width). |
| `messages` | `OrderAnnounce`, `SignedSoftCancel`, `OrderReplace`, `FillNotice` (viem-typed). |
| `topics` | `orderTopic`/`cancelTopic` — Waku content topics bound to `chainId`+`settlement`. |
| `config` | `OrderbookConfig` (+ `lens`), `rootstockTestnetConfig`, `toDeployment`. |
| `transport` | `Transport` interface + `InMemoryTransport`. |
| `cancels` | `CancelVerifier` — EIP-712 soft-cancel signatures under the same signer set the settlement accepts for an order (EOA locally, delegate + EIP-1271 via one call); `evictableHashes` for the separate ownership check. See [docs/soft-cancel.md](../../docs/soft-cancel.md). |
| `verify` | `Verifier` — Layer 1 (local recover/deadline/shape) + Layer 2 (one `SettlementLens.getOrderRelevantStates` call) with a TTL cache. |
| `book` | `Book` — backfill → subscribe → verify → keyed map, with expiry, signed soft-cancel eviction, atomic `ingestReplace` (admit-then-retract), and periodic on-chain re-check. |
| `client` | `HttpTransport` (Transport over the demo backend), `OrderbookClient`, `signSoftCancel`. |

## Verification pipeline

Every inbound announce runs the gauntlet, cheapest first:

- **Layer 1 (local, zero RPC):** recompute `hashOrderStruct(order)`; require a fill
  denominator; `deadline > now`; for 65-byte sigs, `recoverTypedDataAddress` must
  equal the maker. Contract (EIP-1271 / 7702) sigs defer to Layer 2.
- **Layer 2 (one view call):** `SettlementLens.getOrderRelevantStates` returns
  `status` (nonce/deadline/filled), `fillableAmount` (live Permit3 allowance +
  balance cap), `isSignatureValid` (incl. 1271/7702), and `validatorsPass` for the
  whole batch. Admit iff `status == Fillable && sig valid && fillable > 0`. A
  TTL cache keyed by `orderHash` keeps a POST-then-ingest round-trip at one call.

The chain is always the tiebreaker: a junk order that slips every filter just
makes `fill()` revert. The book is a prioritization/spam filter, not a guarantee.

## Usage — maker

```ts
import { OrderbookClient, HttpTransport } from "@1delta-x/orderbook";
import { signOrder, hashOrderStruct } from "@1delta-x/sdk";

const config = { chainId: 31, settlement: "0x…", permit3: "0x…", lens: "0x…", rpcUrl: "https://public-node.testnet.rsk.co" };
const client = new OrderbookClient(new HttpTransport({ baseUrl: "http://localhost:8080", config }), config);

const sig = await signOrder(maker, order, config);          // @1delta-x/sdk
await client.publishOrder(order, sig);                        // POST /orders (protobuf)
```

## Usage — filler (runs a live, verified Book)

```ts
import { Book, Verifier, HttpTransport } from "@1delta-x/orderbook";
import { createPublicClient, http } from "viem";

const rpc = createPublicClient({ transport: http(config.rpcUrl) });
const book = new Book({
  transport: new HttpTransport({ baseUrl: "http://localhost:8080", config }),
  config,
  verifier: new Verifier(rpc, config),
});
book.onAdd((e) => console.log("＋", e.orderHash, e.state?.fillableAmount));
book.onRemove((e) => console.log("－", e.orderHash));
await book.start();  // ← swap HttpTransport for WakuTransport later; nothing else changes
```

## Scripts

```bash
pnpm build       # tsc → dist
pnpm typecheck
pnpm test        # vitest — protobuf round-trip vs the SDK canonical order + golden hash
```

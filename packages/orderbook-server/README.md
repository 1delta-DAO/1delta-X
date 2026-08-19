# @1delta-x/orderbook-server

Demo **centralized orderbook backend** for `Settlement` — the "obvious"
centralized fill of the order-distribution slot, ahead of the decentralized
[Waku transport](../../docs/waku-orderbook.md). It is a thin Fastify REST +
WebSocket access layer over [`@1delta-x/orderbook`](../orderbook)'s verified
`Book`: it plays the design doc's **infra node** (an in-memory Relay+Store bus),
and the HTTP/WS surface lets browser makers/fillers that can't run a relay talk
to it. Protobuf on the wire throughout; the chain stays the source of truth.

**Going P2P is one line:** the backend runs its `Book` over an
`InMemoryTransport`; a Waku deployment runs the same `Book` over a
`WakuTransport`. The routes, verification, and wire format are unchanged.

## Endpoints

### Writes

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/orders` | protobuf `OrderAnnounce` | `202 {orderHash}` · `422` unfillable · `503` at capacity · `413` oversized · `429` rate-limited |
| POST | `/cancels` | protobuf `SoftCancel` | `202 {evicted, requested}` · `403` bad signature |
| POST | `/replaces` | protobuf `OrderReplace` | `202 {orderHash, replaces}` · `422` |

### Reads

| Method | Path | Query | Response |
|---|---|---|---|
| GET | `/orders` | see the filter table below | protobuf `OrderList`, or JSON with `?format=json` / `Accept: application/json` |
| GET | `/orders/:hash` | — | protobuf `OrderAnnounce` · `404` |
| GET | `/orders/:hash/status` | — | JSON status, **including recently-evicted orders** |
| GET | `/fills` | `maker` `solver` `orderHash` `fromBlock` `limit` `cursor` | JSON fills + `coverage` · `501` when indexing is off |
| GET | `/quote` | `hash` `fillAmount` `filler` `[recipient]` `[takerData]` | JSON preview + ready-to-send `fillUpTo` calldata |
| GET | `/stream` | WebSocket | `SNAPSHOT` then live `ADD` / `CANCEL` / `REPLACE` |
| GET | `/health` | — | chain config, book size, limiter and index state |

#### `/orders` filters

| Param | Meaning |
|---|---|
| `maker` | orders this account signed |
| `token` | orders touching this token on **either** side — the "everything against X" view |
| `tokenIn` / `tokenOut` | one-directional: what the maker gives / wants |
| `pair` | `0xA-0xB` — both tokens, either orientation. The market view |
| `side` | `SELL` or `BUY` |
| `fillableOnly` | only what the chain says a filler could take right now |
| `validatorsPass` | additionally require validators to pass for this node's filler |
| `minFillable` | live fillable amount at or above this |
| `expiresAfter` | unix seconds — orders that survive at least this long |
| `sort` | `created` (default) · `deadline` · `fillable` · `price` |
| `direction` | `asc` / `desc` |
| `limit` · `cursor` | page size (max 500) and the keyset cursor from `nextCursor` |

An unparseable filter is a `400`, never a silently-ignored parameter — a
mistyped `maker` that quietly returns the whole book is worse than an error.

Paging is **keyset**, not offset. A book is not a table: orders are admitted and
evicted between requests, so an offset silently skips or repeats rows exactly
when the book is busiest.

## What the node refuses to hold

Ingest is gated in **cost order**, so the expensive check is last and most abuse
never reaches it:

1. **Body size** — over `MAX_BODY_BYTES`, `413`, before anything parses it.
2. **IP budget** — token bucket, `429` with `retry-after`.
3. **Admission** (`checkAdmission`, local, zero RPC) — structural bounds, a
   minimum TTL so an order that expires in two seconds never costs a lens call,
   a maximum TTL so a ten-year deadline cannot squat, and capacity caps on the
   book and per maker. Capacity refusals are `503`, not `422`: it is the node's
   limit, not the order's fault. A **re-announce of an order already held is
   never refused for capacity.**
4. **Maker budget** — a second token bucket keyed by the signing account. An IP
   is free to rotate; a funded account is not.
5. **Verification** (`Verifier`, one `eth_call`) — Layer 1 recovers the maker
   locally; Layer 2 asks `SettlementLens.getOrderRelevantStates` for status,
   signature validity (incl. EIP-1271 / 7702) and the **live fillable amount,
   capped by the maker's real balance and Permit3 allowance**. That last number
   is the solvency check: an order the maker cannot fund reports `0` and is
   rejected with `maker has no allowance/balance for this order`.

Admitted orders stay honest afterwards. `ChainWatcher` evicts on Settlement logs
(cancellations cost **zero** RPC), and a periodic `revalidate` sweep re-runs
Layer 2 to catch what no log announces — a balance or allowance falling away
under a still-valid order.

## Cancel policy

A soft cancel is a maker-signed EIP-712 message, free and instant. Two separate
questions are answered separately, because conflating them is how a valid
signature over someone else's order hash becomes an eviction:

- **Who signed it** — `CancelVerifier` accepts exactly the signer set the
  settlement accepts for an order: the EOA maker (local recover, zero RPC), a
  maker-nominated delegate (`orderSignerExpiry`), or a contract maker via
  EIP-1271 / 7702. A signature that is not the named maker's is `403`.
- **What they may retract** — `evictableHashes` keeps only the hashes whose
  order in this book names that maker. A perfectly valid signature by Mallory
  naming Alice's order is accepted (`202`) and evicts **nothing**; the response
  reports `evicted: []` against `requested: n`.

The book re-verifies independently on ingest. A book that trusted the route that
fed it would be one misconfigured proxy away from open eviction.

## Rate limiting

Cost-weighted token buckets, not a flat requests-per-minute cap — the routes are
not equally expensive. `GET /health` is free, a read costs 1, a book query 2, a
cancel or a quote 5, and a write 10, because a write costs a signature recover
plus an `eth_call` against a paid RPC endpoint.

Two independent buckets: **by IP** (the ordinary flood, trivially defeated by a
botnet, which is why it is not the only one) and **by maker** (the expensive
flood — an account is not free to rotate). Neither replaces an edge proxy; this
bounds what one process will spend, it does not stop packets arriving.

## Fills, and what "no fills" means

`OrderFilled(orderHash, maker, solver)` carries **no amount** — the settlement
does not pay ~256 gas per fill to publish one. `FillIndex` therefore reconstructs
amounts by reading the settlement's cumulative `filled(hash)` and differencing
it: exact for fills seen live, `null` (never `0`) for most backfilled rows.

It is an in-memory, bounded, single-process window that starts empty on restart —
the honest minimum, not a durable indexer. Every `/fills` response therefore
carries its `coverage` (`fromBlock`, `toBlock`, `records`, `live`, `dropped`) so
a caller can tell **"nothing was filled"** from **"not indexed that far back"**.
A durable indexer is the obvious next step and slots in behind the same route.

## Run

Contracts are deployed separately (`packages/core/script/Deploy.s.sol` is a stub).
Point the backend at whatever you deployed. The service runs via `tsx`, which
executes the TypeScript source directly — matching the workspace's
bundler-consumed setup (`moduleResolution: bundler`, same as the SDK), so no
server build step is needed, only the library's `dist`:

```bash
pnpm --filter @1delta-x/orderbook build          # the server imports the built library

CHAIN_ID=1 \
SETTLEMENT=0x… PERMIT3=0x… LENS=0x… \
RPC_URL=https://… \
PORT=8080 \
pnpm --filter @1delta-x/orderbook-server start    # tsx src/bin.ts
```

| env | required | default | notes |
|---|---|---|---|
| `CHAIN_ID` | ✓ | — | e.g. `1` |
| `SETTLEMENT` / `PERMIT3` / `LENS` | ✓ | — | |
| `RPC_URL` | ✓ | — | must serve `eth_getLogs` if `INDEX_FILLS` is on |
| `PORT` / `HOST` | | `8080` / `0.0.0.0` | |
| `DEFAULT_FILLER` | | zero address | filler the lens previews validators for |
| `OCO_MODULES` | | — | comma-separated `OcoGroupModule` addresses to watch |
| `WATCH_CHAIN` | | `true` | evict on Settlement logs instead of on a timer |
| `INDEX_FILLS` | | `true` | index `OrderFilled` so `/fills` can answer |
| `FILLS_FROM_BLOCK` | | lookback window | block to backfill fills from |
| `MAX_ORDERS` | | `25000` | hard cap on live orders |
| `MAX_ORDERS_PER_MAKER` | | `500` | one account cannot own the book |
| `MIN_TTL_SECONDS` | | `15` | below this an order is not worth an `eth_call` |
| `MAX_TTL_SECONDS` | | `7776000` (90d) | above this it is squatting, not a quote |
| `RATE_LIMIT_IP_CAPACITY` / `_REFILL` | | `120` / `1` | burst / tokens per second |
| `RATE_LIMIT_MAKER_CAPACITY` / `_REFILL` | | `120` / `1` | per signing account |
| `MAX_BODY_BYTES` | | `65536` | |
| `TRUST_PROXY` | | `false` | **only** behind a proxy that sets `x-forwarded-for` — otherwise the header is a free way to reset your own bucket |

`WATCH_CHAIN` and `INDEX_FILLS` default **on**: on mainnet, a book that only
learns about cancellations from its own polling sweep serves dead orders to
solvers who pay gas to find out.

## End-to-end demo

```bash
# 1. start the backend (above), then:
MAKER_PK=0x… TOKEN_IN=0x… TOKEN_OUT=0x… AMOUNT_IN=1000000 \
CHAIN_ID=1 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
pnpm --filter @1delta-x/orderbook-server example:maker    # signs + publishes one order

CHAIN_ID=1 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
pnpm --filter @1delta-x/orderbook-server example:filler   # runs a live Book, prints the order
```

The maker must hold `TOKEN_IN` and have approved Permit3 for it, or Layer 2
reports 0 fillable and rejects the order (422) — the backend only books orders a
solver could actually fill.

## Test

```bash
pnpm --filter @1delta-x/orderbook-server test   # REST + WS over an in-memory bus, stub verifier
```

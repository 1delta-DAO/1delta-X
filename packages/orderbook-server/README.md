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
| GET | `/quote` | `hash` `fillAmount` `filler` `[recipient]` `[takerData]` `[gasPrice]` (required for a priority-auction order) | JSON preview + ready-to-send `fillUpTo` calldata that BINDS the quote (see below) |
| GET | `/stream` | WebSocket | bounded `SNAPSHOT` (most recent live orders) then live `ADD` / `CANCEL` / `REPLACE` |
| GET | `/health` | — | chain config, book size, limiter and index state |

#### What `/quote` calldata binds

The returned `data` is a `fillUpTo` that executes at the quoted price **or better
on every leg, or reverts** — it used to carry `minBumpBps = 0` and the raw
requested size (audit 2026-09-30 PERIPH-1.v1):

- **Price.** Both previews (`previewFill`, `previewBump`) run as `filler` at the
  caller's `gasPrice`, and the quoted bump is the calldata's `minBumpBps`, so a
  price module re-reading its feed, a falling basefee, or a descending curve
  reverts `BumpTooLow` instead of moving the price toward the maker's `start`. A
  priority-auction order prices from `tx.gasprice`, so `gasPrice` is **required**
  there (`400` without it) — send the fill at that gas price.
- **Size.** An identity order's calldata carries the resolved `delta`, never the
  requested `fillAmount` (the `2^256-1` "any size" sentinel included). On a
  proportional order that means a balance that moved since the quote reverts
  `OverFill` rather than re-sizing the fill. A fill-module order's `fillAmount` is
  a module-unit proposal and passes through.

The response states `fillAmount`, `minBumpBps`, `gasPrice` and `proportional`
explicitly.

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
| `expiresAfter` | unix seconds — orders that survive at least this long. Default: now, i.e. expired orders are hidden |
| `includeExpired` | `true` to also list orders past their deadline that the sweep has not yet evicted |
| `sort` | `created` (default) · `deadline` · `fillable` · `price` |
| `direction` | `asc` / `desc` |
| `limit` · `cursor` | page size (max 500) and the keyset cursor from `nextCursor` (also sent as the `x-next-cursor` header, for protobuf consumers) |

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

- **Who signed it** — `CancelVerifier` mirrors the settlement's single-order
  signer set: the EOA maker (65- or 64-byte ECDSA, local, zero RPC), a
  maker-nominated ECDSA delegate (`orderSignerExpiry`), a nominated contract
  delegate in the `delegate ‖ innerSig` envelope (codeless maker), or a contract
  maker via its own EIP-1271 (7702 included) — and no ERC-6492/8010 wrapper. A
  signature that is not the named maker's is `403`.
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
flood — an account is not free to rotate). The maker bucket is charged only for
an order the book takes (after Layer 2) and once per order/cancel, so nobody can
drain it by replaying the maker's genuine but dead orders (audit 2026-09-30
G-TS_FILLER-6). Neither replaces an edge proxy; this
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
| `MAX_ORDERS_PER_MAKER` | | `100` | one account cannot own the book; a full book also displaces the largest maker's furthest-dated order for a smaller maker |
| `MAX_CURVE_POINTS` | | `32` | |
| `MAX_ORDER_BYTES` | | `16384` | encoded announce size |
| `ALLOWED_TOKENS` | | any | comma-separated leg-token allowlist — set it whenever the book serves a known market set |
| `MIN_TTL_SECONDS` | | `15` | below this an order is not worth an `eth_call` |
| `MAX_TTL_SECONDS` | | `7776000` (90d) | above this it is squatting, not a quote |
| `REQUIRE_DELTA_VERIFY` | | `false` | admit only `timing` bit-104 orders, so no fill ever makes its filler approve the settlement |
| `RATE_LIMIT_IP_CAPACITY` / `_REFILL` | | `120` / `1` | burst / tokens per second |
| `RATE_LIMIT_MAKER_CAPACITY` / `_REFILL` | | `120` / `1` | per signing account |
| `MAX_BODY_BYTES` | | `65536` | |
| `RATE_LIMIT_MAX_KEYS` | | `100000` | buckets per map, least-recently-used dropped past it |
| `TRUST_PROXY` | | `false` | **only** behind a proxy that sets `x-forwarded-for` — otherwise the header is a free way to reset your own bucket |
| `TRUSTED_PROXY_HOPS` | | `1` | your proxies in front of the node; the client address is read that many entries from the **right** of `x-forwarded-for` |
| `WS_MAX_CONNECTIONS` / `WS_MAX_PER_IP` | | `1000` / `16` | stream sockets in total / per client address |
| `WS_ALLOWED_ORIGINS` | | any | comma-separated browser `Origin`s allowed on `/stream` |
| `WS_SNAPSHOT_LIMIT` | | `1000` | orders in the connect snapshot; page `/orders` for the rest |

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

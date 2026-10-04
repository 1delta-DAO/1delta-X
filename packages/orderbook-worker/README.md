# @1delta-x/orderbook-worker

The **Rootstock beta orderbook** as a Cloudflare Worker + one SQLite-backed
Durable Object per chain. It replaces the Node [`orderbook-server`](../orderbook-server)
for the beta (that server stays as the protobuf / WebSocket reference node) and
speaks **JSON only**: Workers forbid `eval` / `new Function`, which protobufjs
needs to build its codecs, so nothing here imports `@1delta-x/orderbook`'s index
or its proto module. It imports only `@1delta-x/orderbook/pure` (the `Verifier`,
`CancelVerifier`, admission policy and query helpers) and the SDK — and
`pnpm bundle-check` proves the built bundle contains no protobufjs and no runtime
code generator.

## Routes

Same semantics and status codes as `orderbook-server` where it has the route.

| Method | Path | Response |
|---|---|---|
| POST | `/orders` | body `{order, sig}` (SDK `Order`, bigints as decimal strings — the SDK's strict `orderFromJson`). `202 {orderHash}` · `202 {orderHash, duplicate: true}` for a live order · `422 {error}` (admission, Layer 1, Layer 2, soft-cancelled) · `503` capacity / verification unavailable / not configured · `400` bad JSON · `413` · `415` non-JSON · `429` |
| POST | `/cancels` | body `{cancel, sig}`. `202 {evicted, requested}` · `403` signature is not the named maker's · `503` |
| GET | `/orders` | `{orders: [{orderHash, order, sig, addedAt, filledAmount, state}], total, nextCursor?}`. Filters `maker`, `token`, `tokenIn`, `tokenOut`, `side`, `fillableOnly`, `expiresAfter`, `includeExpired`; `limit` (≤500) and keyset `cursor` (`<addedAt>~<hash>`, newest first; also in `x-next-cursor`). An unsupported filter is a `400`, never silently ignored. |
| GET | `/orders/:hash` | the one live order in the same shape · `404` |
| GET | `/orders/:hash/status` | `{live: true, …OrderSummary}`, or the tombstone `{live: false, …lastSummary, reason, removedAt, txHash?}` with `reason` ∈ `filled` `cancelled` `soft-cancelled` `expired` `evicted` `displaced` · `404` |
| GET | `/fills` | `?maker` `solver` `orderHash` `fromBlock` `limit` `cursor` → `{fills: [{orderHash, maker, solver, blockNumber, txHash, logIndex, at, cumulative, amount, order?}], total, nextCursor?, coverage}`, newest first. `order` is the signed order when this node held it. |
| GET | `/health` | config, counts, fill coverage, last alarm, last error |

Write path, in cost order: body size → IP bucket → strict parse → local
admission (soft-cancel tombstones, structure, TTL window, token allowlist,
caps with the Book's displacement rule — zero RPC) → Layer 1 (local signature
recover) + Layer 2 (`SettlementLens.getOrderRelevantStates`, one `eth_call`) →
maker bucket (charged once per order the book takes) → admit (caps re-checked
synchronously, after the awaits). Soft cancels follow the `CancelVerifier` /
`Book` rules exactly: the signature proves who signed (EOA, 2098 compact,
nominated delegate, 1271), and only that maker's named orders are evicted; every
named hash leaves a maker-bound tombstone that blocks a re-post.

`MAX_ORDER_JSON_BYTES` is measured on the canonical JSON announce (the worker
has no protobuf); its default is 2× the server's protobuf `MAX_ORDER_BYTES`.

## Design

### Durable Object layout

One `OrderBookDO` per chain (`idFromName("chain:<CHAIN_ID>")`), SQLite storage
(`new_sqlite_classes` migration). Everything survives a restart or eviction:

| Table | Holds |
|---|---|
| `orders` | live orders: canonical JSON announce, maker / nonce / side / expiry / token columns for the filters, last lens state (`ok`, `status`, JSON), inconclusive strikes, `filled` progress, `checked_at`, `dirty` |
| `graves` | tombstones: last summary, reason, tx hash, announce; TTL `TOMBSTONE_TTL_SECONDS`, cap `MAX_TOMBSTONES` |
| `soft_cancels` | `(hash, maker)` soft-cancel tombstones (pending ones capped per maker, dropped first) |
| `fills` | the fill index, keyed `(txHash, logIndex)`; cap `MAX_FILLS` (oldest dropped, reported in `coverage.dropped`) |
| `meta` | log cursor, first scanned block, last alarm / error |
| `buckets` | rate-limit token buckets `ip:<addr>` / `mk:<maker>` |
| `billed` | orders / cancels already charged to their maker |

In memory there is only the library `Verifier`'s 15-second verdict cache.

### Alarm cadence

The DO's alarm re-arms itself after every pass: every `ALARM_INTERVAL_SECONDS`
(20 s), or after 1 s while the log cursor is behind. Any request re-arms a
missing alarm, and the cron trigger (`* * * * *`) only calls `kick()` to do the
same — it never does the work itself. One pass:

1. prune tombstones, soft cancels, buckets, bills and the fill cap;
2. evict orders past their deadline (`reason: expired`);
3. read Settlement logs from the cursor — at most `MAX_LOG_RANGE` blocks, up to
   `head − CONFIRMATIONS` — with one `eth_getLogs` for the five Settlement events
   `ChainWatcher` watches (`OrderFilled`, `OrderCancelledByHash`,
   `OrdersCancelled`, `NoncesRolledBack`, `NonceWordInvalidated`; ABIs from the
   SDK) plus `GroupClaimed` on `OCO_MODULES`. Cancellations evict with zero
   lens calls, maker-checked. The cursor advances only after the whole range
   applied; the `(txHash, logIndex)` key makes a re-read idempotent. A fresh
   object starts at `START_BLOCK`, else `INITIAL_LOOKBACK_BLOCKS` back;
4. re-check on the lens, in one batched `getOrderRelevantStates` sweep (the
   library `Verifier`'s chunking / bisection), every `dirty` order plus the
   stalest ones not checked for `REVALIDATE_SECONDS`, at most
   `MAX_RECHECK_PER_ALARM`. Not-`ok` ⇒ tombstone; an isolated `Inconclusive`
   three times running ⇒ evicted; an RPC outage (no lens call worked) evicts
   nothing.

### How fills are indexed

`OrderFilled(orderHash, maker, solver)` carries no amount, so the amount is
reconstructed exactly like the library `FillIndex`: `filled(hash)` read **at the
log's block** gives the cumulative; the previous cumulative is the newest
indexed row below that block, else `filled(hash)` at `block − 1`. Several fills
of one order in one block share one cumulative; the delta goes on the last of
them, the others report `amount: null`. The cancelled sentinel and a zero
cumulative (fill-once orders keep progress in the nonce) are `null`, never an
amount. A node that cannot serve the historical read falls back to `latest`
for the cumulative and leaves the amount `null`.

Then the order: cumulative ≥ the anchor (fill total, else the SELL input /
BUY output) ⇒ tombstone `Filled` with the fill's `txHash`; otherwise its
`filledAmount` is updated and it is marked dirty for the lens re-check. A
fill-once / proportional fill is found `Filled` by that re-check and its
tombstone still names the indexed tx. A fill of an order already tombstoned
(e.g. soft-cancelled, then filled by someone holding the signature) updates the
tombstone. Fills of orders this node never held are indexed too (`/fills?maker=`
covers the maker's whole history from the first scanned block).

### Client IP and spoofing

The entry worker resolves the address and passes it to the DO in an internal
header it always overwrites (the DO is reachable only through the entry worker):

1. `x-orderbook-client-ip`, **only** if `x-orderbook-binding-key` equals the
   `BINDING_KEY` secret — set by the app's Pages worker on the service binding
   from the visitor's own edge-set `cf-connecting-ip`. Without a configured key
   the header is ignored.
2. `cf-connecting-ip` — on the public route Cloudflare's edge sets it; a client
   cannot choose it.

`x-forwarded-for` is never read. A service-binding request carries only the
headers its caller set (a rebuilt request has no `cf-connecting-ip`), which is
why the binding passes the address explicitly; see the app README
(*Binding the Worker orderbook*) for the full argument.

## Deploy

```bash
cd packages/orderbook-worker
pnpm --filter @1delta-x/sdk build && pnpm --filter @1delta-x/orderbook build   # the worker bundles their dist/

npx wrangler login
# 1. contract addresses (and anything else) in wrangler.toml [vars], or per deploy:
#    SETTLEMENT / PERMIT3 / LENS are placeholders (zero) until deployed — writes 503 until then.
# 2. the binding secret shared with the Pages project:
KEY=$(openssl rand -hex 32)
echo "$KEY" | npx wrangler secret put BINDING_KEY
# 3. optional private RPC (the public node is the default): remove RPC_URL from [vars]
#    first (a var and a secret cannot share a name), then
#    echo "https://…" | npx wrangler secret put RPC_URL
pnpm bundle-check          # no protobufjs / new Function in the bundle
npx wrangler deploy
```

Then bind it to the app: Pages → *Settings* → *Bindings* → *Service binding*
`ORDERBOOK` → `orderbook-1delta-rsk`, plus the Pages secret
`ORDERBOOK_BINDING_KEY=$KEY`, and build the app with `VITE_ORDERBOOK_URL=/api/book`
(details in `packages/app/README.md`). The beta filler (`packages/rif-filler`)
reads `GET /orders` from the worker's `workers.dev` URL or through `/api/book`.

| var | default | notes |
|---|---|---|
| `CHAIN_ID` | `30` | one deployment (and one DO) per chain |
| `SETTLEMENT` / `PERMIT3` / `LENS` | zero (placeholder) | until set: writes `503`, no chain work |
| `RPC_URL` | `https://public-node.rsk.co` | must serve `eth_getLogs` and (ideally) historical `eth_call` |
| `DEFAULT_FILLER` | zero | filler the lens previews validators for |
| `OCO_MODULES` | — | comma-separated OcoGroupModule addresses |
| `ALLOWED_TOKENS` | USDRIF, USDT0 | leg-token allowlist (empty = any) |
| `MAX_ORDERS` / `MAX_ORDERS_PER_MAKER` | `5000` / `100` | |
| `MAX_CURVE_POINTS` / `MAX_ORDER_JSON_BYTES` | `32` / `32768` | |
| `MIN_TTL_SECONDS` / `MAX_TTL_SECONDS` | `15` / `7776000` | |
| `REQUIRE_DELTA_VERIFY` | `false` | keep `false` for the EOA beta filler (pull orders) |
| `MAX_BODY_BYTES` | `262144` | raw JSON body cap |
| `RATE_LIMIT_IP_CAPACITY` / `_REFILL` | `120` / `1` | costs: read 1, query 2, cancel 5, write 10 |
| `RATE_LIMIT_MAKER_CAPACITY` / `_REFILL` | `120` / `1` | |
| `ALARM_INTERVAL_SECONDS` | `20` | |
| `MAX_LOG_RANGE` / `CONFIRMATIONS` | `2000` / `2` | blocks per alarm / behind head |
| `START_BLOCK` / `INITIAL_LOOKBACK_BLOCKS` | — / `2880` | first scan of a fresh object (set `START_BLOCK` to the Settlement deploy block) |
| `REVALIDATE_SECONDS` / `MAX_RECHECK_PER_ALARM` | `60` / `500` | |
| `TOMBSTONE_TTL_SECONDS` / `MAX_TOMBSTONES` / `MAX_FILLS` | 14 d / `20000` / `50000` | |
| `BINDING_KEY` (secret) | — | see *Client IP and spoofing* |

## Test

```bash
pnpm test           # vitest: workers project (inside workerd via @cloudflare/vitest-pool-workers) + node parity project
pnpm typecheck
pnpm bundle-check
```

The `workers` project runs the real Durable Object, SQLite storage, alarms and
eviction in Miniflare, fully offline; the chain and lens are replaced through
`setDepsFactory` (real Layer 1 signature recovery and the real
`CancelVerifier`, scripted Layer 2 and logs). The `node` project checks JSON
parity against `orderbook-server`'s parse → protobuf → decode path, which cannot
run in workerd.

## Limitations

- **Single-region, single-threaded per chain.** One DO serializes every request
  for the chain; fine at beta volume, a ceiling later.
- **No WebSocket stream, no `/quote`, no `/replaces`, no protobuf.** Clients poll.
- **Reorgs:** logs are read `CONFIRMATIONS` behind head and never re-read; a
  deeper reorg can leave a fill row or an eviction that the canonical chain no
  longer has (an evicted order can be re-posted).
- **Fill amounts depend on historical state.** On an RPC without it, amounts are
  `null` (cumulatives fall back to `latest`).
- **The fill index starts at the first scanned block** (`START_BLOCK` /
  lookback); `coverage` says so.
- **Rate limiting lives in the DO**, so a flood still reaches it (and is billed
  to Workers requests). Put Cloudflare WAF rate-limiting rules in front for
  volumetric abuse.
- **`MAX_ORDER_JSON_BYTES`** is a JSON size, not the server's protobuf size.
- **Subrequests:** one alarm makes ~1 `eth_getLogs` + 1–2 `eth_call` per fill +
  the lens sweep; keep `MAX_LOG_RANGE` and `MAX_RECHECK_PER_ALARM` within the
  Workers subrequest limit for your plan.

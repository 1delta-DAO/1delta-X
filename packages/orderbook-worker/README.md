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

> **RPC requirement — read before deploying.** The alarm indexes fills and applies
> on-chain cancels from `eth_getLogs`. **Rootstock's public node
> (`https://public-node.rsk.co`, the `RPC_URL` default) does not serve `eth_getLogs`**
> (JSON-RPC `-32601 method not found`), so on it the fill index never advances and
> on-chain cancels are never seen. Production needs a keyed provider that serves
> `eth_getLogs` on Rootstock (e.g. Alchemy, which documents it), set as the
> **`RPC_URL_SECRET`** secret — read in preference to the `RPC_URL` var, so the var line
> can stay (a var and a secret cannot share a name):
>
> ```bash
> echo "https://<provider>/<key>" | npx wrangler secret put RPC_URL_SECRET
> ```
>
> Without it the worker still runs, loudly: `/health` reports `logsUnsupported: true`
> and a `lastError` naming `RPC_URL_SECRET`, the lens re-check falls back from
> `REVALIDATE_SECONDS` (300 s) to 60 s (it is then the only way fills and cancels reach
> the book), and the filler worker's monitor alerts (`book:logs-unsupported`).

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
| GET | `/health` | config, counts, fill coverage, `rpc` (which binding the URL came from: `RPC_URL_SECRET` / `RPC_URL` — never the URL), `alarmIntervalSeconds`, `revalidateSeconds` (effective), `lastAlarm`, **`logsUnsupported`**, `logs` (`{ok, unsupported, span, lastOkAt, lastErrorAt, lastError}`), `lastError` (RPC URL redacted) |

The entry worker **buffers** every request body (at most `MAX_BODY_BYTES`; larger is
`413` there) before the Durable Object sees it. It used to stream the body through, and
every refusal the DO answers without reading the body (`429`, `415`, `405`) then threw
"Can't read from request stream after response has been sent" in the entry worker —
one uncaught exception per refused POST (6,941 under the staging harness's abusive
client). `test/entry.test.ts` reproduces it through `SELF.fetch` and workerd's own log.

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
| `meta` | log cursor, first scanned block, the adaptive log span, logs ok / error / unsupported, last alarm / error |
| `buckets` | rate-limit token buckets `ip:<addr>` / `mk:<maker>` |
| `billed` | orders / cancels already charged to their maker (indexed by `at` for its prune) |

In memory there is only the library `Verifier`'s 15-second verdict cache.

Billing notes (every SQLite row written is billed; reads are cheap): there is no index
on `orders(dirty, checked_at)` — each re-check rewrites `checked_at`, and an index entry
is one more written row per re-check, while the re-check query's scan of ≤ `MAX_ORDERS`
rows is reads (objects created before 2026-10-05 drop the old `orders_check` index on
start; the migration is idempotent). A **refused** rate-limit request writes nothing:
the stored `(tokens, updated_at)` already determines the balance at any later time, so
the math is unchanged (`test/ratelimit.test.ts` compares it with the old
write-on-refusal limiter over a long random schedule); idle buckets are pruned only once
they have refilled to capacity.

### Alarm cadence

The DO's alarm re-arms itself after every pass: every `ALARM_INTERVAL_SECONDS`
(20 s), or after 1 s while the log cursor is behind. Any request re-arms a
missing alarm, and the cron trigger (`* * * * *`) only calls `kick()` to do the
same — it never does the work itself.

A pass is **bounded in time**, so a hanging RPC cannot push an alarm toward
Cloudflare's 15-minute alarm wall-clock limit: every RPC call has an explicit 8 s
timeout (viem, one retry); a pass stops sizing fills and starts no re-check once
`ALARM_BUDGET_SECONDS` (240) have passed — the log cursor then stops at the first log
it did not apply and the next pass runs 1 s later; and one lens re-check sweep is
capped at 16 bisection calls and 60 s (the library `Verifier`'s `maxRecheckCalls` /
`maxSweepMs`). One pass:

1. prune tombstones, soft cancels, buckets, bills and the fill cap;
2. evict orders past their deadline (`reason: expired`);
3. read Settlement logs from the cursor — at most `MAX_LOG_RANGE` blocks, up to
   `head − CONFIRMATIONS` — with one `eth_getLogs` for the five Settlement events
   `ChainWatcher` watches (`OrderFilled`, `OrderCancelledByHash`,
   `OrdersCancelled`, `NoncesRolledBack`, `NonceWordInvalidated`; ABIs from the
   SDK) plus `GroupClaimed` on `OCO_MODULES`. Cancellations evict with zero
   lens calls, maker-checked. The cursor advances only after the whole range
   applied; the `(txHash, logIndex)` key makes a re-read idempotent. A fresh
   object starts at `START_BLOCK`, else `INITIAL_LOOKBACK_BLOCKS` back.
   The span per read is **adaptive**: halved after every failed read (a provider's
   block-range cap, a timeout on a wide range) and doubled back after a success
   once no read failed for 10 min, persisted in `meta` — a range cap cannot stall
   the cursor forever. A `-32601` "method not found" is not a range problem: it
   sets `logsUnsupported` (see *RPC requirement* above) and the span stays;
4. re-check on the lens, in one batched `getOrderRelevantStates` sweep (the
   library `Verifier`'s chunking / bisection), every `dirty` order plus the
   stalest ones not checked for `REVALIDATE_SECONDS` (300; 60 while the RPC serves
   no `eth_getLogs`), at most `MAX_RECHECK_PER_ALARM`. Not-`ok` ⇒ tombstone; an
   isolated `Inconclusive` three times running ⇒ evicted; an RPC outage (no lens
   call worked) evicts nothing; a row the sweep's call / time budget did not reach
   stays as it was.

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
# 1. contract addresses in wrangler.toml [vars]: SETTLEMENT / PERMIT3 / LENS are
#    placeholders (zero) until deployed — writes 503 until then — and START_BLOCK
#    (REQUIRED: the Settlement deploy block; unset, older fills are never indexed).
# 2. the binding secret shared with the Pages project:
KEY=$(openssl rand -hex 32)
echo "$KEY" | npx wrangler secret put BINDING_KEY
# 3. REQUIRED: a keyed RPC that serves eth_getLogs (the public node does not):
echo "https://<provider>/<key>" | npx wrangler secret put RPC_URL_SECRET
pnpm bundle-check          # no protobufjs / new Function in the bundle
make -C ../.. workers-smoke   # the worker (and the filler, the app) START in workerd
npx wrangler deploy
curl -s https://orderbook-1delta-rsk.<account>.workers.dev/health | jq '{rpc, logsUnsupported, logs, lastAlarm}'
#    → rpc "RPC_URL_SECRET", logsUnsupported false, logs.ok true within a minute
```

Then bind it to the app: Pages → *Settings* → *Bindings* → *Service binding*
`ORDERBOOK` → `orderbook-1delta-rsk`, plus the Pages secret
`ORDERBOOK_BINDING_KEY=$KEY`, and build the app with `VITE_ORDERBOOK_URL=/api/book`
(details in `packages/app/README.md`). The beta filler's Worker (`packages/filler-worker`)
reads `GET /orders` over its own `ORDERBOOK` service binding to this worker (give it
the same `BINDING_KEY` as its `ORDERBOOK_BINDING_KEY` secret so it gets its own rate-limit
bucket); the Node CLI (`packages/beta-filler`) reads the `workers.dev` URL or `/api/book`.

| var | default | notes |
|---|---|---|
| `CHAIN_ID` | `30` | one deployment (and one DO) per chain |
| `SETTLEMENT` / `PERMIT3` / `LENS` | zero (placeholder) | until set: writes `503`, no chain work |
| **`RPC_URL_SECRET`** (secret) | — | **required in production**: a keyed RPC that serves `eth_getLogs` (and ideally historical `eth_call`); wins over `RPC_URL` |
| `RPC_URL` | `https://public-node.rsk.co` | fallback only — serves no `eth_getLogs` (see *RPC requirement*) |
| `DO_LOCATION_HINT` | — | optional DO location hint (`wnam`, `enam`, `weur`, …; unknown values ignored). Only affects where the object is first **created** |
| `DEFAULT_FILLER` | zero | filler the lens previews validators for |
| `OCO_MODULES` | — | comma-separated OcoGroupModule addresses |
| `ALLOWED_TOKENS` | USDRIF, USDT0, WRBTC, WETH | leg-token allowlist (empty = any): the app's three Rootstock markets. Before 2026-10-05 the default was only USDRIF/USDT0, which refused every WRBTC/USDT0 and WETH/WRBTC (route-market) order with a 422 |
| `MAX_ORDERS` / `MAX_ORDERS_PER_MAKER` | `1000` / `100` | 1000 = the filler worker's intake window (`INTAKE_MAX_PAGES` 2 × `INTAKE_PAGE_SIZE` 500): every order held is one the filler sees. Raise both together |
| `MAX_CURVE_POINTS` / `MAX_ORDER_JSON_BYTES` | `32` / `32768` | |
| `MIN_TTL_SECONDS` / `MAX_TTL_SECONDS` | `120` / `7776000` | 120 s ≥ 4 Rootstock blocks; the filler skips anything expiring within 90 s |
| `REQUIRE_DELTA_VERIFY` | `false` | keep `false` for the EOA beta filler (pull orders) |
| `MAX_BODY_BYTES` | `262144` | raw JSON body cap (enforced by the entry worker and the DO) |
| `RATE_LIMIT_IP_CAPACITY` / `_REFILL` | `120` / `3` | costs: read 1, query 2, cancel 5, write 10. An open app tab spends (T + 2) tokens per 6 s for T tracked orders: 3/s sustains 16 per tab (1/s ran dry above 4) |
| `RATE_LIMIT_MAKER_CAPACITY` / `_REFILL` | `120` / `1` | |
| `ALARM_INTERVAL_SECONDS` | `20` | a monitor flags `lastAlarm` older than 3 × this |
| `ALARM_BUDGET_SECONDS` | `240` | wall-clock budget of one pass (see *Alarm cadence*) |
| `MAX_LOG_RANGE` / `CONFIRMATIONS` | `2000` / `2` | max blocks per `eth_getLogs` (halved automatically on failures) / behind head |
| `START_BLOCK` / `INITIAL_LOOKBACK_BLOCKS` | — / `2880` | **`START_BLOCK` is required for a real deployment**: the Settlement deploy block. Unset, a fresh object indexes only the last ~day |
| `REVALIDATE_SECONDS` / `MAX_RECHECK_PER_ALARM` | `300` / `500` | fills / cancels come from the logs; the re-check only catches balance / allowance moves. 60 s automatically while the RPC serves no `eth_getLogs` |
| `TOMBSTONE_TTL_SECONDS` / `MAX_TOMBSTONES` / `MAX_FILLS` | 14 d / `20000` / `50000` | |
| `BINDING_KEY` (secret) | — | see *Client IP and spoofing* |

`preview_urls = false` in `wrangler.toml`: no per-version preview hostnames, each of which
would be one more public way in to the same Durable Object.

## Test

```bash
pnpm test           # vitest: workers project (inside workerd via @cloudflare/vitest-pool-workers) + node parity project
pnpm typecheck
pnpm bundle-check
make -C ../.. workers-smoke   # starts this worker (and the filler, the app) in wrangler dev and checks /health
```

The unit suite runs the code in workerd but not the way a deployment STARTS it:
workerd refuses a main module that exports anything but entrypoints (a string constant
did exactly that on 2026-10-05), which `test/entry.test.ts` pins and `make
workers-smoke` (`tools/workers-smoke.sh`, ~10 s, not in `test-ts`) checks for real.

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
  to Workers requests — though a refused request no longer writes a row). Put
  Cloudflare WAF rate-limiting rules in front for volumetric abuse.
- **`MAX_ORDER_JSON_BYTES`** is a JSON size, not the server's protobuf size.
- **Subrequests:** one alarm makes ~1 `eth_getLogs` + 2–3 calls per fill it
  sizes + the lens sweep, bounded by `ALARM_BUDGET_SECONDS`. Workers Paid allows
  10,000 subrequests per invocation by default (Free: 50) —
  <https://developers.cloudflare.com/workers/platform/limits/>.

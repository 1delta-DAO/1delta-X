# @1delta-x/filler-worker — the Rootstock beta filler on Cloudflare

The beta filler ([`@1delta-x/beta-filler`](../beta-filler)) wrapped as a Cloudflare Worker
plus one SQLite Durable Object. It runs the same platform-agnostic core as the Node CLI
(`@1delta-x/beta-filler/core`: the strategies, the shared gas Guard, the rebalancer and the
tick engine), with Durable Object storage instead of `STATE_FILE`, an alarm loop instead of
`setInterval`, an admin HTTP API, webhook alerts and a fills/P&L log in SQLite.

```
cron (every minute) ──kick──▶ FillerDO.alarm ──▶ tick ──▶ setAlarm(+3 s pending | +TICK_SECONDS)
                                         ▲
admin API (Bearer) ── /tick ─────────────┘ (joins a running tick, never overlaps)
```

> **RPC.** Set a keyed Rootstock RPC as the **`RPC_URL_SECRET`** secret: it is read in
> preference to the `RPC_URL` var (the public node), so the var line can stay (a var and
> a secret cannot share a name). The public node rate-limits, and an idle filler alone
> makes ~20k calls a day. The **orderbook** worker *requires* such a provider: the public
> node does not serve `eth_getLogs` (see its README) — this worker's monitor alerts when
> the book reports it (`book:logs-unsupported`).

## The tick

One `FillerDO` instance (`idFromName("filler")`). Each alarm runs one tick of the engine
(`packages/beta-filler/src/engine.ts`):

1. **Resolve** the outstanding tx, if any: one `eth_getTransactionReceipt`, never a wait.
   - **Mined:** the gas charge becomes the receipt's real cost (also on a revert). A revert
     releases the budget reservation and is a strike on the order (1 min, 4 min, 16 min,
     1 h, then blacklisted).
   - **No receipt after `RECEIPT_TIMEOUT_MS`:** the budget reservation made at send time
     (the inventory outflow or one route fill) becomes final. A receipt that comes later
     still settles the gas charge to its real cost, so a fills row's `gas_used` and
     `gas_cost_wei` always come from the same receipt; a late revert is a strike but
     does not release the reservation.
   - **Nonce taken by another tx** — no receipt, and the account's *mined* nonce is past
     the tx's own (one extra `eth_getTransactionCount`, only once the tx is ≥ 60 s past
     its last broadcast): it can never mine, so it is dropped at once (no re-broadcasts,
     no 15 min wait). This is what a hand-replaced tx looks like.
   - **Unknown to the node** — a definite `TransactionNotFoundError`, never an RPC
     error, timeout or 429 — **60 s after its last broadcast:** the recorded signed bytes
     are **re-broadcast** (same nonce, same hash, so it is idempotent), at most 5 times,
     ≥ 60 s apart. A broadcast lost in flight (a crash between the commit and the send,
     a dropped connection) used to stall every send for up to 15 min.
   - **Not mined and definitely unknown to the node after 15 min:** dropped. The order
     gets a short backoff; the gas **and** the budget reservation (inventory outflow or
     route fill) stay charged until they leave the hourly window.

   Same engine as the Node CLI, different bounds: the CLI sweeps the whole book until
   the first send (no per-tick order / subrequest / wall-clock bounds), reads up to
   20 × 500 book entries (here `INTAKE_MAX_PAGES` × `INTAKE_PAGE_SIZE`, 2 × 500), runs
   a rebalancer step on every idle poll (here at most every `REBALANCE_SECONDS`), and
   polls a pending receipt every 1 s (here every `PENDING_TICK_SECONDS`, 3 s). **While a tx is outstanding nothing else is
   sent, and the tick ends here.** There is one outstanding tx at a time, so nonces are
   trivially right.
2. **Sweep** the book (if not paused): fetch `GET /orders?fillableOnly=true` over the
   `ORDERBOOK` service binding. **Never-seen orders go first** (oldest first, by the
   book's `addedAt`), then the rest round-robin by order hash after the stored cursor —
   so a new order is evaluated on the next tick however many rest in the book. Each
   order goes through inventory first, then route. The sweep stops at the **first tx
   sent**. Skipped without any RPC:
   - orders expiring within `EXPIRY_MARGIN_SECONDS` (90): a tx cannot land in time;
   - **resting orders**: one every strategy passed on at its current terms
     (unprofitable, out of price, below the minimum, no route) is not re-quoted for
     `RESTING_RECHECK_SECONDS` (300) unless the book reports a different
     `fillableAmount` for it (at most 30 s for an order whose price moves with time).
     A transient refusal (gas price, budgets, balance, a backoff) is not held. 31
     resting orders used to cost ~67 RPC calls per tick (~388k/day);
   - **an order we just filled**, until the book reports a different fillable for it
     or `RESTING_RECHECK_SECONDS` pass: the book indexes a fill ~60–80 s after
     inclusion on Rootstock and serves the order until then (persisted across restarts);
   - the inventory strategy also refuses, at zero RPC, a **fixed-price** order (no
     curve, every leg `end == 0`) whose implied price is outside `MAX_BUY_PRICE` /
     `MIN_SELL_PRICE`.

   `eth_gasPrice` is read once per ~10 s for every order and strategy (it was read
   per order per strategy).
3. If nothing was sent, run **one rebalancer step** (inventory only, at most every
   `REBALANCE_SECONDS`, default 30): redeem USDRIF through MoC, or sell RIF. A missing approval is sent as its own tx first. These txs
   go through the same Guard: the hourly gas budget, `MAX_GAS_PRICE_GWEI`, the
   one-outstanding rule and the same `broadcast()`.
4. **Alerts** (below), then save the state and re-arm: `PENDING_TICK_SECONDS` (3 s)
   while a tx is outstanding — Rootstock blocks come every ~30 s, so 1 s polled ~30
   times per fill for nothing — else `TICK_SECONDS` (5 s). Keep `TICK_SECONDS` ≤ 8: a
   Durable Object idle for ~10 s is evicted from memory, and every tick after that
   would rebuild the engine (config, state, the route strategy's solver check) and lose
   its in-memory caches.

**Sending** (`broadcast` in `packages/beta-filler/src/guard.ts`):

1. Refuse while a tx is pending, above the gas-price ceiling, or when the hourly gas
   budget cannot cover limit × price. Also refuse when the account's *pending* nonce is
   ahead of its *mined* nonce, which means a tx we do not track is in flight.
2. Sign an **explicit legacy (type-0) tx** at the mined nonce, locally, with viem's
   `privateKeyToAccount`. A test verifies this in workerd by recovering the signer.
3. Charge conservatively, record the tx as pending — **with its signed raw bytes** —
   and **commit the state before the broadcast**. A crash between the two cannot lose
   track of a tx that may be in the mempool, and a lost broadcast can be repeated
   verbatim.
4. Send the raw bytes. If the node refuses them and *definitely* does not know the hash
   (`TransactionNotFoundError`), the charges and the pending record are undone; if the
   check itself fails (an RPC error), the tx stays pending and step 1 sorts it out.

### Per-tick bounds

| Bound | Var | Default |
|---|---|---|
| Orders evaluated per tick (only orders a strategy accepts count; the rest are skipped without RPC) | `MAX_ORDERS_PER_TICK` | 10 |
| Subrequests per tick (every RPC call and the book fetch, counted through the transport); a new order starts only while `SUBREQUESTS_PER_ORDER` remain | `MAX_SUBREQUESTS_PER_TICK` / `SUBREQUESTS_PER_ORDER` | 500 / 40 |
| Wall clock: no new order after | `TICK_BUDGET_MS` | 20 000 |
| Book pages × page size per fetch (= the orderbook's `MAX_ORDERS`, 1000) | `INTAKE_MAX_PAGES` / `INTAKE_PAGE_SIZE` | 2 × 500 |
| Resting / own-fill hold; expiry margin | `RESTING_RECHECK_SECONDS` / `EXPIRY_MARGIN_SECONDS` | 300 / 90 |

The round-robin cursor (the last order hash evaluated) lives in the DO, so a bounded
sweep resumes where it stopped across ticks. The set of already-evaluated orders does
not: it is in memory, so after an eviction every order counts as never-seen again and
the sweep restarts from the oldest `addedAt` (the cursor applies once they are seen). In dry run, an order that just
dry-ran is not re-evaluated for 60 s.

**Workers plan:** use **Workers Paid**. Free allows 50 subrequests and 10 ms of CPU per
invocation, which is too little for a route fill (≈ 20–30 RPC calls plus secp256k1
signing). Paid allows **10,000 subrequests per invocation by default**
(<https://developers.cloudflare.com/workers/platform/limits/>); the 500 default here is
about RPC cost and tick length, not the platform limit.

## Admin API

Every route except `/health` needs `Authorization: Bearer $ADMIN_TOKEN`. The comparison
is constant-time over SHA-256 digests (`src/auth.ts`). A missing or wrong token gets 401.
With no `ADMIN_TOKEN` set, every admin route is refused.

| Route | |
|---|---|
| `GET /status` | address, balances (RBTC / USDT0 / USDRIF / RIF / WRBTC / WETH), budgets left, the pending tx (incl. re-broadcasts), an untracked-in-flight streak, the MoC redemption, the orderbook's last `/health` (alarm, logs), recent fills / reverts / skips, the backoff list, alerts, last tick, config summary incl. `rpcSource` (never the key, the admin token, the webhook URL or a secret RPC URL) |
| `POST /pause` / `POST /resume` | stop or allow **new** sends. A pending tx is still resolved, and a running tick stops before its next order |
| `POST /dry-run` `{"on": true\|false}` | runtime override of `DRY_RUN`, persisted in the DO |
| `POST /tick` | run a tick now (joins the running one if any) |
| `GET /fills?limit=&since=&kind=&status=&format=csv` | the fills / P&L log (below) |
| `GET /health` | **unauthenticated**: `{"ok", "lastTickAgeSeconds"}` only |

**Exposure (production):** serve the admin API on a **custom domain behind Cloudflare
Access** (`routes = [{ pattern = "filler.example.com", custom_domain = true }]`, an Access
application on that hostname as a second factor in front of the bearer token — the token
alone can take the filler live), then set `workers_dev = false`. The admin routes answer
404 on any `*.workers.dev` host unless `ADMIN_ALLOW_WORKERS_DEV = "true"` — **never set
that in production**; only `/health` is served there. `preview_urls = false` keeps
Cloudflare from minting per-version preview hostnames for the worker.

```sh
ADMIN=https://filler.example.com
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" $ADMIN/status | jq
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" -X POST $ADMIN/pause
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" -X POST $ADMIN/dry-run -d '{"on":false}'
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$ADMIN/fills?format=csv&since=2026-10-01" > fills.csv
```

## Fills / P&L log

Every resolved tx goes in the DO's SQLite table `fills`: fills, and the rebalancer's
approvals, redemptions and sales. The columns are:

- `at`, `order_hash`, `strategy`, `kind`, `status` (`filled` | `mined` | `reverted` | `dropped`), `tx`;
- `pay_token` / `paid` and `recv_token` / `received`;
- `gas_used` and `gas_cost_wei`: the receipt's figures, or the limit's once timed out;
- `profit_est` / `profit_token`: an estimate of the gross profit before gas.
  - **inventory:** the received USDRIF at $1 less the 0.2% MoC fee, minus the USDT0
    paid (or the reverse on the sell side);
  - **route:** our share of the quoted surplus over the owed amount.

The table keeps at most `MAX_FILL_ROWS` rows. The CSV export neutralises spreadsheet
formulas.

## Alerts

Alerts go by POST to `ALERT_WEBHOOK_URL` (a secret), aborted after 5 s
(`AbortSignal.timeout`) so a hanging webhook cannot hold the tick. Each alert key fires at
most once per `ALERT_COOLDOWN_SECONDS`, and at most `ALERT_MAX_PER_HOUR` go out in total.
Without a webhook they are only logged, and they are always listed in `/status`. Text
that leaves the worker has the RPC URLs (`RPC_URL_SECRET` and `RPC_URL`) redacted.

| Alert | Trigger (var) |
|---|---|
| low RBTC | balance < `ALERT_MIN_RBTC` (checked every `BALANCE_CHECK_SECONDS`) |
| low inventory | USDT0 < `ALERT_MIN_USDT0` (buy side on), USDRIF < `ALERT_MIN_USDRIF` (sell side on, 0 = off) |
| reverts | ≥ `ALERT_REVERTS_PER_HOUR` reverted txs in the last hour |
| gas budget exhausted | a send refused for the hourly gas budget |
| tx pending too long | outstanding > `ALERT_PENDING_TX_SECONDS` (600) |
| untracked tx in flight | sends refused because the pending nonce is ahead of the mined one (a tx this filler does not track: another host on the key, a hand-sent tx) for > `ALERT_PENDING_TX_SECONDS` |
| orderbook alarm stale | the book's `/health` `lastAlarm` older than 3 × its `alarmIntervalSeconds` (read every `BOOK_HEALTH_SECONDS`, 300, over the `ORDERBOOK` binding — and 60 s after an inconclusive read: unreachable, or the book's alarm has not run yet, as right after a deploy) |
| orderbook logs | the book's RPC does not serve `eth_getLogs` (`logsUnsupported`: set `RPC_URL_SECRET` on the orderbook), or its log scan is failing |
| MoC redemption pending | not executed > `ALERT_MOC_PENDING_SECONDS` (900) |
| RPC error streak | ≥ `ALERT_RPC_ERROR_STREAK` consecutive failing ticks (and the same for the book intake) |
| tick exception | anything the engine did not catch |

The webhook body depends on `ALERT_FORMAT`:

- **Slack** (`ALERT_FORMAT = "slack"`, the default). Create an incoming webhook; the
  URL is the secret. The body is `{"text": "[filler-1delta-rsk] …"}`.
- **Telegram** (`ALERT_FORMAT = "telegram"`).
  - `ALERT_WEBHOOK_URL` = `https://api.telegram.org/bot<BOT_TOKEN>/sendMessage`. It is
    a secret, because it contains the bot token.
  - `ALERT_TELEGRAM_CHAT_ID` = the chat id (a var).
  - The body is `{"chat_id": "…", "text": "[filler-1delta-rsk] …", "disable_web_page_preview": true}`.

## Deploy runbook

Prerequisites: the beta contracts are deployed and the orderbook worker
`orderbook-1delta-rsk` is live. See [the beta-filler runbook](../beta-filler/README.md#beta-deploy-runbook-rootstock-chain-30)
steps 1–3. You also need a Cloudflare account on **Workers Paid**.

```sh
cd packages/filler-worker
pnpm --filter @1delta-x/sdk build          # the worker bundles the SDK's dist/
npx wrangler login
```

**1. Vars.** Edit `wrangler.toml` `[vars]`:

- set `SETTLEMENT`, `PERMIT3` and `LENS` (until then every tick records "not
  configured" and sends nothing);
- set `AGGREGATOR_SOLVER` (empty = route strategy off) and `ROUTE_PROFIT_RECIPIENT`
  (a treasury; zero = the hot wallet);
- keep **`DRY_RUN = "1"`**;
- review the strategy, gas and alert knobs. Every knob of the Node CLI has the same
  name and default; see the beta-filler README.

**2. Secrets.** Each one is a separate `wrangler secret put`:

```sh
npx wrangler secret put PRIVATE_KEY          # 0x + 64 hex: the hot wallet / solver operator
openssl rand -hex 32 | tee /dev/stderr | npx wrangler secret put ADMIN_TOKEN   # keep it in your password manager
npx wrangler secret put ALERT_WEBHOOK_URL    # Slack webhook, or the Telegram sendMessage URL
# recommended: a keyed RPC; read in preference to the RPC_URL var (which can stay)
npx wrangler secret put RPC_URL_SECRET
# optional: the orderbook's BINDING_KEY, so its rate limiter bills the filler its own bucket
npx wrangler secret put ORDERBOOK_BINDING_KEY
```

**3. Service binding.** `wrangler.toml` already binds `ORDERBOOK` → `orderbook-1delta-rsk`.
That worker must be deployed in the **same account** first. Without the binding, set
`ORDERBOOK_URL` to its `workers.dev` URL. Over the binding, requests carry no
`cf-connecting-ip`, so the orderbook bills them to `unknown` unless
`ORDERBOOK_BINDING_KEY` is set. The default `ORDERBOOK_CLIENT_IP` names the filler's own
bucket.

**4. Deploy in dry run.**

```sh
pnpm bundle-check             # no protobufjs / node:fs / new Function / eval in the bundle
make -C ../.. workers-smoke   # the three beta workers START in workerd (wrangler dev / pages dev)
npx wrangler deploy
curl -s https://filler-1delta-rsk.<account>.workers.dev/health        # {"ok":true,…} within a minute
```

Then serve the admin API on its custom domain behind Cloudflare Access (see *Admin
API*; do not open it on `workers.dev`). `GET /status` must show `configured: true`,
`dryRun: true`, `config.rpcSource: "RPC_URL_SECRET"` and the expected address and
balances, and `orderbook` must show `logsUnsupported: false`. If the route strategy is
on, `logTail` must show the solver checks passing. Place a small order per market from
the app: `logTail` and `recent.events` should show `dry-run` outcomes (`[dry-run]
[route] would fill …`).

**5. Go live.**

1. Fund the hot wallet: RBTC for gas, plus the USDT0 working inventory if the inventory
   strategy is on.
2. Run `curl -s -H "Authorization: Bearer $ADMIN_TOKEN" -X POST $ADMIN/dry-run -d '{"on":false}'`.
   This is a runtime override and survives deploys. Alternatively, set `DRY_RUN = "0"`
   in `wrangler.toml` and redeploy. The override wins over the var, so clear it with
   `{"on":true}` / `{"on":false}` as needed.
3. Watch `GET /status` (`pending`, `recent.fills`, `budgets`) and the explorer for the
   first fills.

To stop at once, call `POST /pause` (pending txs still resolve), or go back to dry run.

**Rotating the key.**

1. `POST /pause`, then wait until `/status` shows `"pending": null`. Never swap the key
   while a tx is outstanding: the record holds the old account's nonce.
2. **Route strategy:** the `AggregatorFillSolver` operator set is immutable. Either the
   solver was deployed with a standby operator (`OPERATORS=<hot>,<standby>`; recommended
   — then rotation is only a secret swap), or deploy a new solver for the new key. A new
   solver means a new `AGGREGATOR_SOLVER` and a new app `solver`, and open delta-verify
   orders naming the old solver are fillable only by it.
3. From the old key: revoke its Settlement / MoC / router approvals (`approve(…, 0)`)
   and move the inventory and RBTC to the new key.
4. `npx wrangler secret put PRIVATE_KEY` (the new key). The new secret takes effect on
   the next request or tick.
5. `GET /status`: the new `address`, balances, and `pending: null`. Then `POST /resume`.

The budgets and the backoff carry over, because they are not keyed by address.

### Security notes

- **Access to the Cloudflare account is access to the key.** A secret is write-only in
  the dashboard, but any code deployed to this worker can read it. So anyone who can
  deploy to the worker can exfiltrate `PRIVATE_KEY`. Therefore:
  - enforce 2FA (or SSO) for every member;
  - keep the account's members to the minimum, with the narrowest roles, and audit
    them;
  - use scoped API tokens, never the global key;
  - consider a dedicated account for the filler.
- **Keep the inventory small.** The hot wallet's balance is the blast radius. Top it up
  from a cold wallet or Safe. The hourly budgets (`HOURLY_USDT0`, `HOURLY_GAS_RBTC`, …)
  bound how fast even a stream of bad orders can drain it.
- **`ADMIN_TOKEN` can take the filler live and pause it.** It cannot read the key. Keep
  the admin API off `workers.dev` and behind Cloudflare Access.
- `/status`, `/fills`, the logs and the alerts never include the private key, the admin
  token, the webhook URL or a secret RPC URL. The RPC host is redacted from error text.

## Develop and test

```sh
npx tsc --noEmit && npx vitest run && node scripts/bundle-check.mjs
npx wrangler deploy --dry-run
make -C ../.. workers-smoke     # starts this worker, the orderbook and the app's Pages worker for real
```

The tests run inside workerd (`@cloudflare/vitest-pool-workers`) against the real SQLite
Durable Object, its alarms and storage. The chain, the book and the webhook are injected
fakes (`setDeps`, `test/helpers.ts`), so the suite is offline. Signing uses the real viem
account. `wrangler dev` runs it locally against the vars in `wrangler.toml` and a
`.dev.vars` file holding the secrets.

## Local staging + load test (`e2e/`, not CI)

`e2e/staging.sh` runs BOTH beta workers — this one and `orderbook-worker` — against an
anvil fork of Rootstock and puts them under load. It is local only: it never runs
`wrangler deploy`, `wrangler secret`, `wrangler login`, `--remote` or `--tunnel`. The
keys are anvil's well-known dev keys (#0 deploys, #1 is the filler / solver operator)
and keccak-derived test keys. Needs foundry (`anvil`, `cast`, `forge`), `pnpm install`,
`python3`, `openssl`, and network access to a Rootstock RPC (`FORK_URL`, default the
public node).

```sh
packages/filler-worker/e2e/staging.sh all      # ≈ 75 min: both latency runs, restart test, soak, report
# or step by step:
packages/filler-worker/e2e/staging.sh up [label]   # prints `export RUN_DIR=…`
packages/filler-worker/e2e/staging.sh load         # MAKERS=20 ORDERS=200 WINDOW_S=360 READERS=20 …
packages/filler-worker/e2e/staging.sh restart      # crash tests (needs a filled-in stack)
packages/filler-worker/e2e/staging.sh soak         # SOAK_RESTING_S=180 SOAK_IDLE_S=600
packages/filler-worker/e2e/staging.sh report [runDir…]
packages/filler-worker/e2e/staging.sh down
```

**`up`**:

1. Starts `anvil --fork-url $FORK_URL --block-time $BLOCK_TIME` (default 2 s) at one
   pinned fork block. `all` uses the same block for both runs. The chain clock is synced
   to the host.
2. Deploys exactly as the runbook does: `make deploy-core` and the gated
   `make deploy-aggregator-fill` (`OPERATORS` = the filler key, `FLOOR_TOKENS` seeded).
3. Funds the operator by storage writes: 10 RBTC, 20,000 USDT0 and 500 USDRIF.
4. Widens the MoC price provider's 20-block validity window. Nobody publishes prices on
   a fork, and at 2 s blocks the price would lapse after 40 s.
5. Starts `e2e/rpc-proxy.ts` between the workers and anvil. It:
   - counts calls per worker and method;
   - injects latency (`LATENCY_MS`, `JITTER_MS`) and optionally rate-limits (`RATE_LIMIT_RPS`);
   - answers `eth_gasPrice` with Rootstock's price (anvil always reports 1 gwei);
   - logs every raw tx sent;
   - is the alert webhook sink.
6. Runs ONE `wrangler dev --local` with three `-c` configs:
   - the harness edge `e2e/gateway` (the primary, since only the primary is served);
   - the orderbook and this filler, each from its **committed `wrangler.toml` verbatim**
     with only `main` repointed, plus a generated `.dev.vars` (overrides and secrets).

   So the `ORDERBOOK` service binding and the `BINDING_KEY` / `ORDERBOOK_BINDING_KEY`
   pair work as in production. The edge serves `/api/book/*` through the app's real
   Pages worker (`packages/app/public/_worker.js`); `x-sim-ip` stands in for each
   visitor's `cf-connecting-ip`.

Overrides: `RPC_URL_SECRET` (the proxy — as in production; the `RPC_URL` var points at
a proxy tag that must stay unused, `ob-var` / `filler-var`), the addresses, `CHAIN_ID`,
`START_BLOCK`, `CONFIRMATIONS=1`, `DRY_RUN=0`, `SUSHI_ENABLED=0`, `RBTC_PRICE_USD` (the
pool) and a treasury `ROUTE_PROFIT_RECIPIENT`. `MIN_TTL_SECONDS=15` (orderbook) and
`EXPIRY_MARGIN_SECONDS=6` (filler) scale the production 120 s / 90 s to the fork's 2 s
blocks (the same ≥ 4 blocks), so the short-expiry kinds still test expiry races.
`ROUTE_HOURLY_FILLS` and `HOURLY_USDT0` are lifted so the run measures throughput rather
than the production caps. `ALLOWED_TOKENS` is the committed default. Pass more with
`EXTRA_FILLER_VARS` / `EXTRA_ORDERBOOK_VARS`.

`DENY_METHODS=ob:eth_getLogs` makes the proxy refuse `eth_getLogs` to the orderbook
with `-32601`. Rootstock's public node does exactly that, and it also has no
`eth_newFilter`.

**`load`** (`e2e/load.ts`): makers post a seeded mix through the Pages worker, each
maker from its own IP:

- profitable USDRIF→USDT0 pull (inventory);
- WRBTC→USDT0 pull and delta-verify direct (route);
- unprofitable, short-expiry, soft- and on-chain-cancelled (live, and inside an admin
  pause);
- duplicates, and malformed, bad-signature and unfunded posts.

Running alongside:

- read clients poll `/orders?maker=`, `/orders/:hash/status` and `/fills` every 1–2 s;
- one client hammers `POST /orders`;
- the admin API polls `/status` and does pause → resume;
- the minute cron is dispatched through wrangler's local explorer API.

It then drains and verifies against the chain:

- every fillable order is filled exactly once, and every maker got ≥ what it is owed;
- nothing unprofitable, expired or cancelled is filled;
- there are no unexplained reverts or nonce clashes;
- the book's fill index and tombstones match the `OrderFilled` logs (tx hash and amount);
- the filler's `/fills` gas and inventory flows equal the chain's.

It also records:

- per-tick RPC calls, from the proxy's timeline split into ticks;
- per-tick subrequests and wall time, from the DO's own `/status` `lastTick`. The
  runtime's local trace store is only a cross-check, because it drops spans under load;
- latency, 429 behaviour and the DO row counts.

**`restart`**:

- **A:** SIGKILL `wrangler dev` while a fill sits unmined in the mempool, then restart on
  the persisted state.
- **B:** lose a broadcast in flight (the proxy swallows it; the worker is killed during
  the hold): the filler must re-broadcast the same signed bytes by itself once the node
  has not known the tx for 60 s, and send nothing else meanwhile.

**`soak`**, in order:

1. RPC cost per tick with a resting book (topped up to `SOAK_RESTING_TARGET`, 31, with
   never-profitable orders, so runs of any load size compare).
2. An isolated-order latency probe (one profitable order at a time), with the resting
   orders present and again with an empty book.
3. An RPC brownout of the filler only (`BROWNOUT_S`): the RPC-streak alert must reach the
   webhook, and the filler must recover.
4. An idle window, extrapolated to a day.

Everything lands in the gitignored `e2e/.run/<label>/`:

- `results/*.json` and `REPORT.md`;
- `wrangler.log`;
- `rpc-timeline.jsonl` (every RPC call);
- the generated configs and the DO state.

### The app's real shapes against the production gates (`app-shape`)

```sh
packages/filler-worker/e2e/staging.sh app-shape     # or: pnpm --filter @1delta-x/filler-worker e2e:app-shape
```

Its own stack (`up` → `e2e/app-shape.ts` → `down`, also on failure), with
`GATES=production`: the book's `MIN_TTL_SECONDS` and the filler's
`EXPIRY_MARGIN_SECONDS` are READ from the two committed `wrangler.toml` files instead of
the staging 15 / 6, and `TICK_SECONDS` is the committed value (never overridden). The
script imports the app's own code — `planTicket` / `buildOrder`, `parseDeployments` +
`solverForMarket` (production shape: the gated solver deployment-wide,
`rsk-30-usdrif-usd0` on `"pull"`), `planFunding` / `fundingCalls`, and `postOrder`
through the app's Pages worker — and signs five tickets, one fresh maker each:

| ticket | market | shape the app produces |
| --- | --- | --- |
| `market-sell` | WRBTC/USD0 | SELL, decaying output leg (`packTiming(now, 60, 0)`), timing bit 104, `exclusiveFiller` = solver |
| `market-buy` | WRBTC/USD0 | BUY, rising input leg, bit 104, `exclusiveFiller` = solver |
| `market-usdrif` | USDRIF/USD0 | SELL, decaying output leg, pull, `exclusiveFiller` = 0 (the B13 soft window is opt-in, off by default) |
| `limit` | WRBTC/USD0 | resting limit SELL, 24 h, fixed legs |
| `twap` | WRBTC/USD0 | TWAP slice 1 (4 × 5 min), fixed legs |

It fails (exit 1) unless every POST answers 202, every market order fills on-chain by
its floor plus the filler's first re-quote (auction hold cap 30 s + one tick + landing)
and before `expiry − EXPIRY_MARGIN_SECONDS`, the direct market lands as `direct`
(route strategy, tx to the solver) and USDRIF as `pull`, and each maker gets at least
its floor. The app's ladder is reduced to one fee-less rung at the pool's on-chain mid
(what the app's tick ladder centres on; the Oku feed is not on the fork). Results:
`e2e/.run/app-shape-*/results/app-shape.json`.

Economics (2026-10-07): the app's ladder is fee-net (task 15), the app's market floor is
30 bps, and the filler's haircut is 10 bps (volatile) / 5 bps (stable) with
`MIN_PROFIT_RBTC = 0`, so every market ticket fills with production values. A filler
fills once floor-side slack covers its gas (≈ $0.7–0.9 a route fill), so a ticket needs
roughly (gas ÷ (floor − haircut)) of notional to fill at all: ≈ $360–$450 on WRBTC,
≈ $280–$360 on stables. `MARKET_SLIPPAGE_BPS=<bps>` overrides the floor for an
economics experiment (disclosed in the log and results as an ECONOMICS OVERRIDE).

Perturb ONE of the three constants to see it fail: `APP_MARKET_TTL_SECONDS=60` (the app's
`MARKET_TTL_SECONDS`), `MIN_TTL_SECONDS=400` (book), or `EXPIRY_MARGIN_SECONDS=250`
(filler). Sizes: `SELL_WRBTC` (0.01), `BUY_USDT0` (800), `SELL_USDRIF` (300). Local
only, like the rest of `e2e/`; not in CI. Note the fork mines every 2 s, not ~30 s, so
the run proves the gates and the shapes, not production inclusion latency.

## Limitations

- **One outstanding tx.** Throughput is at most one fill per block-and-a-bit: about 30 s
  on Rootstock, plus up to `PENDING_TICK_SECONDS` to notice the receipt. A tx stuck in
  the mempool, still known to the node, blocks every send until it mines. You get an
  alert after 10 min. Nothing speeds it up (no gas-price bump); replace it by hand (same
  nonce) if needed — the filler notices the replacement at its next overdue check (the
  mined nonce passed its own) and resolves the tx as dropped.
- **A tx the node lost** is re-broadcast verbatim (≥ 60 s after its last broadcast, ≤ 5
  times); one that stays unknown is dropped by the CLI's 15-minute rule. Only a definite
  "not found" counts: while the RPC cannot answer, the tx stays pending.
- **Polling.** A new order is seen within `TICK_SECONDS` once it reaches the round-robin
  position. With more than `MAX_ORDERS_PER_TICK` acceptable orders, a full pass takes
  several ticks.
- **The book fetch is bounded** (`INTAKE_MAX_PAGES` × `INTAKE_PAGE_SIZE`). Orders past
  that window are not seen.
- **A pause or a dry-run toggle during a tick** takes effect at the next order boundary;
  a send already in progress completes.
- **RPC load.** An idle tick costs about 2 RPC calls plus one book fetch every
  `TICK_SECONDS`, and the rebalancer adds 2–3 reads every `REBALANCE_SECONDS`. That is
  tens of thousands of calls a day: use a keyed `RPC_URL_SECRET` rather than the public
  node. A resting order is re-quoted once per `RESTING_RECHECK_SECONDS`, not every tick.
- **A resting order is re-quoted at most every `RESTING_RECHECK_SECONDS`** unless its
  book fillable changes: a fixed-price order the market moves into profit is noticed
  within 5 min, not 5 s.
- **The P&L is an estimate:** quoted and previewed amounts, not decoded transfer logs.
- **The admin API is single-tenant.** There is one token and no audit log beyond Workers
  logs.

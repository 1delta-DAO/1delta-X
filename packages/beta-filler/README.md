# @1delta-x/beta-filler — Rootstock beta filler (EOA)

The Rootstock beta's filler bot. It polls the orderbook — the Cloudflare Worker book
(`@1delta-x/orderbook-worker`), as JSON (`GET /orders?fillableOnly=true`, paged) — and
runs every order through up to two strategies, **inventory first, route second**:

| | **inventory** | **route** (DEX aggregator path) |
|---|---|---|
| What fills | the hot wallet itself: `Settlement.fillUpTo` | `AggregatorFillSolver.executeFill`, sent by the same EOA as operator |
| Capital | wallet inventory (USDT0 / USDRIF) | none — the maker's input is swapped on Oku's Uniswap v3 SwapRouter02 |
| Markets | `rsk-30-usdrif-usd0` only | every configured pool: `rsk-30-wrbtc-usd0`, `rsk-30-weth-wrbtc`, `rsk-30-usdrif-usd0` (+ optional multi-hop paths) |
| Delta-verify orders (timing bit 104) | **no** (an EOA cannot run the fill callback) | **yes**, when `exclusiveFiller` = our solver: the route pays the maker directly |
| Pull orders | `exclusiveFiller` 0, this wallet, or another filler whose window is over or **soft** (it pays the premium inside the window) | the same, measured against the **solver**. If a deployment opts in to the app's pull window, which names the solver, the route fills inside it with no premium |
| Spread | the price we chose (`MAX_BUY_PRICE` …) minus fill gas, a share of the rebalance gas + MoC exec fee, and `INVENTORY_MIN_PROFIT_USDT0` | pool quote − owed − gas − `MIN_PROFIT_RBTC`; goes to `ROUTE_PROFIT_RECIPIENT` (default: the operator EOA) |
| Gas per fill (fork-measured, see below) | ≈ 154.4k gross tx | ≈ 247.9k direct / ≈ 282.9k pull, net of refund |
| Switch | `INVENTORY_ENABLED` (default on) | `ROUTE_ENABLED` (default on iff `AGGREGATOR_SOLVER` is set) |

**What the gas row measures** (re-run 2026-10-06, `FOUNDRY_PROFILE=solvers` — legacy
codegen, runs 20,000, `evm_version = prague` — on a Rootstock fork at block 8,920,000,
1,000 USDRIF → USDT0 through Oku's USDRIF/USDT0 pool, fresh transaction, all seeding in
`setUp`):

| figure | what it is | test |
| --- | --- | --- |
| inventory ≈ 154.4k | **gross** tx gas = execution 126,257 + calldata 7,096 + the 21k intrinsic, refund NOT deducted; plain `fill` (not `fillUpTo`), solver holds 1 wei USDRIF | `FreshTxComparisonTest.test_fresh_inventoryFill` (`packages/solvers/test/RawSwapComparison.t.sol`) |
| route direct ≈ 247.9k | **net** tx gas = execution 252,567 + calldata + 21k − refund 37,900 (under the EIP-3529 gasUsed / 5 cap); gross 285.8k; sandboxed solver, solver floor SEEDED (1 wei of each token, treasury paid before), sandbox approval standing | `SandboxGasBench.test_sandbox_gas_direct` (`packages/solvers/test/RouteSandboxFork.t.sol`) |
| route pull ≈ 282.9k | **net** tx gas = execution 310,502 + calldata + 21k − refund 60,600; gross 343.5k; same fixture | `SandboxGasBench.test_sandbox_gas_pull` |

Untyped callback (`amountOutOffset = NO_PATCH`; a still-decaying direct SELL now sends the typed path, ~+5.9k, see Limitations). The figures
the bot actually sees are the node's `eth_estimateGas` — the GROSS figure (refunds
are credited after execution, so the limit must cover them) — and the receipt's
`gasUsed`, which is net. Rootstock's own gas schedule is not Prague's; treat the
fork figures as the shape, not the exact receipt.

**Why inventory first.** The two overlap only on plain pull USDRIF/USDT0 orders
(inventory refuses delta-verify orders and every other pair). There the inventory fill
is the cheaper transaction and earns the full spread at a price we set, with no pool
slippage. The route strategy is the fallback that turns everything else on the
configured pools into a fill without holding inventory. A strategy that skips or fails
falls through to the next one (`src/dispatch.ts`).

DRY_RUN is the default: only `DRY_RUN=0` broadcasts.

**Two hosts, one core.** Everything above runs in a platform-agnostic core
(`src/core.ts`: no `node:*`, no `process.env`, no blocking waits; config from a plain
record, state through an injected `StateStore`), driven by a tick engine
(`src/engine.ts`). Two hosts run it:

- the **Node CLI** (`src/bin.ts`, state in `STATE_FILE`), for local runs, `status`,
  `fill-json`, `mint` and the fork e2e;
- the **Cloudflare Worker** [`@1delta-x/filler-worker`](../filler-worker), the beta's
  production host: a Durable Object alarm loop, an admin API, alerts and a fills/P&L log.

**The tick (non-blocking, one outstanding tx).** Each tick:

1. reads the outstanding tx's receipt **once** (it never waits for one) and applies it:
   gas, backoff, timeout, dropped;
2. while a tx is outstanding, sends nothing else;
3. otherwise sweeps the book and stops at the **first tx sent**;
4. if nothing was sent, runs one rebalancer step.

A send signs a legacy tx locally, commits it as *pending* — with its signed bytes — to
the state store, then broadcasts it. Nonces are trivially right because only one tx is
ever in flight.

**What a sweep re-quotes.** Never-seen orders go first (oldest first by the book's
`addedAt`), then the rest round-robin. An order every strategy passed on at its current
terms (unprofitable, out of price, below the minimum, no route), and an order we just
filled, are held for `RESTING_RECHECK_SECONDS` unless the book reports a different
`fillableAmount` for them. A held order whose exclusivity window is still running is
re-quoted when the window ends, which is when an outsider's price improves. Orders
expiring within `EXPIRY_MARGIN_SECONDS` are skipped;
`eth_gasPrice` is cached for 10 s across orders and strategies (`src/engine.ts`).

## Order policy (both strategies)

Only the shape the beta app signs:
- one input leg and one output leg, paid to the maker;
- no items, validators, invariants, fill module or pricing module;
- not proportional, not a permit-batch or sigless announce.

Then per strategy:
- **inventory:** not delta-verify. `exclusiveFiller` is zero or this wallet, or the order
  is inside another filler's **soft** window or past it. Refused only while a **hard**
  window runs (override 0, no carrier leg, or a block-clocked window). Only the
  USDRIF/USDT0 pair. The app's pull markets are open by default. If a deployment
  opts in to the app's window (`pullExclusivity`), the order names the *solver
  contract*, so inside that window this EOA is an outsider. The lens
  preview runs with `filler` = the EOA, so the premium is already in every price and
  profit gate. The EOA fills if the order is still worth it, and otherwise it waits
  for the window to end (`exclusivityFor` in `src/policy.ts`).
- **route:** delta-verify **only** when `exclusiveFiller` is `AGGREGATOR_SOLVER` (direct
  mode); otherwise `exclusiveFiller` zero or the solver (pull mode), or another filler
  whose window is over or soft; both tokens must be
  in `ROUTE_TOKENS` (default: the Rootstock market tokens WRBTC, USDT0, WETH, USDRIF —
  with Sushi on, every other pair would otherwise pass and cost an API call per sweep);
  the pair must be routable on a configured pool or path (or, for a pull order, by Sushi). The core compares `exclusiveFiller` with
  `msg.sender` of the fill, which for this strategy is the **solver contract**, never our
  EOA.

Anything else is skipped and logged once per order and reason.

Intake is a candidate list, not a verdict. Each order from `GET /orders` is parsed
strictly (the SDK's `orderFromJson`) and must hash to the `orderHash` the book gave;
orders the book itself reports as not `ok` (or failing validators) are dropped. Every
order is then previewed on the lens and simulated from our address before anything is
sent.

## The inventory strategy (USDRIF/USDT0)

1. **Sizes** the fill to the smallest of: `MAX_FILL_USDT0` of notional, the wallet
   balance, and the hourly budget left.
2. **Previews** the fill on `SettlementLens.previewFill` as this wallet.
3. **Prices** it.
   - Buy side (a maker sells USDRIF, we pay USDT0): the price must be ≤
     `MAX_BUY_PRICE`, *and* the live exit must beat the payment by
     `MIN_EXIT_EDGE_BPS`. The live exit is the received USDRIF redeemed at `getPACtp`,
     less the 0.2% MoC fee, then quoted RIF→USDT0 on QuoterV2.
   - Sell side (off by default): the price must be ≥ `MIN_SELL_PRICE`.
4. **Simulates** the exact `fillUpTo` calldata from the filler address, with the lens's
   `previewBump` as `minBumpBps`, so a maker-ward price move before inclusion reverts.
5. **Broadcasts** under the shared gas policy (below):
   - refuses a gas price above `MAX_GAS_PRICE_GWEI`;
   - sends a legacy tx with gas limit = `eth_estimateGas` × 1.25, after pre-checking the
     shared hourly gas budget against limit × price;
   - reserves the payment on the hourly outflow budget, and returns. A later tick reads
     the receipt.

   A revert or a missing receipt puts the order under the per-order backoff. A missing
   Settlement approval is sent first, as its own tx; the fill follows on a later tick,
   once the approval is mined.

Rebalancing (inventory only):

- USDRIF above `USDRIF_RESERVE` is redeemed through MoC (`redeemTP`, ~2.5 min queue).
- RIF ≥ `RIF_SELL_MIN` is sold on the RIF/USDT0 pool, refusing a quote more than
  `RIF_SELL_MAX_DISCOUNT_BPS` under the MoC oracle.
- **Approvals:** each step uses the allowance it already has — it redeems / sells
  `min(balance, allowance)` once that covers one batch (`REDEEM_MIN_USDRIF` /
  `RIF_SELL_MIN`) — and only (re)approves when the allowance is below one batch, to a
  bounded `max(balance, 4 × batch)` (never unlimited). It used to approve exactly the
  current balance; every fill in between outgrew it, so the next step reset the
  allowance to 0, re-approved, was outgrown again — and never redeemed.
- `pnpm mint 250` mints USDRIF from RIF already in the wallet (sell-side inventory).

Each rebalancer step sends at most one tx (its approval first, if missing). Every tx goes
through the same Guard as fills: the gas budget, the price ceiling, one outstanding tx,
and a per-action backoff on reverts. The MoC op id being waited on is part of the
persisted state.

The security model: **the hot wallet's balance is the blast radius.** Fund it with a
small working inventory and top it up from a cold wallet or Safe; the hourly budgets
bound how fast even a stream of bad orders can drain it. Only the filler's own
transactions spend its Settlement approval (core pulls output legs only from the
address that called the fill).

## Gas policy and per-order backoff (both strategies)

Both strategies and the rebalancer share one `Guard` (`src/guard.ts`), persisted through
the state store (`STATE_FILE` for the CLI, Durable Object storage for the Worker):

- **One hourly RBTC gas budget** (`HOURLY_GAS_RBTC`, default `0.002`; the old name
  `ROUTE_HOURLY_GAS_RBTC` is still read). Every fill tx is pre-checked against its gas
  **limit** × gas price — never an estimate — and charged with the receipt's real cost
  (`gasUsed × effectiveGasPrice`) **even when it reverts**.
- **Gas-price ceiling** `MAX_GAS_PRICE_GWEI` (default `0.1`; Rootstock runs at ≈ 0.026):
  above it nothing is sent. All fill txs are legacy (type 0) at the priced gas price.
- **Per-order backoff:**
  - an **on-chain revert** is a strike and blocks the order for **every** strategy:
    1 min, 4 min, 16 min, 1 h; the 5th strike blacklists it until the order's expiry.
    Dispatch never falls through to the route strategy on an order whose inventory tx
    just reverted (and vice versa);
  - a failure **before sending** (simulation revert, `MAX_ROUTE_GAS`, RPC error) blocks
    only that strategy, 30 s doubling to 5 min — the other strategy may still try;
  - **every sent tx is pending** until a later tick reads its receipt. It is charged
    conservatively at send time: gas at the full **limit**, plus the inventory outflow or
    one route fill. Nothing else is sent while it is outstanding.
  - **Receipt before `RECEIPT_TIMEOUT_MS`** (default 120 s): the gas charge becomes the
    receipt's real cost. A revert releases the outflow / fill reservation and is a
    strike; success clears the order.
  - **No receipt by then:** the tx is *timed out* and the outflow / fill reservation is
    final. A later receipt still settles the gas to its real cost (while the charge is
    inside the hourly window) and updates the backoff: success clears, a revert is a
    strike — but a late revert no longer releases the reservation.
  - **Unknown to the node 60 s after its last broadcast** (a definite
    `TransactionNotFoundError`): the recorded signed bytes are **re-broadcast** — same
    nonce, same hash — at most 5 times, ≥ 60 s apart. An RPC error, timeout or 429 on
    the check is no evidence either way and changes nothing.
  - **The nonce was mined by another tx** (the account's mined nonce passed the tx's own
    and it has no receipt — e.g. it was replaced by hand): dropped at the first overdue
    check (≥ 60 s after its last broadcast), not re-broadcast. Short backoff; the
    charges stay (a same-data speed-up may have filled the order under another hash).
  - **Definitely unknown to the node 15 min after the send:** dropped. Short backoff;
    the gas and the outflow / fill reservation stay charged for the hour.
  - **Pending nonce ahead of the mined nonce** (a tx we do not track is in flight):
    nothing is sent. The streak is tracked; the Worker alerts once it outlasts
    `ALERT_PENDING_TX_SECONDS`.

  Strike history is kept 24 h after a block lapses.

The rebalancer's approvals, redemptions and RIF sales are under the same budget and
ceiling.

## The route strategy (DEX aggregator path)

One operator EOA calls `AggregatorFillSolver.executeFill(order, sig, fillAmount, plan, "")`.
The solver starts `Settlement.fillWithCallback(..., PostInputsDirect)`, receives the
maker's input, PUSHES it to its `RouteSandbox`, which approves `plan.router`, fires
`plan.data` and sweeps every token back (the solver has no router allowlist and never
approves a router — any target works, see packages/solvers/README.md), and:

- **direct** (delta-verify order naming the solver): the route is an **exact-output**
  swap paying the **maker** exactly the owed amount; the core verifies the maker's
  balance delta. `amountInMaximum` = input − (gas + min profit, converted to input
  units at the quoted rate), so a worse pool reverts instead of eating the margin;
  the unconsumed input is our spread. `amountInOffset = NO_PATCH` (the bounded maximum
  must survive); on a still-decaying SELL `amountOutOffset` points at `amountOut` so
  the route pays the LIVE owed and keeps the decay (task 05, below).
- **pull** (no bit 104, `exclusiveFiller` 0): the route is an **exact-input** swap paying
  the **solver** — the default for aggregator routes, because exact-input pays the
  surplus to the solver; Settlement then pulls the owed amount. `minOut` = owed + gas +
  min profit, `maxPay` = the previewed owed amount, and `amountInOffset` points at the
  calldata's `amountIn` word so the swap uses exactly what the fill delivered. The
  surplus over the pull is our spread. Two route SOURCES compete (below): the local Oku
  path (SwapRouter02 `exactInput(Single)`, `amountOutMinimum` = owed + gas + min profit)
  and the **Sushi API**.

**The Sushi source (pull orders only).** `GET {SUSHI_API_URL}/swap/v7/30` with
`tokenIn`, `tokenOut`, `amount` = the previewed input, `maxSlippage` =
`ROUTE_SLIPPAGE_BPS` (as a decimal), `sender` = the solver's sandbox, `recipient` =
the SOLVER. The response's `tx` is a call to Sushi's **RedSnwapper**
(`0xAC4c6e212A361c968F1725b4d055b47E63F80b75`, not a RouteProcessor):
`snwap(tokenIn, amountIn, recipient, tokenOut, amountOutMin, executor, executorData)`
pulls `amountIn` from its caller (the sandbox) into the executor and then requires
`recipient`'s `tokenOut` balance to rise by `amountOutMin`. Every response is DECODED
and refused unless: `status = Success`; `tx.to` = the pinned `SUSHI_ROUTER`; no native
value; the selector is `snwap`; `tokenIn` / `tokenOut` are the order's; `amountIn` =
exactly the previewed input (never 0 — that means "the router's own balance");
`recipient` = the solver; `amountOutMin` ≤ `assumedAmountOut`, and — when the plan is
built — `amountOutMin` ≥ owed + gas + min profit. The calldata must be **canonical**
(re-encoding the decoded arguments must give the same bytes: no trailing data, no
relocated `executorData`), and when `SUSHI_EXECUTORS` is set the `executor` must be one
of those addresses (empty = not pinned; a warning is logged at start-up). The executor
observed on Rootstock in 2026-10 is `0xc10EE9031F2a0B84766A86b55A8d90F357910fb4`; verify
it before pinning. At most `SUSHI_MAX_PER_SWEEP` API calls are made per sweep. API
strings are sanitized (control characters stripped, truncated) before they are logged. `amountInOffset` = 36 (snwap's
`amountIn` word; the executor swaps what it actually received, but `amountOutMin` is a
fixed figure, so the quote is taken for the exact amount). Any failure (HTTP, timeout,
shape) just drops the Sushi candidate.

Per order:
1. **classify** (above);
2. **budgets**: `ROUTE_HOURLY_FILLS` fills per rolling hour, the gas-price ceiling and an
   early look at the shared gas budget (see *Gas policy*);
3. **preview** `SettlementLens.previewFill(order, fillable, filler = AGGREGATOR_SOLVER)` —
   the solver contract, because that is `msg.sender` to Settlement — and
   `previewBump(order, AGGREGATOR_SOLVER)`, both as an `eth_call` at the gas price the
   fill will be SENT with (a priority / gas-bump tick reads `tx.gasprice`; at the default
   0 the preview was the no-bid tick). The bump becomes the plan's `minBumpBps`;
4. **quote** the input → output on QuoterV2 (`quoteExactInput`) along every candidate
   path (each matching pool fee tier, each configured multi-hop path) and, for a pull
   order, fetch + validate a Sushi route; rank all candidates by output NET of each
   route's own gas (QuoterV2's estimate / Sushi's `gasSpent`, priced like the fill gas);
5. **gate** the best-ranked candidate (falling through to the next on failure):
   `quote × (1 − haircut) ≥ owed + gas + min profit`, all in output
   units; haircut = `ROUTE_STABLE_SLIPPAGE_BPS` for a $1/$1 pair, else `ROUTE_SLIPPAGE_BPS`. Gas = chain gas price × `ROUTE_GAS_ESTIMATE`; gas and `MIN_PROFIT_RBTC` are
   converted from RBTC into the output token by a QuoterV2 quote of 0.001 WRBTC along a
   configured WRBTC → output path (cached 60 s) and, for a $1 token (`USD_TOKENS`), by
   `RBTC_PRICE_USD` — the **higher** of the two when both exist, so a thin pool can only
   make gas dearer. "gas + min profit" is grossed up by the solver's surplus split,
   read at start-up (`MAKER_SURPLUS_PPM`, `PROTOCOL_SURPLUS_PPM`): the margin must be
   `(gas + profit) × 1e6 / (1e6 − maker − protocol)` so that OUR share covers it. An
   order whose output cannot be priced is skipped;
6. **build** the RoutePlan: Oku — SwapRouter02 calldata (SDK `encodeExactInput(Single)` /
   `encodeExactOutput(Single)`, `swapRouter02AmountInOffset`); Sushi — the validated
   snwap calldata, offset 36, refused if its `amountOutMin` < owed + gas + min profit;
7. **simulate** `executeFill` by `eth_call` from the operator, decode `fillAmountsOut`
   (must be non-zero, and ≤ the previewed owed on the pull path) and take
   `eth_estimateGas`;
8. **re-price at the measured gas**: P = max(`ROUTE_GAS_ESTIMATE`, simulated). If P is
   above the gas the plan's floor was built at, the plan is **rebuilt** with gas
   priced at P (new `minOut` / `amountInMaximum`, gate re-run) and **re-simulated** —
   repeated until the plan's priced gas covers its own measurement. The economics are
   priced at the measurement, NOT the gas limit (2026-10-07): `eth_estimateGas` is the
   gross gas before refunds and already sits above what a receipt charges (e2e
   2026-10-06: estimates 363k–404k vs receipts 317k–341k), so pricing the 1.25× limit
   made every quote ~40 % more expensive in gas — ≈ $0.30 a fill, 1.5 % of a $20
   ticket. The trade: a tx that burns past its estimate can lose at most
   `(G − P) × gasPrice`, cents on Rootstock; a gas-heavy maker token is still bounded
   by `MAX_ROUTE_GAS`;
9. **send** a legacy tx at the priced gas price with gas limit G = max(P, ⌈simulated ×
   1.25⌉) (headroom only, refused above `MAX_ROUTE_GAS`), after checking the shared gas
   budget against G × price. One route fill is reserved; a
   later tick reads the receipt (gas charged even on a revert; see *Gas policy* for
   reverts and timeouts).

At start-up it checks the solver against the config — wired to our `SETTLEMENT`, our EOA
is an operator, its `SANDBOX()` exists and is owned by it. (No router allowlist or
primed tokens to check any more.)

What the hot key can lose here: only RBTC for gas. The solver holds no inventory, and
every amount it moves is a delta of the current fill.

## Configuration

Common:

| Env | Default | Meaning |
|---|---|---|
| `PRIVATE_KEY` | — | the hot wallet / operator EOA (RBTC for gas; inventory for the inventory strategy) |
| `SETTLEMENT`, `PERMIT3`, `LENS` | — | core deployment |
| `ORDERBOOK_URL` | — | the worker book (`workers.dev` URL) or the app's `/api/book` |
| `RPC_URL_SECRET` | — | a keyed Rootstock RPC; wins over `RPC_URL` (on the Worker a secret, so the `RPC_URL` var line can stay) |
| `RPC_URL` | `https://public-node.rsk.co` | Rootstock RPC (fallback) |
| `CHAIN_ID` | `30` | the chain the RPC must report (Rootstock mainnet); Sushi quotes are requested for it |
| `DRY_RUN` | on | only `DRY_RUN=0` broadcasts |
| `INVENTORY_ENABLED` / `ROUTE_ENABLED` | `1` / `1` iff `AGGREGATOR_SOLVER` set | per-strategy switches |
| `POLL_MS`, `STATE_FILE` | `15000`, `.beta-filler-state.json` | CLI poll cadence (1 s while a tx is pending); budgets, the per-order backoff, the pending tx and the MoC op survive restarts here |
| `HOURLY_GAS_RBTC` | `0.002` | rolling one-hour RBTC gas cap, **both strategies together** (old name `ROUTE_HOURLY_GAS_RBTC` still read) |
| `MAX_GAS_PRICE_GWEI` | `0.1` | never send a fill above this gas price |
| `RECEIPT_TIMEOUT_MS` | `120000` | after this without a receipt, a sent tx's outflow / fill reservation is final (a late receipt still settles the gas) |
| `RESTING_RECHECK_SECONDS` | `300` | an order every strategy passed on, or one we just filled, is not re-quoted for this long unless the book's fillable for it changes (≤ 30 s for a time-varying price; `0` = off) |
| `EXPIRY_MARGIN_SECONDS` | `90` | orders expiring within this are skipped (a tx cannot land in time on ~30 s blocks) |

Every numeric knob fails closed: a non-integer, `NaN`, empty or non-positive value (where
a positive one is required) stops start-up instead of becoming `NaN`/`0`.

Route strategy:

| Env | Default | Meaning |
|---|---|---|
| `AGGREGATOR_SOLVER` | — | the deployed, operator-gated `AggregatorFillSolver` |
| `ROUTE_POOLS` | the app's 3 Rootstock Uniswap v3 pools | `;`-separated `tokenA/tokenB/fee` (fee in hundredths of a bip) |
| `ROUTE_PATHS` | `USDRIF>500>USDT0>3000>WRBTC` | `;`-separated multi-hop paths in swap order, usable both ways (`""` = none) |
| `ROUTE_SLIPPAGE_BPS` | `10` | haircut on the live quote in the gate (non-stable pairs). The quote is read on the simulated block and the plan's on-chain floor (`minOut` / `amountInMaximum`) bounds the output, so a price move before inclusion costs a revert's gas, never principal; 10 bps covers a ~30 s Rootstock block of BTC drift. Was 30 until 2026-10-07, which together with gas pushed the app's market fills to the floor |
| `ROUTE_STABLE_SLIPPAGE_BPS` | `5` | the haircut instead when both tokens are in `USD_TOKENS` (e.g. USDRIF/USDT0 on the 0.05 % pool). The quote is read on the simulated block and the plan's on-chain floor bounds the output, so a miss costs a revert's gas, never principal; a $1/$1 pool barely moves before inclusion. At 30 bps the app's 300 USDRIF market never cleared its then-50 bps floor (task 15) |
| `ROUTE_GAS_ESTIMATE` | `320000` | gas assumed by the profitability gate before the simulation, and the FLOOR of the re-price loop: the plan is priced at P = max(`ROUTE_GAS_ESTIMATE`, simulated) and sent with limit G = max(P, ⌈simulated × 1.25⌉) (`routeFiller.ts`, `GAS_LIMIT_PCT = 125` — headroom only, not priced since 2026-10-07). 320k sits above the net pull gas a fill pays (282.9k) and below the gross pull gas the node simulates (343.5k; execution 310.5k + 21k alone is 331.5k), so the gate never under-assumes a fill's real cost, and on today's sandboxed shapes the measured term wins (direct ⌈285.8k × 1.25⌉ ≈ 357k, pull ≈ 429k — one re-price round). Figures: `SandboxGasBench.test_sandbox_gas_*`, see *What the gas row measures* |
| `MAX_ROUTE_GAS` | `1200000` | refuse a route fill whose gas limit (simulated × 1.25) exceeds this. It bounds per-tx exposure, including the at-most `(limit − simulated) × gasPrice` a fill can lose when it burns past its estimate (the floor is priced at the simulated gas). A live Sushi route measured ~554k simulated (693k priced) — one operator-observed `eth_estimateGas` (gross), no repo test, not re-run |
| `ROUTE_TOKENS` | `WRBTC,USDT0,WETH,USDRIF` | comma-separated allowlist; both tokens of a route candidate must be in it |
| `MIN_PROFIT_RBTC` | `0` | profit required on top of gas, in RBTC. 0: the operator's infra is near-free, so a fill that covers its gas and haircut is worth taking |
| `RBTC_PRICE_USD`, `USD_TOKENS` | unset, `USDT0,USDRIF` | RBTC price for $1 tokens; the higher of it and the pool price is used (both strategies) |
| `ROUTE_PROFIT_RECIPIENT` | `0x0` (= the operator EOA) | `RoutePlan.profitRecipient`; point it at a treasury |
| `ROUTE_HOURLY_FILLS` | `60` | rolling one-hour cap on route fills (gas: `HOURLY_GAS_RBTC`) |
| `WRBTC`, `SWAP_ROUTER`, `QUOTER_V2` | Rootstock mainnet | overrides |
| `SUSHI_ENABLED` | `1` | the Sushi API route source (pull orders only) |
| `ROUTE_OKU_PULL` | `1` | whether local Oku routes compete on pull orders (`0` = Sushi-only pull fills; direct orders always use Oku) |
| `SUSHI_API_URL` | `https://api.sushi.com` | API base |
| `SUSHI_ROUTER` | `0xAC4c6e212A361c968F1725b4d055b47E63F80b75` | the pinned RedSnwapper; any other `tx.to` is refused |
| `SUSHI_TIMEOUT_MS` | `4000` | per-request timeout |
| `SUSHI_EXECUTORS` | empty (warned) | comma-separated snwap executor pin list; when set, any other executor is refused |
| `SUSHI_MAX_PER_SWEEP` | `10` | Sushi API calls per sweep over the book, at most |

Inventory strategy:

| Env | Default | Meaning |
|---|---|---|
| `BUY_USDRIF` / `SELL_USDRIF` | `1` / `0` | which side to fill |
| `MAX_BUY_PRICE` | `0.995` | USDT0 paid per USDRIF, max (must be < 1) |
| `MIN_EXIT_EDGE_BPS` | `30` | required margin of the live redeem+sell exit |
| `MIN_SELL_PRICE` | `1.003` | USDT0 received per USDRIF, min |
| `MAX_FILL_USDT0` / `MIN_FILL_USDT0` | `500` / `5` | per-order notional bounds |
| `HOURLY_USDT0` / `HOURLY_USDRIF` | `2000` / `2000` | rolling one-hour outflow caps |
| `USDRIF_RESERVE`, `REDEEM_MIN_USDRIF`, `REDEEM_SLIPPAGE_BPS` | `0`, `1000`, `50` | redemption; `REDEEM_MIN_USDRIF` is also the batch size the rebalance cost is amortised over |
| `INVENTORY_GAS_ESTIMATE` | `260000` | gas assumed for an inventory fill before estimation (re-checked at the real limit) |
| `REBALANCE_GAS` | `450000` | gas of the redeem + RIF sale a fill eventually causes, charged pro rata (fill ÷ `REDEEM_MIN_USDRIF`, capped at 1) plus the MoC exec fee |
| `INVENTORY_MIN_PROFIT_USDT0` | `0.02` | absolute profit floor per inventory fill, on top of gas |
| `RIF_SELL_MIN`, `RIF_SELL_SLIPPAGE_BPS`, `RIF_SELL_MAX_DISCOUNT_BPS` | `200`, `50`, `150` | RIF sale |
| `USDRIF`, `USDT0`, `RIF`, `MOC_CORE`, `MOC_QUEUE` | Rootstock mainnet | overrides |

## Commands

```sh
cd packages/beta-filler
pnpm status                          # balances, approvals, budgets, the pending tx, solver checks
pnpm start                           # DRY RUN: simulates and logs, broadcasts nothing
DRY_RUN=0 pnpm start                 # live (local runs; production runs the Worker)
pnpm exec tsx src/bin.ts fill-json order.json   # one {order, sig, fillAmount?} file, bypassing the book
pnpm exec tsx src/bin.ts redeem      # force a redemption now (inventory)
pnpm exec tsx src/bin.ts sell-rif    # force a RIF sale now (inventory)
pnpm exec tsx src/bin.ts settle      # resolve a leftover pending tx in STATE_FILE, send nothing
```

The one-shot commands (`fill-json`, `redeem`, `sell-rif`, `mint`) drive ticks themselves.
They first resolve any outstanding tx, send at most one tx at a time (an approval first,
if one is missing), and poll each receipt every second until it resolves.

**Never run the CLI live with the same key while the Worker runs.** Each host tracks only
its own outstanding tx. The pending-nonce check makes the second host refuse to send
while the first one's tx is in flight, but their budgets are separate.

## Beta deploy runbook (Rootstock, chain 30)

Signer: a Foundry keystore (`cast wallet import deployer --interactive`). Rootstock
mainnet verifies on Blockscout. Rootstock's block gas limit is **10M** and
`SettlementLens` costs ~7.3M to deploy, so pass `--gas-estimate-multiplier 110`
(forge's default 130% overshoots the block limit). Rootstock has no EIP-1559 fee market,
so send legacy transactions (`--legacy`).

```sh
export RPC=https://public-node.rsk.co
export DEPLOY_ARGS="--account deployer --sender 0x<deployer> --gas-estimate-multiplier 110 --legacy --slow"
export VERIFY_ARGS="--verify --verifier blockscout --verifier-url https://rootstock.blockscout.com/api/"
```

**1. Core** — Permit3 → Settlement (+ its SolverCallbackExecutor) → SettlementLens,
CREATE2 through the shared DeployFactory, `core-deploy` profile (via-IR, Cancun):

```sh
make predict-core RPC=$RPC                          # read-only: the addresses it will use
make deploy-core  RPC=$RPC CORE_SALT=0x… DEPLOY_ARGS="$DEPLOY_ARGS" VERIFY_ARGS="$VERIFY_ARGS"
```

Record `Permit3`, `Settlement`, `SettlementLens` and the deploy block.

**2. AggregatorFillSolver** — `solvers-deploy` profile (Cancun), plain CREATE, gated to
the bot's EOA. The constructor deploys the solver's `RouteSandbox`; there is no router
set, standing flag or prime list any more (BREAKING 2026-10: the script refuses
`ROUTERS`, `STANDING`, `PRIME_TOKENS`). `FLOOR_TOKENS` (optional) has the deployer send
the new solver 1 wei of each traded token — its balance floor, which pays on the pull
path (the deployer must hold 1 wei of each):

```sh
SETTLEMENT=0x<Settlement> \
OPERATORS=0x<filler EOA> \
FLOOR_TOKENS=0x542fDA317318eBF1d3DEAf76E0b632741A7e677d,0x779Ded0c9e1022225f8E0630b35a9b54bE713736,0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590,0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37 \
make deploy-aggregator-fill RPC=$RPC DEPLOY_ARGS="$DEPLOY_ARGS" VERIFY_ARGS="$VERIFY_ARGS"
# MAKER_SURPLUS_PPM / PROTOCOL_SURPLUS_PPM / PROTOCOL_RECIPIENT default to 0.
```

(The tokens are WRBTC, USDT0, WETH, USDRIF.) The script prints the solver and sandbox
addresses and reverts unless every immutable — Settlement, executor, gate, operators,
policy, and the sandbox's owner / Settlement / Permit3 / executor — reads back as
requested. Verify the sandbox on Blockscout too (it is a contract creation inside the
solver's constructor).

*Why no router set:* every route runs in the `RouteSandbox`, which is push-funded with
exactly the fill's input, approved by nobody (the solver included) and ends every call
empty, so its standing approvals to arbitrary targets grant nothing and a new venue (the
Sushi API's RedSnwapper, say) needs no redeploy. The solver never approves a router. The
remaining trust is in the route calldata: Oku routes are built locally by this bot (SDK
encoders); Sushi routes come from a third-party API and are fully decoded and validated
before use (above), on the pull path only, where a hostile route can at worst make the
fill revert. Cost: ~+11.5k gas per fill against the old per-fill-approval instance
(~+18k net against the old standing one; net tx gas, solver floor seeded, Rootstock
fork block 8,920,000, measured 2026-10-04 before tasks 06/08 with the pre-sandbox
contract compiled side by side — `SandboxGasBench`, not re-runnable today) — see
packages/solvers/README.md.

**3. Orderbook worker vars** (`packages/orderbook-worker/wrangler.toml` `[vars]`):

- `SETTLEMENT`, `PERMIT3`, `LENS` = step 1; **`START_BLOCK` = the Settlement deploy
  block (required)**;
- **`RPC_URL_SECRET` secret = a keyed Rootstock RPC that serves `eth_getLogs`
  (required)**: Rootstock's public node answers `eth_getLogs` with `-32601`, which
  freezes the fill index and on-chain cancels (the worker's `/health` then shows
  `logsUnsupported: true` and the filler alerts);
- `ALLOWED_TOKENS` — the default is now `USDRIF,USDT0,WRBTC,WETH` (it used to allow only
  USDRIF/USDT0, which refused every WRBTC / WETH route-market order);
- `REQUIRE_DELTA_VERIFY = false` — USDRIF/USDT0 orders are pull;
- `DEFAULT_FILLER` may stay zero (the beta orders carry no validators);
- `BINDING_KEY` secret, then `npx wrangler deploy` (see that package's README).

**4. App vars** (build time, `packages/app/README.md`):

```sh
VITE_ORDERBOOK_URL=/api/book
VITE_DEPLOYMENTS='{"30":{"settlement":"0x<Settlement>","permit3":"0x<Permit3>","lens":"0x<Lens>","solver":"0x<AggregatorFillSolver>","marketSolvers":{"rsk-30-usdrif-usd0":"pull"}}}'
```

`solver` = the AggregatorFillSolver: the WRBTC/USDT0 and WETH/WRBTC markets sign
delta-verify orders exclusive to it. `rsk-30-usdrif-usd0` stays `"pull"` for the inventory
strategy. Those orders are open to every filler. The soft window
(`pullExclusivity`, see the app README) is opt-in and off by default, because it
costs gas on every fill. Deploy the app only once step 5 runs live — a delta-verify order can be filled
by nobody else.

**5. Filler.** Production: deploy [`@1delta-x/filler-worker`](../filler-worker) in dry
run. Its README has the runbook: `wrangler secret put PRIVATE_KEY` / `ADMIN_TOKEN` /
`ALERT_WEBHOOK_URL`, the `[vars]` below, and the `ORDERBOOK` service binding. For a
local check, use the CLI env:

```sh
export PRIVATE_KEY=0x…              # the operator EOA from step 2; RBTC for gas (+ USDT0 inventory)
export SETTLEMENT=0x… PERMIT3=0x… LENS=0x…
export AGGREGATOR_SOLVER=0x…        # step 2
export ORDERBOOK_URL=https://orderbook-1delta-rsk.<account>.workers.dev
export ROUTE_PROFIT_RECIPIENT=0x…   # treasury (default: the operator EOA)
pnpm status                         # must show both strategies on and pass the solver checks
```

**6. Dry run → live.** Place a small order per market from the app. On the Worker,
`GET /status` (`logTail`, `recent.events`) should show `[dry-run] [route] would fill …`
(or `[inventory]` on the USDRIF market) with `simulation ok`; with the CLI,
`pnpm start` logs the same.

Then go live:

- **Worker:** `POST /dry-run {"on": false}`;
- **CLI:** `DRY_RUN=0 pnpm start`.

Watch the first live fills on the explorer, and `GET /status` or `pnpm status` for the
budgets.

## Fork end-to-end smoke (not in CI)

```sh
packages/beta-filler/e2e/fork-e2e.sh        # needs anvil/forge + network; ~2–3 min
```

It forks Rootstock mainnet with anvil, runs steps 1–2 of the runbook against the fork
(same make targets, anvil dev keys), funds test makers (RBTC → WRBTC + Permit3
approval), signs WRBTC → USDT0 orders priced off the live Oku pool, and feeds each to
`fill-json` in LIVE mode with only the route strategy on. `fill-json` sends the fill,
then polls its receipt until it resolves. It asserts: the **direct**
(delta-verify) and **pull** orders fill and each maker receives at least the owed USDT0,
an order priced at 100% of the quote is skipped as unprofitable, and a **Sushi-routed
pull** order (`ROUTE_OKU_PULL=0` for that case, so the live Sushi API calldata is what
runs against the fork) fills through the sandbox. The Sushi case needs
the fork to be recent (the API quotes live state); `SKIP_SUSHI=1` skips it. `FORK_URL`
and `PORT` override the defaults.

## Known limits (beta)

- `ORDERBOOK_URL` must serve the Worker book's JSON `GET /orders` (full signed orders).
  Through the app's `/api/book` proxy the filler is rate-limited per IP like any visitor;
  point it at the worker's `workers.dev` URL if that is ever too tight.
- Polling, not streaming: a new order is seen within `POLL_MS` (the Worker:
  `TICK_SECONDS`, round-robin, `MAX_ORDERS_PER_TICK` per tick).
- **One outstanding tx per key.** Throughput is at most about one fill per block. A tx
  stuck in the mempool (still known to the node) blocks every send until it mines or is
  replaced by hand (noticed at the next overdue check); one the node lost is
  re-broadcast verbatim.
- A resting order is re-quoted at most every `RESTING_RECHECK_SECONDS` (unless its
  book fillable changes): a market move that makes it profitable is noticed within
  that window, not within a tick.
- One host per key: the budgets live in that host's state store.
- Route: local quotes are Uniswap v3 (Oku) only; Sushi liquidity is reached through the
  Sushi API, and only for PULL orders (direct orders need an exact-output route to the
  maker, which the API does not offer). Gas for a Sushi-only pair is priced like any
  other (a WRBTC path or `RBTC_PRICE_USD`), else the order is skipped.
- Route: the route takes the whole fillable amount in one swap; there is no sizing
  against pool depth beyond the profitability gate. The size is the book's
  `fillableAmount`: the lens preview silently trims an oversized slice, but
  `executeFill` → `fillWithCallback` does not clamp (`OverFill`), so a competing
  partial fill between the book read and our simulation is a skip + backoff, and
  one between the simulation and inclusion burns the gas of a revert (open pull
  orders only; direct orders are exclusive to the solver).
- The route plan carries `minBumpBps` = the bump previewed at the send gas price; the
  solver forwards it to `fillWithCallback` (2026-10, tasks 06/08), so a tick that moved
  maker-ward between the preview and inclusion reverts `BumpTooLow` before anything
  moves — on both paths, the same on-chain floor `fillUpTo` gives the inventory path.
  Priority auctions (timing bit 103 / `priorityScale`), gas-bump orders (`gasBumpBps`)
  and custom decay curves are therefore ADMITTED on the route path now (they were
  refused while the floor was missing: a silent, band-bounded margin erosion on a
  direct BUY). The cost of the floor is a revert's gas when the tick does move.
- Direct path, SELL: since task 05 (2026-10-06, option 3) a direct SELL whose output
  leg is still DECAYING (`patchesLiveOutput` in `src/route.ts`: bit 104, SELL,
  `legsOut[0].end != 0` and below `start`, before `decayStart + decayDuration`; a
  block-clock order is assumed to still decay) sets `amountOutOffset` to the
  exact-output call's `amountOut` word (`exactOutputSingle` 132, `exactOutput`
  tuple + 64). The solver then runs the typed callback and writes the core's LIVE
  `outputAt(t_incl)` there: the route pays exactly what the core verifies and the
  decay since the preview stays on the solver as INPUT residue (our spread, like the
  rest of the unconsumed input). Before this the route paid the previewed owed and the decay —
  ≈ 0.25 % of notional per Rootstock block on the app's then-0.5 %-band market auctions (0.3 % since 2026-10-07, ≈ 0.15 % per block),
  more than the whole gas + min-profit margin — went to the maker. Costs and
  conservatism: the typed path's ~+5.9k execution gas (179,773 vs 173,864 in
  `AggregatorFillGasTest.test_gas_direct_seeded_liveAmountOut` / `test_gas_direct_seeded`)
  is added to the plan's gas estimate as `TYPED_CALLBACK_GAS` = 6,000 — and only paid when
  it pays for itself: the patch is used only if one 30 s block of the leg's decay, pro
  rata to this fill (`liveDecayPerBlock`), is worth more than 6k gas in the output token
  (2026-10-07; on the app's 0.3 % / 60 s market auctions that is tickets above ≈ $9,
  so small test tickets keep the untyped path). The profit gate
  and `amountInMaximum` are still sized on the PREVIEWED owed, so no decay is counted
  on (it is upside only). A direct BUY (fixed output — the rise is already measured
  on-chain), an order past its decay window, and every pull plan keep `NO_PATCH`:
  their live output equals the preview, so the typed gas would buy nothing. Sushi is
  pull-only and snwap is exact-input (its `amountOutMin` is a balance-rise floor, not
  the amount paid), so Sushi plans never patch.
- Inventory: the redemption leg carries RIF price risk for ~2.5 minutes, and a stolen
  hot key loses the whole wallet.
- No priority-fee bidding: Rootstock has no EIP-1559 tip market.

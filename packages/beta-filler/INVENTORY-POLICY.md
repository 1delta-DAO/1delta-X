# Inventory policy: fill strategies and target ratios (Rootstock beta)

One place for **what the filler fills, with what money, and what the operator wallet
should hold**. The numbers are the live configuration (`packages/filler-worker/wrangler.toml`,
2026-10-19). Change them there; this page explains them. The mechanics behind each rule
live in [README.md](README.md) and the source files named below.

## 1. Who holds what

| Holder | Address | Holds | Role |
| --- | --- | --- | --- |
| **Operator EOA** | `0xcafe…083a` | USD₮0, RIF, USDRIF (+ dust WRBTC), **RBTC for gas** | Sends every transaction. It is the inventory strategy's counterparty and runs the rebalancer. It pays the gas of every fill, route fills included. |
| **Solver v3** (`AggregatorFillSolver`) | `0x5987…6cD1` | Only the spread it keeps (retain mode) | Route fills with **zero inventory**: it receives the maker's input, routes it, pays the maker. It approves nothing. |
| Solver v2 (legacy) | `0x48db…32F1` | 1-wei balance floors | Fills only the open DIRECT orders that name it, until they expire. |

The solver never needs funding. All capital decisions on this page concern the **operator EOA**.

## 2. Fill strategies

For every order, the dispatcher tries **inventory first, route second** (`src/dispatch.ts`):
an inventory fill is cheaper (≈ 90–230k gas, no swap) whenever both qualify. Quotes
(`POST /quote`) price both, and the app signs the better one (`delivery: "auto"`).

### 2a. Route strategy: no capital (`src/routeFiller.ts`)

The solver fills from the maker's own input: it pulls the input, swaps it on a route, and
delivers the output.

| Route source | When | Notes |
| --- | --- | --- |
| Uniswap v3 / Sushi v3 pools (direct pool plans, up to 3 hops, mixed venues) | always | Pools are discovered from the Oku and Sushi indexers (TVL ≥ $1,000) and CREATE2-verified. |
| Sushi API | PULL orders | Validated, pinned executor. |
| Nordstern API | PULL orders | `toAmount` × (1 − 2 bps). Gas = API `gasEstimate` × 1.2 × **2.0** (`NORDSTERN_GAS_MULT_PCT`): the API's figure is not Rootstock's (a 3-hop route reported 367k and burned 1.05M). |
| Native RBTC delivery | DIRECT orders receiving RBTC | The solver unwraps the route's WRBTC and sends RBTC; Settlement verifies the receipt through `NativeBalance` (`0xA45e…854c`). |

Selection and gates:

- **Ranking:** routes are ranked by output net of each route's own gas.
- **Dropped routes:** an API route whose fill cannot fit `MAX_ROUTE_GAS` (**2,000,000**) is dropped before ranking.
- **Trial:** each viable route gets the whole trial, best first: simulate, re-price at the
  measured gas, check the gas cap, check profit at that gas. **Any** failure hands over to the
  next route.
- **Profit gate:** route output × (1 − haircut) ≥ owed + gas + `MIN_PROFIT_RBTC` (0). The haircut is 10 bps, 5 bps between $1 tokens, and 0 for an order signed from our own quote.
- **Spread:** the spread stays on the solver (retain mode). See §6 for sweeping it.

### 2b. Inventory strategy: the operator's capital (`src/filler.ts`, `src/policy.ts`)

The operator EOA fills PULL orders directly (`fillUpTo`) from its own balances.

| Direction | Maker does | Wallet pays → receives | Priced at | Status |
| --- | --- | --- | --- | --- |
| `buyUsdrif` | sells USDRIF | USD₮0 → USDRIF | ≤ `MAX_BUY_PRICE` **0.995**, and the MoC exit edge ≥ 30 bps | **on** |
| `sellUsdrif` | buys USDRIF | USDRIF → USD₮0 | ≥ `MIN_SELL_PRICE` 1.003 | off |
| `sellRif` (RIF rail) | buys RIF with USD₮0 | RIF → USD₮0 | MoC replacement cost: USD₮0 → USDRIF (0.05 % pool) → `redeemTP`, + 0.2 % MoC fee + **20 bps** haircut | **on** |
| `sellRifUsdrif` | buys RIF with USDRIF | RIF → USDRIF | one `redeemTP` of the USDRIF received (no pool leg), fee + haircut | **on** |
| `buyRif` | sells RIF for USD₮0 | USD₮0 → RIF | replacement cost while RIF ≤ target; MoC exit (`mintTP` → pool) above it; refused past the high mark | **on** |

Every inventory fill also has to pass:
- **Size:** `MIN_FILL_USDT0` **5** to `MAX_FILL_USDT0` **500** USD₮0 per fill.
- **Profit:** edge ≥ gas + its share of the rebalance it causes + `INVENTORY_MIN_PROFIT_USDT0` 0.02.
- **Money on Chain guard:** for every RIF-delivering direction, MoC must not be paused or liquidated and its reserve must exceed 10× the fill.
- **What it cannot fill:** DIRECT orders (no callback) and orders funded only by an ERC-2612 permit. Those belong to the route.

## 3. Target ratios: the operator wallet

The wallet's value counts USD₮0, USDRIF at $1 and RIF at the MoC oracle. RBTC is gas and
counted separately.

| Asset | Target | Band / limits | Why |
| --- | --- | --- | --- |
| **RIF** | **20 %** of value | refill below **15 %**, drain above **25 %** | RIF is volatile: the rail needs a float, but only a minority. |
| **USD₮0** | the rest (~80 %) | never spend below **100** USD₮0 (`USDT0_RESERVE`) | Pays buys and refills; the reserve keeps the `buyUsdrif` side alive. |
| **USDRIF** | ≈ 0 | held until **100** (`RAIL_USDRIF_BATCH`) or RIF < 15 %, then redeemed (below target) or swapped to USD₮0 (above) | A MoC operation costs ≈ $1.5–2.4 (exec fee 8.9e12 wei + gas): batch it. |
| **RBTC (gas)** | **≥ 0.002 RBTC** | alert below **0.001** (`ALERT_MIN_RBTC`) | Route fills cost 6–9 µRBTC, heavy API routes ~26 µRBTC. 0.002 ≈ 100–250 fills ≈ the hourly gas cap. |
| WRBTC | 0 | n/a | Only dust from unwraps. |

**Sizing.** At today's ~$500 the rail is uneconomic. A refill moves ~$25 (5 % of the
wallet) and costs ≈ $2, so a rail quote rarely beats the pools. The rail wins on tickets
from ~$1.5–2k up, where pool slippage grows. It pays off when the 20 % RIF float is
≥ ~$1k, which means a wallet of **≈ $5k**.

## 4. Rebalancing (`src/rebalance.ts`, `railStep`)

The rebalancer runs every 30 s (`REBALANCE_SECONDS`), only when no transaction is
outstanding, and sends one transaction per step, in this order:

1. **Hold** while a MoC redeem or mint is in its queue (~2.5 min).
2. **USDRIF on hand** (≥ the 100 batch, or at once below 15 %): below target, `redeemTP` the
   gap to 20 % (→ RIF); at or above target, swap it to USD₮0 on the 0.05 % pool.
3. **RIF < 15 %:** swap USD₮0 → USDRIF for the gap to 20 %; step 2 redeems it next.
4. **RIF > 25 %:** `mintTP` the excess RIF into USDRIF; step 2 swaps it to USD₮0 next.

Guards on every step:
- nothing smaller than 5 USD₮0 is moved;
- a pool more than **50 bps** off $1 per USDRIF is refused (peg guard);
- swap slippage floor **30 bps**, redeem/mint slippage **50 bps**;
- **RIF is never sold automatically.** The 2026-10-14 incident: the old rule sold a fresh 1,251 RIF float within a minute. `RIF_SELL_MIN` is effectively off.

Admin: `scripts/admin.sh rebalance-rif` moves the band to target now.

## 5. Risk limits

| Limit | Value | Scope |
| --- | --- | --- |
| Hourly outflow caps | `HOURLY_USDT0` 2,000 · `HOURLY_USDRIF` 2,000 · `HOURLY_RIF` 10,000 | Inventory strategy. The blast radius per hour. |
| Hourly gas | `HOURLY_GAS_RBTC` **0.002** | All strategies + the rebalancer. |
| Route fills per hour | `ROUTE_HOURLY_FILLS` 60 | Route. |
| Gas price ceiling | `MAX_GAS_PRICE_GWEI` 0.1 (sent at block minimum × 1.03) | All. |
| Per-fill gas limit | `MAX_ROUTE_GAS` **2,000,000** (Rootstock block 10M) | Route. A heavy route is allowed exactly when its quote charged the gas. |
| One outstanding transaction | always | All. A revert puts the order under backoff. |

**Approvals** (operator EOA, `src/chain.ts` `maxApprovalSpender`):
- **Maximum, once:** to **Settlement** and **SwapRouter02**, both immutable, and to **Money on Chain's core**, which is an upgradeable proxy the operator trusts. Each pulls only from its caller, inside transactions the EOA sends.
- **Everything else:** refused an unlimited approval.

## 6. The solver's retained spread

Retain mode leaves each fill's spread on solver v3, in whatever token the fill produced
(2026-10-19: ≈ $4.85 across USD₮0, USDRIF, RIF, WRBTC, USDC.e). Sweep it to the operator EOA
when it is worth the gas, for example monthly or above ~$25. Leave **1 wei of each token**:
the balance floor keeps the storage slot warm, which saves gas on the next fill.

Sweep every token in one transaction from the operator (`keep = 1` leaves the floor):
`e2e/sweep-solver.sh`, which calls `AggregatorFillSolver.sweepAll(tokens, to, 1)`.

## 7. Quoting (`src/quote.ts`)

```
amountOut = gross − ⌈gas × (1 + 3 %)⌉
```

- **Gas** is the fill's estimate × the learned receipt ratio (default 0.88) × the send gas price.
  - Estimates are learned per fill shape from our own receipts.
  - API routes are learned under their own shape (`<solver>#nordstern` / `#sushi`), so a heavy route never inflates pool-route quotes.
  - Before any receipts, the defaults apply: `QUOTE_GAS_ESTIMATE_DIRECT` 300k / `_PULL` 320k, or an API route's corrected own gas + 200k for the fill around it.
- **Lifetime:** a quote is valid 30 s. The app signs a short Dutch order from the quote down to the maker's slippage floor.
- **Response:** each quote names its route, `route.gas` and `route.estimate`.

## 8. Operator checklist

- **Daily:** `scripts/admin.sh status`. Check `rifRail.nowBps` (15–25 %), `balances.RBTC` (≥ 0.001), `lastError`, `recent.reverts`.
- **Top up RBTC** below 0.002. As of 2026-10-19 the wallet holds 0.00026, **below the alert line**.
- **Before funding a token** to the EOA: check every automatic rule that moves that token (§4).
- **Before resizing the wallet:** the RIF target is a share of value, so funding USD₮0 alone moves RIF below 15 % and triggers a refill swap at the next rebalance. Fund both, or expect it.

## 9. Decisions (newest first)

| Date | Decision |
| --- | --- |
| 2026-10-19 | Fills fall through to the next route on any failure. Heavy API routes allowed (`MAX_ROUTE_GAS` 2M) when quoted at their corrected gas (Nordstern × 2.0). |
| 2026-10-19 | Maximum approvals to Settlement, SwapRouter02 and MoC's core. Money on Chain is treated as trusted. |
| 2026-10-14 | USDRIF → RIF through one `redeemTP` (`sellRifUsdrif`). USDRIF collected in batches of 100. |
| 2026-10-14 | RIF kept as a 15–25 % (target 20 %) **share** of the wallet, not a fixed float. Volatility. |
| 2026-10-14 | RIF rail on (`SELL_RIF` / `BUY_RIF`). RIF never auto-sold, after the incident. |
| 2026-10-12 | Retain mode: the spread stays on the solver; sweep in batches. |

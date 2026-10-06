# @1delta-x/rif-filler — minimal beta filler (EOA)

The Rootstock beta filler for the **USDRIF/USDT0** market (`rsk-30-usdrif-usd0`). It
runs from a plain **EOA** instead of `UsdrifInventorySolver`:

1. It polls the orderbook — the Cloudflare Worker book (`@1delta-x/orderbook-worker`) —
   as JSON (`GET /orders?fillableOnly=true`, paged).
2. It fills plain one-in/one-out orders with `Settlement.fillUpTo`, out of the wallet's
   own inventory.
3. It turns the USDRIF it receives back into USDT0. First it redeems USDRIF → RIF at the
   MoC oracle price (asynchronously: about 2.5 minutes through the MoC queue). Then it
   sells RIF → USDT0 on the Uniswap v3 RIF/USDT0 pool.

## Why an EOA works, and what it costs

| | `UsdrifInventorySolver` (contract) | this filler (EOA) |
|---|---|---|
| Fill | `executeFill` → `fillWithCallback` | `fillUpTo` directly, `msg.sender` = filler |
| Delta-verify orders (timing bit 104) | yes, via the callback | **no**: they need a callback, so the app must sign **pull** orders for this market |
| MoC `recipient == msg.sender` | satisfied (the contract redeems to itself) | satisfied (the EOA redeems to itself) |
| Fill + redeem atomic | yes (`executeFillAndRedeem`) | no: USDRIF sits in the wallet for a few minutes |
| A stolen operator key loses | at most the on-chain hourly budget | **everything in the wallet** |
| Price guards | on-chain (`minRate`, `maxSpent`) | off-chain policy + `minBumpBps` floor + simulation |

The security model: **the hot wallet's balance is the blast radius.** Fund it with a
small working inventory and top it up from a cold wallet or Safe. The hourly budgets
below limit how fast even a stream of bad orders can drain it.

Only the filler's own transactions ever spend its Settlement approval: core pulls an
order's output legs only from the address that called the fill. So the standing
(bounded) approval is safe to leave in place.

## Order policy (what it fills)

It accepts only the shape the beta app signs:
- one input leg and one output leg, paid to the maker;
- no items, validators, invariants, fill module or pricing module;
- not delta-verify, not proportional, not a permit-batch or sigless announce;
- an `exclusiveFiller` of zero or of this wallet.

Anything else is skipped and logged once.

Intake is a candidate list, not a verdict. Each order from `GET /orders` is parsed
strictly (the SDK's `orderFromJson`) and must hash to the `orderHash` the book gave;
orders the book itself reports as not `ok` (or failing validators) are dropped. The
filler does not re-run the book's Layer 1/2 verification: every order is previewed on
the lens and simulated from our address before anything is sent (steps 2 and 4 below).
There is no `@1delta-x/orderbook` (protobuf) dependency any more.

For each order it:
1. **Sizes** the fill to the smallest of: `MAX_FILL_USDT0` of notional, the wallet
   balance, and the hourly budget left.
2. **Previews** the fill on `SettlementLens.previewFill` as this filler.
3. **Prices** it.
   - Buy side (a maker sells USDRIF, we pay USDT0): the price must be ≤
     `MAX_BUY_PRICE`, *and* the live exit must beat the payment by
     `MIN_EXIT_EDGE_BPS`. The live exit is the received USDRIF redeemed at `getPACtp`,
     less the 0.2% MoC fee, then quoted RIF→USDT0 on QuoterV2.
   - Sell side (off by default): the price must be ≥ `MIN_SELL_PRICE`.
4. **Simulates** the exact `fillUpTo` calldata from the filler address. It uses the
   lens's `previewBump` as `minBumpBps`, so a maker-ward price move before inclusion
   reverts the fill instead of costing us.
5. **Broadcasts**, waits for the receipt, and charges the hourly budget. The budget is
   persisted in `STATE_FILE`.

## Rebalancing

- **Redeem:** USDRIF above `USDRIF_RESERVE` (and at least `REDEEM_MIN_USDRIF`) is
  redeemed with `redeemTP`. It uses vendor `0x0`, `qACmin` = oracle RIF − 0.2% −
  `REDEEM_SLIPPAGE_BPS`, and pays the exec fee in RBTC. Only one redemption is in
  flight at a time. A failed op is refunded by MoC, and the next tick retries it.
- **Sell RIF:** a RIF balance ≥ `RIF_SELL_MIN` is sold on SwapRouter02 with
  `amountOutMinimum` = quote − `RIF_SELL_SLIPPAGE_BPS`. It refuses to sell when the pool
  quote is more than `RIF_SELL_MAX_DISCOUNT_BPS` below the MoC oracle value.
- **Mint** (sell-side inventory, manual): `pnpm mint 250` mints USDRIF from RIF already in
  the wallet.

## Run

```sh
cd packages/rif-filler
export PRIVATE_KEY=0x…            # hot wallet; holds RBTC for gas + a small USDT0 inventory
export SETTLEMENT=0x… PERMIT3=0x… LENS=0x…
export ORDERBOOK_URL=https://…    # the orderbook worker (workers.dev URL), or the app's /api/book proxy
pnpm status                       # balances, approvals, budget left
pnpm start                        # DRY RUN: simulates and logs, broadcasts nothing
DRY_RUN=0 pnpm start              # live
pnpm exec tsx src/bin.ts redeem   # force a redemption now
pnpm exec tsx src/bin.ts sell-rif # force a RIF sale now
```

| Env | Default | Meaning |
|---|---|---|
| `RPC_URL` | `https://public-node.rsk.co` | Rootstock RPC |
| `DRY_RUN` | on | only `DRY_RUN=0` broadcasts |
| `BUY_USDRIF` / `SELL_USDRIF` | `1` / `0` | which side to fill |
| `MAX_BUY_PRICE` | `0.995` | USDT0 paid per USDRIF, max (must be < 1) |
| `MIN_EXIT_EDGE_BPS` | `30` | required margin of the live redeem+sell exit |
| `MIN_SELL_PRICE` | `1.003` | USDT0 received per USDRIF, min |
| `MAX_FILL_USDT0` / `MIN_FILL_USDT0` | `500` / `5` | per-order notional bounds |
| `HOURLY_USDT0` / `HOURLY_USDRIF` | `2000` / `2000` | rolling one-hour outflow caps |
| `USDRIF_RESERVE`, `REDEEM_MIN_USDRIF`, `REDEEM_SLIPPAGE_BPS` | `0`, `50`, `50` | redemption |
| `RIF_SELL_MIN`, `RIF_SELL_SLIPPAGE_BPS`, `RIF_SELL_MAX_DISCOUNT_BPS` | `200`, `50`, `150` | RIF sale |
| `POLL_MS`, `STATE_FILE` | `15000`, `.rif-filler-state.json` | book poll + rebalance cadence, budget persistence |

Token, MoC and Uniswap addresses default to Rootstock mainnet (see `src/config.ts`); each
can be overridden (`USDRIF`, `USDT0`, `RIF`, `MOC_CORE`, `MOC_QUEUE`, `SWAP_ROUTER`,
`QUOTER_V2`).

## App configuration for this market

The app must sign **plain pull-delivery** orders on `rsk-30-usdrif-usd0`. With the
default named-solver setup it signs delta-verify orders, which an EOA cannot fill. Set
the market to `"pull"` in `VITE_DEPLOYMENTS`, and point the app at the orderbook with
`VITE_ORDERBOOK_URL` (see `packages/app/README.md`).

## Known limits (beta)

- `ORDERBOOK_URL` must serve the Worker book's JSON `GET /orders` (full signed orders).
  The Node `orderbook-server` serves only summaries on its JSON listing, so every order
  from it would be skipped. Through the app's `/api/book` proxy the filler is
  rate-limited per IP like any visitor (a 500-order page costs 2 tokens of 120); point
  it at the worker's own `workers.dev` URL if that is ever too tight.
- Polling, not streaming: a new order is seen within `POLL_MS`.

- The redemption leg carries RIF price risk for about 2.5 minutes. USDRIF itself sits in
  the wallet between the fill and the redeem.
- One process, one wallet, fills serialised. There is no priority-fee bidding, which is
  irrelevant on Rootstock: there is no EIP-1559 tip market.
- The hourly budget is per process (`STATE_FILE`). Do not run two instances on one key.

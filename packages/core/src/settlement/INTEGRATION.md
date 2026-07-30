# Filling orders from a DEX aggregator

How a router/aggregator integrates a **single plain limit order** as one hop of
a route — the minimal adapter, the accounting contract, and the sharp edges.
"Plain" means: no items, no fill module, no takerData-requiring validators —
the shape the orderbook serves to aggregators by default.

## TL;DR adapter

```solidity
// once per token the router will deliver:
IERC20(tokenToPay).approve(SETTLEMENT, type(uint256).max); // plain approve works

// per fill:
(uint256 delta, uint256[] memory received, uint256[] memory paid) =
    Settlement(SETTLEMENT).fillUpTo(order, sig, fillAmount, recipient, "");
```

* `fillUpTo` **clamps to the order's remaining size** instead of reverting
  `OverFill` when a competing fill landed first — the race a shared orderbook
  makes routine. A dead order (cancelled / fully filled / expired) still
  reverts loudly.
* `received[i]` — what the filler was paid per `order.legsIn[i]` (exact, even
  for tick-priced BUY receipts; no balance snapshots needed).
* `paid[j]` — what the filler delivered per `order.legsOut[j]`.
* `recipient` redirects `received` (e.g. straight to the user on a last hop);
  `address(0)` = `msg.sender`. Destination only — exclusivity, validators, and
  the output pulls all key on `msg.sender`.
* The strict entries (`fill`, `batchFill`, …) are unchanged — fill-or-kill
  semantics with the classic returns.

## Which side is which

The order is written from the **maker's** frame; the filler is the mirror:

| | maker | filler (you) |
|---|---|---|
| `legsIn` | gives | **receives** (`received[]`) |
| `legsOut` | receives | **delivers** (`paid[]`, approve for these) |

`fillAmount` is denominated in the **anchor**: `legsIn[0]` for a SELL,
`legsOut[0]` for a BUY. Consequences for a router:

* **BUY order → exact-input for you.** `fillAmount` = what you deliver on
  `legsOut[0]`. Your receipt rises with the auction tick — read it from
  `received`, never assume it.
* **SELL order → exact-output for you.** `fillAmount` = what you receive on the
  anchor leg (so `received[0] == delta` exactly for the fixed leg). What you
  pay decays with the tick — the returned `paid` is authoritative.
* Converting a spend budget into `fillAmount`: `fillAmountFromBudget` in
  `@1delta-x/sdk` (side-aware), or quote on-chain (below).

**Price motion is always in the filler's favor between quote and execution**:
SELL outputs decay down, BUY inputs rise, and the gas bump moves the same way.
A quote at block N never executes worse at N+k — the only race risk is *size*,
which the clamp absorbs and your own min-return check prices.

## Quoting

* **On-chain / eth_call:** `SettlementLens.previewFill(order, fillAmount,
  filler, takerData)` returns the same `(delta, received, paid)` the fill
  would settle **in that block** — same clamp, same exclusivity gate, same
  per-leg math. Pair with `getOrderRelevantState` for lifecycle (expiry,
  nonce, signature, validator pass, maker funding capacity).
* **Off-chain:** `previewFillLocal` in `@1delta-x/sdk` mirrors the identical
  math from a timestamp + basefee.
* **HTTP:** the orderbook server's `GET /quote?hash=…&fillAmount=…&filler=…`
  returns the previewed amounts plus ready-to-send `fillUpTo` calldata.

## Funds handling rules

* **Approvals:** a plain ERC20 approval to the Settlement works — the transfer
  layer probes Permit3 first and falls back to `transferFrom`
  (`Permit3TransferLib`). The failed probe costs a few hundred gas per output
  leg; a filler that wants it gone can instead approve via Permit3
  (token → Permit3, then a Permit3 allowance to the Settlement as spender).
* **No pre-funding, no deposits, no callbacks required.** Outputs are pulled
  from the filler during the call; inputs are pushed to `recipient` in the
  same call. Settlement never retains balances (surplus goes to the maker).
* **Native ETH:** filler side is WETH-only — wrap at the edge, as with every
  limit-order venue.
* **Zero-inventory fills:** `fillWithCallback` with `CallbackMode.PostInputs`
  pays your inputs first, lets a callback convert them, then pulls the
  outputs — for executor-style fillers (no clamp variant yet; ask if needed).

## Sharp edges

* `minFillAnchor` is a maker-signed anti-dust floor and gates the **clamped**
  delta: if a race leaves `remaining < minFillAnchor` the fill reverts
  (`FillTooSmall`). Skip such orders — the lens reports remaining size.
* Exclusivity: inside the window, only `exclusiveFiller` fills for free.
  A non-zero `exclusivityOverrideBps` lets outsiders fill at that many bps of
  price improvement to the maker — priced into `previewFill` automatically.
  Hard exclusivity (`overrideBps == 0`) reverts (and previews as) `NotExclusiveFiller`.
* Repeated small fills round per fill (maker-favoring ceil on SELL outputs):
  up to 1 wei per fill vs. one large fill. Don't assume exact linearity.
* Order-shape filters for aggregator ingestion: `items.length == 0`,
  `fillModule == address(0)`, no validators you can't satisfy, and
  `lens.validateOrder(order)` returns ok.

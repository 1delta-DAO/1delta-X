# Filling orders from a DEX aggregator

How a router/aggregator integrates a **single plain limit order** as one hop of
a route — the minimal adapter, the accounting contract, and the sharp edges.
"Plain" means: no items, no fill module, no takerData-requiring validators —
the shape the orderbook serves to aggregators by default.

## TL;DR adapter

```solidity
// once per token the router will deliver — prefer an approval no larger than the
// budget you route through this venue (a standing max is a standing exposure):
IERC20(tokenToPay).approve(SETTLEMENT, budget); // plain approve works

// per fill:
(uint256 delta, uint256[] memory received, uint256[] memory paid) =
    Settlement(SETTLEMENT).fillUpTo(order, sig, fillAmount, recipient, minBumpBps, "");
```

* `fillUpTo` **clamps to the order's remaining size** instead of reverting
  `OverFill` when a competing fill landed first — the race a shared orderbook
  makes routine. A dead order (cancelled / fully filled / expired) still
  reverts loudly. Two exceptions: a fill-module order passes through
  unclamped (the module sizes it, and since 2026-09-30 may never size it
  ABOVE your request), and a **Proportional** (balance-relative) SELL anchor is
  never trimmed down — an oversized request reverts `OverFill`, because a
  proportional fill is whole and trimming to a balance that shrank would charge
  you the full output for less.
* `type(uint256).max` as `fillAmount` means "whatever remains" on **every**
  fill entry (`fill`, `fillUpTo`, `fillWithCallback`, `fillWithPermit`,
  `batchFill`, `fillWithPermitTake`, `matchSettle`) — resolved once by the core,
  and a fill module receives the remaining amount, never `max`. On a Proportional
  order it accepts ANY size up to the cap, so it moves the maker's
  balance-shrink risk onto whoever pays the outputs: pass it only if you fund
  the output from the input you measured arriving (a routed swap). An inventory
  filler must pass the exact size it quoted.
* `received[i]` — what the filler was paid per `order.legsIn[i]` (exact, even
  for tick-priced BUY receipts; no balance snapshots needed).
* `paid[j]` — what the filler delivered per `order.legsOut[j]`.
* `recipient` redirects `received` (e.g. straight to the user on a last hop);
  `address(0)` = `msg.sender`. Destination only — exclusivity, validators, and
  the output pulls all key on `msg.sender`.
* `minBumpBps` — the filler's **price floor** on the resolved decay bump; `0` =
  off. Pass the bump your quote priced at and the fill reverts `BumpTooLow`
  instead of executing below it. One scalar guards every leg at once, because
  every leg price is monotone in the shared bump. See "Price motion" below for
  when it matters. **Do pass it** unless the order is all-fixed.
* The same floor is on `fillWithPermit(order, batch, sig, fillAmount,
  minBumpBps, takerData)` (the ONLY entry that can perform a permit-witness
  order's first fill), `fillWithPermitTake(…, fillAmount, minBumpBps)` and the
  per-order `batchFill(…, revertIfIncomplete, minBumpBps[], takerDatas[])`
  (a floor miss skips that order). Plain `fill` has none — use `fillUpTo` for a
  floored single fill. (Before 2026-09-30 only `fillUpTo` had a floor.)

## Which side is which

The order is written from the **maker's** frame; the filler is the mirror:

| | maker | filler (you) |
|---|---|---|
| `legsIn` | gives | **receives** (`received[]`) |
| `legsOut` | receives | **delivers** (`paid[]`, approve for these) |

`fillAmount` is denominated in the order's **DENOMINATOR**: `fillTotal` when the
order sets one (a fill-module order — e.g. `FullFillModule`, `TwapFillModule`),
else the anchor — `legsIn[0]` for a SELL, `legsOut[0]` for a BUY. The two
statements below hold only when `fillTotal == 0` (2026-09-30 PRICE-1.v2).
Consequences for a router:

* **BUY order → exact-input for you.** `fillAmount` = what you deliver on
  `legsOut[0]`. Your receipt rises with the auction tick — read it from
  `received`, never assume it.
* **SELL order → exact-output for you.** `fillAmount` = what you receive on the
  anchor leg (so `received[0] == delta` exactly for the fixed leg). What you
  pay decays with the tick — the returned `paid` is authoritative.
* Converting a spend budget into `fillAmount`: `fillAmountFromBudget(order,
  budget, now, { filler, baseFee?, priorityFee?, remaining? / prevFilled? })` in
  `@1delta-x/sdk` (side-aware; the `FillerContext` object replaced the positional
  arguments on 2026-09-30, and the soft-exclusivity override is now derived from
  `filler`, so an outsider inside a soft window pays the override), or quote
  on-chain (below).

**Price motion is USUALLY in the filler's favor between quote and execution**
on a plain, monotonically rising clock curve: SELL outputs decay down, BUY
inputs rise. It is not a rule. These move the tick *against* you after the
quote, and `minBumpBps` covers all of them (it reads the bump the fill
actually priced at):

* an order with an **external price module** (`order.pricingModule != 0`) —
  e.g. oracle-pegged, or maker-controlled code that can answer an `eth_call`
  differently from the real call — reprices inside the signed band in either
  direction;
* a **falling basefee** shrinks the gas bump on orders that use one;
* a **priority-auction** order: the bid is `tx.gasprice − basefee − baseline`,
  so a basefee drop before inclusion widens your bid and moves the price
  maker-ward (legacy / fixed gas price especially);
* a **descending segment** of the signed `curve` — the piecewise curve may
  fall, and a falling bump moves every leg maker-ward;
* a module keyed on the filler or on state the maker can flip;
* the **soft-exclusivity lift**: an outsider inside a live soft window pays the
  override bps on the maker's legs. It is identity-dependent (it depends on who
  sends the fill, not on the bump) and is **not** covered by `minBumpBps` — quote
  as the address that will actually fill;
* a **priority-bid quote**: on a priority order your own bid IS the price, so a
  quote made at one gas price does not hold at another.

Quote the bump alongside the amounts (the lens/preview exposes it) and pass it
as the floor; the fill then executes at your quoted price or better, or
reverts `BumpTooLow`.

## Quoting

* **On-chain / eth_call:** `SettlementLens.previewFill(order, fillAmount,
  filler, takerData)` returns the same `(delta, received, paid)` the fill
  would settle **in that block** — same clamp, same exclusivity gate, same
  per-leg math. Pair with `getOrderRelevantState` for lifecycle (expiry,
  nonce, signature, validator pass, maker funding capacity), and with
  `previewBump(order, filler, takerData)` for the `minBumpBps` floor — the
  resolved decay bump this quote priced at, accepted verbatim by a fill in the
  same block. (Priority-auction orders derive the bump from your own gas
  price — quote with the gas price you will send, and DO pass the floor: a
  basefee drop before inclusion moves the bid against you.)
* **Off-chain:** `previewFillLocal(order, fillAmount, prevFilled, now, { filler,
  baseFee?, priorityFee?, … })` in `@1delta-x/sdk` mirrors the identical math,
  including the soft-exclusivity override for `filler`. For a
  **priority-auction** order pass the `priorityFee` you will bid — the SDK throws
  `PricingNeedsContext` without it, because a zero-bid quote prices at the floor
  and would misstate both the delivery and a budget-derived `fillAmount`. A
  `pricingModule` order can't be mirrored locally — quote it via
  `SettlementLens.previewFill`.
* **HTTP:** the orderbook server's `GET /quote?hash=…&fillAmount=…&filler=…[&gasPrice=…]`
  returns the previewed amounts plus ready-to-send `fillUpTo` calldata whose
  `minBumpBps` is the previewed bump and whose `fillAmount` is the resolved delta
  (never the sentinel). `gasPrice` is REQUIRED for priority-auction orders (400
  without it) and is the gas price the quote assumes (2026-09-30 PERIPH-1.v1).
  `fillUpTo` does not trim a Proportional request, so a Proportional quote is valid
  only at exactly that size.

## Funds handling rules

* **Approvals:** a plain ERC20 approval to the Settlement works — the transfer
  layer (`Base._pullViaPermit3`) probes Permit3 first and falls back to
  `transferFrom`. The failed probe is NOT cheap: a reverting Permit3 call plus a
  strict-mode read, measured at roughly 8–9k gas per fill (the saving the
  `*Direct` callback modes exist for — see `CallbackMode`). `fillUpTo` has no
  direct variant, so a high-volume filler should approve via Permit3 instead
  (token → Permit3, then a Permit3 allowance to the Settlement as spender).
* **No pre-funding, no deposits, no callbacks required.** Outputs are pulled
  from the filler during the call; inputs are pushed to `recipient` in the
  same call. Settlement never retains balances (surplus goes to the maker).
* **Native ETH:** filler side is WETH-only — wrap at the edge, as with every
  limit-order venue.
* **Zero-inventory fills:** `fillWithCallback` with `CallbackMode.PostInputs`
  pays your inputs first, lets a callback convert them, then pulls the
  outputs — for executor-style fillers. It has no clamp, but it honours the
  `type(uint256).max` "whatever remains" sentinel (see the TL;DR) and gives your
  callback the real amounts (`*Typed` modes) to bound against your quote.
  ⚠ Two things to get right: (1) the callback runs through the
  `SolverCallbackExecutor`, which ANYONE can drive (an empty `matchSettle`, any
  `fillWithCallback`) — `msg.sender == EXECUTOR` authenticates nothing, so a
  callback that releases funds must also check a flag your own entrypoint armed,
  and never grant the executor anything; (2) in `PostInputs` the maker's token
  code runs before AND after your callback, so a hostile or hook-bearing token
  can sandwich your route inside the transaction — vet tokens and bound the
  route at the quote, not at break-even.
  `PostInputs` is item-free. An ITEM-bearing order can still be filled with zero
  inventory through a one-order `matchSettle` plan (TAKE items → `PULL` →
  `PRESEND` → your `CALL` → `DELIVER` → MAKE items) — the shape
  `AggregatorFillSolver.executeItemFill` builds (packages/solvers; audit
  2026-09-30 AGG-6). A PermitBatchWitness order's FIRST fill has no callback
  entry at all: it needs up-front capital, e.g. a flash loan around
  `fillWithPermit` (the flash solvers' `PERMIT_ENVELOPE`).
* **Permit-witness orders after the permit deadline:** once a gasless order has
  been partly filled, `fillWithPermit` keeps working with the same stored
  calldata after `batch.deadline` (the spent permit is a verified no-op) until
  the order's own expiry.

## Sharp edges

* `minFillAnchor` is a maker-signed anti-dust floor and gates the **clamped**
  delta: if a race leaves `remaining < minFillAnchor` the fill reverts
  (`FillTooSmall`). Skip such orders — the lens reports remaining size.
* Exclusivity: inside the window, only `exclusiveFiller` fills for free.
  A non-zero override bps (in `params`) lets outsiders fill at that many bps of
  price improvement to the maker — priced into `previewFill` automatically.
  Hard exclusivity (`overrideBps == 0`) reverts (and previews as) `NotExclusiveFiller`.
  So does a soft window where no leg can carry the premium — no BUY input, no
  auctioned non-proportional SELL input, no SELL output to the maker (e.g. a fixed
  input with a third-party output).
* Repeated small fills round per fill (maker-favoring ceil on SELL outputs):
  up to 1 wei per fill vs. one large fill. Don't assume exact linearity.
* Order-shape filters for aggregator ingestion (single-order `PostInputs`
  path; see "Zero-inventory fills" for the item-capable `matchSettle` shape): `items.length == 0`,
  `fillModule == address(0)`, no validators you can't satisfy, and
  `lens.validateOrder(order)` returns ok.

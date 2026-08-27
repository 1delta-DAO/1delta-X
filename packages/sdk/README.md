# @1delta-x/sdk

TypeScript SDK for building **order** and **solver** calldata for
`Settlement`. Zero-dependency beyond [viem](https://viem.sh).

It covers both sides of a fill:

- **Maker** — construct an order, hash it, sign it (`fill`), or sign a
  witness-bound Permit3 batch (`fillWithPermit`); cancel, amend, and bracket
  orders (see [Cancelling and amending](#cancelling-and-amending) below).
- **Solver** — build `fill` / `fillWithPermit` calldata, and `executeFill`
  calldata for the flash-solver family (single-input, multi-input, multi-output);
  preview dutch prices off-chain.

The EIP-712 typed-data definitions mirror the Solidity structs exactly. A golden
test (`packages/core/test/HashGolden.t.sol`) pins the on-chain
`hashOrder` of a canonical order, and the SDK test asserts the same constant —
so the hashing is cross-verified against the contract byte-for-byte.

## Install

```bash
pnpm add @1delta-x/sdk viem
```

## Order model

The conversion leg is a **basket on both sides**: the maker gives
`legsIn[]` (`{token, start, end}`) and receives `legsOut[]`
(`{token, start, end, recipient}`).
Partial fills scale every leg (and lending item) by the single fraction
`fillAmount / anchor`. The anchor is `legsIn[0].start` for a SELL order,
`legsOut[0].start` for a BUY, or the signed `fillTotal` when set.

## Maker: sign + fill

```ts
import { privateKeyToAccount } from "viem/accounts";
import {
  signOrder, encodeFill, hashOrderStruct, packTiming, ItemOp, OrderSide,
  type Order, type Deployment,
} from "@1delta-x/sdk";

const dep: Deployment = { chainId: 1, settlement: "0x…", permit3: "0x…" };
const maker = privateKeyToAccount("0x…");

const ZERO = "0x0000000000000000000000000000000000000000" as const;

const order: Order = {
  maker: maker.address,
  side: OrderSide.SELL,              // fixed inputs, decaying outputs
  nonce: 1n,
  deadline: 1893456000n,
  // 2,000 USDC in — `end: 0n` = FIXED, and legsIn[0].start is the fill denominator.
  legsIn: [{ token: "0xUSDC", start: 2_000_000_000n, end: 0n }],
  // A multi-output basket; `recipient: ZERO` means the maker (a non-zero one is a
  // fee/originator leg). `end: 0n` = fixed, else the leg decays start → end.
  legsOut: [
    { token: "0xWETH", start: 1_000000000000000000n, end: 0n, recipient: ZERO },
    { token: "0xDAI",  start: 1_000_000000000000000000n, end: 0n, recipient: ZERO },
  ],
  timing: packTiming(0, 0, 0),       // decay start / duration / exclusivity end — fixed price
  exclusiveFiller: ZERO,
  minFillAnchor: 0n,
  // The four auction scalars; `packOrder` folds them into one signed `params` word.
  exclusivityOverrideBps: 0n,
  gasBumpBps: 0n,
  gasPriceRef: 0n,
  priorityScale: 0n,                 // non-zero only for a PRIORITY auction
  curve: [],
  items: [],
  validators: [],
  invariants: [],
  fillModule: ZERO,
  fillTotal: 0n,
  pricingModule: ZERO,               // an IPriceModule address prices this instead
};

const sig = await signOrder(maker, order, dep);
const orderHash = hashOrderStruct(order);          // == settlement.hashOrder(order)

// Solver-side: build the fill calldata (send from the solver, holding the outputs).
const data = encodeFill(order, sig, 2_000_000_000n);
```

## Maker: single-signature `fillWithPermit`

One signature authorizes the order **and** every Permit3 token/taker allowance:

```ts
import { permitBatch, tokenPermit, takerPermit, signPermitWitness, refOf, encodeFillWithPermit } from "@1delta-x/sdk";

const batch = permitBatch(
  [tokenPermit(dep.settlement, "0xUSDC", 2_000_000_000n, 1893456000)],
  [takerPermit(dep.settlement, refOf(order.items[0].data), 1_500_000_000n, 1893456000)],
  0n,          // permit nonce
  1893456000n, // permit deadline
);

const sig = await signPermitWitness(maker, batch, order, dep);
const data = encodeFillWithPermit(order, batch, sig, 2_000_000_000n);
```

## Solver: flash `executeFill`

```ts
import {
  encodeExecuteFillSingle,     // LimitOrderLeverageSolver, AaveV3/Euler/Morpho FlashSolver
  encodeExecuteFillMultiInput, // borrow proceeds + equity → collateral
  encodeExecuteFillMultiOutput,// flash the whole output basket
  encodeSetupTokenApproval,
} from "@1delta-x/sdk";

const data = encodeExecuteFillMultiInput({
  flashSource: "0xWETH",
  flashAmount: 1_000000000000000000n,
  order, sig, fillAmountIn: 3_000_000_000n,
  dexFees: [500, 3000],        // per tokenIn leg (input→collateral pool)
  minSwapOuts: [0n, 0n],
});
```

## Off-chain pricing

```ts
import { currentAmountOut, fillAmountsOut } from "@1delta-x/sdk";

const now = BigInt(Math.floor(Date.now() / 1000));
const prices = currentAmountOut(order, now);            // per-output dutch tick
const out = fillAmountsOut(order, 1_000_000_000n, now); // delivered amounts (ceil, per leg)
```

## Priority auctions

The bump is bid in **priority fee** rather than elapsed time (`timing` bit 103),
for chains whose sequencer orders transactions by tip. `priorityOrder` sets the
mode, the scale, and — by default — **fill-once**.

```ts
import { priorityOrder, lintPriorityOrder } from "@1delta-x/sdk";

// All-or-nothing, i.e. UniswapX `PriorityOrderReactor` economics.
const o = priorityOrder(order, {
  priorityScale: 2_000_000_000n,   // 2 gwei of tip buys a FULL bump (end → start)
  baselinePriorityFeeWei: 1_000_000n, // the inclusion tip that is NOT a bid
});

lintPriorityOrder(o); // [] — non-fatal advice; nothing here blocks signing
```

**Why fill-once is the default.** The bump is resolved from the filling
transaction's own tip and pinned per fill, so two partial fills at different tips
clear at *different* ticks in the same block — the maker's realised price depends
on how the solver sliced. That makes a partially fillable priority order a
multi-unit **pay-as-bid** auction (maker gets the quantity-weighted average of
accepted bids) where UniswapX's is single-unit **first-price** (maker gets the top
bid). Partial fills do broaden the bidder pool to inventory-constrained solvers,
so it is a real trade rather than a mistake — but it should be chosen, not
inherited:

```ts
const partial = priorityOrder(order, {
  priorityScale: 2_000_000_000n,
  partiallyFillable: true,  // explicit opt-out of the default
  minFillAnchor: 50_000n,   // bounds how finely that average can be diluted
});
lintPriorityOrder(partial); // explains the economics; still signable
```

**What throws vs what lints.** `priorityOrder` throws only where the *settler*
reverts — `priorityScale === 0n` and a non-zero `gasBumpBps`, both
`InvalidAuctionParams`. Everything else is reported by `lintPriorityOrder` and
still builds: a `minFillAnchor` that cannot bind, a decay window or curve that a
priority auction never runs, a `pricingModule` the settler would silently prefer
over the bid. The lint mirrors `SettlementLens.validateOrder`'s priority branch, so
you get the same answer without an RPC round trip. No maker-signed field is ever
rewritten to tidy it away — that would change the order hash behind the author's
back.

There is **no safety difference** — every slice prices inside the maker's signed
band, and a solver's cheapest schedule (all slices unbid) clears at the floor a
single unbid fill would have paid. See `docs/pricing-modes.md` and
`docs/edge-case-matrix.md` §G-8.

## Balance-relative orders

A SELL anchor may be signed as *bps of the maker's balance* rather than an
absolute amount. The marker lives in the top of the existing `start` word, so the
order typehash is unchanged.

```ts
import {
  encodeProportional, resolveProportionalOrder, validateProportional,
} from "@1delta-x/sdk";

// "sell 100% of my USDC, but never more than the amount I quoted against"
order.legsIn[0] = { token: USDC, start: encodeProportional(10_000n), end: quotedAmount };

// The cap is MANDATORY on-chain: `end === 0n` reverts. A balance that grew after
// signing would otherwise be sold at the price of a much smaller one — and anyone
// can raise a maker's balance by transferring to them.
validateProportional(order); // null when fine, else the reason the settler rejects it

// Pricing helpers are pure functions of the order and know nothing about
// balances, so resolve the marker before quoting. `anchorTotal` THROWS on an
// unresolved marker rather than pricing ~1.15e77 and returning a silent nonsense.
const priceable = resolveProportionalOrder(order, makerUsdcBalance);
```

Fill these through `fillUpTo`, not `fill`: the clamp both resolves the size and
bounds the solver against a stale quote. Details, including multi-token sweeps
via `ProportionalSweepModule`, in
[docs/proportional-legs.md](../../docs/proportional-legs.md).

## Scripts

```bash
pnpm build      # tsc → dist
pnpm typecheck
pnpm test       # vitest (golden hash + sign/recover + calldata round-trips)
```

## Cancelling and amending

Five granularities, four on-chain and one free. Pick the narrowest that expresses
the intent — cancelling *by nonce* is bulk, and a nonce may be shared by several
orders.

```ts
import {
  encodeCancelOrder,       // ONE order, by hash — nonce siblings stay fillable
  encodeCancelOrders,      // every order carrying these nonces (bulk)
  encodeInvalidateNonceWord, // 256 nonces, one SSTORE
  encodeRollbackNonces,    // everything below a watermark, one SSTORE
  softCancelOrders,        // free, off-chain, signed — advisory
  amendOrder,              // cancel-and-replace, as one gesture
} from "@1delta-x/sdk";

// Free retraction: one EIP-712 signature retires a whole quote set.
const { cancel, sig } = await softCancelOrders(maker, maker.address, [h1, h2, h3], dep);

// Re-price: a replacement on a fresh nonce + a signed retraction of the old one.
const { order, sig: orderSig, replaces, cancel: c, cancelSig } =
  await amendOrder(maker, prev, nextNonce, { legsOut: repriced }, dep);
```

A soft cancel evicts an order from books that honour it; it does **not** bind a
filler that already holds the signed order. Anything that must not fill needs one
of the on-chain cancels. Full rationale, including why an amend takes a fresh
nonce: [docs/soft-cancel.md](../../docs/soft-cancel.md).

## Brackets (one-cancels-other)

A group of the maker's own orders of which at most one may fill.

```ts
import { ocoNonceGroup, ocoGroup } from "@1delta-x/sdk";

// Free, zero contracts, WHOLE-FILL ONLY: one shared nonce + the fill-once bit.
const [tp, sl] = ocoNonceGroup([takeProfit, stopLoss], sharedNonce);

// Partial-fill capable, N-way: OcoGroupModule's validator + claim item on each
// leg. Appends, so each leg keeps its own trigger validator.
const legs = ocoGroup([takeProfit, stopLoss, timeOut], OCO_MODULE, groupId);
```

[docs/oco.md](../../docs/oco.md) explains the trade-off and why the claim is a
SETTLE item.

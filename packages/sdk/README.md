# @1delta-x/sdk

TypeScript SDK for building **order** and **solver** calldata for
`Settlement`. Zero-dependency beyond [viem](https://viem.sh).

It covers both sides of a fill:

- **Maker** — construct an order, hash it, sign it (`fill`), or sign a
  witness-bound Permit3 batch (`fillWithPermit`); cancel orders.
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
`tokenIn[]`/`amountIn[]` and receives `tokenOut[]`/`startAmountOut[]`/`endAmountOut[]`.
Partial fills scale every leg (and lending item) by the single fraction
`fillAmountIn / amountIn[0]`. `amountIn[0]` is the fill denominator and
`fillAmountIn` is denominated in `tokenIn[0]`.

## Maker: sign + fill

```ts
import { privateKeyToAccount } from "viem/accounts";
import { signOrder, encodeFill, hashOrderStruct, ItemOp, type Order, type Deployment } from "@1delta-x/sdk";

const dep: Deployment = { chainId: 1, settlement: "0x…", permit3: "0x…" };
const maker = privateKeyToAccount("0x…");

const order: Order = {
  maker: maker.address,
  nonce: 1n,
  deadline: 1893456000n,
  tokenIn: ["0xUSDC"],
  amountIn: [2_000_000_000n],       // 2,000 USDC — amountIn[0] = fill denominator
  decayStartTime: 0,
  decayDuration: 0,                  // fixed price
  tokenOut: ["0xWETH", "0xDAI"],     // multi-output basket
  startAmountOut: [1_000000000000000000n, 1_000_000000000000000000n],
  endAmountOut:   [1_000000000000000000n, 1_000_000000000000000000n],
  exclusiveFiller: "0x0000000000000000000000000000000000000000",
  exclusivityEndTime: 0,
  minFillAmountIn: 0n,
  items: [],
  validators: [],
  invariants: [],
};

const sig = await signOrder(maker, order, dep);
const orderHash = hashOrderStruct(order);          // == settlement.hashOrder(order)

// Solver-side: build the fill calldata (send from the solver, holding tokenOut).
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

## Scripts

```bash
pnpm build      # tsc → dist
pnpm typecheck
pnpm test       # vitest (golden hash + sign/recover + calldata round-trips)
```

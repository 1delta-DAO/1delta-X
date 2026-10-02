import { encodeFunctionData, type Address, type Hex } from "viem";

import { FLASH_SOLVER_ABI, MULTI_INPUT_SOLVER_ABI, MULTI_OUTPUT_SOLVER_ABI, orderComponents } from "./abi";
import type { Order, OutputLeg } from "./types";
import { packOrder } from "./packed";

/**
 * The flash solvers' optional `FlashOpts{recipient, takerData}` tail: a profit
 * recipient (`0` = the caller) and the shared `takerData` blob (validators,
 * invariants, price module). Passing it selects the `executeFill(..., FlashOpts)`
 * overload; omitting it keeps the original ABI byte-for-byte.
 */
export interface FlashOpts {
  recipient?: Address;
  takerData?: Hex;
}

const flashOpts = (o: FlashOpts) => ({
  recipient: o.recipient ?? "0x0000000000000000000000000000000000000000",
  takerData: o.takerData ?? "0x",
});

/**
 * Single-input flash solver `executeFill` (LimitOrderLeverageSolver,
 * AaveV3/Euler/Morpho FlashSolver). Flash-loans `flashSource` collateral, fills,
 * swaps the single borrow leg (legsIn[0]) back on Uniswap v3.
 */
export function encodeExecuteFillSingle(args: {
  flashSource: Address;
  flashAmount: bigint;
  order: Order;
  sig: Hex;
  fillAmountIn: bigint;
  dexFee: number;
  minSwapOut: bigint;
  opts?: FlashOpts;
}): Hex {
  const head = [
    args.flashSource,
    args.flashAmount,
    packOrder(args.order) as any,
    args.sig,
    args.fillAmountIn,
    args.dexFee,
    args.minSwapOut,
  ] as const;
  return encodeFunctionData({
    abi: FLASH_SOLVER_ABI,
    functionName: "executeFill",
    args: (args.opts ? [...head, flashOpts(args.opts)] : head) as any,
  });
}

/**
 * Multi-input flash solver `executeFill` (Balancer MultiInputLeverageSolver +
 * Aave/Euler/Morpho variants). Swaps EVERY input leg back to the collateral;
 * `dexFees`/`minSwapOuts` are aligned with `order.legsIn`.
 */
export function encodeExecuteFillMultiInput(args: {
  flashSource: Address;
  flashAmount: bigint;
  order: Order;
  sig: Hex;
  fillAmountIn: bigint;
  dexFees: readonly number[];
  minSwapOuts: readonly bigint[];
  opts?: FlashOpts;
}): Hex {
  const head = [
    args.flashSource,
    args.flashAmount,
    packOrder(args.order) as any,
    args.sig,
    args.fillAmountIn,
    args.dexFees,
    args.minSwapOuts,
  ] as const;
  return encodeFunctionData({
    abi: MULTI_INPUT_SOLVER_ABI,
    functionName: "executeFill",
    args: (args.opts ? [...head, flashOpts(args.opts)] : head) as any,
  });
}

/**
 * MultiOutputFlashSolver `executeFill`. Flash-loans the whole output basket
 * (one `OutputLeg` per token, sorted ascending by token address) and buys each
 * back from the received input.
 */
export function encodeExecuteFillMultiOutput(args: {
  order: Order;
  sig: Hex;
  fillAmountIn: bigint;
  legs: readonly OutputLeg[];
  opts?: FlashOpts;
}): Hex {
  const head = [packOrder(args.order) as any, args.sig, args.fillAmountIn, args.legs as any] as const;
  return encodeFunctionData({
    abi: MULTI_OUTPUT_SOLVER_ABI,
    functionName: "executeFill",
    args: (args.opts ? [...head, flashOpts(args.opts)] : head) as any,
  });
}

/** `solver.setupTokenApproval(token)` — one-time per collateral/output token. */
export function encodeSetupTokenApproval(token: Address): Hex {
  return encodeFunctionData({ abi: FLASH_SOLVER_ABI, functionName: "setupTokenApproval", args: [token] });
}

/// `UsdrifInventorySolver` — operator-gated, inventory-funded USDRIF→USDT0 filler.
/// BREAKING (audit 2026-09-30 PERIPH-1.v2 / OPS-USDRIF-MAXSPENT): both entries take
/// the operator's `maxSpent` price bound.
export const USDRIF_INVENTORY_SOLVER_ABI = [
  {
    type: "function",
    name: "executeFill",
    stateMutability: "nonpayable",
    inputs: [
      { name: "order", type: "tuple", components: orderComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "maxSpent", type: "uint256" },
    ],
    outputs: [{ name: "paid", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "executeFillAndRedeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "order", type: "tuple", components: orderComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "maxSpent", type: "uint256" },
      { name: "qACmin", type: "uint256" },
    ],
    outputs: [
      { name: "paid", type: "uint256[]" },
      { name: "opId", type: "uint256" },
    ],
  },
] as const;

/**
 * `UsdrifInventorySolver.executeFill` / `executeFillAndRedeem` calldata. `maxSpent`
 * is REQUIRED: the most of the output token this fill may move out of inventory —
 * quote it at the operator's real gas price and the price it evaluated. The strict
 * `fill` the solver uses carries no price floor, so this is the operator's only
 * bound against a maker-ward price move (priority bump, price module, descending
 * curve). Pass `qACmin` to redeem in the same transaction.
 */
export function encodeUsdrifInventoryFill(args: {
  order: Order;
  sig: Hex;
  fillAmountIn: bigint;
  maxSpent: bigint;
  qACmin?: bigint;
}): Hex {
  if (typeof args.maxSpent !== "bigint") throw new Error("encodeUsdrifInventoryFill: maxSpent is required");
  const head = [packOrder(args.order) as any, args.sig, args.fillAmountIn, args.maxSpent] as const;
  return args.qACmin === undefined
    ? encodeFunctionData({ abi: USDRIF_INVENTORY_SOLVER_ABI, functionName: "executeFill", args: head as any })
    : encodeFunctionData({
        abi: USDRIF_INVENTORY_SOLVER_ABI,
        functionName: "executeFillAndRedeem",
        args: [...head, args.qACmin] as any,
      });
}

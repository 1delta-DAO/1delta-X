import { encodeFunctionData, type Address, type Hex } from "viem";

import { FLASH_SOLVER_ABI, MULTI_INPUT_SOLVER_ABI, MULTI_OUTPUT_SOLVER_ABI } from "./abi";
import type { Order, OutputLeg } from "./types";

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
}): Hex {
  return encodeFunctionData({
    abi: FLASH_SOLVER_ABI,
    functionName: "executeFill",
    args: [
      args.flashSource,
      args.flashAmount,
      args.order as any,
      args.sig,
      args.fillAmountIn,
      args.dexFee,
      args.minSwapOut,
    ],
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
}): Hex {
  return encodeFunctionData({
    abi: MULTI_INPUT_SOLVER_ABI,
    functionName: "executeFill",
    args: [
      args.flashSource,
      args.flashAmount,
      args.order as any,
      args.sig,
      args.fillAmountIn,
      args.dexFees,
      args.minSwapOuts,
    ],
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
}): Hex {
  return encodeFunctionData({
    abi: MULTI_OUTPUT_SOLVER_ABI,
    functionName: "executeFill",
    args: [args.order as any, args.sig, args.fillAmountIn, args.legs as any],
  });
}

/** `solver.setupTokenApproval(token)` — one-time per collateral/output token. */
export function encodeSetupTokenApproval(token: Address): Hex {
  return encodeFunctionData({ abi: FLASH_SOLVER_ABI, functionName: "setupTokenApproval", args: [token] });
}

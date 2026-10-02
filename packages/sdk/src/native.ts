import { encodeFunctionData, zeroAddress, type Address, type Hex } from "viem";

import { orderComponents } from "./abi";
import { packOrder } from "./packed";
import { BLOCK_CLOCK_BIT, OrderSide, type Order } from "./types";

const U32 = 0xffff_ffffn;

/**
 * Bind a native-in order to the `NativeSettler` (audit 2026-09-30 PERIPH-9).
 *
 * A native-in order is a plain SELL of WETH that `NativeSettler.settleFromNative`
 * funds by wrapping the maker's `msg.value`. Unbound, a maker who also holds WETH
 * under a standing Permit3 allowance can have it filled by ANYONE at the signed
 * minimum, losing the route surplus the settler sweeps back to them. This returns
 * the order with:
 *   • exactly one input leg, `weth` fixed at `amountIn`;
 *   • `exclusiveFiller = nativeSettler`, a HARD window (`exclusivityOverrideBps = 0`)
 *     covering the order's whole life (`exclusivityEndTime = expiry`, or the uint32
 *     maximum on a block-clocked order).
 * Output legs are kept as given — any number ≥ 1, fee-split `[LegOut, LegOut]`
 * included (the settler approves and sweeps every distinct output token).
 */
export function nativeInOrder(order: Order, p: { nativeSettler: Address; weth: Address; amountIn: bigint }): Order {
  if (order.side !== OrderSide.SELL) throw new Error("nativeInOrder: a native-in order is a SELL of WETH");
  if (order.legsOut.length === 0) throw new Error("nativeInOrder: at least one output leg is required");
  if (p.nativeSettler.toLowerCase() === zeroAddress) throw new Error("nativeInOrder: nativeSettler is required");
  const blockClock = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n;
  const end = blockClock ? U32 : order.expiry;
  if (end > U32) throw new Error("nativeInOrder: expiry exceeds the uint32 exclusivity clock");
  const timing = (order.timing & ~(U32 << 64n)) | (end << 64n);
  return {
    ...order,
    legsIn: [{ token: p.weth, start: p.amountIn, end: 0n }],
    exclusiveFiller: p.nativeSettler,
    exclusivityOverrideBps: 0n,
    timing,
  };
}

export const NATIVE_SETTLER_ABI = [
  {
    type: "function",
    name: "settleFromNative",
    stateMutability: "payable",
    inputs: [
      { name: "order", type: "tuple", components: orderComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmount", type: "uint256" },
      { name: "dexTarget", type: "address" },
      { name: "dexCallData", type: "bytes" },
    ],
    outputs: [{ name: "outs", type: "uint256[]" }],
  },
] as const;

/** `NativeSettler.settleFromNative` calldata (send with `value = amountIn`). */
export function encodeSettleFromNative(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  dexTarget: Address;
  dexCallData: Hex;
}): Hex {
  return encodeFunctionData({
    abi: NATIVE_SETTLER_ABI,
    functionName: "settleFromNative",
    args: [packOrder(args.order) as never, args.sig, args.fillAmount, args.dexTarget, args.dexCallData],
  });
}

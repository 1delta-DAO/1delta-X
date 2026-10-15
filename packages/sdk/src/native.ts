import { encodeFunctionData, zeroAddress, type Address, type Hex } from "viem";

import { orderComponents } from "./abi";
import { packOrder } from "./packed";
import { BLOCK_CLOCK_BIT, DELTA_VERIFY_OUTPUTS_BIT, OrderSide, type LegOut, type Order } from "./types";

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

// ──────────────────── native delivery through a balance view (task 30) ────────────────────

/**
 * `NativeBalance` per chain (packages/periphery/src/NativeBalance.sol): a stateless
 * view whose `balanceOf(a)` is `a.balance` and `decimals()` 18 — nothing else (no
 * `transfer`, `transferFrom` or `approve`). `undefined` where it is not deployed:
 * native delivery is then OFF and nothing may sign the shape.
 *
 * A DIRECT (delta-verify, timing bit 104) order that names it as `legsOut[0].token`
 * receives the RAW native coin: Settlement only ever reads `balanceOf` on a
 * delta-verified output, so it measures the recipient's native balance before and
 * after the solver's callback. The solver (AggregatorFillSolver v3, `NATIVE_BALANCE`
 * immutable) routes into the wrapped coin, unwraps it and sends it. Any other use —
 * an input leg, a PULL output — fails closed on-chain (`transferFrom` does not exist).
 */
export const NATIVE_BALANCE: Readonly<Record<number, Address | undefined>> = Object.freeze({
  // Rootstock: deployed 2026-10-15 with AggregatorFillSolver v3 0x5987A4AF…6cD1
  // (docs/deployment-rootstock-beta.md; Sourcify-verified).
  30: "0xA45ec37619C9F9B2f9d54692d578D1b1246c854c",
});

/** The chain's {@link NATIVE_BALANCE}, or `undefined` (native delivery off). */
export function nativeBalanceOf(chainId: number): Address | undefined {
  const a = NATIVE_BALANCE[chainId];
  return a && a.toLowerCase() !== zeroAddress ? a : undefined;
}

/**
 * The output leg of an order that receives the RAW native coin: `{ token:
 * nativeBalance, start, end, recipient: 0x0 }` — the maker. Sign it as `legsOut[0]`
 * of a DIRECT order (`withDeltaVerifyOutputs`) whose `exclusiveFiller` is a solver
 * that delivers native (AggregatorFillSolver v3 with this `NATIVE_BALANCE`), and as
 * the order's ONLY leg in either the view or the wrapped coin. Amounts are 18-dec
 * native wei, like the wrapped coin's. `end` as for any {@link LegOut} (`0n` = fixed;
 * a SELL's falling auction floor otherwise).
 */
export function nativeOutLeg(p: { nativeBalance: Address; start: bigint; end?: bigint }): LegOut {
  if (!p.nativeBalance || p.nativeBalance.toLowerCase() === zeroAddress) throw new Error("nativeOutLeg: nativeBalance is not deployed on this chain");
  if (p.start <= 0n) throw new Error("nativeOutLeg: start must be > 0");
  const end = p.end ?? 0n;
  if (end !== 0n && end > p.start) throw new Error("nativeOutLeg: an output leg falls (end ≤ start)");
  return { token: p.nativeBalance, start: p.start, end, recipient: zeroAddress };
}

/** Whether `order` receives native through `nativeBalance` (its `legsOut[0].token`). */
export function isNativeOutOrder(order: Order, nativeBalance: Address | undefined): boolean {
  const leg = order.legsOut[0];
  return !!nativeBalance && !!leg && leg.token.toLowerCase() === nativeBalance.toLowerCase();
}

/**
 * Why `order` misuses the `nativeBalance` view, or `null` when it is fine (or does not
 * name it at all). The view is only ever a DELTA-VERIFIED OUTPUT: an input leg, a
 * PULL-delivered output, or a second leg in it can never settle (the core's
 * `transferFrom` on a view reverts; the solver delivers one native leg). A book
 * refuses such an order at admission instead of verifying a dead shape.
 */
export function nativeBalanceMisuse(order: Order, nativeBalance: Address | undefined): string | null {
  if (!nativeBalance || nativeBalance.toLowerCase() === zeroAddress) return null;
  const nb = nativeBalance.toLowerCase();
  if (order.legsIn.some((l) => l.token.toLowerCase() === nb)) return "NativeBalance is a balance view: it can never be an input leg";
  const outs = order.legsOut.map((l, i) => (l.token.toLowerCase() === nb ? i : -1)).filter((i) => i >= 0);
  if (outs.length === 0) return null;
  if (outs.length > 1 || outs[0] !== 0) return "NativeBalance may only be legsOut[0], once";
  if (((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) !== 1n) return "a NativeBalance output needs DIRECT (delta-verify, timing bit 104) delivery: it cannot be pulled";
  if (order.exclusiveFiller.toLowerCase() === zeroAddress) return "a NativeBalance order must name the solver that delivers native as exclusiveFiller";
  return null;
}

import { AGGREGATOR_FILL_SOLVER_ABI, hashOrderStruct, SETTLEMENT_ABI, unpackOrder, type Order, type WireOrder } from "@1delta-x/sdk";
import { decodeFunctionData, type Hex } from "viem";

/**
 * The order a fill transaction carried (2026-11-02). Every beta fill is an
 * AggregatorFillSolver call (`executeFill` / `executeItemFill`) or a direct Settlement
 * fill (`fill*`, `batchFill`, …), so its order is in the calldata: decode the call,
 * unpack every order-shaped argument and keep the one that HASHES to `orderHash` —
 * nothing the tx sender chose can make a different order match. `null` when the
 * calldata is neither contract's call or holds no such order (e.g. a fill relayed
 * through some other contract).
 */
export function orderFromCalldata(input: Hex, orderHash: string): Order | null {
  const want = orderHash.toLowerCase();
  for (const abi of [AGGREGATOR_FILL_SOLVER_ABI, SETTLEMENT_ABI] as const) {
    let args: unknown;
    try {
      args = decodeFunctionData({ abi, data: input }).args;
    } catch {
      continue; // not this contract's call
    }
    for (const w of wireOrders(args)) {
      try {
        const order = unpackOrder(w);
        if (hashOrderStruct(order).toLowerCase() === want) return order;
      } catch {
        // a malformed blob: not this order
      }
    }
  }
  return null;
}

/** Every wire order among decoded call arguments (a tuple with `maker`, packed `legsIn` and a `timing` word). */
function wireOrders(v: unknown, out: WireOrder[] = []): WireOrder[] {
  if (Array.isArray(v)) for (const x of v) wireOrders(x, out);
  else if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (typeof o.maker === "string" && typeof o.legsIn === "string" && typeof o.timing === "bigint") out.push(o as unknown as WireOrder);
    else for (const x of Object.values(o)) wireOrders(x, out);
  }
  return out;
}

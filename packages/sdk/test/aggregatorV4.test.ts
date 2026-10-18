import { describe, expect, it } from "vitest";
import { decodeFunctionData, getAddress, toFunctionSelector, zeroAddress, type Address, type Hex } from "viem";

import {
  AGGREGATOR_FILL_SOLVER_ABI,
  AGGREGATOR_FILL_SOLVER_V4_ABI,
  AGGREGATOR_SELECTORS,
  ItemOp,
  MULTI_ROUTE,
  NO_ITEM_FILL_GUARD,
  NO_PATCH,
  OrderSide,
  POOL_AMOUNT_IN_OFFSET,
  POOL_ROUTE,
  detectAggregatorVersion,
  encodeAggregatorExecuteFill,
  encodeAggregatorExecuteItemFill,
  encodeMultiRoute,
  encodePoolRoute,
  type Order,
  type RoutePlan,
} from "../src";

/**
 * AggregatorFillSolver v4 (in-tree 2026-10-18) next to v3 (live): both ABIs, selected per
 * call. The selectors are pinned against the forge artifacts' `methodIdentifiers`
 * (v3: the deployed 0x5987…6cD1 build; v4: out/agent-solver-agg, 2026-10-18).
 */
const A = (n: string): Address => getAddress(n);
const WRBTC = A("0x542fDA317318eBF1d3DEAf76E0b632741A7e677d");
const USDT0 = A("0x779Ded0c9e1022225f8E0630b35a9b54bE713736");
const MAKER = A("0x00000000000000000000000000000000000000aa");
const ROUTER = A("0x0B14ff67f0014046b4b99057Aec4509640b3947A");

const order = (over: Partial<Order> = {}): Order => ({
  maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
  legsIn: [{ token: WRBTC, start: 10n ** 16n, end: 0n }],
  legsOut: [{ token: USDT0, start: 900_000_000n, end: 0n, recipient: zeroAddress }],
  timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
  gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
  fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
});
const poolPlan = (over: Partial<RoutePlan> = {}): RoutePlan => ({
  router: POOL_ROUTE, minOut: 901n, maxPay: 900n, amountInOffset: POOL_AMOUNT_IN_OFFSET, amountOutOffset: NO_PATCH, minBumpBps: 0n,
  profitRecipient: zeroAddress, originator: zeroAddress, originatorPpm: 0,
  data: encodePoolRoute({ tokens: [WRBTC, USDT0], fees: [3000], venues: [0], amountIn: 10n ** 16n, amountOut: 0n }).data, ...over,
});
const sel = (abi: readonly unknown[], name: string) => toFunctionSelector((abi as Array<{ type: string; name?: string }>).find((x) => x.type === "function" && x.name === name) as never);
const base = { order: order(), sig: "0x01" as Hex, fillAmount: 10n ** 16n };

describe("AggregatorFillSolver v3 / v4 ABIs", () => {
  it("selectors match the compiled contracts", () => {
    expect(sel(AGGREGATOR_FILL_SOLVER_ABI, "executeFill")).toBe(AGGREGATOR_SELECTORS[3].executeFill);
    expect(sel(AGGREGATOR_FILL_SOLVER_ABI, "executeItemFill")).toBe(AGGREGATOR_SELECTORS[3].executeItemFill);
    expect(sel(AGGREGATOR_FILL_SOLVER_V4_ABI, "executeFill")).toBe("0x50358c9e");
    expect(sel(AGGREGATOR_FILL_SOLVER_V4_ABI, "executeItemFill")).toBe("0xac44b909");
    expect(AGGREGATOR_SELECTORS[3].executeFill).toBe("0xd828b11a");
  });

  it("detectAggregatorVersion reads the dispatcher's selector", () => {
    expect(detectAggregatorVersion(`0x6080${"50358c9e"}63`)).toBe(4);
    expect(detectAggregatorVersion(`0x6080${"d828b11a"}63`)).toBe(3);
    expect(detectAggregatorVersion("0x6080")).toBeUndefined();
    expect(detectAggregatorVersion(undefined)).toBeUndefined();
  });

  it("default (v3) is byte-for-byte the old encoding; v4 carries inventory", () => {
    const v3 = encodeAggregatorExecuteFill({ ...base, plan: poolPlan() });
    expect(v3.slice(0, 10)).toBe("0xd828b11a");
    expect(encodeAggregatorExecuteFill({ ...base, plan: poolPlan(), version: 3 })).toBe(v3);
    const v4 = encodeAggregatorExecuteFill({ ...base, plan: poolPlan({ inventory: 5n }), version: 4, fillAmount: (1n << 256n) - 1n });
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_V4_ABI, data: v4 });
    expect(d.functionName).toBe("executeFill");
    expect((d.args![3] as { inventory: bigint }).inventory).toBe(5n);
    expect(d.args![2]).toBe((1n << 256n) - 1n);
  });

  it("refusals: inventory on v3, ≥ 2^128 on v4, an empty route without inventory or on v3, MULTI_ROUTE outside a v4 item fill", () => {
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: poolPlan({ inventory: 1n }) })).toThrow(/v4/);
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: poolPlan({ maxPay: 1n << 128n }), version: 4 })).toThrow(/AmountTooLarge/);
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: poolPlan({ inventory: 1n << 128n }), version: 4 })).toThrow(/AmountTooLarge/);
    const empty = poolPlan({ data: "0x", amountInOffset: NO_PATCH });
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: empty, version: 4 })).toThrow(/inventory/);
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: { ...empty, inventory: 900n }, version: 3 })).toThrow(/v4/);
    expect(encodeAggregatorExecuteFill({ ...base, plan: { ...empty, inventory: 900n }, version: 4 }).slice(0, 10)).toBe("0x50358c9e");
    const multi = poolPlan({ router: MULTI_ROUTE, amountInOffset: NO_PATCH, data: encodeMultiRoute([ROUTER], ["0x1234"]) });
    expect(() => encodeAggregatorExecuteFill({ ...base, plan: multi, version: 4 })).toThrow(/MULTI_ROUTE/);
    expect(() => encodeAggregatorExecuteItemFill({ ...base, plan: multi, lateItems: 0n })).toThrow(/MULTI_ROUTE/);
    expect(() => encodeMultiRoute([ROUTER], [])).toThrow(/BadMulticall/);
  });

  it("v4 executeItemFill takes the ItemFillGuard (default: no check); v3 refuses one", () => {
    const it0 = { op: ItemOp.TAKE, module: ROUTER, amount: 1n, recipient: zeroAddress, data: "0x" as Hex };
    const o = order({ items: [it0] });
    const guard = { orderHash: ("0x" + "ab".repeat(32)) as Hex, expectedFilled: 7n, liveNonce: true, receipts: [WRBTC] };
    const data = encodeAggregatorExecuteItemFill({ ...base, order: o, plan: poolPlan(), lateItems: 0n, version: 4, guard });
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_V4_ABI, data });
    expect([d.functionName, d.args![7]]).toEqual(["executeItemFill", guard]);
    const dflt = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_V4_ABI, data: encodeAggregatorExecuteItemFill({ ...base, order: o, plan: poolPlan(), lateItems: 0n, version: 4 }) });
    expect(dflt.args![7]).toEqual(NO_ITEM_FILL_GUARD);
    expect(() => encodeAggregatorExecuteItemFill({ ...base, order: o, plan: poolPlan(), lateItems: 0n, guard })).toThrow(/v4/);
    expect(encodeAggregatorExecuteItemFill({ ...base, order: o, plan: poolPlan(), lateItems: 0n }).slice(0, 10)).toBe(AGGREGATOR_SELECTORS[3].executeItemFill);
    // MULTI_ROUTE on the v4 item path is fine.
    const multi = poolPlan({ router: MULTI_ROUTE, amountInOffset: NO_PATCH, data: encodeMultiRoute([ROUTER], ["0x1234"]) });
    expect(encodeAggregatorExecuteItemFill({ ...base, order: o, plan: multi, lateItems: 0n, version: 4 }).slice(0, 10)).toBe("0xac44b909");
  });
});

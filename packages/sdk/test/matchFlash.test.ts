import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, toFunctionSelector, zeroAddress, type Address, type Hex } from "viem";

import {
  FlashKind,
  MATCH_FLASH_SOLVER_ABI,
  MatchStepKind,
  ItemOp,
  OrderSide,
  buildFlashMatchPlan,
  decodeFlashPath,
  decodeMatchFlashResult,
  encodeFlashPath,
  encodeMatchFlashExecute,
  encodeOnMatchStep,
  forLegPreFund,
  packMatchStep,
  packOrder,
  withDeltaVerifyOutputs,
  type FlashMatch,
  type Item,
  type Order,
  type RaceCheck,
} from "../src";

/**
 * MatchFlashSolver ABI (packages/solvers/src/match/MatchFlashSolver.sol). The selectors are
 * pinned against the compiled artifact's `methodIdentifiers` (forge, 2026-10-18): a shape
 * drift in the Order tuple, the MatchPlan tuple or the solver's structs changes them.
 */
const A = (n: string): Address => getAddress(n);
const WRBTC = A("0x542fDA317318eBF1d3DEAf76E0b632741A7e677d");
const USDT0 = A("0x779Ded0c9e1022225f8E0630b35a9b54bE713736");
const SOLVER = A("0x00000000000000000000000000000000000f1a51");
const LENDER = A("0x00000000000000000000000000000000000000d1");
const MAKER = A("0x00000000000000000000000000000000000000aa");
const SETTLEMENT = A("0x0000000000000000000000000000000000005e77");

function openOrder(over: Partial<Order> = {}): Order {
  const it: Item = { op: ItemOp.TAKE_FOR, module: LENDER, amount: 100_000_000n, recipient: zeroAddress, data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [forLegPreFund(0, WRBTC, 0), 0n]) };
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: USDT0, start: 100_000_000n, end: 0n }],
    legsOut: [{ token: WRBTC, start: 10n ** 15n, end: 0n, recipient: LENDER }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [it], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  };
}
const race: RaceCheck = { orderHashes: [("0x" + "ab".repeat(32)) as Hex], expectedFilled: [0n], nonceMakers: [], nonces: [] };
function job(over: Partial<FlashMatch["flash"]> = {}, swaps: FlashMatch["swaps"] = []): FlashMatch {
  return {
    flash: { kind: FlashKind.UNI_V3_FLASH, token: WRBTC, amount: 10n ** 15n, pairToken: USDT0, fee: 3000, venue: 1, vault: zeroAddress, maxRepay: 0n, ...over },
    swaps,
    recipient: zeroAddress,
    extraSweep: [],
    minProfit: [{ token: WRBTC, min: 1n }],
  };
}

describe("MatchFlashSolver ABI", () => {
  it("selectors match the compiled contract", () => {
    const sel = (name: "executeMatch" | "onMatchStep") => {
      const f = MATCH_FLASH_SOLVER_ABI.find((x) => x.type === "function" && x.name === name)!;
      return toFunctionSelector(f as never);
    };
    expect(sel("executeMatch")).toBe("0x9f8b239e");
    expect(sel("onMatchStep")).toBe("0xf16438ef");
  });

  it("packMatchStep mirrors MatchStep.pack; the one-order plan is CALL → DELIVER → ITEM 0..n", () => {
    expect(packMatchStep(MatchStepKind.ITEM, 0, 2)).toBe(2n | (2n << 24n));
    const p = buildFlashMatchPlan({ order: openOrder(), sig: "0x01", fillAmount: 100_000_000n, solver: SOLVER, flashToken: WRBTC });
    expect(p.schedule).toEqual([4n, 1n, 2n]);
    expect([p.callTargets, p.profitRecipient, p.takerDatas]).toEqual([[SOLVER], zeroAddress, []]);
    const d = decodeFunctionData({ abi: MATCH_FLASH_SOLVER_ABI, data: p.callDatas[0]! });
    expect(d.args).toEqual([[], [WRBTC], [(1n << 256n) - 1n]]);
    expect(() => encodeOnMatchStep([], [WRBTC], [])).toThrow(/LengthMismatch/);
  });

  it("flash paths: tokenIn ‖ fee(3) ‖ venue(1) ‖ tokenOut", () => {
    const path = encodeFlashPath([USDT0, WRBTC], [3000], [0]);
    expect(path).toBe(`0x${USDT0.slice(2).toLowerCase()}000bb800${WRBTC.slice(2).toLowerCase()}`);
    expect(decodeFlashPath(path)).toEqual([{ tokenIn: USDT0.toLowerCase(), fee: 3000, venue: 0, tokenOut: WRBTC.toLowerCase() }]);
    expect(() => encodeFlashPath([USDT0], [], [])).toThrow();
  });

  it("encodes executeMatch with the PACKED order, and round-trips the result", () => {
    const o = openOrder();
    const plan = buildFlashMatchPlan({ order: o, sig: "0x01", fillAmount: 100_000_000n, solver: SOLVER, flashToken: WRBTC });
    const swaps = [{ path: encodeFlashPath([USDT0, WRBTC], [3000], [0]), amountIn: 0n, minOut: 1n }];
    const data = encodeMatchFlashExecute({ race, job: job({}, swaps), plan, settlement: SETTLEMENT });
    const d = decodeFunctionData({ abi: MATCH_FLASH_SOLVER_ABI, data });
    expect(d.functionName).toBe("executeMatch");
    const wire = (d.args![2] as { orders: unknown[] }).orders[0];
    expect(wire).toEqual(packOrder(o));
    const ret = encodeFunctionResult({ abi: MATCH_FLASH_SOLVER_ABI, functionName: "executeMatch", result: [[WRBTC, USDT0], [5n, 0n]] });
    expect(decodeMatchFlashResult(ret)).toEqual({ tokens: [WRBTC, USDT0], profit: [5n, 0n] });
  });

  it("refuses what the solver or the core reverts on", () => {
    const plan = (o: Order) => buildFlashMatchPlan({ order: o, sig: "0x01", fillAmount: 1n, solver: SOLVER, flashToken: WRBTC });
    const settle: Item = { op: ItemOp.SETTLE, module: LENDER, amount: 1n, recipient: zeroAddress, data: "0x" };
    expect(() => encodeMatchFlashExecute({ race, job: job(), plan: plan(openOrder({ items: [settle] })) })).toThrow(/SettleUnsupported/);
    expect(() => encodeMatchFlashExecute({ race, job: job(), plan: plan(openOrder({ timing: withDeltaVerifyOutputs(0n) })) })).toThrow(/delta-verify/);
    expect(() => encodeMatchFlashExecute({ race, job: job(), plan: { ...plan(openOrder()), profitRecipient: SETTLEMENT }, settlement: SETTLEMENT })).toThrow(/ProfitStranded/);
    expect(() => encodeMatchFlashExecute({ race: { ...race, expectedFilled: [] }, job: job(), plan: plan(openOrder()) })).toThrow(/GuardLengthMismatch/);
    // LOK: flash from Sushi 0.3 % (venue 1), repay on the SAME pool.
    const same = [{ path: encodeFlashPath([USDT0, WRBTC], [3000], [1]), amountIn: 0n, minOut: 0n }];
    expect(() => encodeMatchFlashExecute({ race, job: job({}, same), plan: plan(openOrder()) })).toThrow(/LOK/);
    // …another venue or fee tier is fine, and a flash SWAP has no repayment swap to collide with.
    expect(() => encodeMatchFlashExecute({ race, job: job({}, [{ ...same[0]!, path: encodeFlashPath([USDT0, WRBTC], [3000], [0]) }]), plan: plan(openOrder()) })).not.toThrow();
    expect(() => encodeMatchFlashExecute({ race, job: job({ kind: FlashKind.UNI_V3_SWAP, venue: 0 }), plan: plan(openOrder()) })).not.toThrow();
  });
});

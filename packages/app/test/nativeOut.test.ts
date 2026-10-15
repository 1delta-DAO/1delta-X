/**
 * NATIVE-OUT: an order that receives WRBTC can ask for raw RBTC instead.
 *  • task 30 (what the RBTC receive entry signs when `nativeBalance` is deployed): the
 *    output leg's token is the NativeBalance view, DIRECT to the market's solver, no item —
 *    exactly what the filler accepts (beta-filler policy.ts `plainShape` nativeBalance);
 *  • task 28 (dormant): the leg goes to the NativeUnwrapModule, one MAKE item unwraps it.
 */
import { DELTA_VERIFY_OUTPUTS_BIT, ItemOp, ItemPolicy, forLegPreFund, nativeBalanceMisuse, type Deployment } from "@1delta-x/sdk";
import { decodeAbiParameters, getAddress, zeroAddress, type Address } from "viem";
import { describe, expect, it } from "vitest";

import { rowResolver } from "../src/backend/restore";
import { nativeOutFor, parseDeployments } from "../src/config/deploymentConfig";
import { rowSymbols } from "../src/config/markets";
import { buildOrder, nativeOutItem } from "../src/lib/order";
import { parseQuote } from "../src/lib/quote";

const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const MODULE = getAddress("0xB6107a1DEa7Ae04129aBc27ce607249049f3C735");
const WRBTC = { address: getAddress("0x542fda317318ebf1d3deaf76e0b632741a7e677d"), decimals: 18 };
const USD0 = { address: getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"), decimals: 6 };
const SOLVER = getAddress("0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1");
const base = { maker: MAKER, pay: USD0, recv: WRBTC, amountIn: 50, targetOut: 0.0006, minOut: 0.00059, ttlSeconds: 300, decaySeconds: 60, now: 1_800_000_000 };

describe("buildOrder: native-out", () => {
  it("SELL USD0 → raw RBTC: the WRBTC leg to the module, one MAKE item (amount 0, leg-0 pre-fund reference, payout = maker), ORDERED (zero-capital fillable after task 31), pull", () => {
    const { order } = buildOrder({ ...base, side: "buy", nativeOut: { module: MODULE } });
    expect(order.legsOut).toHaveLength(1);
    expect(order.legsOut[0]).toMatchObject({ token: WRBTC.address, recipient: MODULE });
    expect(order.items).toHaveLength(1);
    const it0 = order.items[0]!;
    expect([it0.op, it0.module, it0.amount, it0.recipient]).toEqual([ItemOp.MAKE, MODULE, 0n, zeroAddress]);
    expect(it0.data.length).toBe(2 + 128);
    const [desc, payout] = decodeAbiParameters([{ type: "uint256" }, { type: "address" }], it0.data);
    expect(desc).toBe(forLegPreFund(0, WRBTC.address, 0));
    expect(desc).toBe((5n << 253n) | (BigInt(WRBTC.address) << 16n)); // the module test's literal
    expect(payout).toBe(zeroAddress);
    expect(Number((order.timing >> 96n) & 0xfn)).toBe(ItemPolicy.ORDERED);
    expect((order.timing >> 104n) & 1n).toBe(0n); // pull, not delta-verify
    expect(order.exclusiveFiller).toBe(zeroAddress);
    expect(nativeOutItem(MODULE, WRBTC.address)).toEqual(it0);
  });

  it("refuses a solver or a window (the module, not the maker, receives the leg)", () => {
    expect(() => buildOrder({ ...base, side: "buy", solver: SOLVER, nativeOut: { module: MODULE } })).toThrow(/pull delivery/);
    expect(() => buildOrder({ ...base, side: "buy", exclusivity: { filler: SOLVER, seconds: 60, overrideBps: 5 }, nativeOut: { module: MODULE } })).toThrow(/pull delivery/);
  });

  it("without it: the plain shape, unchanged", () => {
    const { order } = buildOrder({ ...base, side: "buy" });
    expect(order.items).toHaveLength(0);
    expect(order.legsOut[0]!.recipient).toBe(zeroAddress);
  });
});

describe("deployment config + quote", () => {
  const dep = (extra: Record<string, unknown>) =>
    parseDeployments(JSON.stringify({ 30: { settlement: "0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5", permit3: "0xabaefb5ae495Dcbce40d1e057346f31A500668a8", ...extra } }));

  it("`nativeUnwrap` is optional and strict", () => {
    expect(dep({})[30]!.nativeUnwrap).toBeUndefined();
    expect(dep({ nativeUnwrap: MODULE })[30]!.nativeUnwrap).toBe(MODULE);
    expect(dep({ nativeUnwrap: "0xnope" })[30]).toBeUndefined(); // malformed: the deployment is dropped
  });

  it("a native-out request takes only a quote priced for it (an older filler's would be the plain shape's price)", () => {
    const now = 1_800_000_000;
    const json = {
      quoteId: "q_1", chainId: 30, tokenIn: USD0.address, tokenOut: WRBTC.address, amountIn: "50000000", amountOut: "600000000000000",
      grossOut: "610000000000000", gasUnits: "400000", gasCostOut: "1", gasChargeOut: "2", gasMarginBps: "300", issuedAt: now * 1000,
      validUntil: now + 30, strategy: "route", delivery: "pull", route: { source: "oku" }, live: true,
    };
    const req = { chainId: 30, tokenIn: USD0.address, tokenOut: WRBTC.address, amountIn: 50_000_000n, delivery: "pull" as const, nativeOut: true };
    expect(() => parseQuote(json, req, now)).toThrow(/native-out/);
    expect(parseQuote({ ...json, nativeOut: true }, req, now).nativeOut).toBe(true);
    expect(() => parseQuote({ ...json, nativeOut: true }, { ...req, nativeOut: false }, now)).toThrow(/native-out/);
  });
});

const NB = getAddress("0x00000000000000000000000000000000000a7b01");

describe("buildOrder: native-out through the NativeBalance view (task 30)", () => {
  it("SELL USD0 → raw RBTC: leg 0 is the view (to the maker), DIRECT to the solver, no item, no item policy", () => {
    const { order } = buildOrder({ ...base, side: "buy", solver: SOLVER, nativeOut: { nativeBalance: NB } });
    expect(order.legsOut).toEqual([{ token: NB, start: order.legsOut[0]!.start, end: 0n, recipient: zeroAddress }]);
    expect(order.legsOut[0]!.start).toBe(590_000_000_000_000n); // minOut, 18-dec wei
    expect((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n).toBe(1n);
    expect(order.exclusiveFiller).toBe(SOLVER);
    expect(order.items).toHaveLength(0);
    expect(Number((order.timing >> 96n) & 0xfn)).toBe(ItemPolicy.ANY);
    expect(nativeBalanceMisuse(order, NB)).toBeNull(); // the book's admission rule
  });

  it("SELL USDRIF → raw RBTC: the decaying output keeps its auction on the view", () => {
    const usdrif = { address: getAddress("0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37"), decimals: 18 };
    const { order } = buildOrder({ ...base, pay: usdrif, side: "sell", solver: SOLVER, nativeOut: { nativeBalance: NB } });
    expect(order.legsOut[0]).toMatchObject({ token: NB, start: 600_000_000_000_000n, end: 590_000_000_000_000n, recipient: zeroAddress });
  });

  it("refuses pull delivery and a non-18-decimal receive token", () => {
    expect(() => buildOrder({ ...base, side: "buy", nativeOut: { nativeBalance: NB } })).toThrow(/DIRECT/);
    expect(() => buildOrder({ ...base, side: "buy", recv: USD0, pay: WRBTC, solver: SOLVER, nativeOut: { nativeBalance: NB } })).toThrow(/18-decimal/);
  });
});

describe("deployment: `nativeBalance` and the shape a market signs", () => {
  const raw = (extra: Record<string, unknown>) =>
    JSON.stringify({ 30: { settlement: "0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5", permit3: "0xabaefb5ae495Dcbce40d1e057346f31A500668a8", solver: SOLVER, ...extra } });

  it("`nativeBalance` is optional and strict", () => {
    expect(parseDeployments(raw({}))[30]!.nativeBalance).toBeUndefined();
    expect(parseDeployments(raw({ nativeBalance: NB }))[30]!.nativeBalance).toBe(NB);
    expect(parseDeployments(raw({ nativeBalance: "0xnope" }))[30]).toBeUndefined();
  });

  it("NativeBalance on a DIRECT market; the module shape otherwise (or nothing)", () => {
    const both = parseDeployments(raw({ nativeBalance: NB, nativeUnwrap: MODULE, marketSolvers: { "rsk-30-usdrif-usd0": "pull" } }))[30]!;
    expect(nativeOutFor(both, "rsk-30-wrbtc-usd0")).toEqual({ nativeBalance: NB });
    expect(nativeOutFor(both, "rsk-30-usdrif-usd0")).toEqual({ module: MODULE }); // a pull market cannot carry the view
    const nbOnly = parseDeployments(raw({ nativeBalance: NB, solver: zeroAddress }))[30]!;
    expect(nativeOutFor(nbOnly, "rsk-30-wrbtc-usd0")).toBeUndefined(); // no solver: no direct market
    expect(nativeOutFor(parseDeployments(raw({}))[30]!, "rsk-30-wrbtc-usd0")).toBeUndefined();
    expect(nativeOutFor(null, "rsk-30-wrbtc-usd0")).toBeUndefined();
  });

  it("a native request is DIRECT: the filler's quote must be direct and priced native", () => {
    const now = 1_800_000_000;
    const json = {
      quoteId: "q_2", chainId: 30, tokenIn: USD0.address, tokenOut: WRBTC.address, amountIn: "50000000", amountOut: "600000000000000",
      grossOut: "610000000000000", gasUnits: "330000", gasCostOut: "1", gasChargeOut: "2", gasMarginBps: "1000", issuedAt: now * 1000,
      validUntil: now + 30, strategy: "route", delivery: "direct", nativeOut: true, route: { source: "oku" }, live: true,
    };
    const req = { chainId: 30, tokenIn: USD0.address, tokenOut: WRBTC.address, amountIn: 50_000_000n, delivery: "direct" as const, nativeOut: true };
    expect(parseQuote(json, req, now)).toMatchObject({ delivery: "direct", nativeOut: true });
    expect(() => parseQuote({ ...json, delivery: "pull" }, req, now)).toThrow(/delivery/);
    expect(() => parseQuote({ ...json, nativeOut: false }, req, now)).toThrow(/native-out/);
  });
});

describe("book rows: a NativeBalance order shows as RBTC", () => {
  const DEP: Deployment & { nativeBalance?: Address } = { chainId: 30, settlement: "0x00000000000000000000000000000000005e771e", permit3: "0x000000000000000000000000000000000000aaaa", nativeBalance: NB };

  it("restores onto the WRBTC market, flagged native", () => {
    const { order } = buildOrder({ ...base, side: "buy", solver: SOLVER, nativeOut: { nativeBalance: NB } });
    const row = rowResolver((id) => (id === 30 ? DEP : null))(order);
    expect(row).toMatchObject({ marketId: "rsk-30-wrbtc-usd0", side: "buy", native: true });
    expect(row!.size).toBeCloseTo(0.00059, 12);
    // Without the deployment's view the leg is an unknown token: not this app's order.
    expect(rowResolver((id) => (id === 30 ? { ...DEP, nativeBalance: undefined } : null))(order)).toBeNull();
    // A plain WRBTC order is not native.
    expect(rowResolver((id) => (id === 30 ? DEP : null))(buildOrder({ ...base, side: "buy" }).order)?.native).toBeUndefined();
  });

  it("labels the wrapped side with the native coin", () => {
    expect(rowSymbols("rsk-30-wrbtc-usd0", true)).toEqual({ base: "RBTC", quote: "USD0" });
    expect(rowSymbols("rsk-30-wrbtc-usd0", false)).toEqual({ base: "WRBTC", quote: "USD0" });
    expect(rowSymbols("rsk-30-rif-wrbtc", true)).toEqual({ base: "RIF", quote: "RBTC" });
  });
});

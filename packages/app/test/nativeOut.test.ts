/**
 * NATIVE-OUT (task 28): an order that receives WRBTC can ask for raw RBTC instead — the
 * leg goes to the deployed NativeUnwrapModule, one MAKE item unwraps it in the fill.
 * The shape must be exactly what the filler accepts (beta-filler policy.ts
 * `nativeOutShape`) and the module's own tests sign.
 */
import { ItemOp, ItemPolicy, forLegPreFund } from "@1delta-x/sdk";
import { decodeAbiParameters, getAddress, zeroAddress } from "viem";
import { describe, expect, it } from "vitest";

import { parseDeployments } from "../src/config/deploymentConfig";
import { buildOrder, nativeOutItem } from "../src/lib/order";
import { parseQuote } from "../src/lib/quote";

const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const MODULE = getAddress("0xB6107a1DEa7Ae04129aBc27ce607249049f3C735");
const WRBTC = { address: getAddress("0x542fda317318ebf1d3deaf76e0b632741a7e677d"), decimals: 18 };
const USD0 = { address: getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"), decimals: 6 };
const SOLVER = getAddress("0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1");
const base = { maker: MAKER, pay: USD0, recv: WRBTC, amountIn: 50, targetOut: 0.0006, minOut: 0.00059, ttlSeconds: 300, decaySeconds: 60, now: 1_800_000_000 };

describe("buildOrder: native-out", () => {
  it("SELL USD0 → raw RBTC: the WRBTC leg to the module, one MAKE item (amount 0, leg-0 pre-fund reference, payout = maker), CANONICAL, pull", () => {
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
    expect(Number((order.timing >> 96n) & 0xfn)).toBe(ItemPolicy.CANONICAL);
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

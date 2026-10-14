/**
 * NATIVE-OUT (task 28): the route fills orders whose WRBTC leg goes to the deployed
 * NativeUnwrapModule and whose one MAKE item unwraps it for the maker — exactly that
 * shape (the app's lib/order.ts `nativeOut`), nothing looser. Quotes for it are pull,
 * route-only, + NATIVE_OUT_GAS, and bind only to native-out orders.
 */
import { forLegPreFund, ItemOp, OrderSide, withDeltaVerifyOutputs, type Order } from "@1delta-x/sdk";
import { encodeAbiParameters, getAddress, zeroAddress, type Address, type Hex } from "viem";
import { describe, expect, it } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import { nativeOutShape, plainShape } from "../src/policy";
import { parseQuoteRequest, quoteMatches, type IssuedQuote } from "../src/quote";
import { classifyRoute, NATIVE_OUT_NOT_ROUTABLE } from "../src/route";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const MAKER = getAddress("0x00000000000000000000000000000000000000bb");
const MODULE = getAddress(ROOTSTOCK.nativeUnwrap);
const WRBTC = getAddress(ROOTSTOCK.wrbtc);
const ENV = {
  PRIVATE_KEY: "0x" + "11".repeat(32),
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://localhost:8080/",
  AGGREGATOR_SOLVER: SOLVER,
};
const cfg = loadConfig(ENV);
const rc = cfg.route!;
const NU = { module: MODULE, wrapped: WRBTC };

const data = (desc: bigint, payout: Address): Hex => encodeAbiParameters([{ type: "uint256" }, { type: "address" }], [desc, payout]);

/** Maker pays 50 USD₮0 for 0.0006 WRBTC, delivered to the module and unwrapped to them. */
function nativeOrder(over: Partial<Order> = {}, item: Partial<Order["items"][number]> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.usdt0, start: 50_000_000n, end: 0n }],
    legsOut: [{ token: WRBTC, start: 6n * 10n ** 14n, end: 0n, recipient: MODULE }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n,
    items: [{ op: ItemOp.MAKE, module: MODULE, amount: 0n, recipient: zeroAddress, data: data(forLegPreFund(0, WRBTC, 0), zeroAddress), ...item }],
    validators: [], invariants: [], fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
    ...over,
  } as Order;
}

describe("the native-out shape", () => {
  it("accepted exactly: the module's MAKE, amount 0, leg-0 reference, payout maker (0x0 or explicit)", () => {
    expect(nativeOutShape(nativeOrder(), MODULE, WRBTC)).toEqual({ ok: true });
    expect(nativeOutShape(nativeOrder({}, { data: data(forLegPreFund(0, WRBTC, 0), MAKER) }), MODULE, WRBTC).ok).toBe(true);
    expect(plainShape(nativeOrder(), { nativeUnwrap: NU })).toEqual({ ok: true, nativeOut: true });
  });

  it.each([
    ["another module", {}, { module: getAddress("0x00000000000000000000000000000000000000cc") }, /NativeUnwrapModule/],
    ["a TAKE", {}, { op: ItemOp.TAKE }, /NativeUnwrapModule/],
    ["a signed amount", {}, { amount: 1n }, /amount/],
    ["a payout to a stranger", {}, { data: data(forLegPreFund(0, WRBTC, 0), getAddress("0x00000000000000000000000000000000000000dd")) }, /third party/],
    ["a wrong leg reference", {}, { data: data(forLegPreFund(1, WRBTC, 0), zeroAddress) }, /leg reference/],
    ["trailing data", {}, { data: (data(forLegPreFund(0, WRBTC, 0), zeroAddress) + "00") as Hex }, /exactly/],
    ["a leg to the maker", { legsOut: [{ token: WRBTC, start: 1n, end: 0n, recipient: zeroAddress }] }, {}, /module/],
    ["a non-WRBTC leg", { legsOut: [{ token: ROOTSTOCK.usdrif, start: 1n, end: 0n, recipient: MODULE }] }, {}, /wrapped native/],
    ["delta-verify", { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }, {}, /pull/],
  ] as const)("refuses %s", (_n, over, item, why) => {
    const v = nativeOutShape(nativeOrder(over as Partial<Order>, item as never), MODULE, WRBTC);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(why);
  });

  it("without NATIVE_UNWRAP_MODULE (or for the inventory strategy) any item is refused", () => {
    expect(plainShape(nativeOrder()).ok).toBe(false);
    expect(loadConfig({ ...ENV, NATIVE_UNWRAP_MODULE: "" }).route!.nativeUnwrap).toBeUndefined();
    expect(rc.nativeUnwrap).toBe(MODULE); // the Rootstock deployment by default
  });

  it("classifyRoute recognises it but refuses it: the deployed solver cannot fill a pre-funded MAKE (fork-proven)", () => {
    const v = classifyRoute(nativeOrder(), rc, { nativeUnwrap: NU });
    expect(v).toEqual({ ok: false, reason: NATIVE_OUT_NOT_ROUTABLE });
    expect(classifyRoute(nativeOrder(), rc).ok).toBe(false);
  });
});

describe("native-out quotes", () => {
  const body = { chainId: 30, side: "buy", tokenIn: ROOTSTOCK.usdt0, tokenOut: WRBTC, amountIn: "50000000", delivery: "auto", nativeOut: true };

  it("parse: pull (an `auto` resolves to it), direct refused, a boolean only", () => {
    const v = parseQuoteRequest(body, cfg);
    expect(v.ok && [v.req.delivery, v.req.nativeOut]).toEqual(["pull", true]);
    expect(parseQuoteRequest({ ...body, delivery: "direct" }, cfg).ok).toBe(false);
    expect(parseQuoteRequest({ ...body, nativeOut: "yes" }, cfg).ok).toBe(false);
  });

  it("a native-out quote binds only a native-out order, and a plain quote never one", () => {
    const q: IssuedQuote = { id: "q", tokenIn: ROOTSTOCK.usdt0.toLowerCase(), tokenOut: WRBTC.toLowerCase(), amountIn: "50000000", amountOut: (6n * 10n ** 14n).toString(), delivery: "pull", issuedAt: 0, validUntil: 2_000_000_000, nativeOut: true };
    const plain = nativeOrder({ legsOut: [{ token: WRBTC, start: 6n * 10n ** 14n, end: 0n, recipient: zeroAddress }], items: [] });
    expect(quoteMatches(q, nativeOrder(), 1, 30)).toBe(true);
    expect(quoteMatches(q, plain, 1, 30)).toBe(false);
    expect(quoteMatches({ ...q, nativeOut: undefined }, nativeOrder(), 1, 30)).toBe(false);
    expect(quoteMatches({ ...q, nativeOut: undefined }, plain, 1, 30)).toBe(true);
  });
});

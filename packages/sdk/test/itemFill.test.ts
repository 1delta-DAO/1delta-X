import { describe, expect, it } from "vitest";
import { encodeAbiParameters, getAddress, zeroAddress, type Address, type Hex } from "viem";

import {
  ItemOp,
  ItemPolicy,
  NO_PATCH,
  OrderSide,
  POOL_ROUTE,
  classifyItemFill,
  encodeAggregatorExecuteItemFill,
  encodePoolRoute,
  forBalance,
  forLeg,
  forLegPreFund,
  forTotal,
  withDeltaVerifyOutputs,
  withItemPolicy,
  type Item,
  type ItemFillCaps,
  type Order,
  type RoutePlan,
} from "../src";

/**
 * The fill-path classifier (task 31, docs/fill-ordering-capital-plan.md §3 / §4.4):
 * every row of the blast-radius table goes to `executeFill`, `executeItemFill` with
 * the right `lateItems`, or a reasoned skip — on the LIVE Settlement and on the
 * task-31 one.
 */
const A = (n: string): Address => getAddress(n);
const USDC = A("0x00000000000000000000000000000000000000c1");
const WETH = A("0x00000000000000000000000000000000000000e1");
const MAKER = A("0x00000000000000000000000000000000000000aa");
const MOD = A("0x00000000000000000000000000000000000000d1");
const MOD2 = A("0x00000000000000000000000000000000000000d2");
const SETTLEMENT = A("0x0000000000000000000000000000000000005e77");

const LIVE: ItemFillCaps = { nettedDeliveryFundedItems: false };
const NEXT: ItemFillCaps = { nettedDeliveryFundedItems: true, settlement: SETTLEMENT };

const word = (w: bigint, ...rest: bigint[]): Hex =>
  encodeAbiParameters([{ type: "uint256" }, ...rest.map(() => ({ type: "uint256" as const }))], [w, ...rest]);
const item = (op: ItemOp, data: Hex = "0x", over: Partial<Item> = {}): Item => ({ op, module: MOD, amount: 1n, recipient: zeroAddress, data, ...over });

function order(items: Item[], over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: USDC, start: 1_000n, end: 0n }],
    legsOut: [{ token: WETH, start: 1n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items, validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  };
}

const TAKE = () => item(ItemOp.TAKE, word(0n));
const MAKE_PULL = () => item(ItemOp.MAKE, word(123n));
const MAKE_PREFUND = () => item(ItemOp.MAKE, word(forLegPreFund(0, WETH, 0)), { amount: 0n });
const SETTLE = () => item(ItemOp.SETTLE, word(42n));
const TAKE_FOR_LEG = (over: Partial<Item> = {}) => item(ItemOp.TAKE_FOR, word(forLeg(0, 4)), over);
const TAKE_FOR_TOTAL = () => item(ItemOp.TAKE_FOR, word(forTotal(5n)));
const TAKE_FOR_BALANCE = () => item(ItemOp.TAKE_FOR, word(forBalance(WETH), 100n));

describe("classifyItemFill", () => {
  it("item-free → executeFill (direct or pull)", () => {
    expect(classifyItemFill(order([]), LIVE)).toEqual({ path: "executeFill" });
    expect(classifyItemFill(order([], { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: MOD }), LIVE)).toEqual({ path: "executeFill" });
  });

  it("DIRECT with items → skip", () => {
    const v = classifyItemFill(order([TAKE()], { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: MOD }), NEXT);
    expect(v.path === "skip" && v.reason).toMatch(/DIRECT/);
  });

  it("sell out of a position (TAKE) → early on the live Settlement", () => {
    expect(classifyItemFill(order([TAKE()]), LIVE)).toEqual({ path: "executeItemFill", lateItems: 0n, roles: [{ kind: "take", at: "early" }] });
  });

  it("swap → wallet-funded sink (pull MAKE) → late on the live Settlement", () => {
    expect(classifyItemFill(order([MAKE_PULL()]), LIVE)).toEqual({ path: "executeItemFill", lateItems: 1n, roles: [{ kind: "make-pull", at: "late" }] });
  });

  it("withdraw → swap → deposit: sources early, sinks late, mask by index", () => {
    const v = classifyItemFill(order([MAKE_PULL(), TAKE(), MAKE_PULL()]), LIVE);
    expect(v.path === "executeItemFill" && v.lateItems).toBe(0b101n);
  });

  it.each([
    ["pre-funded MAKE (swap → supply, native-out via the module)", MAKE_PREFUND, /pre-funded MAKE/],
    ["SETTLE (OCO bracket leg, NFT sale)", SETTLE, /SETTLE/],
    ["leg-reference TAKE_FOR", () => TAKE_FOR_LEG({ recipient: MAKER }), /TAKE_FOR/],
    ["literal TAKE_FOR", TAKE_FOR_TOTAL, /TAKE_FOR/],
  ] as const)("%s → skip on the live Settlement", (_n, mk, why) => {
    const v = classifyItemFill(order([mk()]), LIVE);
    expect(v.path).toBe("skip");
    expect(v.path === "skip" && v.reason).toMatch(why);
    expect(v.path === "skip" && v.reason).toMatch(/nettedDeliveryFundedItems/);
  });

  it("…and runs on the task-31 Settlement: pre-fund MAKE late, SETTLE early, TAKE_FOR by funding form", () => {
    expect(classifyItemFill(order([MAKE_PREFUND()]), NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 1n });
    expect(classifyItemFill(order([SETTLE()]), NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 0n });
    expect(classifyItemFill(order([TAKE_FOR_TOTAL()]), NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 0n, roles: [{ kind: "take-for-total", at: "early" }] });
    // Proceeds to the maker: no cycle, the composite consumes the delivery late.
    expect(classifyItemFill(order([TAKE_FOR_LEG({ recipient: MAKER })]), NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 1n, roles: [{ kind: "take-for-leg", at: "late" }] });
  });

  it("BALANCE-form TAKE_FOR → skip on every Settlement", () => {
    for (const caps of [LIVE, NEXT]) {
      const v = classifyItemFill(order([TAKE_FOR_BALANCE()]), caps);
      expect(v.path === "skip" && v.reason).toMatch(/BALANCE-form/);
    }
  });

  it("leverage at the edge: a leg-ref TAKE_FOR whose proceeds fund the input → skip, needs flash", () => {
    for (const it0 of [TAKE_FOR_LEG(), TAKE_FOR_LEG({ recipient: SETTLEMENT })]) {
      const v = classifyItemFill(order([it0]), NEXT);
      expect(v).toMatchObject({ path: "skip", needsFlash: true });
    }
    // Known proceeds in the input token: still a cycle.
    expect(classifyItemFill(order([TAKE_FOR_LEG()]), { ...NEXT, proceedsAsset: () => USDC })).toMatchObject({ path: "skip", needsFlash: true });
    // Known proceeds in a token no input leg takes (refunded to the maker): no cycle.
    expect(classifyItemFill(order([TAKE_FOR_LEG()]), { ...NEXT, proceedsAsset: () => WETH })).toMatchObject({ path: "executeItemFill", lateItems: 1n });
  });

  it("item policy against the fixed schedule (task-31 core: ORDERED/ATOMIC pull waits for non-MAKE items)", () => {
    const at = (p: ItemPolicy, items: Item[], caps = LIVE) => classifyItemFill(order(items, { timing: withItemPolicy(0n, p) }), caps);
    // CANONICAL: never — forward-only, needs capital.
    for (const items of [[TAKE()], [MAKE_PULL()]]) {
      const v = at(ItemPolicy.CANONICAL, items);
      expect(v.path === "skip" && v.reason).toMatch(/forward-only/);
    }
    // ORDERED: non-MAKE early, MAKE late, early before late in signed order.
    expect(at(ItemPolicy.ORDERED, [TAKE(), MAKE_PULL()])).toMatchObject({ path: "executeItemFill", lateItems: 2n });
    expect(at(ItemPolicy.ORDERED, [TAKE(), SETTLE(), MAKE_PREFUND()], NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 4n });
    // swap → deposit → borrow-to-wallet: the TAKE must follow the deposit yet precede the pull.
    expect(at(ItemPolicy.ORDERED, [MAKE_PULL(), TAKE()])).toMatchObject({ path: "skip", needsFlash: true });
    // A leg-reference TAKE_FOR must precede the pull but consumes the delivery — even with
    // its proceeds paid to the maker (fine under ANY).
    expect(at(ItemPolicy.ORDERED, [TAKE_FOR_LEG({ recipient: MAKER })], NEXT)).toMatchObject({ path: "skip", needsFlash: true });
    expect(at(ItemPolicy.ANY, [TAKE_FOR_LEG({ recipient: MAKER })], NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 1n });
    // A literal (wallet-funded) TAKE_FOR is a source: early under ORDERED.
    expect(at(ItemPolicy.ORDERED, [TAKE_FOR_TOTAL(), MAKE_PULL()], NEXT)).toMatchObject({ path: "executeItemFill", lateItems: 2n });
    // ATOMIC: one side only.
    expect(at(ItemPolicy.ATOMIC, [TAKE(), TAKE()])).toMatchObject({ path: "executeItemFill", lateItems: 0n });
    expect(at(ItemPolicy.ATOMIC, [MAKE_PULL(), MAKE_PULL()])).toMatchObject({ path: "executeItemFill", lateItems: 3n });
    expect(at(ItemPolicy.ATOMIC, [TAKE(), MAKE_PULL()])).toMatchObject({ path: "skip" });
    // ANY: anything acyclic.
    expect(at(ItemPolicy.ANY, [MAKE_PULL(), TAKE()])).toMatchObject({ path: "executeItemFill", lateItems: 1n });
  });

  it("an unknown op, or a TAKE_FOR without a descriptor → skip", () => {
    expect(classifyItemFill(order([item(9 as ItemOp, word(0n))]), NEXT)).toMatchObject({ path: "skip" });
    expect(classifyItemFill(order([item(ItemOp.TAKE_FOR, "0x")]), NEXT)).toMatchObject({ path: "skip" });
    // A MAKE with short data is a plain pull MAKE (no descriptor to read).
    expect(classifyItemFill(order([item(ItemOp.MAKE, "0x1234")]), LIVE)).toMatchObject({ path: "executeItemFill", lateItems: 1n });
  });
});

describe("encodeAggregatorExecuteItemFill", () => {
  const route = encodePoolRoute({ tokens: [USDC, WETH], fees: [500], venues: [0], amountIn: 1_000n, amountOut: 0n });
  const plan: RoutePlan = {
    router: POOL_ROUTE, minOut: 1n, maxPay: 1n, amountInOffset: 0n, amountOutOffset: NO_PATCH, minBumpBps: 0n,
    profitRecipient: zeroAddress, originator: zeroAddress, originatorPpm: 0, data: route.data,
  };
  const o = order([TAKE(), MAKE_PULL()]);

  it("encodes executeItemFill (selector 0x12272841) with lateItems", () => {
    const data = encodeAggregatorExecuteItemFill({ order: o, sig: "0x", fillAmount: 1_000n, plan, lateItems: 2n });
    expect(data.slice(0, 10)).toBe("0x12272841");
  });

  it("refuses what the netted path cannot honour (ItemFillUnsupported) and a mask past the items (BadItemSchedule)", () => {
    expect(() => encodeAggregatorExecuteItemFill({ order: o, sig: "0x", fillAmount: 1n, plan: { ...plan, minBumpBps: 1n }, lateItems: 0n })).toThrow(/minBumpBps/);
    expect(() => encodeAggregatorExecuteItemFill({ order: o, sig: "0x", fillAmount: 1n, plan: { ...plan, amountOutOffset: 32n }, lateItems: 0n })).toThrow(/amountOutOffset/);
    expect(() => encodeAggregatorExecuteItemFill({ order: o, sig: "0x", fillAmount: 1n, plan, lateItems: 4n })).toThrow(/lateItems/);
  });
});

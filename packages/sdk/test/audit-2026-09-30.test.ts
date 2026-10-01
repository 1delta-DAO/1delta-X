import { describe, expect, it } from "vitest";
import { getAddress, zeroAddress, type Address } from "viem";

import {
  adviseBand,
  amountAtBump,
  amendOrder,
  assertNonceSiblingsFillOnce,
  assertOrderNonce,
  bumpBps,
  bumpDistribution,
  currentAmountIn,
  currentAmountOut,
  encodeFillWithPermit,
  encodePermitBatch,
  encodePermitTake,
  exclusivityOverrideFor,
  FILL_ONCE_BIT,
  FILLER_SET_SENTINEL,
  fillAmountFromBudget,
  fillAmountsOut,
  forBalance,
  forBalanceFloorBpsRaw,
  forLeg,
  forLegPreFund,
  inputOwed,
  ocoGroup,
  ocoNonceGroup,
  OrderSide,
  packTiming,
  patchOrder,
  Permit3MessageKind,
  permit3Nonce,
  permitTakeTypedData,
  permitWitnessTypedData,
  PreFundOp,
  preFundOp,
  preFundToken,
  previewFillLocal,
  priorityOrder,
  randomOrderNonce,
  readFundingPosture,
  withDeltaVerifyOutputs,
  type ContractReader,
  type Deployment,
  type Order,
  type PermitBatch,
  type PermitTake,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

/**
 * Regression tests for the 2026-09-30 whole-tree audit, group B-sdk. Each test is
 * named `test_audit_<ID>_<what>` and asserts the SAFE end state; every one fails
 * against the pre-fix SDK (wrong number, missing throw, or missing API).
 */

const A = (n: string): Address => getAddress(n);
const MAKER = A("0x00000000000000000000000000000000000000a1");
const EXCLUSIVE = A("0x000000000000000000000000000000000000dead");
const ROUTER = A("0x0000000000000000000000000000000000000f11");
const WETH = A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2");
const USDC = A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48");
const E18 = 10n ** 18n;

const DEPLOYMENT: Deployment = {
  chainId: 1,
  settlement: A("0x00000000000000000000000000000000000000a1"),
  permit3: A("0x00000000000000000000000000000000000000b2"),
};

/** 10,000 USDC fixed in, WETH out at 4.2 → (fixed per test) to the maker. */
function sell(): Order {
  return {
    ...CANONICAL_ORDER,
    maker: MAKER,
    side: OrderSide.SELL,
    nonce: 7n,
    legsIn: [{ token: USDC, start: 10_000n * 10n ** 6n, end: 0n }],
    legsOut: [{ token: WETH, start: 42n * E18 / 10n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    exclusivityOverrideBps: 0n,
    minFillAnchor: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    priorityScale: 0n,
    pricingModule: zeroAddress,
  };
}

/** A soft-exclusive SELL for EXCLUSIVE until t = 1000, 100% premium for outsiders. */
function softExclusiveSell(): Order {
  return { ...sell(), exclusiveFiller: EXCLUSIVE, exclusivityOverrideBps: 10_000n, timing: packTiming(0, 0, 1_000) };
}

describe("CORE-FILLER-1.v2 / A-FLEX-1.v3 — budget sizing is filler-aware", () => {
  it("test_audit_CORE_FILLER_1_v2_outsider_budget_not_overspent", () => {
    const o = softExclusiveSell();
    const budget = 42n * E18 / 10n; // 4.2 WETH
    // The router is NOT the named filler: it pays the 100% premium inside the window.
    const amount = fillAmountFromBudget(o, budget, 10n, { filler: ROUTER });
    expect(amount).toBe(5_000n * 10n ** 6n); // half the order — not the whole 10,000
    const { paid } = previewFillLocal(o, amount, 0n, 10n, { filler: ROUTER });
    expect(paid[0]!).toBeLessThanOrEqual(budget);
    // Tight: one more anchor unit would overspend.
    expect(previewFillLocal(o, amount + 1n, 0n, 10n, { filler: ROUTER }).paid[0]!).toBeGreaterThan(budget);
  });

  it("test_audit_CORE_FILLER_1_v2_exclusive_and_post_window_pay_no_premium", () => {
    const o = softExclusiveSell();
    const budget = 42n * E18 / 10n;
    expect(fillAmountFromBudget(o, budget, 10n, { filler: EXCLUSIVE })).toBe(10_000n * 10n ** 6n);
    expect(fillAmountFromBudget(o, budget, 1_000n, { filler: ROUTER })).toBe(10_000n * 10n ** 6n);
  });

  it("test_audit_CORE_FILLER_1_v2_previewFillLocal_derives_the_override_from_the_filler", () => {
    const o = softExclusiveSell();
    const full = 10_000n * 10n ** 6n;
    expect(previewFillLocal(o, full, 0n, 10n, { filler: EXCLUSIVE }).paid[0]).toBe(42n * E18 / 10n);
    expect(previewFillLocal(o, full, 0n, 10n, { filler: ROUTER }).paid[0]).toBe(84n * E18 / 10n);
  });

  it("test_audit_CORE_FILLER_1_v2_exclusivityOverrideFor_mirrors_OrderGates", () => {
    const o = softExclusiveSell();
    expect(exclusivityOverrideFor(o, ROUTER, 10n)).toBe(10_000n);
    expect(exclusivityOverrideFor(o, EXCLUSIVE, 10n)).toBe(0n);
    expect(exclusivityOverrideFor(o, ROUTER, 1_000n)).toBe(0n); // window over (end is exclusive)
    // Hard window: the outsider is refused, not quoted.
    expect(() => exclusivityOverrideFor({ ...o, exclusivityOverrideBps: 0n }, ROUTER, 10n)).toThrow("NotExclusiveFiller");
    // Above 10,000 bps the settler reverts InvalidOverrideBps.
    expect(() => exclusivityOverrideFor({ ...o, exclusivityOverrideBps: 10_001n }, ROUTER, 10n)).toThrow("InvalidOverrideBps");
    // Filler SET: members are free, outsiders pay; the set must be supplied.
    const set = { ...o, exclusiveFiller: FILLER_SET_SENTINEL };
    expect(exclusivityOverrideFor(set, ROUTER, 10n, [EXCLUSIVE, ROUTER])).toBe(0n);
    expect(exclusivityOverrideFor(set, ROUTER, 10n, [EXCLUSIVE])).toBe(10_000n);
    expect(() => exclusivityOverrideFor(set, ROUTER, 10n)).toThrow("MalformedFillerSet");
    // Delta-verify: only the named filler, ever.
    const dv = { ...sell(), exclusiveFiller: EXCLUSIVE, timing: withDeltaVerifyOutputs(0n) };
    expect(() => exclusivityOverrideFor(dv, ROUTER, 5_000n)).toThrow("NotExclusiveFiller");
    expect(exclusivityOverrideFor(dv, EXCLUSIVE, 5_000n)).toBe(0n);
  });
});

describe("PRICE-1.v2 / X-ARITH-1.v4 — BUY budget converts through fillTotal", () => {
  /** BUY 1000 USDC (fixed out) for ≤ 0.5 WETH, denominated in fillTotal = 10,000 units. */
  function buyWithTotal(): Order {
    return {
      ...sell(),
      side: OrderSide.BUY,
      legsIn: [{ token: WETH, start: 4n * E18 / 10n, end: 5n * E18 / 10n }],
      legsOut: [{ token: USDC, start: 1_000n * 10n ** 6n, end: 0n, recipient: zeroAddress }],
      fillTotal: 10_000n,
    };
  }

  it("test_audit_PRICE_1_v2_buy_fillTotal_budget_is_converted", () => {
    const o = buyWithTotal();
    const budget = 250n * 10n ** 6n;
    const amount = fillAmountFromBudget(o, budget, 0n, { filler: ROUTER });
    expect(amount).toBe(2_500n); // a quarter of fillTotal — NOT 250e6 (which clamps to a full fill)
    expect(previewFillLocal(o, amount, 0n, 0n, { filler: ROUTER }).paid[0]).toBe(budget);
  });

  it("test_audit_PRICE_1_v2_buy_fillTotal_exact_after_partial_fill", () => {
    const o = { ...buyWithTotal(), fillTotal: 3n, legsOut: [{ token: USDC, start: 10n, end: 0n, recipient: zeroAddress }] };
    // prevFilled = 1 ⇒ ceil(10/3) = 4 already delivered; slices are 4 | 3 | 3.
    const amount = fillAmountFromBudget(o, 3n, 0n, { filler: ROUTER, prevFilled: 1n });
    expect(amount).toBe(1n);
    expect(previewFillLocal(o, amount, 1n, 0n, { filler: ROUTER }).paid[0]).toBe(3n);
  });

  it("test_audit_PRICE_1_v2_fill_module_orders_refused", () => {
    const o = { ...buyWithTotal(), fillModule: A("0x000000000000000000000000000000000000f111") };
    expect(() => fillAmountFromBudget(o, 1n, 0n, { filler: ROUTER })).toThrow(/fill-module/);
  });
});

describe("G-TS_FILLER-5 — SDK previews refuse what the contract views refuse", () => {
  function prio(): Order {
    return priorityOrder({ ...sell(), legsOut: [{ token: WETH, start: 5n * E18, end: 4n * E18, recipient: zeroAddress }] }, {
      priorityScale: 1_000_000_000n,
      partiallyFillable: true,
    });
  }

  it("test_audit_G_TS_FILLER_5_priority_needs_an_explicit_bid", () => {
    const o = prio();
    expect(() => currentAmountOut(o, 0n)).toThrow("PricingNeedsContext");
    expect(() => bumpBps(o, 0n)).toThrow("PricingNeedsContext");
    expect(() => fillAmountsOut(o, 1n, 0n)).toThrow("PricingNeedsContext");
    expect(() => previewFillLocal(o, 1n, 0n, 0n, { filler: ROUTER })).toThrow("PricingNeedsContext");
    expect(() => fillAmountFromBudget(o, E18, 0n, { filler: ROUTER })).toThrow("PricingNeedsContext");
    // With the bid, the tick moves toward `start`: 0.5 gwei ⇒ half the band.
    expect(currentAmountOut(o, 0n, 0n, 500_000_000n)).toEqual([45n * E18 / 10n]);
    expect(currentAmountOut(o, 0n, 0n, 0n)).toEqual([4n * E18]); // explicit zero bid = floor
  });

  it("test_audit_G_TS_FILLER_5_priority_with_gas_bump_is_refused", () => {
    const o = { ...prio(), gasBumpBps: 50n, gasPriceRef: 1n };
    expect(() => bumpBps(o, 0n, 0n, 1n)).toThrow("InvalidAuctionParams");
  });

  it("test_audit_G_TS_FILLER_5_currentAmountIn_takes_basefee_and_bid", () => {
    // BUY with a rising input and a gas bump: at basefee == gasPriceRef the bump is +5000 bps.
    const o: Order = {
      ...sell(),
      side: OrderSide.BUY,
      legsIn: [{ token: WETH, start: 1_000n, end: 2_000n }],
      legsOut: [{ token: USDC, start: 10n, end: 0n, recipient: zeroAddress }],
      gasBumpBps: 5_000n,
      gasPriceRef: 100n,
    };
    expect(currentAmountIn(o, 0n, 100n)).toEqual([1_500n]);
    expect(inputOwed(o, 0, 0n, 10n, 0n, 100n)).toBe(1_500n);
  });

  it("test_audit_G_TS_FILLER_5_previewFillLocal_mirrors_fill_reverts", () => {
    const o = sell();
    expect(() => previewFillLocal(o, 0n, 0n, 0n, { filler: ROUTER })).toThrow("ZeroFill");
    const once = { ...o, timing: FILL_ONCE_BIT };
    expect(() => previewFillLocal(once, 1n, 0n, 0n, { filler: ROUTER })).toThrow("FillOnceMustBeFull");
    expect(previewFillLocal(once, 10n ** 30n, 0n, 0n, { filler: ROUTER }).delta).toBe(10_000n * 10n ** 6n);
    // A budget that cannot cover a fill-once order sizes to 0 rather than a reverting partial.
    expect(fillAmountFromBudget(once, E18, 0n, { filler: ROUTER })).toBe(0n);
    // An out-of-range override is refused, never priced into negative amounts.
    const bad = { ...softExclusiveSell(), exclusivityOverrideBps: 20_000n };
    bad.legsIn = [{ token: USDC, start: 10_000n * 10n ** 6n, end: 20_000n * 10n ** 6n }];
    expect(() => previewFillLocal(bad, 1n, 0n, 10n, { filler: ROUTER })).toThrow("InvalidOverrideBps");
  });
});

describe("G-TS_SIGN-2 — amending a shared-nonce bracket leg keeps it in the bracket", () => {
  it("test_audit_G_TS_SIGN_2_fill_once_replacement_keeps_the_shared_nonce", async () => {
    const [tp, sl] = ocoNonceGroup([sell(), { ...sell(), legsOut: [{ ...sell().legsOut[0]!, start: E18 }] }], 42n);
    // A fresh nonce would silently take TP' out of the bracket: refused.
    expect(() => patchOrder(tp!, 43n, { minFillAnchor: 5n })).toThrow(/FILL-ONCE/);
    const tp2 = patchOrder(tp!, tp!.nonce, { minFillAnchor: 5n });
    expect(tp2.nonce).toBe(sl!.nonce); // still shares the bracket nonce
    expect((tp2.timing & FILL_ONCE_BIT) !== 0n).toBe(true);
    expect(() => assertNonceSiblingsFillOnce([tp!, tp2, sl!])).not.toThrow();
  });

  it("test_audit_G_TS_SIGN_2_explicit_opt_out_leaves_the_group", () => {
    const [tp] = ocoNonceGroup([sell(), sell()], 42n);
    expect(patchOrder(tp!, 43n, { minFillAnchor: 5n }, { leaveNonceGroup: true }).nonce).toBe(43n);
  });
});

describe("PRICE-5 — an amend never reuses the predecessor's nonce", () => {
  const MODULE = A("0x00000000000000000000000000000000000c0c00");

  it("test_audit_PRICE_5_same_nonce_replacement_refused", async () => {
    const o = sell();
    expect(() => patchOrder(o, o.nonce, { minFillAnchor: 5n })).toThrow(/FRESH nonce/);
    expect(() => patchOrder(o, 99n, { nonce: o.nonce, minFillAnchor: 5n })).toThrow(/FRESH nonce/);
    // The OcoGroupModule variant — the case where the two would share a claim slot.
    const [leg] = ocoGroup([{ ...sell(), nonce: 5n }, { ...sell(), nonce: 6n }], MODULE, 77n);
    expect(() => patchOrder(leg!, 5n, { minFillAnchor: 5n })).toThrow(/FRESH nonce/);
    const signer = { signTypedData: async () => "0x" as `0x${string}` };
    await expect(amendOrder(signer, leg!, 5n, { minFillAnchor: 5n }, DEPLOYMENT)).rejects.toThrow(/FRESH nonce/);
    // A fresh nonce still works and re-homes the claim item.
    expect(patchOrder(leg!, 8n, { minFillAnchor: 5n }).nonce).toBe(8n);
  });
});

describe("G-TS_SIGN-8 — shared nonce is an OR only with the fill-once bit", () => {
  it("test_audit_G_TS_SIGN_8_unflagged_shared_nonce_pair_is_flagged", () => {
    const a = sell();
    const b = { ...sell(), legsOut: [{ ...sell().legsOut[0]!, start: E18 }] };
    expect(() => assertNonceSiblingsFillOnce([a, b])).toThrow(/fill-once/);
    expect(() => assertNonceSiblingsFillOnce(ocoNonceGroup([a, b], a.nonce))).not.toThrow();
    // Distinct nonces, or distinct makers, are not a group.
    expect(() => assertNonceSiblingsFillOnce([a, { ...b, nonce: 8n }])).not.toThrow();
    expect(() => assertNonceSiblingsFillOnce([a, { ...b, maker: ROUTER }])).not.toThrow();
  });
});

describe("G-TS_SIGN-10 — band advice respects the end == 0 fixed-leg sentinel", () => {
  it("test_audit_G_TS_SIGN_10_fixed_leg_is_not_a_band_to_zero", () => {
    const fixed = { start: 1_000_000_000n, end: 0n };
    expect(amountAtBump(fixed, 500)).toBe(1_000_000_000n);
    expect(amountAtBump({ ...fixed, rising: true }, 500)).toBe(1_000_000_000n);
    const d = bumpDistribution([100, 200, 300, 400, 500]);
    expect(adviseBand(fixed, d)).toBeNull(); // nothing to tighten — never "raise the floor" to 950
    // A real band is unaffected.
    expect(adviseBand({ start: 2_000n, end: 1_000n }, d, { coverage: 1 })!.suggestedEnd).toBe(1_950n);
  });
});

describe("G-BYTE_MAP-2 — pre-fund descriptors carry the module op", () => {
  it("test_audit_G_BYTE_MAP_2_repay_op_is_encoded", () => {
    const repay = forLegPreFund(1, WETH, PreFundOp.AaveV3.Repay);
    expect(preFundOp(repay)).toBe(1);
    expect((repay >> 244n) & 0xffn).toBe(1n);
    // Nothing the settler reads moves.
    expect(repay & 0xffffn).toBe(1n);
    expect(preFundToken(repay)).toBe(WETH.toLowerCase());
    expect(repay >> 253n).toBe(5n);
    expect(preFundOp(forLegPreFund(0, WETH, PreFundOp.MorphoBlue.Repay))).toBe(2);
  });

  it("test_audit_G_BYTE_MAP_2_op_is_mandatory_and_range_checked", () => {
    expect(() => (forLegPreFund as (i: number, t: `0x${string}`) => bigint)(1, WETH)).toThrow(/op/);
    expect(() => forLegPreFund(1, WETH, 256)).toThrow(/op/);
    expect(() => forLegPreFund(1, WETH, -1)).toThrow(/op/);
  });

  it("test_audit_G_BYTE_MAP_2_pull_and_balance_descriptors_carry_op", () => {
    const open = forLeg(2, PreFundOp.EulerV2Operator.Open);
    expect(preFundOp(open)).toBe(4);
    expect(open & 0xffffn).toBe(2n);
    const bal = forBalance(WETH, 8_000, PreFundOp.DolomiteOperator.Open);
    expect(preFundOp(bal)).toBe(6);
    expect(forBalanceFloorBpsRaw(bal)).toBe(8_000);
    expect(forLeg(2)).toBe((1n << 255n) | 2n); // default op 0 unchanged
  });
});

describe("G-TS_SIGN-11 — order nonces stay below 2^255", () => {
  it("test_audit_G_TS_SIGN_11_randomOrderNonce_is_always_legal", () => {
    for (let i = 0; i < 512; i++) {
      const n = randomOrderNonce();
      expect(n < 1n << 255n).toBe(true);
      expect(assertOrderNonce(n)).toBe(n);
    }
  });
});

describe("G-TS_SIGN-12 — the Permit3 nonce kind is asserted at signing and encoding", () => {
  const takeNonce = permit3Nonce(Permit3MessageKind.Take, 7n);
  const batchLiteral: PermitBatch = { tokens: [], takers: [], nonce: takeNonce, deadline: 1n };
  const takeLiteral: PermitTake = { module: ROUTER, ref: `0x${"00".repeat(32)}`, amount: 1n, nonce: 0n, deadline: 1n };
  const SIG = `0x${"11".repeat(65)}` as const;

  it("test_audit_G_TS_SIGN_12_object_literals_cannot_bypass_the_builder", () => {
    expect(() => permitWitnessTypedData(batchLiteral, sell(), DEPLOYMENT)).toThrow(/namespaced/);
    expect(() => encodeFillWithPermit(sell(), batchLiteral, SIG, 1n)).toThrow(/namespaced/);
    expect(() => encodePermitBatch(MAKER, batchLiteral, SIG)).toThrow(/namespaced/);
    expect(() => permitTakeTypedData(takeLiteral, ROUTER, DEPLOYMENT)).toThrow(/namespaced/);
    expect(() => encodePermitTake(takeLiteral, MAKER, MAKER, "0x", SIG)).toThrow(/namespaced/);
    // Correctly namespaced literals still pass.
    expect(() => permitWitnessTypedData({ ...batchLiteral, nonce: 3n }, sell(), DEPLOYMENT)).not.toThrow();
    expect(() => permitTakeTypedData({ ...takeLiteral, nonce: takeNonce }, ROUTER, DEPLOYMENT)).not.toThrow();
  });
});

describe("G-TS_SIGN-13 — funding posture honours per-token strict mode", () => {
  it("test_audit_G_TS_SIGN_13_per_token_strict_is_not_reported_as_exposed", async () => {
    // Payer: no global strict mode, per-token strict on THIS token, a direct
    // approval, and no Permit3 grant. The fallback cannot fund a pull.
    const reader: ContractReader = {
      async readContract({ functionName }) {
        switch (functionName) {
          case "tokenAllowance":
            return [0n, 0];
          case "allowance":
            return 10n ** 30n;
          case "strictMode":
            return false;
          case "strictModeToken":
          case "isStrict":
            return true;
          default:
            throw new Error(`unexpected read ${functionName}`);
        }
      },
    };
    const p = await readFundingPosture(reader, { permit3: DEPLOYMENT.permit3, token: WETH, owner: MAKER, spender: ROUTER });
    expect(p.strictMode).toBe(true);
    expect(p.fallbackIsLoadBearing).toBe(false);
  });
});

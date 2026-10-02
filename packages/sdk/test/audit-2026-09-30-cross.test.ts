import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { decodeAbiParameters, decodeFunctionData, getAddress, zeroAddress, type Address, type Hex } from "viem";

import {
  BalanceMode,
  FLASH_SOLVER_ABI,
  ItemOp,
  MULTI_INPUT_SOLVER_ABI,
  MULTI_OUTPUT_SOLVER_ABI,
  OrderSide,
  PERMIT3_ABI,
  SETTLEMENT_ABI,
  SETTLEMENT_LENS_ABI,
  aaveIsolationWarning,
  assertBlockClockHeadroom,
  assertLzSponsorshipSafe,
  assertSweepReceipts,
  buildCancelGaslessOrder,
  buildRevokeAll,
  clockBump,
  cometAllowTail,
  decodeMode,
  effectiveQuotedBump,
  encodeBatchFill,
  encodeChainlinkThresholdData,
  encodeExecuteFillMultiInput,
  encodeExecuteFillMultiOutput,
  encodeExecuteFillSingle,
  encodeFillUpTo,
  encodeFillWithPermitTake,
  encodeMode,
  encodeTickFloorData,
  evcPermitTail,
  evcPermitTypedData,
  exactlyRepayTotalFor,
  fillerListingWarnings,
  findSharedBalanceLedgers,
  morphoAuthTail,
  needsBumpFloor,
  overrideHasCarrier,
  packOrder,
  packTiming,
  Permit3MessageKind,
  permit3Nonce,
  quoteDigest,
  randomOrderNonce,
  signOrder,
  nativeInOrder,
  encodeUsdrifInventoryFill,
  USDRIF_INVENTORY_SOLVER_ABI,
  encodeSettleFromNative,
  NATIVE_SETTLER_ABI,
  unpackTiming,
  type Order,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

/**
 * 2026-09-30 audit, cross-component remediation (SDK side). Each test is named
 * `test_audit_<ID>_<what>` and asserts the SAFE end state; each fails against the
 * pre-fix SDK (a missing guard, a wrong answer, or a missing API).
 */

const A = (n: string): Address => getAddress(n);
const MAKER = A("0x00000000000000000000000000000000000000a1");
const SIG = ("0x" + "11".repeat(64) + "1b") as Hex;
const T1 = A("0x00000000000000000000000000000000000000aa");
const T2 = A("0x00000000000000000000000000000000000000bb");
const SETTLEMENT = A("0x0000000000000000000000000000000000005e77");
const PERMIT3 = A("0x000000000000000000000000000000000000003a");
const maker = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

function plain(over: Partial<Order> = {}): Order {
  return {
    ...CANONICAL_ORDER,
    maker: MAKER,
    side: OrderSide.SELL,
    legsIn: [{ token: T1, start: 1_000n, end: 0n }],
    legsOut: [{ token: T2, start: 2_000n, end: 1_000n, recipient: zeroAddress }],
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
    ...over,
  };
}

describe("CORE-FILL-1 — amount-aware carrier mirror", () => {
  it("test_audit_CORE_FILL_1_zeroPlaceholderLegsCarryNothing", () => {
    // BUY whose only input is a zero placeholder: no carrier.
    const buy = plain({ side: OrderSide.BUY, legsIn: [{ token: T1, start: 0n, end: 0n }] });
    buy.legsOut = [{ token: T2, start: 2_000n, end: 0n, recipient: zeroAddress }];
    expect(overrideHasCarrier(buy)).toBe(false);
    // SELL whose only maker-addressed output is start == 0: no carrier.
    expect(overrideHasCarrier(plain({ legsOut: [{ token: T2, start: 0n, end: 0n, recipient: zeroAddress }] }))).toBe(
      false,
    );
    // Controls: a real BUY input and a real maker output still carry.
    expect(overrideHasCarrier({ ...buy, legsIn: [{ token: T1, start: 5n, end: 0n }] })).toBe(true);
    expect(overrideHasCarrier(plain())).toBe(true);
  });
});

describe("PERIPH-1.v1/v3/v4 — the floor is required and reachable on every entry", () => {
  it("test_audit_PERIPH_1_v1_encodeFillUpToRequiresExplicitFloor", () => {
    expect(() =>
      encodeFillUpTo({ order: plain(), sig: SIG, fillAmount: 1n } as unknown as Parameters<typeof encodeFillUpTo>[0]),
    ).toThrow(/minBumpBps is required/);
    const data = encodeFillUpTo({ order: plain(), sig: SIG, fillAmount: 1n, minBumpBps: 4_200n });
    expect((decodeFunctionData({ abi: SETTLEMENT_ABI, data }).args as readonly unknown[])[4]).toBe(4_200n);
  });

  it("test_audit_PERIPH_1_v3_batchFillAndPermitTakeEncodersCarryFloors", () => {
    const o = plain();
    const b = decodeFunctionData({
      abi: SETTLEMENT_ABI,
      data: encodeBatchFill({ orders: [o, o], sigs: [SIG, SIG], fillAmounts: [1n, 2n], minBumpBps: [7n, 9n] }),
    });
    expect(b.functionName).toBe("batchFill");
    expect((b.args as readonly unknown[]).length).toBe(6);
    expect((b.args as readonly unknown[])[4]).toEqual([7n, 9n]);
    expect((b.args as readonly unknown[])[5]).toEqual(["0x", "0x"]);
    // Legacy 4-arg form still reachable.
    const legacy = decodeFunctionData({
      abi: SETTLEMENT_ABI,
      data: encodeBatchFill({ orders: [o], sigs: [SIG], fillAmounts: [1n] }),
    });
    expect((legacy.args as readonly unknown[]).length).toBe(4);
    expect(() => encodeBatchFill({ orders: [o], sigs: [SIG], fillAmounts: [1n], minBumpBps: [1n, 2n] })).toThrow(
      /LengthMismatch/,
    );

    const permit = {
      module: T1,
      ref: `0x${"00".repeat(32)}` as Hex,
      amount: 5n,
      nonce: permit3Nonce(Permit3MessageKind.Take, 3n),
      deadline: 9n,
    };
    const p = decodeFunctionData({
      abi: SETTLEMENT_ABI,
      data: encodeFillWithPermitTake({ order: o, permit, sig: SIG, fillAmount: 1n, minBumpBps: 11n }),
    });
    expect(p.functionName).toBe("fillWithPermitTake");
    expect((p.args as readonly unknown[])[4]).toBe(11n);
    // A batch-kind nonce is refused for a take.
    expect(() =>
      encodeFillWithPermitTake({ order: o, permit: { ...permit, nonce: 3n }, sig: SIG, fillAmount: 1n, minBumpBps: 0n }),
    ).toThrow();
  });

  it("test_audit_PERIPH_1_v3_lensAbiExposesFloorAndPinnedSurfaces", () => {
    const names = SETTLEMENT_LENS_ABI.map((f) => f.name);
    for (const n of ["bumpFloorAdvised", "pinnedBump", "previewFillInFlightPinned", "fillState", "CHECKS"]) {
      expect(names).toContain(n);
    }
    const settle = SETTLEMENT_ABI.map((f) => f.name);
    expect(settle).toContain("PERMIT3");
    expect(settle).toContain("minValidNonce");
  });

  it("test_audit_PERIPH_1_v4_needsBumpFloorNamesEveryMover", () => {
    expect(needsBumpFloor(plain())).toBeNull();
    expect(needsBumpFloor(plain({ pricingModule: T1 }))).toBe("price module");
    expect(needsBumpFloor(plain({ timing: 1n << 103n }))).toBe("priority auction");
    expect(needsBumpFloor(plain({ gasBumpBps: 5n }))).toBe("gas bump");
    expect(
      needsBumpFloor(plain({ curve: [{ timeDelta: 0, bumpBps: 5_000 }, { timeDelta: 10, bumpBps: 1_000 }] })),
    ).toBe("descending curve segment");
    expect(needsBumpFloor(plain({ curve: [{ timeDelta: 0, bumpBps: 1_000 }, { timeDelta: 10, bumpBps: 5_000 }] }))).toBe(
      null,
    );
  });
});

describe("SDK-FLASHOPTS — FlashOpts overloads", () => {
  it("test_audit_SDK_FLASHOPTS_overloadSelectedOnlyWithOpts", () => {
    const base = { flashSource: T1, flashAmount: 1n, order: plain(), sig: SIG, fillAmountIn: 1n };
    const without = encodeExecuteFillSingle({ ...base, dexFee: 500, minSwapOut: 0n });
    const withOpts = encodeExecuteFillSingle({ ...base, dexFee: 500, minSwapOut: 0n, opts: { recipient: T2, takerData: "0xab" } });
    expect(without.slice(0, 10)).not.toBe(withOpts.slice(0, 10));
    const d = decodeFunctionData({ abi: FLASH_SOLVER_ABI, data: withOpts });
    expect((d.args as readonly unknown[])[7]).toEqual({ recipient: T2, takerData: "0xab" });
    const m = decodeFunctionData({
      abi: MULTI_INPUT_SOLVER_ABI,
      data: encodeExecuteFillMultiInput({ ...base, dexFees: [500], minSwapOuts: [0n], opts: {} }),
    });
    expect((m.args as readonly unknown[]).length).toBe(8);
    const o = decodeFunctionData({
      abi: MULTI_OUTPUT_SOLVER_ABI,
      data: encodeExecuteFillMultiOutput({ order: plain(), sig: SIG, fillAmountIn: 1n, legs: [], opts: { takerData: "0x01" } }),
    });
    expect((o.args as readonly unknown[]).length).toBe(5);
  });
});

describe("G-TS_SIGN-3 — randomOrderNonce(minValid)", () => {
  it("test_audit_G_TS_SIGN_3_randomNonceRespectsWatermark", () => {
    const floor = (1n << 255n) - 10n;
    for (let i = 0; i < 64; i++) {
      const n = randomOrderNonce(floor);
      expect(n >= floor && n < 1n << 255n).toBe(true);
    }
    expect(() => randomOrderNonce(1n << 255n)).toThrow();
  });
});

describe("CORE-FILL-3 — block-clock range", () => {
  it("test_audit_CORE_FILL_3_blockClockedOrderRefusedNearUint32Limit", async () => {
    const o = plain({ timing: 1n << 102n });
    expect(() => assertBlockClockHeadroom(o, (1n << 32n) - 100n)).toThrow(/block-clock limit/);
    expect(() => assertBlockClockHeadroom(o, 20_000_000n)).not.toThrow();
    // Timestamp-clocked orders are unaffected.
    expect(() => assertBlockClockHeadroom(plain(), (1n << 32n) + 5n)).not.toThrow();
    const d = { chainId: 31, settlement: SETTLEMENT, permit3: PERMIT3 };
    await expect(signOrder(maker, { ...o, maker: maker.address }, d)).rejects.toThrow(/headBlock/);
    await expect(signOrder(maker, { ...o, maker: maker.address }, d, { headBlock: (1n << 32n) - 1n })).rejects.toThrow();
    await expect(signOrder(maker, { ...o, maker: maker.address }, d, { headBlock: 1_000n })).resolves.toMatch(/^0x/);
  });
});

describe("VAL-1.v2 — packOrder mirrors the lens consideration rule", () => {
  const inv = [{ target: T1, data: "0x01" as Hex }];
  it("test_audit_VAL_1_invariantOnlyPurchaseNeedsLifelongHardFiller", () => {
    const open = plain({ legsOut: [], invariants: inv });
    expect(() => packOrder(open)).toThrow(/invariant-only consideration/);
    // SETTLE items are not consideration either.
    const settle = plain({
      invariants: inv,
      items: [{ op: ItemOp.SETTLE, module: T1, amount: 1n, recipient: zeroAddress, data: "0x" }],
    });
    expect(() => packOrder(settle)).toThrow(/invariant-only consideration/);
    // Soft window → refused; hard lifelong window → admitted.
    const ex = A("0x000000000000000000000000000000000000beef");
    const life = Number(open.expiry);
    expect(() =>
      packOrder({ ...open, exclusiveFiller: ex, exclusivityOverrideBps: 5n, timing: packTiming(0, 0, life) }),
    ).toThrow();
    expect(() => packOrder({ ...open, exclusiveFiller: ex, timing: packTiming(0, 0, life - 1) })).toThrow();
    expect(() => packOrder({ ...open, exclusiveFiller: ex, timing: packTiming(0, 0, life) })).not.toThrow();
    // A position item is consideration: unaffected.
    expect(() =>
      packOrder({ ...open, items: [{ op: ItemOp.MAKE, module: T1, amount: 1n, recipient: zeroAddress, data: "0x" }] }),
    ).not.toThrow();
  });
});

describe("CENSUS-A-3 / L-CMT-3 / L-ML-9 — revocation that actually revokes", () => {
  it("test_audit_CENSUS_A_3_revokeAllRequiresAndBurnsOutstandingPermitNonces", () => {
    expect(() => buildRevokeAll({ permit3: PERMIT3 } as unknown as Parameters<typeof buildRevokeAll>[0])).toThrow(
      /outstandingPermitNonces is required/,
    );
    const n1 = permit3Nonce(Permit3MessageKind.Batch, 5n);
    const n2 = permit3Nonce(Permit3MessageKind.Batch, 6n); // same word as n1
    const calls = buildRevokeAll({ permit3: PERMIT3, outstandingPermitNonces: [n1, n2] });
    expect(calls).toHaveLength(1);
    const d = decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data });
    expect(d.functionName).toBe("lockdownAll");
    const [, , words, masks] = d.args as readonly [unknown, unknown, bigint[], bigint[]];
    expect(words).toEqual([n1 >> 8n]);
    expect(masks).toEqual([(1n << (n1 & 0xffn)) | (1n << (n2 & 0xffn))]);
  });

  it("test_audit_CENSUS_A_3_gaslessCancelAlsoBurnsTheWitnessNonce", () => {
    const nonce = permit3Nonce(Permit3MessageKind.Batch, 300n);
    const [cancel, burn] = buildCancelGaslessOrder({ settlement: SETTLEMENT, permit3: PERMIT3, order: plain(), permitNonce: nonce });
    expect(cancel!.to).toBe(SETTLEMENT);
    expect(decodeFunctionData({ abi: SETTLEMENT_ABI, data: cancel!.data }).functionName).toBe("cancelOrder");
    expect(burn!.to).toBe(PERMIT3);
    const d = decodeFunctionData({ abi: PERMIT3_ABI, data: burn!.data });
    expect(d.functionName).toBe("invalidateUnorderedNonces");
    expect(d.args).toEqual([nonce >> 8n, 1n << (nonce & 0xffn)]);
  });

  it("test_audit_L_CMT_3_signedVenueRevokesConsumeTheNonce", () => {
    const comet = A("0x000000000000000000000000000000000000c0e7");
    const morpho = A("0x000000000000000000000000000000000000b10e");
    const calls = buildRevokeAll({
      permit3: PERMIT3,
      outstandingPermitNonces: [],
      signedVenueRevokes: [
        { kind: "comet", comet, owner: MAKER, manager: T1, nonce: 4n, expiry: 99n, sig: SIG },
        { kind: "morpho", morpho, authorizer: MAKER, authorized: T2, nonce: 8n, deadline: 99n, sig: SIG },
      ],
    });
    expect(calls).toHaveLength(2);
    expect(calls[0]!.to).toBe(comet);
    expect(calls[0]!.data.slice(0, 10)).toBe("0xbb24d994"); // allowBySig(address,address,bool,uint256,uint256,uint8,bytes32,bytes32)
    const [, , isAllowed, nonce] = decodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "bool" }, { type: "uint256" }],
      `0x${calls[0]!.data.slice(10, 10 + 64 * 4)}`,
    );
    expect(isAllowed).toBe(false);
    expect(nonce).toBe(4n);
    expect(calls[1]!.to).toBe(morpho);
    const [, , isAuth, mNonce] = decodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "bool" }, { type: "uint256" }],
      `0x${calls[1]!.data.slice(10, 10 + 64 * 4)}`,
    );
    expect(isAuth).toBe(false);
    expect(mNonce).toBe(8n);
  });

  it("test_audit_L_CMT_3_inDataGrantsMayNotOutliveTheOrder", () => {
    expect(() => cometAllowTail({ nonce: 0n, expiry: 101n, sig: SIG, orderExpiry: 100n })).toThrow(/expiry/);
    expect(() => morphoAuthTail({ nonce: 0n, deadline: 101n, sig: SIG, orderExpiry: 100n })).toThrow(/deadline/);
    expect((cometAllowTail({ nonce: 0n, expiry: 100n, sig: SIG, orderExpiry: 100n }).length - 2) / 2).toBe(160);
    expect((morphoAuthTail({ nonce: 0n, deadline: 100n, sig: SIG, orderExpiry: 100n }).length - 2) / 2).toBe(160);
  });
});

describe("L-ED-1 — EVC permit builder binds the module", () => {
  it("test_audit_L_ED_1_evcPermitSenderMustBeTheModule", () => {
    const base = {
      evc: T1,
      chainId: 1,
      signer: MAKER,
      nonceNamespace: 1n,
      nonce: 0n,
      deadline: 10n,
      data: "0x" as Hex,
    };
    expect(() => evcPermitTypedData({ ...base, sender: zeroAddress })).toThrow(/never address\(0\)/);
    const td = evcPermitTypedData({ ...base, sender: T2 });
    expect(td.message.sender).toBe(T2);
    expect(td.domain.name).toBe("Ethereum Vault Connector");
    const permit = { nonceNamespace: 1n, nonce: 0n, deadline: 10n, evcData: "0x12" as Hex, sig: SIG };
    expect(() => evcPermitTail([permit], 9n)).toThrow(/deadline/);
    const [decoded] = decodeAbiParameters(
      [
        {
          type: "tuple[]",
          components: [
            { name: "nonceNamespace", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
            { name: "evcData", type: "bytes" },
            { name: "sig", type: "bytes" },
          ],
        },
      ],
      evcPermitTail([permit], 10n),
    );
    expect(decoded[0]!.evcData).toBe("0x12");
  });
});

describe("PRICE-8 — sequencer pair on the Chainlink validators", () => {
  it("test_audit_PRICE_8_sequencerPairAppendedAfterHeadWords", () => {
    const seq = { uptimeFeed: T2, gracePeriod: 3_600n };
    const head3 = encodeChainlinkThresholdData(T1, 100n, 60n);
    const with3 = encodeChainlinkThresholdData(T1, 100n, 60n, seq);
    expect((with3.length - 2) / 64).toBe(5);
    expect(with3.startsWith(head3)).toBe(true);
    const p = { dIn: 18, dOut: 6, dFeed: 8, tolBps: 0 };
    const with4 = encodeTickFloorData(T1, 60n, p, seq);
    expect((with4.length - 2) / 64).toBe(6);
    const [, , , , feed, grace] = decodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }],
      with4,
    );
    expect(feed).toBe(T2);
    expect(grace).toBe(3_600n);
  });
});

describe("G-BYTE_MAP-4 — tagged BalanceMode word", () => {
  it("test_audit_G_BYTE_MAP_4_encodeModeIsTagged", () => {
    expect(encodeMode(BalanceMode.Exact)).toBe(0n);
    expect(encodeMode(BalanceMode.Full)).toBe(0xb0de0001n);
    expect(decodeMode(0xb0de0001n)).toBe(BalanceMode.Full);
    expect(() => decodeMode(1n)).toThrow(/InvalidModeWord/);
  });
});

describe("X-TOKENS-2 — shared balance ledgers", () => {
  it("test_audit_X_TOKENS_2_doubleEntryPairFlagged", async () => {
    const proxyA = A("0x00000000000000000000000000000000000000d1");
    const proxyB = A("0x00000000000000000000000000000000000000d2"); // same ledger as A
    const other = A("0x00000000000000000000000000000000000000d3");
    const ledger: Record<string, bigint> = { h1: 5n, h2: 7n };
    const bal = async (t: Address, h: Address) => {
      const key = h.endsWith("1") ? "h1" : "h2";
      if (t === other) return key === "h1" ? 5n : 9n;
      return ledger[key]!;
    };
    const pairs = await findSharedBalanceLedgers([proxyA, proxyB, other], [A("0x0000000000000000000000000000000000000001"), A("0x0000000000000000000000000000000000000002")], bal);
    expect(pairs).toEqual([[proxyA, proxyB]]);
  });
});

describe("assorted preflight helpers", () => {
  it("test_audit_L_AAVE_3_isolatedCollateralOnPre37PoolWarned", () => {
    expect(aaveIsolationWarning({ debtCeiling: 1n, poolAtLeast37: false, alreadyCollateral: false })).toMatch(/isolation/);
    expect(aaveIsolationWarning({ debtCeiling: 1n, poolAtLeast37: true, alreadyCollateral: false })).toBeNull();
    expect(aaveIsolationWarning({ debtCeiling: 1n, poolAtLeast37: false, alreadyCollateral: true })).toBeNull();
    expect(aaveIsolationWarning({ debtCeiling: 0n, poolAtLeast37: false, alreadyCollateral: false })).toBeNull();
  });

  it("test_audit_L_FSE_2_exactlyTotalIsTheLegFloor", () => {
    expect(exactlyRepayTotalFor(plain(), 0)).toBe(1_000n); // decaying: its end
    expect(exactlyRepayTotalFor(plain({ legsOut: [{ token: T2, start: 7n, end: 0n, recipient: zeroAddress }] }), 0)).toBe(7n);
  });

  it("test_audit_X_DIFF_REST_3_sponsoredSendNeedsLifelongHardSponsorFullFill", () => {
    const sponsor = A("0x000000000000000000000000000000000000beef");
    const ok = plain({ exclusiveFiller: sponsor, minFillAnchor: 1_000n, timing: packTiming(0, 0, Number(plain().expiry)) });
    expect(() => assertLzSponsorshipSafe(ok, sponsor)).not.toThrow();
    expect(() => assertLzSponsorshipSafe({ ...ok, exclusiveFiller: T1 }, sponsor)).toThrow(/exclusiveFiller/);
    expect(() => assertLzSponsorshipSafe({ ...ok, exclusivityOverrideBps: 1n }, sponsor)).toThrow(/HARD/);
    expect(() => assertLzSponsorshipSafe({ ...ok, minFillAnchor: 1n }, sponsor)).toThrow(/full-fill/);
    expect(() => assertLzSponsorshipSafe({ ...ok, timing: packTiming(0, 0, 5) }, sponsor)).toThrow(/whole life/);
  });

  it("test_audit_VAL_5_contractFillerListingWarned", () => {
    const gated = A("0x00000000000000000000000000000000000000ee");
    const w = fillerListingWarnings(
      [
        { address: T1, hasCode: true },
        { address: T2, hasCode: false },
        { address: gated, hasCode: true },
      ],
      [gated],
    );
    expect(w).toHaveLength(1);
    expect(w[0]).toContain(T1);
  });

  it("test_audit_SWEEP_FILLER_WRAPPER_shortSweepThrows", () => {
    const before = new Map([[T1.toLowerCase(), 10n]]);
    expect(() => assertSweepReceipts(before, new Map([[T1.toLowerCase(), 14n]]), new Map([[T1, 5n]]))).toThrow(/quoted/);
    expect(() => assertSweepReceipts(before, new Map([[T1.toLowerCase(), 15n]]), new Map([[T1, 5n]]))).not.toThrow();
  });
});

describe("QUOTE-TOOLING — prevFilled-bound quotes and the effective bump", () => {
  it("test_audit_QUOTE_TOOLING_digestBindsPrevFilledAndEffectiveBumpIsMin", () => {
    const binding = { module: T1, chainId: 31 };
    const q = { orderHash: `0x${"11".repeat(32)}` as Hex, filler: T2, bumpBps: 3_000, deadline: 9n, prevFilled: 0n };
    expect(quoteDigest(q, binding)).not.toBe(quoteDigest({ ...q, prevFilled: 5n }, binding));
    const timing = packTiming(100, 1_000, 0);
    expect(clockBump(timing, 600n)).toBe(5_000);
    expect(effectiveQuotedBump(3_000, timing, 600n)).toBe(3_000);
    expect(effectiveQuotedBump(9_000, timing, 600n)).toBe(5_000);
    expect(effectiveQuotedBump(null, timing, 600n)).toBe(0); // unquoted: no concession
  });
});

describe("PERIPH-9 — native-in builder binds the NativeSettler", () => {
  it("test_audit_PERIPH_9_nativeInOrderIsHardExclusiveForLife", () => {
    const settler = A("0x00000000000000000000000000000000000005e1");
    const weth = A("0x00000000000000000000000000000000000000e7");
    const base = plain({ exclusiveFiller: T1, exclusivityOverrideBps: 25n, timing: packTiming(10, 20, 5) });
    const o = nativeInOrder(base, { nativeSettler: settler, weth, amountIn: 7n });
    expect(o.exclusiveFiller).toBe(settler);
    expect(o.exclusivityOverrideBps).toBe(0n);
    expect(BigInt(unpackTiming(o.timing).exclusivityEndTime)).toBe(o.expiry);
    expect(unpackTiming(o.timing).decayStartTime).toBe(10);
    expect(o.legsIn).toEqual([{ token: weth, start: 7n, end: 0n }]);
    const data = encodeSettleFromNative({ order: o, sig: SIG, fillAmount: 7n, dexTarget: T2, dexCallData: "0x" });
    expect(decodeFunctionData({ abi: NATIVE_SETTLER_ABI, data }).functionName).toBe("settleFromNative");
    expect(() => nativeInOrder({ ...base, legsOut: [] }, { nativeSettler: settler, weth, amountIn: 1n })).toThrow();
  });
});

describe("OPS-USDRIF-MAXSPENT — operator encoders carry the price bound", () => {
  it("test_audit_OPS_USDRIF_MAXSPENT_encodersRequireMaxSpent", () => {
    const f = decodeFunctionData({
      abi: USDRIF_INVENTORY_SOLVER_ABI,
      data: encodeUsdrifInventoryFill({ order: plain(), sig: SIG, fillAmountIn: 5n, maxSpent: 9n }),
    });
    expect(f.functionName).toBe("executeFill");
    expect((f.args as readonly unknown[])[3]).toBe(9n);
    const r = decodeFunctionData({
      abi: USDRIF_INVENTORY_SOLVER_ABI,
      data: encodeUsdrifInventoryFill({ order: plain(), sig: SIG, fillAmountIn: 5n, maxSpent: 9n, qACmin: 1n }),
    });
    expect(r.functionName).toBe("executeFillAndRedeem");
    expect(() =>
      encodeUsdrifInventoryFill({ order: plain(), sig: SIG, fillAmountIn: 5n } as unknown as Parameters<typeof encodeUsdrifInventoryFill>[0]),
    ).toThrow(/maxSpent/);
  });
});

import { describe, expect, it } from "vitest";

import { CANONICAL_ORDER } from "./canonicalOrder";
import {
  FILL_ONCE_BIT,
  isFillOnce,
  isPriorityAuction,
  lintPriorityOrder,
  packOrder,
  packTiming,
  priorityOrder,
  timingFlags,
  withBlockClock,
  withDeltaVerifyOutputs,
  withPriorityAuction,
  type Order,
} from "../src/index";

const SCALE = 2_000_000_000n; // 2 gwei buys a full bump
const BASELINE = 1_000_000n;
const ANCHOR = 2_000_000_000n;

/**
 * A minimal decaying SELL: one fixed input (the anchor), one banded output so a
 * bid has something to move, and NOTHING else set.
 *
 * Deliberately NOT derived from {@link CANONICAL_ORDER}. That fixture is the
 * maximal one — it mirrors `HashGolden.t.sol` field-for-field, so it carries a
 * curve, a decay window, a `fillTotal` of 42, a `pricingModule` and a
 * `minFillAnchor` above its own anchor. Every one of those is a legitimate lint
 * hit, which makes it useless as the baseline for "reports nothing".
 */
const BANDED: Order = {
  ...CANONICAL_ORDER,
  legsIn: [{ token: CANONICAL_ORDER.legsIn[0]!.token, start: ANCHOR, end: 0n }],
  legsOut: [{ ...CANONICAL_ORDER.legsOut[0]!, start: 1_000n, end: 500n }],
  timing: packTiming(0, 0, 0),
  minFillAnchor: 0n,
  curve: [],
  gasBumpBps: 0n,
  gasPriceRef: 0n,
  fillTotal: 0n,
  fillModule: "0x0000000000000000000000000000000000000000",
  pricingModule: "0x0000000000000000000000000000000000000000",
};

describe("priorityOrder — the all-or-nothing default", () => {
  it("sets the priority bit AND fill-once, so the top bid takes the whole size", () => {
    const o = priorityOrder(BANDED, { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE });
    expect(isPriorityAuction(o)).toBe(true);
    expect(isFillOnce(o), "the default is UniswapX's all-or-nothing").toBe(true);
    expect(o.priorityScale).toBe(SCALE);
    expect(o.baselinePriorityFeeWei).toBe(BASELINE);
  });

  it("partiallyFillable is an explicit opt-out, and clears fill-once", () => {
    const o = priorityOrder(BANDED, {
      priorityScale: SCALE,
      partiallyFillable: true,
      minFillAnchor: 10n,
    });
    expect(isPriorityAuction(o)).toBe(true);
    expect(isFillOnce(o)).toBe(false);
    expect(o.minFillAnchor, "the lever that bounds how finely the average is diluted").toBe(10n);
  });

  it("clears a fill-once bit the caller had already set when they ask for partials", () => {
    const pre = { ...BANDED, timing: BANDED.timing | FILL_ONCE_BIT };
    const o = priorityOrder(pre, { priorityScale: SCALE, partiallyFillable: true });
    expect(isFillOnce(o), "the option decides, not whatever was on the input").toBe(false);
  });

  it("passes minFillAnchor through untouched, even where it is inert", () => {
    // It is INERT on an all-or-nothing order, not wrong — and `== anchor` is a
    // legitimate redundant restatement of fill-once. Silently zeroing a
    // maker-signed field would change the order hash behind the author's back;
    // the lint says so instead. (House rule: throw only where the settler
    // reverts.)
    const o = priorityOrder({ ...BANDED, minFillAnchor: 99n }, { priorityScale: SCALE });
    expect(o.minFillAnchor).toBe(99n);
    expect(lintPriorityOrder(o).some((m) => /can never bind/.test(m))).toBe(true);
  });

  it("accepts an explicit minFillAnchor on an all-or-nothing order rather than throwing", () => {
    const o = priorityOrder(BANDED, { priorityScale: SCALE, minFillAnchor: 5n });
    expect(o.minFillAnchor).toBe(5n);
  });
});

describe("priorityOrder — rejects exactly what the settler rejects", () => {
  it("refuses a zero priorityScale (InvalidAuctionParams)", () => {
    expect(() => priorityOrder(BANDED, { priorityScale: 0n })).toThrow(/priorityScale must be non-zero/);
  });

  it("refuses a gas bump, which moves the tick the wrong way", () => {
    expect(() => priorityOrder({ ...BANDED, gasBumpBps: 100n }, { priorityScale: SCALE })).toThrow(
      /gasBumpBps must be 0/,
    );
  });

  it("throws ONLY where the settler reverts — an inert field is a lint, not an error", () => {
    // The two throws above both mirror `InvalidAuctionParams`. Nothing else does,
    // so nothing else throws: an inert `minFillAnchor`, a dead decay window and a
    // dead curve all build fine and are reported by `lintPriorityOrder`.
    const inert = priorityOrder(
      { ...BANDED, minFillAnchor: 7n, timing: packTiming(111, 222, 0), curve: [{ timeDelta: 1, bumpBps: 100 }] },
      { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE },
    );
    expect(inert.minFillAnchor, "built fine — nothing here throws").toBe(7n);
    const msgs = lintPriorityOrder(inert);
    expect(msgs.some((m) => /can never bind/.test(m))).toBe(true);
    expect(msgs.some((m) => /decayDuration is set/.test(m))).toBe(true);
    expect(msgs.some((m) => /decay curve is set/.test(m))).toBe(true);
  });
});

describe("lintPriorityOrder", () => {
  it("is silent on a well-formed all-or-nothing order", () => {
    const o = priorityOrder(BANDED, { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE });
    expect(lintPriorityOrder(o)).toEqual([]);
  });

  it("says nothing at all about a non-priority order", () => {
    expect(lintPriorityOrder(BANDED)).toEqual([]);
  });

  it("flags the pay-as-bid economics of a partially fillable order, and an unbounded slice", () => {
    const o = priorityOrder(
      { ...BANDED, minFillAnchor: 0n }, // no floor carried in from the base order
      { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE, partiallyFillable: true },
    );
    const msgs = lintPriorityOrder(o);
    expect(msgs.some((m) => /pay-as-bid/.test(m))).toBe(true);
    expect(msgs.some((m) => /minFillAnchor is 0/.test(m))).toBe(true);
  });

  it("stops nagging about the slice bound once minFillAnchor is set", () => {
    const o = priorityOrder(BANDED, {
      priorityScale: SCALE,
      baselinePriorityFeeWei: BASELINE,
      partiallyFillable: true,
      minFillAnchor: 10n,
    });
    expect(lintPriorityOrder(o).some((m) => /minFillAnchor is 0/.test(m))).toBe(false);
  });

  it("flags a zero baseline, which reads every inclusion tip as a bid", () => {
    const o = priorityOrder(BANDED, { priorityScale: SCALE });
    expect(lintPriorityOrder(o).some((m) => /inclusion tip/.test(m))).toBe(true);
  });

  it("flags an unfillable floor differently from a merely inert one", () => {
    const anchor = ANCHOR;
    const inert = priorityOrder({ ...BANDED, minFillAnchor: anchor }, { priorityScale: SCALE });
    expect(lintPriorityOrder(inert).some((m) => /can never bind/.test(m))).toBe(true);

    const dead = priorityOrder({ ...BANDED, minFillAnchor: anchor + 1n }, { priorityScale: SCALE });
    expect(lintPriorityOrder(dead).some((m) => /can never fill/.test(m))).toBe(true);
  });

  it("flags a price module, which the settler silently prefers over the bid", () => {
    const o = priorityOrder(
      { ...BANDED, pricingModule: "0x00000000000000000000000000000000000000aa" },
      { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE },
    );
    expect(lintPriorityOrder(o).some((m) => /IPriceModule/.test(m))).toBe(true);
  });

  it("does NOT flag decayStartTime, which keeps its 'not before' meaning", () => {
    const o = priorityOrder({ ...BANDED, timing: packTiming(111, 0, 0) }, {
      priorityScale: SCALE,
      baselinePriorityFeeWei: BASELINE,
    });
    expect(lintPriorityOrder(o)).toEqual([]);
  });

  it("flags a fixed output leg, which no bid can move", () => {
    const fixedLegs = { ...BANDED, legsOut: BANDED.legsOut.map((l) => ({ ...l, end: 0n })) };
    const o = priorityOrder(fixedLegs, { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE });
    expect(lintPriorityOrder(o).some((m) => /FIXED/.test(m))).toBe(true);
  });
});

describe("packOrder accepts the mode flags it used to reject", () => {
  // REGRESSION. The guard was `timing >> 101 != 0`, i.e. "bit 101 and above must
  // be clear", which made bits 102/103/104 unreachable — so a priority auction, a
  // block-clock order and a delta-verify order were all UNBUILDABLE through the
  // SDK, even though `withDeltaVerifyOutputs` has always returned a word with bit
  // 104 set and `pricing.ts` has always read bit 103.
  it("packs a priority order", () => {
    const o = priorityOrder(BANDED, { priorityScale: SCALE, baselinePriorityFeeWei: BASELINE });
    const w = packOrder(o);
    expect(timingFlags(w.timing).priorityAuction).toBe(true);
    expect(timingFlags(w.timing).fillOnce).toBe(true);
  });

  it("packs a block-clock order and a delta-verify order", () => {
    expect(timingFlags(packOrder({ ...BANDED, timing: withBlockClock(BANDED.timing) }).timing).blockClock).toBe(true);
    expect(
      timingFlags(packOrder({ ...BANDED, timing: withDeltaVerifyOutputs(BANDED.timing) }).timing).deltaVerifyOutputs,
    ).toBe(true);
  });

  it("still refuses bit 101 — `side` is packOrder's to write", () => {
    expect(() => packOrder({ ...BANDED, timing: BANDED.timing | (1n << 101n) })).toThrow(/bit 101/);
  });

  it("refuses bit 105 and above — that space is reserved for `expiry`", () => {
    expect(() => packOrder({ ...BANDED, timing: BANDED.timing | (1n << 105n) })).toThrow(/bit 105/);
    expect(() => packOrder({ ...BANDED, timing: BANDED.timing | (1n << 160n) })).toThrow(/bit 105/);
  });

  it("round-trips the clocks alongside the flags", () => {
    const o = priorityOrder({ ...BANDED, timing: withBlockClock(BANDED.timing) }, { priorityScale: SCALE });
    const f = timingFlags(packOrder(o).timing);
    expect(f).toMatchObject({ priorityAuction: true, blockClock: true, fillOnce: true });
  });
});

describe("withPriorityAuction is the raw bit", () => {
  it("sets the mode without any of the defaults or checks", () => {
    const t = withPriorityAuction(BANDED.timing);
    expect(timingFlags(t).priorityAuction).toBe(true);
    expect(timingFlags(t).fillOnce, "the raw helper applies no policy").toBe(false);
  });
});

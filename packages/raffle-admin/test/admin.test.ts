import { describe, expect, it } from "vitest";
import { hashOrderStruct, orderToJson, PARTICIPATION_QUESTIONS, type Order } from "@1delta-x/sdk";
import { zeroAddress } from "viem";

import { pinnedToken } from "@app/config/markets";
import { entriesCsv, tallyFeedback, type AdminEntry } from "../src/adminApi";
import type { FillWire } from "@app/lib/dashboard";
import { ALWAYS_EXCLUDED, DAY, dayCsv, dayRows, dayWindow, pricesFrom, utcMidnight } from "../src/qualifiers";
import { buildOrder } from "@app/lib/order";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";
const DAY_STR = "2026-10-25";
const FROM = utcMidnight(Date.parse(`${DAY_STR}T00:00:00Z`) / 1000);

function sell(maker: string, nonce: bigint, amountIn: number): Order {
  return buildOrder({
    maker: maker as `0x${string}`,
    side: "sell",
    pay: pinnedToken(30, "USDRIF")!,
    recv: pinnedToken(30, "USD₮0")!,
    amountIn,
    targetOut: amountIn * 0.995,
    minOut: amountIn * 0.995,
    ttlSeconds: 3600,
    decaySeconds: 0,
    solver: zeroAddress,
    nonce,
    now: FROM,
  }).order;
}
let tx = 0;
const fill = (o: Order, at: number): FillWire => ({
  orderHash: hashOrderStruct(o),
  order: orderToJson(o),
  maker: o.maker.toLowerCase(),
  solver: ALWAYS_EXCLUDED[0],
  txHash: `0x${String(++tx).padStart(64, "0")}`,
  logIndex: 0,
  at,
  amount: o.legsIn[0]!.start.toString(),
});

describe("the daily qualifier list", () => {
  it("values each maker's UTC day like the Dashboard and marks the qualifier, leaving excluded addresses out", () => {
    const fills = [
      fill(sell(A, 1n, 25), FROM + 100), // A: $25 ✓
      fill(sell(B, 2n, 12), FROM + 200), // B: 12 + 9 = $21 ✓
      fill(sell(B, 3n, 9), FROM + 300),
      fill(sell(C, 4n, 19), FROM + 400), // C: below
      fill(sell(A, 5n, 500), FROM - 10), // the day before: ignored
      fill(sell(A, 6n, 500), FROM + DAY + 10), // the day after: ignored
    ];
    const rows = dayRows({ fills, day: DAY_STR, prices: pricesFrom({}), qualifierUsd: 20, exclude: [] });
    expect(rows).toEqual([
      { address: A, usd: 25, fills: 1, unsized: 0, qualifies: true },
      { address: B, usd: 21, fills: 2, unsized: 0, qualifies: true },
      { address: C, usd: 19, fills: 1, unsized: 0, qualifies: false },
    ]);
    // No registration (TC §4.1): a maker is listed whether or not it ever gave feedback.
    expect(dayRows({ fills, day: DAY_STR, prices: pricesFrom({}), qualifierUsd: 20, exclude: [A.toUpperCase().replace("0X", "0x")] }).map((r) => r.address)).toEqual([B, C]);
    expect(dayRows({ fills: [fill(sell(ALWAYS_EXCLUDED[0]!, 7n, 100), FROM + 1)], day: DAY_STR, prices: pricesFrom({}), qualifierUsd: 20, exclude: [] })).toEqual([]);
    expect(dayCsv(DAY_STR, rows).split("\n")[1]).toBe(`${DAY_STR},${A},25,1,0,true`);
    expect(() => dayWindow("25-10-2026")).toThrow(/YYYY-MM-DD/);
  });
});

describe("feedback tallies and CSV", () => {
  const entry = (address: string, answers: AdminEntry["answers"], over: Partial<AdminEntry> = {}): AdminEntry => ({
    address,
    enteredAt: 1_792_000_000,
    updatedAt: 1_792_000_000,
    issuedAt: 1_792_000_000,
    answers,
    signature: "0x",
    source: "signed",
    note: null,
    ...over,
  });
  const entries = [
    entry(A, { rating: 5, safety: 4, purpose: ["Get RBTC", "Exit USDRIF"], ease: 4, fill: 5, friction: 'the "approve" step, twice' }),
    entry(B, { rating: 3, safety: 2, purpose: ["Get RBTC"], ease: 2, fill: 3 }),
  ];

  it("counts options, averages scales and lists texts", () => {
    const t = tallyFeedback(PARTICIPATION_QUESTIONS, entries);
    const safety = t.find((x) => x.q.id === "safety")!;
    expect(safety.kind === "scale" && safety.average).toBe(3);
    const purpose = t.find((x) => x.q.id === "purpose")!;
    expect(purpose.kind === "counts" && Object.fromEntries(purpose.counts)).toMatchObject({ "Get RBTC": 2, "Exit USDRIF": 1 });
    const ease = t.find((x) => x.q.id === "ease")!;
    expect(ease.kind === "scale" && ease.average).toBe(3);
    const friction = t.find((x) => x.q.id === "friction")!;
    expect(friction.kind === "texts" && friction.texts).toEqual([{ address: A, text: 'the "approve" step, twice' }]);
  });

  it("writes one quoted CSV row per entry", () => {
    const csv = entriesCsv(PARTICIPATION_QUESTIONS, entries).trim().split("\n");
    expect(csv).toHaveLength(3);
    expect(csv[0]).toMatch(/^address,enteredAt,updatedAt,source,note,rating,/);
    expect(csv[1]).toContain('"the ""approve"" step, twice"');
    expect(csv[1]).toContain("Get RBTC | Exit USDRIF");
  });
});

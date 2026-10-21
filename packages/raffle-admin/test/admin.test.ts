import { describe, expect, it } from "vitest";
import { hashOrderStruct, orderToJson, PARTICIPATION_QUESTIONS, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";

import { pinnedToken } from "@app/config/markets";
import { entriesCsv, tallyFeedback, type AdminEntry } from "../src/adminApi";
import type { FillWire } from "@app/lib/dashboard";
import { ALWAYS_EXCLUDED, announcement, buildFinalSnapshot, buildSnapshot, carriedForward, completedPeriods, DAY, listHashOf, periodWindow, pickWinners, pricesFrom, utcMidnight, type Snapshot } from "../src/draw";
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

const RULES = { qualifierUsd: 20, periodDays: 3, minQualifiers: 2, prizes: [25], prizeToken: "USDRIF", onePrizePerAddress: true };
const BLOCK = `0x${"5a".repeat(32)}` as Hex;
const base = (records: Snapshot[] = [], over: Partial<Parameters<typeof buildSnapshot>[0]> = {}) => ({
  promotion: "p",
  startsAt: FROM + 3600, // mid-day start: periods still begin at the UTC midnight
  period: 0,
  fills: [] as FillWire[],
  cutoff: FROM + 10 * DAY,
  rules: RULES,
  prices: pricesFrom({}),
  exclude: [] as string[],
  records,
  drawBlock: 100n,
  ...over,
});

describe("periods and tickets", () => {
  it("counts periods from the start's UTC midnight and lists the completed ones newest first", () => {
    expect(periodWindow(FROM + 3600, 3, 0)).toEqual([FROM, FROM + 3 * DAY]);
    expect(periodWindow(FROM + 3600, 3, 2)).toEqual([FROM + 6 * DAY, FROM + 9 * DAY]);
    expect(completedPeriods(FROM + 3600, 3, FROM + 7 * DAY).map((p) => p.k)).toEqual([1, 0]);
    // Entries closing at the end of period 0: period 1 never exists.
    expect(completedPeriods(FROM + 3600, 3, FROM + 7 * DAY, FROM + 3 * DAY).map((p) => p.k)).toEqual([0]);
    expect(completedPeriods(0, 3, FROM)).toEqual([]);
  });

  it("one ticket per qualifying UTC day in the period, nothing outside it", () => {
    const fills = [
      fill(sell(A, 1n, 25), FROM + 100), // day 1 ✓
      fill(sell(A, 2n, 12), FROM + DAY + 100), // day 2: 12 + 9 = 21 ✓
      fill(sell(A, 3n, 9), FROM + DAY + 200),
      fill(sell(A, 4n, 19), FROM + 2 * DAY + 100), // day 3: below
      fill(sell(B, 5n, 50), FROM + 2 * DAY + 100), // B: 1 ticket
      fill(sell(C, 6n, 50), FROM + 100), // C: 1 ticket, no registration needed (TC §4.1)
      fill(sell(A, 7n, 500), FROM + 3 * DAY + 10), // next period
      fill(sell(A, 8n, 500), FROM - 10), // before the start
    ];
    const snap = buildSnapshot(base([], { fills }));
    expect(snap.day).toBe(DAY_STR);
    expect(snap.tickets).toEqual([
      [A, 2],
      [B, 1],
      [C, 1],
    ]);
    expect(snap.volumes.find((v) => v.address === A)).toMatchObject({ days: 2, fills: 4, usd: 65 });
    expect(snap.skipped).toBe(false);
    expect(snap.payouts).toEqual([25]);
    expect(snap.carriedOut).toBe(0);
    expect(snap.listHash).toBe(listHashOf([[B, 1], [C, 1], [A, 2]]));
    expect(announcement(snap)).toContain("3 qualifying addresses, 4 tickets");
    // An excluded address never gets a ticket even if it entered and traded.
    expect(buildSnapshot(base([], { fills, exclude: [A.toUpperCase().replace("0X", "0x")] })).list).toEqual([B, C]);
  });

  it("below the minimum: no draw, the prize is carried forward and lands on the next first prize", () => {
    const fills = [fill(sell(A, 1n, 25), FROM + 100)];
    const p0 = buildSnapshot(base([], { fills }));
    expect(p0).toMatchObject({ skipped: true, payouts: [], carriedIn: 0, carriedOut: 25, drawBlock: "" });
    expect(announcement(p0)).toMatch(/carried forward, 25 USDRIF/);
    const fills1 = [fill(sell(A, 2n, 25), FROM + 3 * DAY + 100), fill(sell(B, 3n, 25), FROM + 4 * DAY + 100)];
    const p1 = buildSnapshot(base([p0], { fills: fills1, period: 1, rules: { ...RULES, prizes: [25, 10] } }));
    expect(p1).toMatchObject({ skipped: false, carriedIn: 25, payouts: [50, 10], carriedOut: 0 });
    // Two skipped periods stack.
    const p1s = buildSnapshot(base([p0], { fills: [], period: 1 }));
    expect(p1s.carriedOut).toBe(50);
    expect(carriedForward([p0, p1s])).toBe(50);
  });

  it("the final draw spends the carry among addresses with ≥ 2 qualifying days", () => {
    const fills = [fill(sell(A, 1n, 25), FROM + 100), fill(sell(A, 2n, 25), FROM + 5 * DAY), fill(sell(B, 3n, 25), FROM + 100), fill(sell(B, 4n, 25), FROM + 6 * DAY), fill(sell(C, 5n, 25), FROM + 100)];
    const skipped = { ...buildSnapshot(base([], { fills: [] })), carriedOut: 50 };
    const fin = buildFinalSnapshot({ ...base([skipped], { fills }), endsAt: FROM + 9 * DAY });
    expect(fin).toMatchObject({ kind: "final", carriedIn: 50, payouts: [50], skipped: false, list: [A, B] });
    const nothing = buildFinalSnapshot({ ...base([], { fills }), endsAt: FROM + 9 * DAY });
    expect(nothing.skipped).toBe(true);
  });
});

describe("the draw rule", () => {
  const tickets: Array<[string, number]> = [
    [C, 1],
    [A, 3],
    [B, 1],
  ];
  it("hashes the tickets independently of order and case", () => {
    expect(listHashOf(tickets)).toBe(listHashOf([[B.toUpperCase().replace("0X", "0x"), 1], [A, 3], [C, 1]]));
    expect(listHashOf(tickets)).not.toBe(listHashOf([[A, 2], [B, 1], [C, 1]]));
  });
  it("is deterministic, every ticket one chance, a winner's other tickets leave the pool", () => {
    const w = pickWinners(tickets, BLOCK, 3);
    expect(pickWinners([...tickets].reverse(), BLOCK, 3)).toEqual(w);
    expect(new Set(w).size).toBe(3);
    const firsts = new Set(Array.from({ length: 12 }, (_, i) => pickWinners(tickets, `0x${(i + 7).toString(16).padStart(64, "0")}`, 1)[0]));
    expect(firsts.size).toBeGreaterThan(1);
    expect(pickWinners([], BLOCK, 1)).toEqual([]);
    // With 3 of 5 tickets, A wins the first pick for most block hashes.
    let aFirst = 0;
    for (let i = 0; i < 200; i++) if (pickWinners(tickets, `0x${i.toString(16).padStart(64, "0")}`, 1)[0] === A) aFirst++;
    expect(aFirst).toBeGreaterThan(90);
    expect(aFirst).toBeLessThan(150);
  });
  it("honours skips, and defers earlier winners until nobody else is left", () => {
    const [first] = pickWinners(tickets, BLOCK, 1);
    expect(pickWinners(tickets, BLOCK, 1, [first!])[0]).not.toBe(first);
    // A has already won: only B or C can win now, whatever the hash.
    for (let i = 0; i < 50; i++) expect(pickWinners(tickets, `0x${i.toString(16).padStart(64, "0")}`, 1, [], [A])[0]).not.toBe(A);
    // …but when A is the only one left, A wins.
    expect(pickWinners(tickets, BLOCK, 1, [B, C], [A])).toEqual([A]);
    expect(pickWinners(tickets, BLOCK, 3, [], [A])[2]).toBe(A);
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

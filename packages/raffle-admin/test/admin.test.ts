import { describe, expect, it } from "vitest";
import { hashOrderStruct, orderToJson, PARTICIPATION_QUESTIONS, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";

import { pinnedToken } from "@app/config/markets";
import { entriesCsv, tallyFeedback, type AdminEntry } from "../src/adminApi";
import type { FillWire } from "@app/lib/dashboard";
import { ALWAYS_EXCLUDED, announcement, buildSnapshot, dayWindow, listHashOf, pickWinners, pricesFrom } from "../src/draw";
import { buildOrder } from "@app/lib/order";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";
const DAY = "2026-10-25";
const [FROM] = dayWindow(DAY);

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

describe("the daily snapshot", () => {
  it("lists entered makers at or above the qualifier on that UTC day only", () => {
    const fills = [
      fill(sell(A, 1n, 25), FROM + 100), // A: $25 → qualifies
      fill(sell(B, 2n, 12), FROM + 200), // B: $12 + $9 = $21 → qualifies
      fill(sell(B, 3n, 9), FROM + 300),
      fill(sell(C, 4n, 50), FROM + 400), // C: never entered
      fill(sell(A, 5n, 500), FROM - 10), // the day before: ignored
    ];
    const snap = buildSnapshot({
      promotion: "p",
      day: DAY,
      fills,
      entrants: [
        { address: A, enteredAt: FROM },
        { address: B, enteredAt: FROM },
      ],
      cutoff: FROM + 86_400,
      qualifierUsd: 20,
      prices: pricesFrom({}),
      exclude: [],
      drawBlock: 100n,
    });
    expect(snap.volumes).toEqual([
      { address: A, usd: 25, fills: 1, unsized: 0 },
      { address: B, usd: 21, fills: 2, unsized: 0 },
    ]);
    expect(snap.list).toEqual([A, B]);
    expect(snap.listHash).toBe(listHashOf([B, A]));
    expect(announcement(snap)).toContain("2 qualifying addresses");

    const strict = buildSnapshot({ ...{ promotion: "p", day: DAY, fills, prices: pricesFrom({}), drawBlock: 1n, cutoff: FROM + 86_400 }, entrants: [{ address: A, enteredAt: FROM }, { address: B, enteredAt: FROM + 90_000 }], qualifierUsd: 22, exclude: [] });
    // B entered after the cutoff and A alone is above $22.
    expect(strict.list).toEqual([A]);
    expect(buildSnapshot({ promotion: "p", day: DAY, fills, prices: pricesFrom({}), drawBlock: 1n, cutoff: FROM + 86_400, entrants: [{ address: A, enteredAt: FROM }], qualifierUsd: 20, exclude: [A.toUpperCase().replace("0X", "0x")] }).list).toEqual([]);
  });
});

describe("feedback tallies and CSV", () => {
  const entry = (address: string, answers: AdminEntry["answers"], over: Partial<AdminEntry> = {}): AdminEntry => ({
    address,
    enteredAt: 1_792_000_000,
    updatedAt: 1_792_000_000,
    issuedAt: 1_792_000_000,
    answers,
    contact: null,
    signature: "0x",
    source: "signed",
    note: null,
    ...over,
  });
  const entries = [
    entry(A, { heard: "A friend", purpose: ["Get RBTC", "Exit USDRIF"], ease: 4, fill: 5, friction: 'the "approve" step, twice' }),
    entry(B, { heard: "A friend", purpose: ["Get RBTC"], ease: 2, fill: 3 }, { contact: "@b" }),
  ];

  it("counts options, averages scales, lists texts and never tallies the contact", () => {
    const t = tallyFeedback(PARTICIPATION_QUESTIONS, entries);
    expect(t.find((x) => x.q.id === "contact")).toBeUndefined();
    const heard = t.find((x) => x.q.id === "heard")!;
    expect(heard.kind === "counts" && heard.counts.find(([o]) => o === "A friend")?.[1]).toBe(2);
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
    expect(csv[0]).toMatch(/^address,enteredAt,updatedAt,source,note,contact,heard,/);
    expect(csv[1]).toContain('"the ""approve"" step, twice"');
    expect(csv[1]).toContain("Get RBTC | Exit USDRIF");
    expect(csv[2]).toContain("@b");
  });
});


describe("the draw rule", () => {
  const list = ["0x00000000000000000000000000000000000000c3", "0x00000000000000000000000000000000000000A1", "0x00000000000000000000000000000000000000b2"];
  const hash = `0x${"5a".repeat(32)}` as Hex;
  it("hashes the list independently of order and case", () => {
    expect(listHashOf(list)).toBe(listHashOf([...list].reverse().map((a) => a.toLowerCase())));
  });
  it("is deterministic, without replacement, and honours skips", () => {
    const w = pickWinners(list, hash, 3);
    expect(pickWinners([...list].reverse(), hash, 3)).toEqual(w);
    expect(new Set(w).size).toBe(3);
    expect(pickWinners(list, `0x${"5b".repeat(32)}`, 3)).not.toEqual(w);
    const [first] = w;
    const again = pickWinners(list, hash, 1, [first!]);
    expect(again).toHaveLength(1);
    expect(again[0]).not.toBe(first);
    expect(pickWinners([], hash, 1)).toEqual([]);
  });
});

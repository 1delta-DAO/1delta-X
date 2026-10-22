import { describe, expect, it } from "vitest";

import { betaCapFor, capCheck, usedUsd } from "../src/lib/betaCap";
import type { Fill, RestingOrder } from "../src/lib/types";

const ME = "0x00000000000000000000000000000000000000aa";
const OTHER = "0x00000000000000000000000000000000000000bb";
const fill = (over: Partial<Fill>): Fill => ({ id: "f", marketId: "m", side: "sell", size: 100, price: 1, source: "LMT", filler: "", tx: "", at: 0, mine: true, maker: ME, simulated: false, ...over }) as Fill;
const order = (over: Partial<RestingOrder>, maker = ME): RestingOrder =>
  ({ id: "o", marketId: "m", side: "sell", type: "limit", size: 300, filled: 100, price: 1, createdAt: 0, expiresAt: 0, mine: true, signed: { order: { maker } } as never, ...over }) as RestingOrder;
const base = { account: ME, chainId: 30, baseUsd: (m: string) => (m === "m" ? 2 : undefined), chainOf: () => 30 };

describe("pre-audit cap: $1,000 per wallet on Rootstock (UI)", () => {
  it("is set on Rootstock only", () => {
    expect(betaCapFor(30)).toBe(1000);
    expect(betaCapFor(1)).toBeUndefined();
  });

  it("counts the wallet's fills and its open orders' unfilled rest, at USD per base", () => {
    const r = usedUsd({ ...base, fills: [fill({}), fill({ maker: OTHER }), fill({ simulated: true }), fill({ mine: false })], orders: [order({}), order({}, OTHER), order({ cancelled: "soft" })] });
    // fill 100 × $2 = 200; open rest (300 − 100) × $2 = 400, twice (the soft-cancelled one stays fillable)
    expect(r).toEqual({ usd: 1000, unpriced: 0 });
    expect(usedUsd({ ...base, fills: [fill({ marketId: "x" })], orders: [] })).toEqual({ usd: 0, unpriced: 1 });
  });

  it("a ticket over the room left is refused; at the cap passes", () => {
    expect(capCheck(1000, 700, 300)).toMatchObject({ leftUsd: 300, over: false });
    expect(capCheck(1000, 700, 301)).toMatchObject({ over: false }); // within the 0.5 % slack
    expect(capCheck(1000, 700, 320)).toMatchObject({ over: true });
    expect(capCheck(1000, 1200, 1)).toMatchObject({ leftUsd: 0, over: true });
    expect(capCheck(1000, 0, undefined).over).toBe(false);
  });
});

import { describe, expect, it } from "vitest";

import { BETA_TOTAL_FILL_CAP_USD, betaCapFor, capCheck, capLimitsNote, openUsd } from "../src/lib/betaCap";
import type { RestingOrder } from "../src/lib/types";

const ME = "0x00000000000000000000000000000000000000aa";
const OTHER = "0x00000000000000000000000000000000000000bb";
const order = (over: Partial<RestingOrder>, maker = ME): RestingOrder =>
  ({ id: "o", marketId: "m", side: "sell", type: "limit", size: 300, filled: 100, price: 1, createdAt: 0, expiresAt: 0, mine: true, signed: { order: { maker } } as never, ...over }) as RestingOrder;

describe("pre-audit caps (UI): $1,000 per order and per wallet's open orders; $25k total (filler)", () => {
  it("are set on Rootstock only", () => {
    expect([betaCapFor(30), BETA_TOTAL_FILL_CAP_USD[30]]).toEqual([1000, 25000]);
    expect(betaCapFor(1)).toBeUndefined();
  });

  it("open orders count their unfilled rest (soft-cancelled too), other makers' do not", () => {
    const base = { account: ME, chainId: 30, baseUsd: (m: string) => (m === "m" ? 2 : undefined), chainOf: () => 30 };
    expect(openUsd({ ...base, orders: [order({}), order({}, OTHER), order({ cancelled: "soft" }), order({ marketId: "x" })] })).toBe(800);
  });

  it("a ticket over $1,000 breaks the per-order cap; within it, the open orders' room decides", () => {
    expect(capCheck(1000, 1000, 0)).toMatchObject({ over: false, leftUsd: 1000 });
    expect(capCheck(1000, 2991, 0)).toMatchObject({ over: true, kind: "order" });
    expect(capCheck(1000, 600, 700)).toMatchObject({ over: true, kind: "wallet", leftUsd: 300 });
    expect(capCheck(1000, 300, 700)).toMatchObject({ over: false });
    expect(capCheck(1000, undefined, 5000).over).toBe(false);
  });

  it("the info note states all three limits", () => {
    const n = capLimitsNote(1000, 25000);
    expect(n).toMatch(/each order is capped at \$1,000/);
    expect(n).toMatch(/open orders together may not exceed \$1,000/);
    expect(n).toMatch(/\$25,000 has been filled in total/);
  });
});

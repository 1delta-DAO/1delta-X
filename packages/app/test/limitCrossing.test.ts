import { describe, expect, it } from "vitest";

import { quote as ladderQuote } from "../src/lib/ladder";
import { limitTtlSeconds, planTicket } from "../src/lib/plan";
import type { Level } from "../src/lib/types";

const rung = (price: number): Level => ({ price, size: 1e9, source: "UNI" });

describe("a LIMIT ticket that crosses the book entirely is still a limit order", () => {
  // The 2026-10-13 ticket: buy RIF with 8.53 USD0, limit 0.0885557 above a ~0.0843 ask.
  const q = ladderQuote({ bids: [rung(0.0836)], asks: [rung(0.08456)], side: "buy", amountIn: 8.53, limit: 0.0885557, slippageBps: 30 });

  it("the walk crosses all of it (nothing rests)", () => {
    expect(q.resting).toBeNull();
    expect(q.totalIn).toBeCloseTo(8.53, 9);
  });

  it("floor = the LIMIT price, life = the chosen expiry, auction from the book's price down to it", () => {
    const p = planTicket({ q, mid: 0.0843, mode: "limit", side: "buy", amount: 8.53, limit: 0.0885557, slices: 1, everyMin: 1, expiry: "7d" })!;
    expect(p.kind).toBe("limit");
    expect(p.minOut).toBeCloseTo(8.53 / 0.0885557, 9); // ≈ 96.3 RIF — room for the filler's gas
    expect(p.targetOut).toBeCloseTo(8.53 / 0.08456, 6); // starts at the book's price
    expect(p.ttlSeconds).toBe(limitTtlSeconds("7d"));
    expect(p.restingBase).toBe(0);
  });
});

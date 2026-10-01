import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import type { SignedOrder } from "../src/backend/api";
import { MockOrderbook } from "../src/backend/mock";
import { mergeLadder, quote } from "../src/lib/ladder";
import { planTicket } from "../src/lib/plan";
import { needsSliceSignature, orderStatus, type Level, type PoolBook } from "../src/lib/types";

const src = (p: string) => readFileSync(resolve(__dirname, "..", p), "utf8");

function signed(hash: string): SignedOrder {
  return {
    order: { nonce: BigInt(hash.length) } as unknown as SignedOrder["order"],
    sig: "0x",
    hash: hash as `0x${string}`,
    deployment: { chainId: 30, settlement: "0x0000000000000000000000000000000000000001", permit3: "0x0000000000000000000000000000000000000002" },
    deployed: true,
  };
}

const H1 = `0x${"11".repeat(32)}`;
const H2 = `0x${"22".repeat(32)}`;

const softCancel = (hash: string) => ({
  cancel: { maker: "0x00000000000000000000000000000000000000aa" as const, orderHashes: [hash as `0x${string}`], issuedAt: 0n, expiry: 1n },
  sig: "0x" as const,
});

function emptyBook(): PoolBook {
  return {
    pool: "p",
    chainId: 30,
    block: 1,
    base: { address: "0x1", symbol: "B", name: "B", decimals: 18 },
    quote: { address: "0x2", symbol: "Q", name: "Q", decimals: 6 },
    venues: [],
    tick: 2,
    step: 1,
    bids: [],
    asks: [],
    mid: 100,
  };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(1_700_000_000_000);
});
afterEach(() => {
  vi.useRealTimers();
});

describe("G-TS_SIGN-4 — soft cancel is signed, advisory, and never silently evicts", () => {
  it("test_audit_G_TS_SIGN_4_unsignedCancelDoesNotEvict", async () => {
    const book = new MockOrderbook();
    await book.place({ marketId: "m", side: "sell", type: "limit", size: 1, price: 100, ttlMs: 3_600_000, signed: signed(H1) });
    // The old mock evicted on an unsigned cancel (the wrong-chain path in App).
    await expect(book.cancel(H1, undefined as never)).rejects.toThrow(/signed/);
    expect(book.orders().map((o) => o.id)).toEqual([H1]);
    expect(book.orders()[0]!.cancelled).toBeUndefined();
  });

  it("test_audit_G_TS_SIGN_4_softCancelKeepsRowLabelledStillFillable", async () => {
    const book = new MockOrderbook();
    await book.place({ marketId: "m", side: "sell", type: "limit", size: 1, price: 100, ttlMs: 3_600_000, signed: signed(H1) });
    await book.cancel(H1, softCancel(H1));
    const [o] = book.orders();
    expect(o?.id).toBe(H1); // still listed until expiry: its signature is still valid on-chain
    expect(o?.cancelled).toBe("soft");
    expect(orderStatus(o!)).toBe("soft-cancelled");
    // ...but no longer offered as depth.
    expect(mergeLadder(emptyBook(), book.orders()).asks).toEqual([]);
    // A cancel naming a different order is refused.
    await expect(book.cancel(H1, softCancel(H2))).rejects.toThrow();
  });

  it("test_audit_G_TS_SIGN_4_hardCancelRemovesRow", async () => {
    const book = new MockOrderbook();
    await book.place({ marketId: "m", side: "sell", type: "limit", size: 1, price: 100, ttlMs: 3_600_000, signed: signed(H1) });
    book.confirmHardCancel(H1);
    expect(book.orders()).toEqual([]);
  });

  it("test_audit_G_TS_SIGN_4_uiOffersOnChainCancelAndDropsFreeCancelCopy", () => {
    const app = src("src/App.tsx");
    expect(app).toContain("encodeCancelOrders(");
    // No unsigned fall-through eviction.
    expect(app).not.toMatch(/await orderbook\.cancel\(orderHash\);/);
    const orders = src("src/components/Orders.tsx");
    expect(orders).not.toContain("cancelling is free");
    expect(orders).toContain("Cancel on-chain");
    expect(app).not.toContain("resting · free to cancel");
  });
});

describe("G-TS_SIGN-15 — nothing unsigned is shown as traded; mock fills are labelled simulated", () => {
  it("test_audit_G_TS_SIGN_15_bookRefusesUnsignedOrders", async () => {
    const book = new MockOrderbook();
    await expect(
      book.place({ marketId: "m", side: "sell", type: "limit", size: 1, price: 1, ttlMs: 1, signed: undefined as never }),
    ).rejects.toThrow(/signed/);
  });

  it("test_audit_G_TS_SIGN_15_unsignedTwapSlicesDoNotFill", async () => {
    const book = new MockOrderbook();
    await book.place({
      marketId: "m",
      side: "sell",
      type: "twap",
      size: 3,
      price: 100,
      ttlMs: 10 * 60_000,
      slices: { total: 3, everyMin: 1 },
      signed: signed(H1),
    });
    book.observe({ marketId: "m", mid: 100, tick: 2, step: 1, depth: 10 });
    const tick = () => (book as unknown as { tick(): void }).tick();

    vi.advanceTimersByTime(2 * 60_000 + 1); // slices 1..3 are all due now
    tick();
    let mine = book.orders().find((o) => o.id === H1)!;
    // Only slice 1 was signed, so only slice 1 fills — the old mock filled due slices regardless.
    expect(mine.slices!.done).toBe(1);
    expect(mine.filled).toBeCloseTo(1);
    expect(needsSliceSignature(mine, Date.now())).toBe(true);

    book.addSlice(H1, signed(H2));
    tick();
    mine = book.orders().find((o) => o.id === H1)!;
    expect(mine.slices!.done).toBe(2);
    expect(mine.signedOrders).toHaveLength(2);

    const fills = book.fills().filter((f) => f.mine);
    expect(fills.length).toBeGreaterThan(0);
    expect(fills.every((f) => f.simulated)).toBe(true);
  });

  it("test_audit_G_TS_SIGN_15_recordedTakesAreSimulated", () => {
    const book = new MockOrderbook();
    book.recordTake({ marketId: "m", side: "sell", size: 1, price: 100, bySource: { UNI: 1, SUSHI: 0, LMT: 0 } });
    expect(book.fills().every((f) => f.simulated)).toBe(true);
  });

  it("test_audit_G_TS_SIGN_15_limitTicketSignsCrossingPart", () => {
    const bids: Level[] = [
      { price: 101, size: 1, source: "UNI" },
      { price: 99, size: 5, source: "UNI" },
    ];
    const asks: Level[] = [{ price: 102, size: 5, source: "UNI" }];
    // Sell 3 at a limit of 100: 1 crosses at 101 now, 2 rest at 100.
    const q = quote({ bids, asks, side: "sell", amountIn: 3, limit: 100, slippageBps: 50 });
    const plan = planTicket({ q, mid: 101.5, mode: "limit", side: "sell", amount: 3, limit: 100, slices: 1, everyMin: 1 })!;
    expect(plan.kind).toBe("limit");
    // The signed order covers the WHOLE ticket — crossing part included —
    // instead of only the resting remainder.
    expect(plan.amountIn).toBeCloseTo(3);
    expect(plan.crossedBase).toBeCloseTo(1);
    expect(plan.restingBase).toBeCloseTo(2);
    expect(plan.minOut).toBeCloseTo(300); // the limit, over the full size
    expect(plan.targetOut).toBeCloseTo(301); // the book's price for what crosses now
  });

  it("test_audit_G_TS_SIGN_15_copyNoLongerClaimsSettlement", () => {
    const app = src("src/App.tsx");
    expect(app).not.toContain("settled · 0 gas");
    expect(src("src/components/Orders.tsx")).not.toContain("every fill settles on-chain and is verifiable");
    expect(src("src/components/OrderForm.tsx")).not.toContain("Order signed · broadcast");
  });
});

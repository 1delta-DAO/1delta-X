import { describe, expect, it } from "vitest";
import { zeroAddress, type Hex } from "viem";

import type { SignedOrder } from "../src/backend/api";
import { RemoteOrderbook, inferType } from "../src/backend/remote";
import { pinnedToken } from "../src/config/markets";
import {
  CANCELLED_SENTINEL,
  fillStatusLabel,
  orderPhase,
  orderTypeLabel,
  outcomeOf,
  phaseLine,
  retireReason,
  rowStatus,
  rowStatusLabel,
} from "../src/lib/orderLifecycle";
import { buildOrder } from "../src/lib/order";
import type { RestingOrder } from "../src/lib/types";

const NOW = 1_700_000_000_000;
const row = (o: Partial<RestingOrder> = {}): RestingOrder => ({
  id: "0xaa",
  marketId: "rsk-30-usdrif-usd0",
  side: "sell",
  type: "limit",
  size: 100,
  filled: 0,
  price: 1,
  createdAt: NOW - 1000,
  expiresAt: NOW + 60_000,
  mine: true,
  ...o,
});

describe("order type and status labels", () => {
  it("a market ticket's order says Market, a limit Limit, a TWAP TWAP", () => {
    expect(orderTypeLabel({ type: "market" })).toBe("Market");
    expect(orderTypeLabel({ type: "limit" })).toBe("Limit");
    expect(orderTypeLabel({ type: "twap" })).toBe("TWAP");
    // restored orders: a ≤ 15 min life was a market ticket
    expect(inferType(NOW, NOW + 300_000)).toBe("market");
    expect(inferType(NOW, NOW + 3_600_000)).toBe("limit");
  });

  it("filled ≥ size is FILLED; partial only for 0 < filled < size", () => {
    expect(rowStatus(row({ filled: 0 }), NOW)).toBe("open");
    expect(rowStatus(row({ filled: 40 }), NOW)).toBe("partial");
    expect(rowStatus(row({ filled: 100 }), NOW)).toBe("filled");
    expect(rowStatus(row({ filled: 99.99999999 }), NOW)).toBe("filled"); // wei → float dust
    expect(rowStatus(row({ filled: 100, offBook: "x" }), NOW)).toBe("filled");
    expect(rowStatus(row({ expiresAt: NOW - 1 }), NOW)).toBe("expired");
    expect(rowStatus(row({ pendingFill: { txHash: "0x01" } }), NOW)).toBe("fill-pending");
    expect(rowStatus(row({ cancelled: "soft", filled: 100 }), NOW)).toBe("soft-cancelled");
    expect(rowStatusLabel("fill-pending")).toBe("fill submitted");
  });

  it("outcome from Settlement.filled: sentinel = cancelled, ≥ anchor = filled, 0 = expired", () => {
    expect(outcomeOf({ filledWei: 100n, anchor: 100n })).toBe("filled");
    expect(outcomeOf({ filledWei: 40n, anchor: 100n })).toBe("partially-filled");
    expect(outcomeOf({ filledWei: 0n, anchor: 100n })).toBe("expired");
    expect(outcomeOf({ filledWei: CANCELLED_SENTINEL, anchor: 100n })).toBe("cancelled");
    expect(outcomeOf({ filledWei: 0n, anchor: 100n, cancelled: true })).toBe("cancelled");
  });

  it("retire: filled at once, expired at expiry, a live partial stays", () => {
    expect(retireReason(row({ filled: 100 }), { now: NOW })).toBe("filled");
    expect(retireReason(row({ filled: 40 }), { now: NOW })).toBeNull();
    expect(retireReason(row({ filled: 40, expiresAt: NOW }), { now: NOW })).toBe("partially-filled");
    expect(retireReason(row({ expiresAt: NOW }), { now: NOW })).toBe("expired");
    expect(retireReason(row(), { now: NOW, cancelledOnChain: true })).toBe("cancelled");
    expect(fillStatusLabel({ status: "expired", filledPct: 40, size: 0 })).toBe("expired · 40% filled");
    expect(fillStatusLabel({ status: "filled", size: 1 })).toBe("filled");
  });

  it("the order card line follows the order from signing to its end", () => {
    expect(phaseLine({ kind: "signing" }).text).toMatch(/Signing/);
    expect(phaseLine({ kind: "posting" }).text).toMatch(/Posting/);
    const r = row({ id: "0xAB", book: "remote" });
    expect(orderPhase("0xab", [r], [], NOW)).toEqual({ kind: "posted", simulated: false });
    expect(orderPhase("0xab", [{ ...r, pendingFill: { txHash: "0xfeed" } }], [], NOW)).toEqual({ kind: "fill-pending", tx: "0xfeed" });
    const fill = { id: "f", orderHash: "0xab", marketId: r.marketId, side: r.side, size: 100, price: 1, source: "LMT" as const, filler: "x", tx: "0x77", at: NOW, mine: true, simulated: false, status: "filled" as const };
    expect(orderPhase("0xab", [], [fill], NOW)).toEqual({ kind: "filled", tx: "0x77" });
    expect(phaseLine({ kind: "filled", tx: "0x77" })).toMatchObject({ text: "Filled ✓", tx: "0x77" });
    const expired = { ...fill, id: "e", size: 0, tx: "", status: "expired" as const, filledPct: 0 };
    expect(orderPhase("0xab", [], [expired], NOW)).toEqual({ kind: "expired", pct: 0 });
    expect(phaseLine({ kind: "expired", pct: 0 }).text).toBe("Expired · not filled");
  });
});

// ──────────────── the remote book: an order that leaves the book moves to Recent fills ────────────────

const BASE = "https://book.test";
const MAKER = "0x00000000000000000000000000000000000000aa" as const;
const TX = `0x${"7e".repeat(32)}`;
const PENDING_TX = `0x${"5e".repeat(32)}`;

function signedOrder(ttlSeconds = 300, nonce = 1n): SignedOrder {
  const draft = buildOrder({
    maker: MAKER,
    side: "sell",
    pay: pinnedToken(30, "USDRIF")!,
    recv: pinnedToken(30, "USD0")!,
    amountIn: 100,
    targetOut: 100,
    minOut: 99.5,
    ttlSeconds,
    decaySeconds: 0,
    solver: zeroAddress,
    nonce,
    now: NOW / 1000,
  });
  return {
    order: draft.order,
    sig: `0x${"ab".repeat(65)}` as Hex,
    hash: draft.hash,
    deployment: { chainId: 30, settlement: "0x00000000000000000000000000000000005e771e", permit3: "0x000000000000000000000000000000000000aaaa" },
    deployed: true,
  };
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** A scripted book: `status` / `fills` are swapped between polls. */
function scripted(s: SignedOrder) {
  const state: { status: unknown; fills: unknown[]; statusCode: number } = { status: { live: true, status: "Fillable", filledAmount: "0" }, fills: [], statusCode: 200 };
  const fetch = async (url: string, init?: RequestInit) => {
    if (init?.method === "POST") return json(202, { orderHash: s.hash });
    if (url.endsWith("/status")) return json(state.statusCode, state.status);
    if (url.includes("/fills?")) return json(200, { fills: state.fills });
    return json(404, { error: "unknown" });
  };
  return { state, fetch };
}

describe("remote book — filled / expired orders move to Recent fills (2026-10-11)", () => {
  it("a market order the book reports Filled before the index has it: Filled at once, no tx — then the tx link", async () => {
    const s = signedOrder();
    const anchor = s.order.legsIn[0]!.start;
    const { state, fetch } = scripted(s);
    let now = NOW;
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch, now: () => now });
    await book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "market", size: 100, price: 1, ttlMs: 300_000, signed: s });
    expect(book.orders()[0]!.type).toBe("market");

    // A filler's tx is sent: the row says so.
    state.status = { live: true, status: "Fillable", filledAmount: "0", pendingFill: { txHash: PENDING_TX, sentAt: NOW / 1000 } };
    await book.poll();
    expect(rowStatus(book.orders()[0]!, now)).toBe("fill-pending");
    expect(orderPhase(s.hash, book.orders(), book.fills(), now)).toEqual({ kind: "fill-pending", tx: PENDING_TX });

    // Mined: the book graves it Filled; /fills has not caught up.
    state.status = { live: false, status: "Filled", reason: "filled", filledAmount: anchor.toString() };
    await book.poll();
    expect(book.orders()).toHaveLength(0); // it left the open orders…
    const f = book.fills();
    expect(f).toHaveLength(1); // …and did NOT vanish
    expect(f[0]).toMatchObject({ status: "filled", tx: "", orderHash: s.hash, orderType: "market", simulated: false });
    expect(f[0]!.size).toBeCloseTo(100, 6);
    expect(orderPhase(s.hash, book.orders(), f, now)).toEqual({ kind: "filled", tx: "" });

    // The index catches up: the same row gets its transaction, nothing is double counted.
    now += 12_000;
    state.fills = [{ orderHash: s.hash, maker: MAKER, solver: "0x00000000000000000000000000000000000f111e", blockNumber: "9", txHash: TX, logIndex: 2, at: NOW / 1000 + 10, cumulative: anchor.toString(), amount: anchor.toString() }];
    await book.poll();
    const g = book.fills();
    expect(g).toHaveLength(1);
    expect(g[0]).toMatchObject({ tx: TX, status: "filled" });
    expect(g[0]!.size).toBeCloseTo(100, 6);
    expect(orderPhase(s.hash, book.orders(), g, now)).toEqual({ kind: "filled", tx: TX });
    await book.poll();
    expect(book.fills()).toHaveLength(1);
  });

  it("the grave's txHash is used when the index has none", async () => {
    const s = signedOrder();
    const anchor = s.order.legsIn[0]!.start;
    const { state, fetch } = scripted(s);
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch, now: () => NOW });
    await book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "market", size: 100, price: 1, ttlMs: 300_000, signed: s });
    state.status = { live: false, status: "Filled", reason: "filled", filledAmount: anchor.toString(), txHash: TX };
    await book.poll();
    expect(book.fills()[0]).toMatchObject({ tx: TX, status: "filled" });
  });

  it("an order that expires unfilled shows as Expired instead of vanishing", async () => {
    const s = signedOrder();
    const { state, fetch } = scripted(s);
    let now = NOW;
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch, now: () => now });
    await book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "market", size: 100, price: 1, ttlMs: 300_000, signed: s });
    now += 301_000;
    state.status = { live: false, status: "Expired", reason: "expired", filledAmount: "0" };
    await book.poll();
    expect(book.orders()).toHaveLength(0);
    expect(book.fills()).toHaveLength(1);
    expect(book.fills()[0]).toMatchObject({ status: "expired", size: 0, orderHash: s.hash });
    expect(orderPhase(s.hash, [], book.fills(), now)).toEqual({ kind: "expired", pct: 0 });
  });

  it("an order the book lost track of is checked on-chain: Settlement.filled says filled → Filled", async () => {
    const s = signedOrder(3600);
    const anchor = s.order.legsIn[0]!.start;
    const { state, fetch } = scripted(s);
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch, now: () => NOW });
    const reads: string[] = [];
    book.setFillReader(async (so) => {
      reads.push(so.hash);
      return anchor;
    });
    await book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "limit", size: 100, price: 1, ttlMs: 3_600_000, signed: s });
    state.statusCode = 404;
    state.status = { error: "unknown order" };
    await book.poll();
    expect(reads).toEqual([s.hash]);
    expect(book.orders()).toHaveLength(0);
    expect(book.fills()[0]).toMatchObject({ status: "filled", tx: "", orderHash: s.hash });
  });

  it("at expiry the chain has the last word: a partial fill the book missed ends as Expired · 40% filled", async () => {
    const s = signedOrder(3600);
    const anchor = s.order.legsIn[0]!.start;
    const { fetch } = scripted(s);
    let now = NOW;
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch, now: () => now });
    book.setFillReader(async () => (anchor * 40n) / 100n);
    await book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "limit", size: 100, price: 1, ttlMs: 3_600_000, signed: s });
    now += 3_600_001;
    await book.poll();
    expect(book.orders()).toHaveLength(0);
    const f = book.fills();
    const exp = f.find((x) => x.status === "expired")!;
    expect(exp.filledPct).toBeCloseTo(40, 6);
    const part = f.find((x) => x.status === "partial")!;
    expect(part.size).toBeCloseTo(40, 6);
    expect(orderPhase(s.hash, [], f, now)).toEqual({ kind: "expired", pct: 40 });
  });
});

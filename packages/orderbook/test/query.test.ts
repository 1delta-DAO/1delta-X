import { describe, expect, it } from "vitest";
import { OrderSide, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Address, type Hex } from "viem";

import type { BookEntry } from "../src/book";
import { checkAdmission, DEFAULT_ADMISSION } from "../src/admission";
import { orderPrice, queryOrders, summarize } from "../src/query";
import { OrderStatus, type Layer2Result } from "../src/verify";

const A = (n: number): Address => `0x${n.toString(16).padStart(40, "0")}` as Address;
const WETH = A(0xaa);
const USDC = A(0xbb);
const DAI = A(0xcc);
const ALICE = A(1);
const BOB = A(2);

const NOW = 1_800_000_000;

function order(overrides: Partial<Order> = {}): Order {
  return {
    maker: ALICE,
    side: OrderSide.SELL,
    nonce: 1n,
    deadline: BigInt(NOW + 3600),
    legsIn: [{ token: WETH, start: 1_000n, end: 0n }],
    legsOut: [{ token: USDC, start: 2_000n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...overrides,
  };
}

function state(overrides: Partial<Layer2Result> = {}): Layer2Result {
  return {
    ok: true,
    status: OrderStatus.Fillable,
    fillableAmount: 1_000n,
    isSignatureValid: true,
    validatorsPass: true,
    ...overrides,
  };
}

let seq = 0;
function entry(o: Order, opts: { addedAt?: number; state?: Layer2Result } = {}): BookEntry {
  return {
    orderHash: `0x${(++seq).toString(16).padStart(64, "0")}` as Hex,
    announce: { order: o, sig: "0x" as Hex },
    addedAt: opts.addedAt ?? NOW,
    ...(opts.state ? { state: opts.state } : {}),
  };
}

describe("queryOrders — one-sided, pair and side filters", () => {
  const sellWethForUsdc = entry(order());
  const buyWethWithUsdc = entry(
    order({
      side: OrderSide.BUY,
      legsIn: [{ token: USDC, start: 2_000n, end: 0n }],
      legsOut: [{ token: WETH, start: 1_000n, end: 0n, recipient: zeroAddress }],
    }),
  );
  const sellDaiForUsdc = entry(
    order({ maker: BOB, legsIn: [{ token: DAI, start: 5n, end: 0n }] }),
  );
  const all = [sellWethForUsdc, buyWethWithUsdc, sellDaiForUsdc];

  it("token matches either side — the 'everything against X' view", () => {
    const res = queryOrders(all, { token: WETH });
    expect(res.items).toHaveLength(2);
    expect(res.items).toContain(sellWethForUsdc);
    // The BUY order gives USDC and wants WETH; a taker holding WETH wants it.
    expect(res.items).toContain(buyWethWithUsdc);
  });

  it("tokenIn and tokenOut are one-directional", () => {
    expect(queryOrders(all, { tokenIn: WETH }).items).toEqual([sellWethForUsdc]);
    expect(queryOrders(all, { tokenOut: WETH }).items).toEqual([buyWethWithUsdc]);
  });

  it("pair matches both orientations and excludes other markets", () => {
    const res = queryOrders(all, { pair: [WETH, USDC] });
    expect(res.items).toHaveLength(2);
    expect(res.items).not.toContain(sellDaiForUsdc);
  });

  it("side narrows within a pair", () => {
    const res = queryOrders(all, { pair: [WETH, USDC], side: OrderSide.BUY });
    expect(res.items).toEqual([buyWethWithUsdc]);
  });

  it("maker filter is case-insensitive", () => {
    expect(queryOrders(all, { maker: BOB.toUpperCase() as Address }).items).toEqual([sellDaiForUsdc]);
  });
});

describe("queryOrders — solvency filters", () => {
  const fillable = entry(order(), { state: state() });
  const brokeMaker = entry(order({ nonce: 2n }), { state: state({ ok: false, fillableAmount: 0n }) });
  const conditional = entry(order({ nonce: 3n }), { state: state({ validatorsPass: false }) });
  const unchecked = entry(order({ nonce: 4n }));
  const all = [fillable, brokeMaker, conditional, unchecked];

  it("fillableOnly keeps what the chain says a filler could take now", () => {
    const res = queryOrders(all, { fillableOnly: true });
    expect(res.items).toEqual([fillable, conditional]);
  });

  it("a never-verified entry is not fillable — absence of evidence is not evidence", () => {
    expect(queryOrders([unchecked], { fillableOnly: true }).items).toEqual([]);
  });

  it("validatorsPass is separate, so filler-conditional orders stay book-worthy", () => {
    expect(queryOrders(all, { fillableOnly: true, validatorsPass: true }).items).toEqual([fillable]);
  });

  it("minFillable filters on the live amount", () => {
    expect(queryOrders(all, { minFillable: 500n }).items).toEqual([fillable, conditional]);
  });

  it("status filters on the on-chain state", () => {
    const filled = entry(order({ nonce: 5n }), { state: state({ ok: false, status: OrderStatus.Filled }) });
    expect(queryOrders([...all, filled], { status: [OrderStatus.Filled] }).items).toEqual([filled]);
  });
});

describe("queryOrders — sorting and keyset paging", () => {
  const cheap = entry(order({ legsOut: [{ token: USDC, start: 1_000n, end: 0n, recipient: zeroAddress }] }), {
    addedAt: NOW + 3,
  });
  const mid = entry(order({ legsOut: [{ token: USDC, start: 2_000n, end: 0n, recipient: zeroAddress }] }), {
    addedAt: NOW + 2,
  });
  const rich = entry(order({ legsOut: [{ token: USDC, start: 3_000n, end: 0n, recipient: zeroAddress }] }), {
    addedAt: NOW + 1,
  });
  const all = [cheap, mid, rich];

  it("sorts by price ascending", () => {
    expect(queryOrders(all, { sort: "price", direction: "asc" }).items).toEqual([cheap, mid, rich]);
  });

  it("defaults to newest first", () => {
    expect(queryOrders(all).items).toEqual([cheap, mid, rich].sort((a, b) => b.addedAt - a.addedAt));
  });

  it("pages with a cursor and stops cleanly", () => {
    const first = queryOrders(all, { sort: "price", direction: "asc", limit: 2 });
    expect(first.items).toEqual([cheap, mid]);
    expect(first.total).toBe(3);
    expect(first.nextCursor).toBeDefined();

    const second = queryOrders(all, { sort: "price", direction: "asc", limit: 2, cursor: first.nextCursor });
    expect(second.items).toEqual([rich]);
    expect(second.nextCursor).toBeUndefined();
  });

  it("a cursor survives its own row being evicted mid-page", () => {
    const first = queryOrders(all, { sort: "price", direction: "asc", limit: 1 });
    expect(first.items).toEqual([cheap]);
    // `cheap` is filled and gone before the caller asks for page two. Offset
    // paging would now skip `mid`; keyset paging must not.
    const second = queryOrders([mid, rich], { sort: "price", direction: "asc", limit: 1, cursor: first.nextCursor });
    expect(second.items).toEqual([mid]);
  });

  it("caps the page at the requested limit and reports the true total", () => {
    const res = queryOrders(all, { limit: 1 });
    expect(res.items).toHaveLength(1);
    expect(res.total).toBe(3);
  });
});

describe("orderPrice and summarize", () => {
  it("prices the anchor legs as out-per-in", () => {
    expect(orderPrice(order())).toBe(2);
  });

  it("derives filled from the anchor minus what is left", () => {
    const s = summarize(entry(order(), { state: state({ fillableAmount: 400n }) }));
    expect(s.amountIn).toBe("1000");
    expect(s.filledAmount).toBe("600");
    expect(s.status).toBe("Fillable");
    expect(s.fillable).toBe(true);
  });

  it("reports unknown rather than zero when nothing has been checked", () => {
    const s = summarize(entry(order()));
    expect(s.filledAmount).toBeNull();
    expect(s.fillableAmount).toBeNull();
    expect(s.status).toBe("Unknown");
    expect(s.fillable).toBe(false);
  });
});

describe("checkAdmission", () => {
  const ctx = { size: 0, makerCount: () => 0, now: NOW };

  it("admits an ordinary order", () => {
    expect(checkAdmission(order(), ctx).ok).toBe(true);
  });

  it("rejects an order that expires too soon to be worth verifying", () => {
    const res = checkAdmission(order({ deadline: BigInt(NOW + 2) }), ctx);
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/min 15s/);
  });

  it("rejects a deadline far enough out to be squatting", () => {
    const res = checkAdmission(order({ deadline: BigInt(NOW + 400 * 24 * 3600) }), ctx);
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/max/);
  });

  it("bounds structural size", () => {
    const legsIn = Array.from({ length: DEFAULT_ADMISSION.maxLegsIn + 1 }, () => ({
      token: WETH,
      start: 1n,
      end: 0n,
    }));
    expect(checkAdmission(order({ legsIn }), ctx).reason).toMatch(/input legs/);
  });

  it("refuses new orders at book capacity, and flags it as capacity", () => {
    const res = checkAdmission(order(), { ...ctx, size: DEFAULT_ADMISSION.maxOrders });
    expect(res.ok).toBe(false);
    expect(res.capacity).toBe(true);
  });

  it("caps one maker's share of the book", () => {
    const res = checkAdmission(order(), { ...ctx, makerCount: () => DEFAULT_ADMISSION.maxOrdersPerMaker });
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/order limit/);
  });

  it("never refuses a re-announce of an order it already holds", () => {
    const full = { ...ctx, size: DEFAULT_ADMISSION.maxOrders, known: true };
    expect(checkAdmission(order(), full).ok).toBe(true);
  });
});

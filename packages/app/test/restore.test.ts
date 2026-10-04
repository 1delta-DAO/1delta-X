import { describe, expect, it } from "vitest";
import { hashOrderStruct, orderToJson, type Deployment, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";

import { RemoteOrderbook } from "../src/backend/remote";
import { rowResolver } from "../src/backend/restore";
import { pinnedToken } from "../src/config/markets";
import { buildOrder } from "../src/lib/order";

/**
 * Page-reload rehydration: with a wallet connected, the remote book reads
 * `GET /orders?maker=` and `GET /fills?maker=` and rebuilds the maker's rows and
 * fills — never trusting the node's hash or maker, never inventing a market.
 */

const BASE = "https://book.test";
const MAKER = "0x00000000000000000000000000000000000000aa" as const;
const OTHER = "0x00000000000000000000000000000000000000bb" as const;
const SIG = `0x${"ab".repeat(65)}` as Hex;
const DEP: Deployment = { chainId: 30, settlement: "0x00000000000000000000000000000000005e771e", permit3: "0x000000000000000000000000000000000000aaaa" };
const resolve = rowResolver((id) => (id === 30 ? DEP : null));
const T0 = 1_700_000_000;

function order(side: "sell" | "buy", nonce: bigint, maker: `0x${string}` = MAKER, amountIn = 100): Order {
  const usdrif = pinnedToken(30, "USDRIF")!;
  const usd0 = pinnedToken(30, "USD0")!;
  return buildOrder({
    maker,
    side,
    pay: side === "sell" ? usdrif : usd0,
    recv: side === "sell" ? usd0 : usdrif,
    amountIn,
    targetOut: side === "sell" ? 99.5 : 100,
    minOut: side === "sell" ? 99.5 : 100,
    ttlSeconds: 3600,
    decaySeconds: 0,
    solver: zeroAddress,
    nonce,
    now: T0,
  }).order;
}

const item = (o: Order, extra: Record<string, unknown> = {}) => ({
  orderHash: hashOrderStruct(o),
  order: orderToJson(o),
  sig: SIG,
  addedAt: T0 + 5,
  filledAmount: "0",
  ...extra,
});

function fakeFetch(routes: Record<string, unknown>) {
  const calls: string[] = [];
  const fn = async (url: string): Promise<Response> => {
    calls.push(url.slice(BASE.length));
    const path = url.slice(BASE.length).split("?")[0]!;
    const body = routes[path];
    return body === undefined
      ? new Response(JSON.stringify({ error: "not found" }), { status: 404 })
      : new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
  };
  return { fn, calls };
}

describe("rowResolver", () => {
  it("inverts buildOrder for both sides of a pinned market", () => {
    const sell = resolve(order("sell", 1n))!;
    expect(sell).toMatchObject({ marketId: "rsk-30-usdrif-usd0", side: "sell", size: 100 });
    expect(sell.price).toBeCloseTo(0.995, 9);
    const buy = resolve(order("buy", 2n))!;
    expect(buy).toMatchObject({ marketId: "rsk-30-usdrif-usd0", side: "buy", size: 100 });
    expect(buy.price).toBeCloseTo(1, 9);
  });

  it("refuses orders it cannot place: unknown tokens, no deployment", () => {
    const o = order("sell", 3n);
    expect(resolve({ ...o, legsIn: [{ ...o.legsIn[0]!, token: "0x1111111111111111111111111111111111111111" }] })).toBeNull();
    expect(rowResolver(() => null)(o)).toBeNull();
  });
});

describe("RemoteOrderbook.restore", () => {
  it("rebuilds the maker's resting rows and fills from the book", async () => {
    const live = order("sell", 10n);
    const partial = order("buy", 11n);
    const gone = order("sell", 12n, MAKER, 50); // fully filled before the reload
    const forged = order("sell", 13n);
    const stranger = order("sell", 14n, OTHER);
    const TX1 = `0x${"11".repeat(32)}`;
    const TX2 = `0x${"22".repeat(32)}`;
    const { fn, calls } = fakeFetch({
      "/orders": {
        orders: [
          item(live),
          item(partial, { filledAmount: (40n * 10n ** 18n).toString() }),
          item(forged, { orderHash: `0x${"00".repeat(32)}` }), // node-supplied hash does not match: skipped
          item(stranger), // not this maker's: skipped
        ],
        total: 4,
      },
      "/fills": {
        fills: [
          { orderHash: hashOrderStruct(partial), txHash: TX2, logIndex: 0, at: T0 + 60, amount: (40n * 10n ** 18n).toString(), cumulative: (40n * 10n ** 18n).toString(), solver: OTHER },
          { orderHash: hashOrderStruct(gone), txHash: TX1, logIndex: 1, at: T0 + 30, amount: (50n * 10n ** 18n).toString(), cumulative: (50n * 10n ** 18n).toString(), solver: OTHER, order: orderToJson(gone) },
        ],
        total: 2,
      },
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn, resolveRow: resolve, now: () => (T0 + 100) * 1000 });
    let notified = 0;
    book.subscribe(() => notified++);
    await book.restore(MAKER);

    expect(calls[0]).toBe(`/orders?maker=${MAKER}&limit=500`);
    expect(calls[1]).toBe(`/fills?maker=${MAKER}&limit=500`);
    const rows = book.orders();
    expect(rows.map((r) => r.id).sort()).toEqual([hashOrderStruct(live), hashOrderStruct(partial)].sort());
    const p = rows.find((r) => r.id === hashOrderStruct(partial))!;
    expect(p).toMatchObject({ side: "buy", marketId: "rsk-30-usdrif-usd0", book: "remote", mine: true, createdAt: (T0 + 5) * 1000 });
    expect(p.filled).toBeCloseTo(40, 6);
    expect(p.signed?.sig).toBe(SIG);

    const fills = book.fills();
    expect(fills.map((f) => f.tx).sort()).toEqual([TX1, TX2].sort());
    const historical = fills.find((f) => f.tx === TX1)!;
    expect(historical).toMatchObject({ side: "sell", size: 50, simulated: false, mine: true });
    expect(notified).toBeGreaterThan(0);

    // Once per maker.
    await book.restore(MAKER);
    expect(calls).toHaveLength(2);
    book.subscribe(() => {})();
  });

  it("an unreachable book leaves nothing restored and retries on the next call", async () => {
    let up = false;
    const live = order("sell", 20n);
    const fn = async (url: string) =>
      up
        ? new Response(JSON.stringify(url.includes("/orders") ? { orders: [item(live)] } : { fills: [] }), { status: 200 })
        : new Response("down", { status: 503 });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn, resolveRow: resolve, now: () => (T0 + 100) * 1000 });
    await book.restore(MAKER);
    expect(book.orders()).toHaveLength(0);
    up = true;
    await book.restore(MAKER);
    expect(book.orders()).toHaveLength(1);
  });
});

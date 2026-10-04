import { describe, expect, it } from "vitest";
import { buildSoftCancel, hashOrderStruct } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";

import type { SignedOrder } from "../src/backend/api";
import { orderbookUrl } from "../src/backend/book";
import { RemoteOrderbook, postOrder } from "../src/backend/remote";
import { pinnedToken } from "../src/config/markets";
import { mergeLadder } from "../src/lib/ladder";
import { buildOrder } from "../src/lib/order";
import type { PoolBook } from "../src/lib/types";
// The SERVER's strict JSON parser (test-only import): whatever the app sends must
// be accepted by it and must hash to the order the maker signed.
import { announceFromJson, softCancelFromJson } from "../../orderbook-server/src/json";

const BASE = "https://book.test";
const MAKER = "0x00000000000000000000000000000000000000aa" as const;
const SIG = `0x${"ab".repeat(65)}` as Hex;
const TX = `0x${"7e".repeat(32)}` as Hex;
const SOLVER = "0x00000000000000000000000000000000000f111e";

function signedOrder(nonce = 1n, deployed = true, now = 1_700_000_000): SignedOrder {
  const draft = buildOrder({
    maker: MAKER,
    side: "sell",
    pay: pinnedToken(30, "USDRIF")!,
    recv: pinnedToken(30, "USD0")!,
    amountIn: 100,
    targetOut: 100,
    minOut: 99.5,
    ttlSeconds: 3600,
    decaySeconds: 0,
    solver: zeroAddress,
    nonce,
    now,
  });
  return {
    order: draft.order,
    sig: SIG,
    hash: draft.hash,
    deployment: { chainId: 30, settlement: "0x00000000000000000000000000000000005e771e", permit3: "0x000000000000000000000000000000000000aaaa" },
    deployed,
  };
}

interface Call {
  url: string;
  method: string;
  contentType: string | null;
  body: string | null;
}

type Route = (url: string, init?: RequestInit) => Response | undefined;

/** A fetch double: records every call and answers from `route`, else 404. */
function fakeFetch(route: Route) {
  const calls: Call[] = [];
  const fn = async (url: string, init?: RequestInit): Promise<Response> => {
    const headers = new Headers(init?.headers);
    calls.push({
      url,
      method: init?.method ?? "GET",
      contentType: headers.get("content-type"),
      body: typeof init?.body === "string" ? init.body : null,
    });
    return route(url, init) ?? json(404, { error: "unknown order" });
  };
  return { fn, calls };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const accept = (hash: Hex): Route => (url, init) =>
  init?.method === "POST" && url === `${BASE}/orders` ? json(202, { orderHash: hash }) : undefined;

function place(book: RemoteOrderbook, s: SignedOrder) {
  return book.place({ marketId: "rsk-30-usdrif-usd0", side: "sell", type: "limit", size: 100, filled: 40, price: 1, ttlMs: 3_600_000, signed: s });
}

describe("remote orderbook client — request encoding", () => {
  it("POSTs the signed order as JSON {order, sig} to /orders, in the server's strict form", async () => {
    const s = signedOrder();
    const { fn, calls } = fakeFetch(accept(s.hash));
    await expect(postOrder(fn, `${BASE}/`, s)).resolves.toEqual({ orderHash: s.hash, duplicate: false });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(`${BASE}/orders`);
    expect(calls[0]!.method).toBe("POST");
    expect(calls[0]!.contentType).toBe("application/json");
    const raw = JSON.parse(calls[0]!.body!) as { order: Record<string, unknown>; sig: string };
    // bigints travel as decimal strings
    expect(raw.order.nonce).toBe("1");
    expect(raw.order.expiry).toBe(String(s.order.expiry));
    const decoded = announceFromJson(raw);
    expect(decoded.sig).toBe(SIG);
    expect(hashOrderStruct(decoded.order)).toBe(s.hash);
    expect(decoded.order.exclusiveFiller).toBe(zeroAddress);
  });

  it("POSTs a soft cancel as JSON {cancel, sig} to /cancels and marks the row soft", async () => {
    const s = signedOrder();
    const { fn, calls } = fakeFetch((url, init) =>
      accept(s.hash)(url, init) ?? (url === `${BASE}/cancels` ? json(202, { evicted: [s.hash], requested: 1 }) : undefined),
    );
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    const cancel = buildSoftCancel(MAKER, [s.hash], { now: 1_700_000_000n });
    await book.cancel(s.hash, { cancel, sig: SIG });
    const post = calls.find((c) => c.url === `${BASE}/cancels`)!;
    expect(post.method).toBe("POST");
    expect(post.contentType).toBe("application/json");
    const decoded = softCancelFromJson(JSON.parse(post.body!));
    expect(decoded.cancel.orderHashes).toEqual([s.hash]);
    expect(decoded.cancel.maker.toLowerCase()).toBe(MAKER);
    expect(decoded.sig).toBe(SIG);
    expect(book.orders()[0]!.cancelled).toBe("soft");
  });

  it("a refused cancel (403) throws and leaves the row as it was", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch((url, init) =>
      accept(s.hash)(url, init) ?? (url === `${BASE}/cancels` ? json(403, { error: "signer is not the maker" }) : undefined),
    );
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    const cancel = buildSoftCancel(MAKER, [s.hash]);
    await expect(book.cancel(s.hash, { cancel, sig: SIG })).rejects.toThrow(/signer is not the maker/);
    expect(book.orders()[0]!.cancelled).toBeUndefined();
  });
});

describe("remote orderbook client — 202 / 422 / 503", () => {
  it("202: the row rests, and NOTHING is counted filled before the chain says so", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch(accept(s.hash));
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    let emitted = 0;
    book.subscribe(() => emitted++);
    const row = await place(book, s);
    expect(row.id).toBe(s.hash);
    expect(row.book).toBe("remote");
    expect(row.filled).toBe(0);
    expect(book.orders()).toHaveLength(1);
    expect(emitted).toBe(1);
    // The mock books the crossing part as a simulated fill; the real book must not.
    book.recordTake({ marketId: row.marketId, side: "sell", size: 40, price: 1, bySource: { UNI: 40, SUSHI: 0, LMT: 0 } });
    expect(book.fills()).toHaveLength(0);
  });

  it("422: the server's reason reaches the user and no row is shown", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch(() => json(422, { error: "maker balance below the order's input" }));
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await expect(place(book, s)).rejects.toThrow(/rejected the order: maker balance below the order's input/);
    expect(book.orders()).toHaveLength(0);
  });

  it("503: reported as unavailable / not posted, and no row is shown", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch(() => json(503, { error: "verification unavailable, retry later" }));
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await expect(place(book, s)).rejects.toThrow(/unavailable.*NOT posted/);
    expect(book.orders()).toHaveLength(0);
  });

  it("an unreachable server, or a 202 for a DIFFERENT hash, is an error too", async () => {
    const s = signedOrder();
    const down = new RemoteOrderbook({
      baseUrl: BASE,
      fetch: async () => {
        throw new TypeError("Failed to fetch");
      },
    });
    await expect(place(down, s)).rejects.toThrow(/Could not reach the orderbook/);
    expect(down.orders()).toHaveLength(0);

    const other = signedOrder(2n);
    const { fn } = fakeFetch(accept(other.hash));
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await expect(place(book, s)).rejects.toThrow(/different order hash/);
    expect(book.orders()).toHaveLength(0);
  });

  it("an order signed into an undeployed domain is not posted at all", async () => {
    const { fn, calls } = fakeFetch(() => json(202, {}));
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await expect(place(book, signedOrder(1n, false))).rejects.toThrow(/No Settlement is deployed/);
    expect(calls).toHaveLength(0);
  });
});

describe("remote orderbook client — status polling shows only REAL fills", () => {
  it("a filled order becomes a fill row carrying the indexed transaction hash", async () => {
    const s = signedOrder();
    const anchor = s.order.legsIn[0]!.start;
    const { fn } = fakeFetch((url, init) => {
      if (init?.method === "POST") return accept(s.hash)(url, init);
      if (url === `${BASE}/orders/${s.hash}/status`) return json(200, { live: false, status: "Filled", filledAmount: anchor.toString() });
      if (url.startsWith(`${BASE}/fills?maker=`))
        return json(200, {
          fills: [{ orderHash: s.hash, solver: SOLVER, txHash: TX, logIndex: 3, at: 1_700_000_100, cumulative: anchor.toString(), amount: anchor.toString() }],
        });
      return undefined;
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    await book.poll();
    const fills = book.fills();
    expect(fills).toHaveLength(1);
    expect(fills[0]!.simulated).toBe(false);
    expect(fills[0]!.tx).toBe(TX);
    expect(fills[0]!.size).toBeCloseTo(100);
    expect(book.orders()).toHaveLength(0); // fully filled: it leaves the open orders
    await book.poll();
    expect(book.fills()).toHaveLength(1); // the same log is never counted twice
  });

  it("a partial fill moves `filled` and keeps the row", async () => {
    const s = signedOrder();
    const half = s.order.legsIn[0]!.start / 2n;
    const { fn } = fakeFetch((url, init) => {
      if (init?.method === "POST") return accept(s.hash)(url, init);
      if (url.endsWith("/status")) return json(200, { live: true, status: "Fillable", filledAmount: half.toString() });
      if (url.includes("/fills?"))
        return json(200, { fills: [{ orderHash: s.hash, solver: SOLVER, txHash: TX, logIndex: 0, at: null, cumulative: half.toString(), amount: half.toString() }] });
      return undefined;
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    await book.poll();
    expect(book.orders()[0]!.filled).toBeCloseTo(50);
    expect(book.fills()[0]!.size).toBeCloseTo(50);
  });

  it("with no fill index (501), a Filled order is shown without a hash — never an invented one", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch((url, init) => {
      if (init?.method === "POST") return accept(s.hash)(url, init);
      if (url.endsWith("/status")) return json(200, { live: false, status: "Filled", filledAmount: null });
      if (url.includes("/fills?")) return json(501, { error: "fill indexing is not enabled on this node" });
      return undefined;
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    await book.poll();
    const fills = book.fills();
    expect(fills).toHaveLength(1);
    expect(fills[0]!.simulated).toBe(false);
    expect(fills[0]!.tx).toBe("");
    expect(book.orders()).toHaveLength(0);
  });

  it("an order the server no longer knows (404) stays listed, labelled off book", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch((url, init) => {
      if (init?.method === "POST") return accept(s.hash)(url, init);
      if (url.includes("/fills?")) return json(200, { fills: [] });
      return undefined; // status → 404
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    await book.poll();
    expect(book.orders()[0]!.offBook).toMatch(/still fillable on-chain/);
    expect(book.fills()).toHaveLength(0);
  });

  it("an order cancelled on-chain leaves the open orders with no fill", async () => {
    const s = signedOrder();
    const { fn } = fakeFetch((url, init) => {
      if (init?.method === "POST") return accept(s.hash)(url, init);
      if (url.endsWith("/status")) return json(200, { live: false, status: "Cancelled", filledAmount: "0" });
      if (url.includes("/fills?")) return json(200, { fills: [] });
      return undefined;
    });
    const book = new RemoteOrderbook({ baseUrl: BASE, fetch: fn });
    await place(book, s);
    await book.poll();
    expect(book.orders()).toHaveLength(0);
    expect(book.fills()).toHaveLength(0);
  });
});

describe("remote book plumbing", () => {
  it("VITE_ORDERBOOK_URL: blank means the mock, a trailing slash is dropped", () => {
    expect(orderbookUrl(undefined)).toBeNull();
    expect(orderbookUrl("  ")).toBeNull();
    expect(orderbookUrl("https://book.test/")).toBe("https://book.test");
    expect(orderbookUrl("/api/book")).toBe("/api/book");
  });

  it("a real-book order priced through the pool mid is not drawn as ladder depth", () => {
    const pool: PoolBook = {
      pool: "p", chainId: 30, block: 1,
      base: { address: "0x1", symbol: "B", name: "B", decimals: 18 },
      quote: { address: "0x2", symbol: "Q", name: "Q", decimals: 6 },
      venues: [], tick: 2, step: 1, bids: [], asks: [], mid: 100,
    };
    const row = { id: "x", marketId: "m", type: "limit" as const, size: 1, filled: 0, createdAt: 0, expiresAt: 1, mine: true, book: "remote" as const };
    const crossed = mergeLadder(pool, [{ ...row, side: "buy", price: 101 }]);
    expect(crossed.bids).toHaveLength(0);
    const resting = mergeLadder(pool, [{ ...row, side: "buy", price: 99 }]);
    expect(resting.bids).toHaveLength(1);
  });
});

describe("remote orderbook client — end to end against the real server routes", () => {
  it("place + soft cancel through buildServer (JSON bodies), with a stub chain verifier", async () => {
    const { buildServer } = await import("../../orderbook-server/src/server");
    const s = signedOrder(1n, true, Math.floor(Date.now() / 1000));
    const server = await buildServer({
      config: { chainId: 30, settlement: s.deployment.settlement, permit3: s.deployment.permit3, lens: zeroAddress, rpcUrl: "" },
      verifier: {
        verifyLayer1: async (a: { order: Parameters<typeof hashOrderStruct>[0] }) => ({ ok: true, orderHash: hashOrderStruct(a.order), deferSig: false }),
        verifyAnnounce: async (a: { order: Parameters<typeof hashOrderStruct>[0] }) => ({
          ok: true,
          orderHash: hashOrderStruct(a.order),
          state: { ok: true, status: 1 /* OrderStatus.Fillable */, fillableAmount: 1n, isSignatureValid: true, validatorsPass: true },
        }),
        refreshStates: async () => new Map(),
      } as never,
      // Accept any cancel signature: this checks the wire, not ECDSA.
      cancelVerifier: { verify: async () => ({ ok: true, signer: MAKER }) } as never,
      logger: false,
      disableRateLimit: true,
    });
    try {
      const viaInject = async (url: string, init?: RequestInit): Promise<Response> => {
        const res = await server.app.inject({
          method: (init?.method ?? "GET") as "GET" | "POST",
          url: url.slice(BASE.length),
          headers: Object.fromEntries(new Headers(init?.headers).entries()),
          ...(typeof init?.body === "string" ? { payload: init.body } : {}),
        });
        return new Response(res.body, { status: res.statusCode, headers: { "content-type": "application/json" } });
      };
      const book = new RemoteOrderbook({ baseUrl: BASE, fetch: viaInject });
      const row = await place(book, s);
      expect(row.id).toBe(s.hash);
      expect(server.book.get(s.hash)?.announce.sig).toBe(SIG);
      await book.cancel(s.hash, { cancel: buildSoftCancel(MAKER, [s.hash]), sig: SIG });
      expect(book.orders()[0]!.cancelled).toBe("soft");
      // A malformed body is a 400 the client surfaces as an error.
      const bad = await viaInject(`${BASE}/orders`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
      expect(bad.status).toBe(400);
    } finally {
      await server.close();
    }
  });
});

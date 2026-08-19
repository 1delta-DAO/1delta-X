import { afterEach, describe, expect, it } from "vitest";
import {
  buildSoftCancel,
  hashOrderStruct,
  OrderSide,
  signSoftCancel,
  type Order,
} from "@1delta-x/sdk";
import {
  encodeOrderAnnounce,
  encodeSoftCancel,
  InMemoryTransport,
  OrderStatus,
  type Layer2Result,
  type OrderAnnounce,
  type OrderbookConfig,
  type OrderSummary,
  type Verifier,
} from "@1delta-x/orderbook";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex } from "viem";

import { buildServer, type OrderbookServer } from "../src/server";

const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const mallory = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

const config: OrderbookConfig = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};

const WETH = "0x1111111111111111111111111111111111111111" as Address;
const USDC = "0x2222222222222222222222222222222222222222" as Address;
const DAI = "0x3333333333333333333333333333333333333333" as Address;

const hour = () => BigInt(Math.floor(Date.now() / 1000) + 3600);

function orderFor(maker: Address, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce: 1n,
    deadline: hour(),
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
    ...over,
  };
}

const okState: Layer2Result = {
  ok: true,
  status: OrderStatus.Fillable,
  fillableAmount: 1_000n,
  isSignatureValid: true,
  validatorsPass: true,
};

/**
 * Admits everything and attaches a Fillable state, so the routes see the shape a
 * real lens would return. Nonce 999 is the "chain says no" sentinel.
 */
function stubVerifier(state: Layer2Result = okState): Verifier {
  return {
    verifyAnnounce: async (a: OrderAnnounce) => {
      const orderHash = hashOrderStruct(a.order);
      if (a.order.nonce === 999n) {
        return { ok: false, reason: "maker has no allowance/balance for this order", orderHash };
      }
      return { ok: true, orderHash, state };
    },
    refreshStates: async () => new Map(),
  } as unknown as Verifier;
}

function makeServer(over: Parameters<typeof buildServer>[0] extends infer T ? Partial<T> : never = {}) {
  return buildServer({
    config,
    verifier: stubVerifier(),
    transport: new InMemoryTransport(),
    logger: false,
    disableRateLimit: true,
    ...over,
  });
}

const post = (url: string, bytes: Uint8Array) => ({
  method: "POST" as const,
  url,
  headers: { "content-type": "application/x-protobuf" },
  payload: Buffer.from(bytes),
});

let server: OrderbookServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function announce(s: OrderbookServer, order: Order): Promise<Hex> {
  const sig = "0x" as Hex;
  const res = await s.app.inject(post("/orders", encodeOrderAnnounce({ order, sig })));
  expect(res.statusCode).toBe(202);
  // The bus is async; the book has ingested by the next tick.
  await new Promise((r) => setTimeout(r, 5));
  return res.json().orderHash as Hex;
}

// ──────────────────── 1 + 2: admission and solvency ────────────────────

describe("admission — what never reaches the chain", () => {
  it("refuses an order that expires too soon to be worth an eth_call", async () => {
    server = await makeServer();
    const order = orderFor(alice.address, { deadline: BigInt(Math.floor(Date.now() / 1000) + 2) });
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })));
    expect(res.statusCode).toBe(422);
    expect(res.json().error).toMatch(/expires in/);
  });

  it("refuses a structurally oversized order before verifying it", async () => {
    server = await makeServer({ admission: { maxLegsIn: 1 } });
    const order = orderFor(alice.address, {
      legsIn: [
        { token: WETH, start: 1n, end: 0n },
        { token: DAI, start: 1n, end: 0n },
      ],
    });
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })));
    expect(res.statusCode).toBe(422);
    expect(res.json().error).toMatch(/input legs/);
  });

  it("caps one maker's share of the book, and says it is capacity not fault", async () => {
    server = await makeServer({ admission: { maxOrdersPerMaker: 1 } });
    await announce(server, orderFor(alice.address, { nonce: 1n }));

    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, { nonce: 2n }), sig: "0x" })));
    expect(res.statusCode).toBe(503);
    expect(res.json().error).toMatch(/order limit/);
  });

  it("still accepts a re-announce of an order it already holds when full", async () => {
    server = await makeServer({ admission: { maxOrdersPerMaker: 1 } });
    const order = orderFor(alice.address);
    await announce(server, order);
    const again = await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })));
    expect(again.statusCode).toBe(202);
  });

  it("rejects an order the chain says the maker cannot fund", async () => {
    server = await makeServer();
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, { nonce: 999n }), sig: "0x" })));
    expect(res.statusCode).toBe(422);
    expect(res.json().error).toMatch(/allowance\/balance/);
  });

  it("does not keep an order whose solvency check failed", async () => {
    server = await makeServer();
    await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, { nonce: 999n }), sig: "0x" })));
    await new Promise((r) => setTimeout(r, 5));
    expect(server.book.size).toBe(0);
  });
});

// ──────────────────── 3: soft-cancel policy ────────────────────

describe("soft cancel — a signature proves who, never what", () => {
  it("evicts on the maker's own signature", async () => {
    server = await makeServer();
    const hash = await announce(server, orderFor(alice.address));

    const cancel = buildSoftCancel(alice.address, [hash]);
    const sig = await signSoftCancel(alice, cancel, config);
    const res = await server.app.inject(post("/cancels", encodeSoftCancel({ cancel, sig })));
    expect(res.statusCode).toBe(202);
    expect(res.json().evicted).toEqual([hash]);
    await new Promise((r) => setTimeout(r, 5));
    expect(server.book.size).toBe(0);
  });

  it("rejects a cancel whose signature is not the named maker's", async () => {
    server = await makeServer();
    const hash = await announce(server, orderFor(alice.address));

    // Mallory claims to be Alice and signs it herself.
    const forged = buildSoftCancel(alice.address, [hash]);
    const sig = await signSoftCancel(mallory, forged, config);
    const res = await server.app.inject(post("/cancels", encodeSoftCancel({ cancel: forged, sig })));
    expect(res.statusCode).toBe(403);
    expect(server.book.size).toBe(1);
  });

  it("will not let a valid signature retract someone else's order", async () => {
    server = await makeServer();
    const victim = await announce(server, orderFor(alice.address));

    // Perfectly valid signature — by Mallory, over Mallory's own cancel, naming
    // Alice's order hash. Authentication succeeds; authorisation must not.
    const cancel = buildSoftCancel(mallory.address, [victim]);
    const sig = await signSoftCancel(mallory, cancel, config);
    const res = await server.app.inject(post("/cancels", encodeSoftCancel({ cancel, sig })));
    expect(res.statusCode).toBe(202);
    expect(res.json().evicted).toEqual([]);

    await new Promise((r) => setTimeout(r, 10));
    expect(server.book.size).toBe(1);
    expect(server.book.get(victim)).toBeDefined();
  });
});

// ──────────────────── 4: rate limiting ────────────────────

describe("rate limiting", () => {
  const inject = (s: OrderbookServer, url: string) => s.app.inject({ method: "GET", url });

  it("refuses reads once the IP budget is spent, with a retry-after", async () => {
    server = await makeServer({
      disableRateLimit: false,
      rateLimit: { ip: { capacity: 4, refillPerSecond: 0 } },
    });
    // /orders costs 2, so the third call is over budget.
    expect((await inject(server, "/orders")).statusCode).toBe(200);
    expect((await inject(server, "/orders")).statusCode).toBe(200);
    const refused = await inject(server, "/orders");
    expect(refused.statusCode).toBe(429);
    expect(refused.headers["retry-after"]).toBeDefined();
    expect(refused.json().error).toMatch(/ip/);
  });

  it("charges writes far more than reads", async () => {
    server = await makeServer({
      disableRateLimit: false,
      rateLimit: { ip: { capacity: 9, refillPerSecond: 0 } },
    });
    // A single write costs 10 and cannot be afforded out of 9.
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address), sig: "0x" })));
    expect(res.statusCode).toBe(429);
  });

  it("meters a maker independently of the IP it arrives from", async () => {
    server = await makeServer({
      disableRateLimit: false,
      rateLimit: { ip: { capacity: 1_000, refillPerSecond: 0 }, maker: { capacity: 10, refillPerSecond: 0 } },
      admission: { maxOrdersPerMaker: 100 },
    });
    const first = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, { nonce: 1n }), sig: "0x" })));
    expect(first.statusCode).toBe(202);

    const second = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, { nonce: 2n }), sig: "0x" })));
    expect(second.statusCode).toBe(429);
    expect(second.json().error).toMatch(/maker/);
  });

  it("rejects an oversized body before parsing it", async () => {
    server = await makeServer({ disableRateLimit: false, rateLimit: { maxBodyBytes: 32 } });
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address), sig: "0x" })));
    expect(res.statusCode).toBe(413);
  });

  it("leaves /health free so a monitor never trips the limiter", async () => {
    server = await makeServer({ disableRateLimit: false, rateLimit: { ip: { capacity: 0, refillPerSecond: 0 } } });
    expect((await inject(server, "/health")).statusCode).toBe(200);
  });
});

// ──────────────────── 5: readers ────────────────────

describe("readers", () => {
  async function seeded(): Promise<OrderbookServer> {
    const s = await makeServer({ admission: { maxOrdersPerMaker: 50 } });
    await announce(s, orderFor(alice.address, { nonce: 1n }));
    await announce(
      s,
      orderFor(alice.address, {
        nonce: 2n,
        side: OrderSide.BUY,
        legsIn: [{ token: USDC, start: 4_000n, end: 0n }],
        legsOut: [{ token: WETH, start: 1_000n, end: 0n, recipient: zeroAddress }],
      }),
    );
    await announce(
      s,
      orderFor(mallory.address, { nonce: 3n, legsIn: [{ token: DAI, start: 500n, end: 0n }] }),
    );
    return s;
  }

  const json = async (s: OrderbookServer, url: string) => {
    const res = await s.app.inject({ method: "GET", url });
    expect(res.statusCode).toBe(200);
    return res.json() as { orders: OrderSummary[]; total: number; nextCursor?: string };
  };

  it("(a) lists a user's open orders", async () => {
    server = await seeded();
    const res = await json(server, `/orders?format=json&maker=${alice.address}`);
    expect(res.total).toBe(2);
    expect(res.orders.every((o) => o.maker.toLowerCase() === alice.address.toLowerCase())).toBe(true);
  });

  it("(c) serves a status for a live order", async () => {
    server = await makeServer();
    const hash = await announce(server, orderFor(alice.address));
    const res = await server.app.inject({ method: "GET", url: `/orders/${hash}/status` });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.live).toBe(true);
    expect(body.status).toBe("Fillable");
    expect(body.fillableAmount).toBe("1000");
    expect(body.filledAmount).toBe("0");
  });

  it("(c) still answers after the order leaves the book", async () => {
    server = await makeServer();
    const hash = await announce(server, orderFor(alice.address));
    const cancel = buildSoftCancel(alice.address, [hash]);
    const sig = await signSoftCancel(alice, cancel, config);
    await server.app.inject(post("/cancels", encodeSoftCancel({ cancel, sig })));
    await new Promise((r) => setTimeout(r, 10));

    const res = await server.app.inject({ method: "GET", url: `/orders/${hash}/status` });
    expect(res.statusCode).toBe(200);
    expect(res.json().live).toBe(false);
    expect(res.json().removedAt).toBeGreaterThan(0);
  });

  it("(c) 404s an order it has genuinely never seen", async () => {
    server = await makeServer();
    const res = await server.app.inject({ method: "GET", url: `/orders/0x${"ff".repeat(32)}/status` });
    expect(res.statusCode).toBe(404);
  });

  it("(d) reads a pair in both orientations", async () => {
    server = await seeded();
    const res = await json(server, `/orders?format=json&pair=${WETH}-${USDC}`);
    expect(res.total).toBe(2);
    const sides = res.orders.map((o) => o.side).sort();
    expect(sides).toEqual(["BUY", "SELL"]);
  });

  it("(e) reads one token across both sides", async () => {
    server = await seeded();
    const res = await json(server, `/orders?format=json&token=${WETH}`);
    expect(res.total).toBe(2);

    const dai = await json(server, `/orders?format=json&token=${DAI}`);
    expect(dai.total).toBe(1);
  });

  it("(f) sorts, filters and pages", async () => {
    server = await seeded();
    const sorted = await json(server, "/orders?format=json&sort=price&direction=asc");
    const prices = sorted.orders.map((o) => o.price);
    expect([...prices].sort((a, b) => a - b)).toEqual(prices);

    const page = await json(server, "/orders?format=json&sort=price&direction=asc&limit=2");
    expect(page.orders).toHaveLength(2);
    expect(page.total).toBe(3);
    expect(page.nextCursor).toBeDefined();

    const rest = await json(server, `/orders?format=json&sort=price&direction=asc&limit=2&cursor=${encodeURIComponent(page.nextCursor!)}`);
    expect(rest.orders).toHaveLength(1);
    expect(rest.nextCursor).toBeUndefined();
  });

  it("(f) rejects a nonsense filter instead of quietly ignoring it", async () => {
    server = await seeded();
    expect((await server.app.inject({ method: "GET", url: "/orders?maker=not-an-address" })).statusCode).toBe(400);
    expect((await server.app.inject({ method: "GET", url: "/orders?sort=whatever" })).statusCode).toBe(400);
    expect((await server.app.inject({ method: "GET", url: "/orders?pair=0x1111" })).statusCode).toBe(400);
  });

  it("keeps protobuf as the default so book peers still get signed announces", async () => {
    server = await seeded();
    const res = await server.app.inject({ method: "GET", url: "/orders" });
    expect(res.headers["content-type"]).toContain("application/x-protobuf");
  });

  it("(b) says plainly that fills are not indexed rather than returning an empty list", async () => {
    server = await makeServer();
    const res = await server.app.inject({ method: "GET", url: `/fills?maker=${alice.address}` });
    expect(res.statusCode).toBe(501);
    expect(res.json().error).toMatch(/not enabled/);
  });
});

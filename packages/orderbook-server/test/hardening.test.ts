import { afterEach, describe, expect, it, vi } from "vitest";
import {
  decodeStreamMessage,
  encodeOrderAnnounce,
  encodeSoftCancel,
  InMemoryTransport,
  OrderStatus,
  signSoftCancel,
  StreamKind,
  type FillIndex,
  type OrderAnnounce,
  type OrderbookConfig,
  type Verifier,
} from "@1delta-x/orderbook";
import { hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import type { FastifyRequest } from "fastify";
import { privateKeyToAccount } from "viem/accounts";
import { HttpRequestError, zeroAddress, type Address, type Hex } from "viem";
import { WebSocket } from "ws";

import { clientAddress, createRateLimiter } from "../src/ratelimit";
import { buildServer, type OrderbookServer } from "../src/server";

/** Regressions for the 2026-09 order-book audit, server side (F5–F9, F11, low items). */

const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const config: OrderbookConfig = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};
const SECRET_RPC = "https://rpc.example/v2/SECRET-API-KEY";
const unix = () => Math.floor(Date.now() / 1000);

function orderFor(maker: Address, nonce = 1n, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce,
    expiry: BigInt(unix() + 3600),
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 0n, recipient: zeroAddress }],
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

const okState = { ok: true, status: OrderStatus.Fillable, fillableAmount: 1000n, isSignatureValid: true, validatorsPass: true };

function stubVerifier(over: Partial<Record<"verifyAnnounce" | "verifyLayer1", unknown>> = {}): Verifier {
  return {
    verifyLayer1: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order), deferSig: false }),
    verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order), state: okState }),
    refreshStates: async () => new Map(),
    ...over,
  } as unknown as Verifier;
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

function makeServer(over: Partial<Parameters<typeof buildServer>[0]> = {}) {
  return buildServer({ config, verifier: stubVerifier(), transport: new InMemoryTransport(), logger: false, disableRateLimit: true, ...over });
}

// ──────────────────── F5 — replays do not drain the maker ────────────────────

describe("F5 — a maker is billed once per new order / cancel", () => {
  const tight = { ip: { capacity: 10_000, refillPerSecond: 0 }, maker: { capacity: 10, refillPerSecond: 0 } };

  it("re-posting a maker's order from anywhere never charges the maker again", async () => {
    server = await makeServer({ disableRateLimit: false, rateLimit: tight });
    const bytes = encodeOrderAnnounce({ order: orderFor(alice.address), sig: "0x" });
    expect((await server.app.inject(post("/orders", bytes))).statusCode).toBe(202);
    for (let i = 0; i < 5; i++) {
      const res = await server.app.inject(post("/orders", bytes));
      expect(res.statusCode).toBe(202);
      expect(res.json().duplicate).toBe(true);
    }
  });

  it("a replay of an order the maker was already billed for costs the maker nothing, even once evicted", async () => {
    // Maker budget for exactly one write + one cancel.
    server = await makeServer({ disableRateLimit: false, rateLimit: { ...tight, maker: { capacity: 15, refillPerSecond: 0 } } });
    const order = orderFor(alice.address);
    const bytes = encodeOrderAnnounce({ order, sig: "0x" });
    expect((await server.app.inject(post("/orders", bytes))).statusCode).toBe(202);
    const cancel = encodeSoftCancel(await signSoftCancel(alice, alice.address, [hashOrderStruct(order)], config));
    expect((await server.app.inject(post("/cancels", cancel))).statusCode).toBe(202);
    // The same signed cancel, replayed: accepted, not billed (the bucket is empty).
    for (let i = 0; i < 3; i++) expect((await server.app.inject(post("/cancels", cancel))).statusCode).toBe(202);
    // The cancelled order, replayed: refused by the tombstone (F6) — never a 429.
    for (let i = 0; i < 3; i++) expect((await server.app.inject(post("/orders", bytes))).statusCode).toBe(422);
  });
});

// ──────────────────── F6 — tombstones on the REST path ────────────────────

describe("F6 — POST /orders honours soft cancels", () => {
  it("refuses a soft-cancelled order, including a cancel that arrived first", async () => {
    server = await makeServer();
    const order = orderFor(alice.address, 7n);
    const cancel = await signSoftCancel(alice, alice.address, [hashOrderStruct(order)], config);
    expect((await server.app.inject(post("/cancels", encodeSoftCancel(cancel)))).statusCode).toBe(202);
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })));
    expect(res.statusCode).toBe(422);
    expect(res.json().error).toMatch(/soft-cancelled/);
    expect(server.book.size).toBe(0);
  });
});

// ──────────────────── F7 — WebSocket limits ────────────────────

async function listen(s: OrderbookServer): Promise<number> {
  await s.app.listen({ host: "127.0.0.1", port: 0 });
  const addr = s.app.server.address();
  if (!addr || typeof addr === "string") throw new Error("no port");
  return addr.port;
}

function connect(port: number, headers: Record<string, string> = {}) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/stream`, { headers });
  const frames: Uint8Array[] = [];
  ws.binaryType = "arraybuffer";
  ws.on("message", (d: ArrayBuffer | Buffer) => frames.push(new Uint8Array(d as ArrayBuffer)));
  const closed = new Promise<number>((resolve) => ws.on("close", (code) => resolve(code)));
  ws.on("error", () => undefined);
  return { ws, frames, closed };
}

describe("F7 — the stream is bounded", () => {
  it("refuses a browser Origin that is not on the allowlist", async () => {
    server = await makeServer({ stream: { allowedOrigins: ["https://app.example"] } });
    const port = await listen(server);
    expect(await connect(port, { origin: "https://evil.example" }).closed).toBe(1008);
    const ok = connect(port, { origin: "https://app.example" });
    await vi.waitFor(() => expect(ok.frames.length).toBe(1));
    ok.ws.close();
  });

  it("caps connections per client address", async () => {
    server = await makeServer({ stream: { maxPerIp: 2 } });
    const port = await listen(server);
    const a = connect(port);
    const b = connect(port);
    await vi.waitFor(() => expect(a.frames.length + b.frames.length).toBe(2));
    expect(await connect(port).closed).toBe(1013);
    a.ws.close();
    b.ws.close();
  });

  it("sends a bounded snapshot of live orders only", async () => {
    server = await makeServer({ stream: { snapshotLimit: 2 } });
    for (let n = 1n; n <= 4n; n++) server.book.admit(hashOrderStruct(orderFor(alice.address, n)), { order: orderFor(alice.address, n), sig: "0x" });
    const expired = orderFor(alice.address, 9n, { expiry: BigInt(unix() - 10) });
    server.book.admit(hashOrderStruct(expired), { order: expired, sig: "0x" });
    const port = await listen(server);
    const c = connect(port);
    await vi.waitFor(() => expect(c.frames.length).toBe(1));
    const snap = decodeStreamMessage(c.frames[0]!);
    expect(snap.kind).toBe(StreamKind.SNAPSHOT);
    if (snap.kind === StreamKind.SNAPSHOT) {
      expect(snap.orders).toHaveLength(2);
      expect(snap.orders.every((a) => a.order.nonce !== 9n)).toBe(true);
    }
    c.ws.close();
  });

  it("drops a consumer whose backlog exceeds the bound instead of buffering for it", async () => {
    server = await makeServer({ stream: { maxBufferedBytes: -1 } }); // any backlog at all
    const port = await listen(server);
    const c = connect(port);
    await vi.waitFor(() => expect(c.frames.length).toBe(1));
    await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address), sig: "0x" })));
    expect(await c.closed).not.toBe(1000);
  });
});

// ──────────────────── F8 — no RPC detail in errors; bad input is a 400 ────────────────────

describe("F8 — errors never leak the RPC URL; malformed input is a 400", () => {
  const rpcError = () => new HttpRequestError({ url: SECRET_RPC, status: 500, body: { method: "eth_call" } });

  it("a verifier RPC failure is a generic 503", async () => {
    server = await makeServer({ verifier: stubVerifier({ verifyAnnounce: async () => Promise.reject(rpcError()) }) });
    const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address), sig: "0x" })));
    expect(res.statusCode).toBe(503);
    expect(res.body).not.toContain("SECRET");
  });

  it("an unexpected throw is a generic 500 via the global handler", async () => {
    const fillIndex = { query: () => { throw rpcError(); }, coverage: {}, stop: () => undefined } as unknown as FillIndex;
    server = await makeServer({ fillIndex });
    const res = await server.app.inject({ method: "GET", url: "/fills" });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ error: "internal error" });
  });

  it("a non-numeric fromBlock is a 400, not a 500", async () => {
    const fillIndex = { query: () => ({ items: [], total: 0 }), coverage: {}, stop: () => undefined } as unknown as FillIndex;
    server = await makeServer({ fillIndex });
    expect((await server.app.inject({ method: "GET", url: "/fills?fromBlock=abc" })).statusCode).toBe(400);
  });

  it("/quote validates its inputs and never echoes an RPC error", async () => {
    server = await makeServer({ client: { readContract: async () => Promise.reject(rpcError()) } as never });
    const order = orderFor(alice.address);
    const { orderHash } = (await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })))).json();
    expect((await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=1&filler=nope` })).statusCode).toBe(400);
    const res = await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=1&filler=${alice.address}` });
    expect(res.statusCode).toBe(422);
    expect(res.body).not.toContain("SECRET");
    expect(res.body).not.toContain("rpc.example");
  });
});

// ──────────────────── F9 — the client address and the bucket map ────────────────────

describe("F9 — X-Forwarded-For is read from the proxy's end; buckets are bounded", () => {
  const req = (xff: string | undefined) => ({ ip: "10.0.0.1", headers: xff === undefined ? {} : { "x-forwarded-for": xff } }) as unknown as FastifyRequest;

  it("takes the entry the trusted proxy appended, not the client-written leftmost", () => {
    expect(clientAddress(req("6.6.6.6, 1.2.3.4"), { trustProxy: true, trustedHops: 1 })).toBe("1.2.3.4");
    expect(clientAddress(req("6.6.6.6, 1.2.3.4, 10.0.0.9"), { trustProxy: true, trustedHops: 2 })).toBe("1.2.3.4");
    // fewer entries than configured proxies → the socket peer
    expect(clientAddress(req("1.2.3.4"), { trustProxy: true, trustedHops: 2 })).toBe("10.0.0.1");
    expect(clientAddress(req("6.6.6.6"), { trustProxy: false, trustedHops: 1 })).toBe("10.0.0.1");
  });

  it("rotating spoofed keys cannot grow the bucket map past maxKeys", () => {
    const limiter = createRateLimiter({ maxKeys: 3, trustProxy: true });
    for (let i = 0; i < 50; i++) limiter.allow(req(`9.9.9.${i}`), 1);
    expect(limiter.stats().ips).toBe(3);
    limiter.stop();
  });
});

// ──────────────────── low: expiry filter, paging header ────────────────────

describe("GET /orders — expired orders and paging", () => {
  it("does not serve an expired order still awaiting the sweep, unless asked", async () => {
    server = await makeServer();
    const live = orderFor(alice.address, 1n);
    const dead = orderFor(alice.address, 2n, { expiry: BigInt(unix() - 5) });
    server.book.admit(hashOrderStruct(live), { order: live, sig: "0x" });
    server.book.admit(hashOrderStruct(dead), { order: dead, sig: "0x" });
    expect((await server.app.inject({ method: "GET", url: "/orders?format=json" })).json().total).toBe(1);
    expect((await server.app.inject({ method: "GET", url: "/orders?format=json&includeExpired=true" })).json().total).toBe(2);
  });

  it("carries the next cursor in a header for protobuf consumers", async () => {
    server = await makeServer();
    for (let n = 1n; n <= 3n; n++) server.book.admit(hashOrderStruct(orderFor(alice.address, n)), { order: orderFor(alice.address, n), sig: "0x" });
    const res = await server.app.inject({ method: "GET", url: "/orders?limit=2" });
    expect(res.headers["x-next-cursor"]).toBeTruthy();
    expect(res.headers["x-total-count"]).toBe("3");
  });
});

// ──────────────────── F11 — the stored announce is first-seen ────────────────────

describe("F11 — a re-post cannot rewrite the served announce", () => {
  it("keeps the original signature / permitBatch", async () => {
    server = await makeServer();
    const order = orderFor(alice.address);
    await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0xaa" as Hex })));
    await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0xbb" as Hex })));
    expect(server.book.get(hashOrderStruct(order))?.announce.sig).toBe("0xaa");
  });
});

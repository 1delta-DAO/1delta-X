import { afterEach, describe, expect, it } from "vitest";
import {
  encodeOrderAnnounce,
  encodeSoftCancel,
  InMemoryTransport,
  OrderStatus,
  signSoftCancel,
  type OrderAnnounce,
  type OrderbookConfig,
  type Verifier,
} from "@1delta-x/orderbook";
import { hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address } from "viem";

import { buildServer, type OrderbookServer } from "../src/server";

/**
 * JSON request bodies on POST /orders and POST /cancels: a strict-CSP browser
 * cannot run the protobuf codec, so it posts `{order, sig}` / `{cancel, sig}`
 * with bigints as decimal strings. Every check must run exactly as for protobuf.
 */

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
const SIG = `0x${"ab".repeat(65)}` as const;
const hour = () => BigInt(Math.floor(Date.now() / 1000) + 3600);

function orderFor(maker: Address, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: hour(),
    legsIn: [{ token: WETH, start: 1_000n, end: 0n }],
    legsOut: [{ token: USDC, start: 2_000n, end: 1_900n, recipient: zeroAddress }],
    timing: (5n << 32n) | 1n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [{ timeDelta: 10, bumpBps: 5000 }],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [{ target: USDC, data: "0x1234" }],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

const okState = { ok: true, status: OrderStatus.Fillable, fillableAmount: 1000n, isSignatureValid: true, validatorsPass: true };

function stubVerifier(): Verifier {
  return {
    verifyLayer1: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order), deferSig: false }),
    verifyAnnounce: async (a: OrderAnnounce) => {
      const orderHash = hashOrderStruct(a.order);
      if (a.order.nonce === 999n) return { ok: false, reason: "maker has no allowance/balance for this order", orderHash };
      if (a.order.nonce === 998n) throw new Error("rpc down");
      return { ok: true, orderHash, state: okState };
    },
    refreshStates: async () => new Map(),
  } as unknown as Verifier;
}

/** The documented JSON form: bigints as decimal strings, everything else as-is. */
const toJson = (v: unknown) => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x));

const pb = (url: string, bytes: Uint8Array) => ({
  method: "POST" as const,
  url,
  headers: { "content-type": "application/x-protobuf" },
  payload: Buffer.from(bytes),
});
const js = (url: string, body: string | object) => ({
  method: "POST" as const,
  url,
  headers: { "content-type": "application/json" },
  payload: typeof body === "string" ? body : toJson(body),
});

const servers: OrderbookServer[] = [];
afterEach(async () => {
  for (const s of servers.splice(0)) await s.close();
});
async function makeServer(over: Partial<Parameters<typeof buildServer>[0]> = {}) {
  const s = await buildServer({ config, verifier: stubVerifier(), transport: new InMemoryTransport(), logger: false, disableRateLimit: true, ...over });
  servers.push(s);
  return s;
}

describe("POST /orders — JSON and protobuf are the same order", () => {
  it("parity: same orderHash, same book entry, same status", async () => {
    const order = orderFor(alice.address, { baselinePriorityFeeWei: 7n });
    const a = await makeServer();
    const b = await makeServer();
    const viaPb = await a.app.inject(pb("/orders", encodeOrderAnnounce({ order, sig: SIG })));
    const viaJson = await b.app.inject(js("/orders", { order, sig: SIG }));
    expect(viaPb.statusCode).toBe(202);
    expect(viaJson.statusCode).toBe(202);
    const hash = hashOrderStruct(order);
    expect(viaJson.json().orderHash).toBe(hash);
    expect(viaJson.json().orderHash).toBe(viaPb.json().orderHash);
    expect(b.book.get(hash)!.announce).toEqual(a.book.get(hash)!.announce);
    const sa = (await a.app.inject({ method: "GET", url: `/orders/${hash}/status` })).json();
    const sb = (await b.app.inject({ method: "GET", url: `/orders/${hash}/status` })).json();
    expect({ ...sb, addedAt: 0 }).toEqual({ ...sa, addedAt: 0 });
  });

  it("a JSON re-post of a protobuf-posted order is the same order (duplicate)", async () => {
    const order = orderFor(alice.address);
    const s = await makeServer();
    expect((await s.app.inject(pb("/orders", encodeOrderAnnounce({ order, sig: SIG })))).statusCode).toBe(202);
    const again = await s.app.inject(js("/orders", { order, sig: SIG }));
    expect(again.statusCode).toBe(202);
    expect(again.json()).toEqual({ orderHash: hashOrderStruct(order), duplicate: true });
    expect(s.book.size).toBe(1);
  });

  it("accepts a charset parameter on the content type", async () => {
    const s = await makeServer();
    const res = await s.app.inject({
      method: "POST",
      url: "/orders",
      headers: { "content-type": "application/json; charset=utf-8" },
      payload: toJson({ order: orderFor(alice.address), sig: SIG }),
    });
    expect(res.statusCode).toBe(202);
  });

  it("runs the same checks: precheck 422, Layer 2 422, capacity 503, verifier outage 503", async () => {
    const s = await makeServer({ admission: { maxOrdersPerMaker: 1 } });
    const soon = await s.app.inject(js("/orders", { order: orderFor(alice.address, { expiry: BigInt(Math.floor(Date.now() / 1000) + 2) }), sig: SIG }));
    expect(soon.statusCode).toBe(422);
    expect(soon.json().error).toMatch(/expires in/);
    const unfunded = await s.app.inject(js("/orders", { order: orderFor(alice.address, { nonce: 999n }), sig: SIG }));
    expect(unfunded.statusCode).toBe(422);
    expect(unfunded.json().error).toMatch(/allowance\/balance/);
    const down = await s.app.inject(js("/orders", { order: orderFor(alice.address, { nonce: 998n }), sig: SIG }));
    expect(down.statusCode).toBe(503);
    expect((await s.app.inject(js("/orders", { order: orderFor(alice.address, { nonce: 1n }), sig: SIG }))).statusCode).toBe(202);
    const full = await s.app.inject(js("/orders", { order: orderFor(alice.address, { nonce: 2n }), sig: SIG }));
    expect(full.statusCode).toBe(503);
    expect(full.json().error).toMatch(/order limit/);
  });

  it("bills the maker once, whichever content type re-posts it", async () => {
    // Budget for exactly one write.
    const s = await makeServer({
      disableRateLimit: false,
      rateLimit: { ip: { capacity: 10_000, refillPerSecond: 0 }, maker: { capacity: 10, refillPerSecond: 0 } },
    });
    const order = orderFor(alice.address);
    expect((await s.app.inject(js("/orders", { order, sig: SIG }))).statusCode).toBe(202);
    expect((await s.app.inject(pb("/orders", encodeOrderAnnounce({ order, sig: SIG })))).statusCode).toBe(202);
    // A NEW order is billed and the bucket is empty: 429.
    expect((await s.app.inject(js("/orders", { order: orderFor(alice.address, { nonce: 2n }), sig: SIG }))).statusCode).toBe(429);
  });
});

describe("POST /orders — malformed JSON is a 400 and never reaches the book", () => {
  const good = () => JSON.parse(toJson({ order: orderFor(alice.address), sig: SIG })) as { order: Record<string, unknown>; sig: string };
  const cases: Array<[string, (b: ReturnType<typeof good>) => unknown]> = [
    ["unknown top-level field", (b) => ({ ...b, sigless: true })],
    ["unknown order field", (b) => ({ ...b, order: { ...b.order, extra: "1" } })],
    ["unknown leg field", (b) => ({ ...b, order: { ...b.order, legsIn: [{ ...(b.order.legsIn as object[])[0], x: 1 }] } })],
    ["missing field", (b) => { const { timing: _t, ...rest } = b.order; return { ...b, order: rest }; }],
    ["bigint as a number", (b) => ({ ...b, order: { ...b.order, nonce: 1 } })],
    ["bigint as hex", (b) => ({ ...b, order: { ...b.order, nonce: "0x1" } })],
    ["bigint with a leading zero", (b) => ({ ...b, order: { ...b.order, nonce: "01" } })],
    ["bigint over uint256", (b) => ({ ...b, order: { ...b.order, nonce: (1n << 256n).toString() } })],
    ["negative bigint", (b) => ({ ...b, order: { ...b.order, nonce: "-1" } })],
    ["bad address", (b) => ({ ...b, order: { ...b.order, maker: "0x1234" } })],
    ["bad checksum", (b) => ({ ...b, order: { ...b.order, maker: "0x70997970c51812dc3A010C7d01b50e0d17dc79C8" } })],
    ["side out of range", (b) => ({ ...b, order: { ...b.order, side: 2 } })],
    ["odd-length sig", (b) => ({ ...b, sig: "0xabc" })],
    ["curve point as a string", (b) => ({ ...b, order: { ...b.order, curve: [{ timeDelta: "10", bumpBps: 1 }] } })],
    ["legs not an array", (b) => ({ ...b, order: { ...b.order, legsIn: {} } })],
    ["body is an array", () => []],
  ];

  it.each(cases)("%s", async (_name, mutate) => {
    const s = await makeServer();
    const res = await s.app.inject(js("/orders", mutate(good()) as object));
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toMatch(/^invalid JSON OrderAnnounce: /);
    expect(s.book.size).toBe(0);
  });

  it("syntax errors and empty bodies", async () => {
    const s = await makeServer();
    const broken = await s.app.inject(js("/orders", "{\"order\":"));
    expect(broken.statusCode).toBe(400);
    expect(broken.json().error).toMatch(/not valid JSON/);
    const empty = await s.app.inject({ method: "POST", url: "/orders", headers: { "content-type": "application/json" }, payload: "" });
    expect(empty.statusCode).toBe(400);
  });

  it("caps the raw JSON body, and holds its protobuf form to maxBodyBytes like a protobuf post", async () => {
    const s = await makeServer({ maxJsonBodyBytes: 512 });
    const big = await s.app.inject(js("/orders", { order: orderFor(alice.address), sig: `0x${"ab".repeat(400)}` }));
    expect(big.statusCode).toBe(413);

    // The protobuf limit applies to the re-encoding: a JSON body under its own
    // cap whose order would not fit as protobuf is refused the same way.
    const order = orderFor(alice.address, { validators: [{ target: USDC, data: `0x${"00".repeat(300)}` }] });
    const limited = await makeServer({
      disableRateLimit: false,
      rateLimit: { maxBodyBytes: encodeOrderAnnounce({ order, sig: SIG }).length - 1 },
    });
    expect((await limited.app.inject(pb("/orders", encodeOrderAnnounce({ order, sig: SIG })))).statusCode).toBe(413);
    expect((await limited.app.inject(js("/orders", { order, sig: SIG }))).statusCode).toBe(413);
  });
});

describe("POST /cancels — JSON", () => {
  it("evicts on the maker's own signed cancel, like protobuf", async () => {
    const s = await makeServer();
    const order = orderFor(alice.address);
    const hash = hashOrderStruct(order);
    expect((await s.app.inject(js("/orders", { order, sig: SIG }))).statusCode).toBe(202);
    const signed = await signSoftCancel(alice, alice.address, [hash], config);
    const res = await s.app.inject(js("/cancels", signed));
    expect(res.statusCode).toBe(202);
    expect(res.json().evicted).toEqual([hash]);
    expect(s.book.size).toBe(0);
    // The same cancel as protobuf is the same cancel (idempotent).
    expect((await s.app.inject(pb("/cancels", encodeSoftCancel(signed)))).statusCode).toBe(202);
  });

  it("a stranger's signature is a 403; malformed bodies are a 400", async () => {
    const s = await makeServer();
    const order = orderFor(alice.address);
    const hash = hashOrderStruct(order);
    await s.app.inject(js("/orders", { order, sig: SIG }));
    const forged = await signSoftCancel(mallory, alice.address, [hash], config);
    expect((await s.app.inject(js("/cancels", forged))).statusCode).toBe(403);
    expect(s.book.size).toBe(1);

    const good = JSON.parse(toJson(await signSoftCancel(alice, alice.address, [hash], config))) as {
      cancel: Record<string, unknown>;
      sig: string;
    };
    for (const bad of [
      { ...good, extra: 1 },
      { ...good, cancel: { ...good.cancel, orderHashes: ["0x1234"] } },
      { ...good, cancel: { ...good.cancel, issuedAt: 5 } },
      { sig: good.sig },
    ]) {
      const res = await s.app.inject(js("/cancels", bad));
      expect(res.statusCode).toBe(400);
      expect(res.json().error).toMatch(/^invalid JSON SoftCancel: /);
    }
    expect(s.book.size).toBe(1);
  });
});

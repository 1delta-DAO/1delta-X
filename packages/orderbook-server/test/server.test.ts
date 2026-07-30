import { afterEach, describe, expect, it, vi } from "vitest";

import {
  decodeOrderAnnounce,
  decodeOrderList,
  decodeStreamMessage,
  encodeOrderAnnounce,
  encodeOrderSoftCancel,
  InMemoryTransport,
  signSoftCancel,
  StreamKind,
  type OrderAnnounce,
  type OrderbookConfig,
  type Verifier,
} from "@1delta-x/orderbook";
import { hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Hex } from "viem";
import { WebSocket } from "ws";

import { buildServer, type OrderbookServer } from "../src/server";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const config: OrderbookConfig = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};

// Admit everything except the sentinel nonce 999 (to exercise a 422).
const stubVerifier = {
  verifyAnnounce: async (a: OrderAnnounce) => {
    const orderHash = hashOrderStruct(a.order);
    if (a.order.nonce === 999n) return { ok: false, reason: "stub-reject", orderHash };
    return { ok: true, orderHash };
  },
  refreshStates: async () => new Map(),
} as unknown as Verifier;

function orderFor(maker: Hex, nonce = 1n): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce,
    deadline: 4_000_000_000n,
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 800n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
  };
}

function makeServer(): Promise<OrderbookServer> {
  return buildServer({ config, verifier: stubVerifier, transport: new InMemoryTransport(), logger: false });
}

const postOrder = (announce: OrderAnnounce) => ({
  method: "POST" as const,
  url: "/orders",
  headers: { "content-type": "application/x-protobuf" },
  payload: Buffer.from(encodeOrderAnnounce(announce)),
});

let server: OrderbookServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

describe("orderbook backend", () => {
  it("POST /orders admits, GET /orders + /orders/:hash serve it", async () => {
    server = await makeServer();
    const order = orderFor(account.address);
    const orderHash = hashOrderStruct(order);

    const res = await server.app.inject(postOrder({ order, sig: "0x" }));
    expect(res.statusCode).toBe(202);
    expect(res.json().orderHash).toBe(orderHash);

    await vi.waitFor(() => expect(server!.book.size).toBe(1));

    const list = await server.app.inject({ method: "GET", url: "/orders" });
    const orders = decodeOrderList(new Uint8Array(list.rawPayload));
    expect(orders).toHaveLength(1);
    expect(orders[0]!.order.maker).toBe(account.address);

    const one = await server.app.inject({ method: "GET", url: `/orders/${orderHash}` });
    expect(one.statusCode).toBe(200);
    expect(decodeOrderAnnounce(new Uint8Array(one.rawPayload)).order.nonce).toBe(1n);

    const missing = await server.app.inject({ method: "GET", url: `/orders/0x${"00".repeat(32)}` });
    expect(missing.statusCode).toBe(404);
  });

  it("rejects an unverifiable order with 422 and a reason", async () => {
    server = await makeServer();
    const res = await server.app.inject(postOrder({ order: orderFor(account.address, 999n), sig: "0x" }));
    expect(res.statusCode).toBe(422);
    expect(res.json().error).toBe("stub-reject");
  });

  it("GET /orders filters by maker", async () => {
    server = await makeServer();
    await server.app.inject(postOrder({ order: orderFor(account.address, 1n), sig: "0x" }));
    await server.app.inject(postOrder({ order: orderFor("0x00000000000000000000000000000000000000aa", 2n), sig: "0x" }));
    await vi.waitFor(() => expect(server!.book.size).toBe(2));

    const list = await server.app.inject({ method: "GET", url: `/orders?maker=${account.address}` });
    expect(decodeOrderList(new Uint8Array(list.rawPayload))).toHaveLength(1);
  });

  it("POST /cancels evicts on a maker-signed cancel; rejects a stranger", async () => {
    server = await makeServer();
    const order = orderFor(account.address);
    const orderHash = hashOrderStruct(order);
    await server.app.inject(postOrder({ order, sig: "0x" }));
    await vi.waitFor(() => expect(server!.book.size).toBe(1));

    // Stranger's signature → 403, order stays.
    const stranger = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
    const bad = await server.app.inject({
      method: "POST",
      url: "/cancels",
      headers: { "content-type": "application/x-protobuf" },
      payload: Buffer.from(encodeOrderSoftCancel(await signSoftCancel(stranger, orderHash))),
    });
    expect(bad.statusCode).toBe(403);
    expect(server.book.size).toBe(1);

    // Maker's own signature → 202, evicted.
    const ok = await server.app.inject({
      method: "POST",
      url: "/cancels",
      headers: { "content-type": "application/x-protobuf" },
      payload: Buffer.from(encodeOrderSoftCancel(await signSoftCancel(account, orderHash))),
    });
    expect(ok.statusCode).toBe(202);
    await vi.waitFor(() => expect(server!.book.size).toBe(0));
  });

  it("GET /health reports chain config + book size", async () => {
    server = await makeServer();
    const res = await server.app.inject({ method: "GET", url: "/health" });
    expect(res.json()).toMatchObject({ chainId: 31, settlement: config.settlement, orders: 0 });
  });

  it("WebSocket /stream sends a SNAPSHOT then a live ADD", async () => {
    server = await makeServer();
    await server.app.listen({ host: "127.0.0.1", port: 0 });
    const addr = server.app.server.address();
    if (!addr || typeof addr === "string") throw new Error("no port");

    const ws = new WebSocket(`ws://127.0.0.1:${addr.port}/stream`);
    const frames: Uint8Array[] = [];
    ws.binaryType = "arraybuffer";
    ws.on("message", (data: ArrayBuffer | Buffer) => frames.push(data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data)));
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });

    // First frame is the SNAPSHOT (empty book).
    await vi.waitFor(() => expect(frames.length).toBeGreaterThanOrEqual(1));
    const snapshot = decodeStreamMessage(frames[0]!);
    expect(snapshot.kind).toBe(StreamKind.SNAPSHOT);

    // Publishing an order pushes a live ADD.
    await server.app.inject(postOrder({ order: orderFor(account.address), sig: "0x" }));
    await vi.waitFor(() => expect(frames.length).toBeGreaterThanOrEqual(2));
    const add = decodeStreamMessage(frames[frames.length - 1]!);
    expect(add.kind).toBe(StreamKind.ADD);
    if (add.kind === StreamKind.ADD) expect(add.order.order.maker).toBe(account.address);

    ws.close();
  });

  it("GET /quote previews via the lens and returns fillUpTo calldata", async () => {
    // Stub client: previewFill returns a fixed (delta, received, paid) triple.
    const stubClient = {
      readContract: async (args: { functionName: string }) => {
        expect(args.functionName).toBe("previewFill");
        return [500n, [500n], [450n]];
      },
    };
    server = await buildServer({
      config,
      verifier: stubVerifier,
      transport: new InMemoryTransport(),
      client: stubClient as never,
      logger: false,
    });
    const order = orderFor(account.address);
    const res0 = await server.app.inject(postOrder({ order, sig: "0x" }));
    const { orderHash } = res0.json() as { orderHash: string };

    const res = await server.app.inject({
      method: "GET",
      url: `/quote?hash=${orderHash}&fillAmount=1000&filler=${account.address}`,
    });
    expect(res.statusCode).toBe(200);
    const quote = res.json() as {
      to: string;
      data: string;
      delta: string;
      receiving: { token: string; amount: string }[];
      paying: { token: string; amount: string }[];
      recipient: string;
    };
    expect(quote.to).toBe(config.settlement);
    expect(quote.data.startsWith("0x")).toBe(true);
    expect(quote.delta).toBe("500");
    expect(quote.receiving[0]).toEqual({ token: order.legsIn[0]!.token, amount: "500" });
    expect(quote.paying[0]).toEqual({ token: order.legsOut[0]!.token, amount: "450" });
    expect(quote.recipient).toBe(account.address); // defaults to the filler
  });

  it("GET /quote 404s an unknown order and 400s missing params", async () => {
    server = await makeServer();
    const missing = await server.app.inject({ method: "GET", url: "/quote?hash=0x01" });
    expect(missing.statusCode).toBe(400);
    const unknown = await server.app.inject({
      method: "GET",
      url: `/quote?hash=0x${"ab".repeat(32)}&fillAmount=1&filler=${account.address}`,
    });
    expect(unknown.statusCode).toBe(404);
  });
});

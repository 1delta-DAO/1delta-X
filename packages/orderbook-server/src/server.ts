import {
  Book,
  decodeOrderAnnounce,
  decodeOrderSoftCancel,
  encodeOrderAnnounce,
  encodeOrderList,
  encodeStreamMessage,
  InMemoryTransport,
  StreamKind,
  topicsFor,
  Verifier,
  type OrderbookConfig,
} from "@1delta-x/orderbook";
import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import { createPublicClient, http, recoverMessageAddress, type Hex, type PublicClient } from "viem";
import type { WebSocket as WsWebSocket } from "ws";

const PROTOBUF_CONTENT_TYPES = ["application/x-protobuf", "application/protobuf", "application/octet-stream"];

export interface BuildServerOptions {
  config: OrderbookConfig;
  /** Inject a viem client (tests / custom RPC). Defaults to `http(config.rpcUrl)`. */
  client?: PublicClient;
  /** Inject a verifier (tests use a stub to skip the chain). */
  verifier?: Verifier;
  /** Inject the internal bus (tests). */
  transport?: InMemoryTransport;
  /** Inject a preconfigured book (tests: e.g. `revalidateMs: 0`). */
  book?: Book;
  logger?: boolean;
}

export interface OrderbookServer {
  app: FastifyInstance;
  book: Book;
  transport: InMemoryTransport;
  config: OrderbookConfig;
  close: () => Promise<void>;
}

/**
 * The demo backend as an "infra node": an `InMemoryTransport` bus, a verified
 * `Book`, and a Fastify REST + WebSocket access layer bridging browser
 * makers/fillers to that bus. Protobuf on the wire throughout. To go P2P, swap
 * the `InMemoryTransport` for a Waku transport — the routes, the Book, and the
 * verification are unchanged.
 *
 * Routes:
 *   POST /orders        protobuf OrderAnnounce  → verify (L1+L2) → publish  → 202
 *   GET  /orders        → protobuf OrderList (filters: maker,tokenIn,tokenOut,side)
 *   GET  /orders/:hash  → protobuf OrderAnnounce
 *   POST /cancels       protobuf OrderSoftCancel → verify maker sig → evict → 202
 *   GET  /stream (ws)   → SNAPSHOT then live ADD / CANCEL StreamMessages
 *   GET  /health        → chain config + book size
 */
export async function buildServer(opts: BuildServerOptions): Promise<OrderbookServer> {
  const { config } = opts;
  const app = Fastify({ logger: opts.logger ?? false });

  // Raw protobuf request bodies arrive as a Buffer.
  app.addContentTypeParser(PROTOBUF_CONTENT_TYPES, { parseAs: "buffer" }, (_req, body, done) => done(null, body));
  await app.register(websocket);

  const transport = opts.transport ?? new InMemoryTransport();
  // Only touch the RPC when we actually need to build a verifier (tests inject a stub).
  const verifier = opts.verifier ?? new Verifier(opts.client ?? createPublicClient({ transport: http(config.rpcUrl) }), config);
  const book = opts.book ?? new Book({ transport, config, verifier });

  const { orders: ordersTopic, cancels: cancelsTopic } = topicsFor(config);

  // Live fan-out to WebSocket clients. Adds are driven by the Book (so they
  // reflect the verified view); maker soft-cancels are broadcast from the
  // /cancels handler (they carry the maker's signature, which clients re-verify).
  // Node self-evictions (expiry / on-chain) are NOT broadcast — a client running
  // its own Book self-evicts via its re-check timer.
  const sockets = new Set<WsWebSocket>();
  const broadcast = (bytes: Uint8Array): void => {
    const buf = Buffer.from(bytes);
    for (const s of sockets) {
      try {
        s.send(buf);
      } catch {
        /* drop dead socket on its own close event */
      }
    }
  };
  book.onAdd((e) => broadcast(encodeStreamMessage({ kind: StreamKind.ADD, order: e.announce })));

  await book.start();

  // ──────────────────── routes ────────────────────

  app.post("/orders", async (request, reply) => {
    const body = request.body as Uint8Array | undefined;
    if (!body || body.length === 0) return reply.code(400).send({ error: "empty body" });
    let announce;
    try {
      announce = decodeOrderAnnounce(body);
    } catch {
      return reply.code(400).send({ error: "undecodable OrderAnnounce" });
    }
    const res = await verifier.verifyAnnounce(announce);
    if (!res.ok) return reply.code(422).send({ error: res.reason ?? "rejected", orderHash: res.orderHash });
    await transport.publish(ordersTopic, body); // Book ingests (cache hit) → onAdd → broadcast
    return reply.code(202).send({ orderHash: res.orderHash });
  });

  app.get("/orders", async (request, reply) => {
    const q = request.query as { maker?: string; tokenIn?: string; tokenOut?: string; side?: string };
    let items = book.list().map((e) => e.announce);
    if (q.maker) items = items.filter((a) => a.order.maker.toLowerCase() === q.maker!.toLowerCase());
    if (q.tokenIn) items = items.filter((a) => a.order.legsIn.some((l) => l.token.toLowerCase() === q.tokenIn!.toLowerCase()));
    if (q.tokenOut) items = items.filter((a) => a.order.legsOut.some((l) => l.token.toLowerCase() === q.tokenOut!.toLowerCase()));
    if (q.side != null) items = items.filter((a) => String(a.order.side) === q.side);
    return reply.type("application/x-protobuf").send(Buffer.from(encodeOrderList(items)));
  });

  app.get("/orders/:hash", async (request, reply) => {
    const { hash } = request.params as { hash: string };
    const entry = book.get(hash as Hex);
    if (!entry) return reply.code(404).send({ error: "not found" });
    return reply.type("application/x-protobuf").send(Buffer.from(encodeOrderAnnounce(entry.announce)));
  });

  app.post("/cancels", async (request, reply) => {
    const body = request.body as Uint8Array | undefined;
    if (!body || body.length === 0) return reply.code(400).send({ error: "empty body" });
    let cancel;
    try {
      cancel = decodeOrderSoftCancel(body);
    } catch {
      return reply.code(400).send({ error: "undecodable OrderSoftCancel" });
    }
    const entry = book.get(cancel.orderHash);
    if (!entry) return reply.code(404).send({ error: "unknown order" });
    let signer: string;
    try {
      signer = await recoverMessageAddress({ message: { raw: cancel.orderHash }, signature: cancel.makerSig });
    } catch {
      return reply.code(400).send({ error: "bad signature" });
    }
    if (signer.toLowerCase() !== entry.announce.order.maker.toLowerCase()) {
      return reply.code(403).send({ error: "not order maker" });
    }
    await transport.publish(cancelsTopic, body); // Book verifies + evicts → onRemove
    broadcast(encodeStreamMessage({ kind: StreamKind.CANCEL, cancel }));
    return reply.code(202).send({ orderHash: cancel.orderHash });
  });

  app.get("/stream", { websocket: true }, (socket: WsWebSocket) => {
    sockets.add(socket);
    try {
      socket.send(Buffer.from(encodeStreamMessage({ kind: StreamKind.SNAPSHOT, orders: book.list().map((e) => e.announce) })));
    } catch {
      /* client may already be gone */
    }
    socket.on("close", () => sockets.delete(socket));
  });

  app.get("/health", async () => ({
    chainId: config.chainId,
    settlement: config.settlement,
    permit3: config.permit3,
    lens: config.lens,
    orders: book.size,
  }));

  return {
    app,
    book,
    transport,
    config,
    close: async () => {
      await book.stop();
      await app.close();
    },
  };
}

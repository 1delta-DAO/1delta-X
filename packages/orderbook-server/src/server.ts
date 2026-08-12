import {
  Book,
  CancelVerifier,
  ChainWatcher,
  decodeOrderAnnounce,
  decodeOrderReplace,
  decodeSoftCancel,
  encodeOrderAnnounce,
  encodeOrderList,
  encodeStreamMessage,
  InMemoryTransport,
  StreamKind,
  topicsFor,
  Verifier,
  type OrderbookConfig,
} from "@1delta-x/orderbook";
import { encodeFillUpTo, SETTLEMENT_LENS_ABI } from "@1delta-x/sdk";
import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import { createPublicClient, http, type Address, type Hex, type PublicClient } from "viem";
import type { WebSocket as WsWebSocket } from "ws";

const PROTOBUF_CONTENT_TYPES = ["application/x-protobuf", "application/protobuf", "application/octet-stream"];

export interface BuildServerOptions {
  config: OrderbookConfig;
  /** Inject a viem client (tests / custom RPC). Defaults to `http(config.rpcUrl)`. */
  client?: PublicClient;
  /** Inject a verifier (tests use a stub to skip the chain). */
  verifier?: Verifier;
  /** Inject the soft-cancel verifier (tests). */
  cancelVerifier?: CancelVerifier;
  /**
   * Watch Settlement logs so cancellations evict immediately and for free,
   * instead of waiting for the O(book) sweep. Off by default because it opens a
   * live log subscription — every test would otherwise start polling a chain.
   * Pass `true` (needs a real `rpcUrl`) or inject a preconfigured watcher.
   */
  watchChain?: boolean;
  watcher?: ChainWatcher;
  /** {OcoGroupModule} addresses to watch `GroupClaimed` on — retires bracket siblings. */
  ocoModules?: Address[];
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
 *   POST /cancels       protobuf SoftCancel → verify EIP-712 sig → evict → 202
 *   POST /replaces      protobuf OrderReplace → admit new, retract old → 202
 *   GET  /stream (ws)   → SNAPSHOT then live ADD / CANCEL / REPLACE StreamMessages
 *   GET  /quote         → JSON fill quote + ready-to-send `fillUpTo` calldata
 *   GET  /health        → chain config + book size
 */
export async function buildServer(opts: BuildServerOptions): Promise<OrderbookServer> {
  const { config } = opts;
  const app = Fastify({ logger: opts.logger ?? false });

  // Raw protobuf request bodies arrive as a Buffer.
  app.addContentTypeParser(PROTOBUF_CONTENT_TYPES, { parseAs: "buffer" }, (_req, body, done) => done(null, body));
  await app.register(websocket);

  const transport = opts.transport ?? new InMemoryTransport();
  // Lazy so a fully-injected test setup (stub verifier, no RPC URL) never
  // constructs a real transport; /quote guards for the no-RPC case itself.
  let clientInst: PublicClient | undefined = opts.client;
  const getClient = (): PublicClient => (clientInst ??= createPublicClient({ transport: http(config.rpcUrl) }));
  const verifier = opts.verifier ?? new Verifier(getClient(), config);
  const cancelVerifier = opts.cancelVerifier ?? new CancelVerifier(getClient, config);
  const watcher =
    opts.watcher ??
    (opts.watchChain
      ? new ChainWatcher({
          client: getClient(),
          config,
          ...(opts.ocoModules ? { ocoModules: opts.ocoModules } : {}),
          onError: (e: unknown) => app.log.warn({ err: e }, "chain watcher"),
        })
      : undefined);
  const book = opts.book ?? new Book({ transport, config, verifier, cancelVerifier, ...(watcher ? { watcher } : {}) });
  // A book that has silently stopped self-cleaning looks exactly like a healthy
  // one, which is why this is wired rather than left to the caller.
  book.onError((err: unknown) => app.log.error({ err }, "book revalidate failed"));

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

  if (watcher) await watcher.start();
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

  // The cancel is verified HERE only to give the caller a real status code; the
  // Book re-verifies it independently on ingest, because a book must never trust
  // the route that fed it.
  app.post("/cancels", async (request, reply) => {
    const body = request.body as Uint8Array | undefined;
    if (!body || body.length === 0) return reply.code(400).send({ error: "empty body" });
    let cancel;
    try {
      cancel = decodeSoftCancel(body);
    } catch {
      return reply.code(400).send({ error: "undecodable SoftCancel" });
    }
    const verdict = await cancelVerifier.verify(cancel);
    if (!verdict.ok) return reply.code(403).send({ error: verdict.reason ?? "rejected" });

    // Which of the named hashes this maker actually owns here. Reported back so
    // a caller can tell "retracted" from "we never had it" — the cancel is
    // accepted either way, since a book that has not seen an order has nothing
    // to evict and nothing to complain about.
    const known = cancel.cancel.orderHashes.filter(
      (h: Hex) => book.get(h)?.announce.order.maker.toLowerCase() === verdict.maker!.toLowerCase(),
    );

    await transport.publish(cancelsTopic, body); // Book verifies + evicts → onRemove
    broadcast(encodeStreamMessage({ kind: StreamKind.CANCEL, cancel }));
    return reply.code(202).send({ evicted: known });
  });

  // Cancel-and-replace: one call, one atomic outcome. The replacement is
  // admitted first and the retraction applied only if it verified, so the
  // maker's quote is never briefly absent from the book.
  app.post("/replaces", async (request, reply) => {
    const body = request.body as Uint8Array | undefined;
    if (!body || body.length === 0) return reply.code(400).send({ error: "empty body" });
    let replace;
    try {
      replace = decodeOrderReplace(body);
    } catch {
      return reply.code(400).send({ error: "undecodable OrderReplace" });
    }
    const res = await book.ingestReplace(replace);
    if (!res.ok) return reply.code(422).send({ error: res.reason ?? "rejected" });

    broadcast(encodeStreamMessage({ kind: StreamKind.REPLACE, replace }));
    return reply.code(202).send({ orderHash: res.orderHash, replaces: replace.replaces });
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

  // Aggregator quote: exact-execution amounts from `SettlementLens.previewFill`
  // (same clamp / exclusivity / pricing as the fill) + ready-to-send `fillUpTo`
  // calldata. JSON, not protobuf — this route talks to router integrations, not
  // book peers. The filler pays `paying.token`s (approve `to` for them) and
  // receives `receiving` at `recipient` (default: the caller).
  //
  //   GET /quote?hash=0x…&fillAmount=…&filler=0x…[&recipient=0x…][&takerData=0x…]
  app.get("/quote", async (request, reply) => {
    const q = request.query as { hash?: string; fillAmount?: string; filler?: string; recipient?: string; takerData?: string };
    if (!q.hash || !q.fillAmount || !q.filler) {
      return reply.code(400).send({ error: "hash, fillAmount, filler are required" });
    }
    const entry = book.get(q.hash as Hex);
    if (!entry) return reply.code(404).send({ error: "unknown order" });
    const order = entry.announce.order;
    let fillAmount: bigint;
    try {
      fillAmount = BigInt(q.fillAmount);
    } catch {
      return reply.code(400).send({ error: "fillAmount not an integer" });
    }
    const takerData = (q.takerData ?? "0x") as Hex;
    if (!clientInst && !config.rpcUrl) return reply.code(503).send({ error: "no RPC configured for quoting" });

    let delta: bigint, received: readonly bigint[], paid: readonly bigint[];
    try {
      [delta, received, paid] = (await getClient().readContract({
        address: config.lens as Address,
        abi: SETTLEMENT_LENS_ABI,
        functionName: "previewFill",
        args: [order as never, fillAmount, q.filler as Address, takerData],
      })) as [bigint, readonly bigint[], readonly bigint[]];
    } catch (err) {
      // Preview reverts mirror execution reverts (NotExclusiveFiller, FillTooSmall,
      // OrderCancelled, …) — surface them as an unfillable quote, not a 500.
      const msg = err instanceof Error ? err.message.split("\n")[0] : "preview reverted";
      return reply.code(422).send({ error: msg });
    }

    const data = encodeFillUpTo({
      order,
      sig: entry.announce.sig,
      fillAmount,
      recipient: q.recipient as Address | undefined,
      takerData,
    });
    return reply.send({
      orderHash: q.hash,
      to: config.settlement, //   send the tx here — and approve it for `paying` tokens
      data,
      value: "0",
      delta: delta.toString(),
      receiving: order.legsIn.map((l, i) => ({ token: l.token, amount: received[i]!.toString() })),
      paying: order.legsOut.map((l, j) => ({ token: l.token, amount: paid[j]!.toString() })),
      filler: q.filler,
      recipient: q.recipient ?? q.filler,
    });
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
      watcher?.stop();
      await book.stop();
      await app.close();
    },
  };
}

import {
  Book,
  CancelVerifier,
  ChainWatcher,
  checkAdmission,
  DEFAULT_ADMISSION,
  decodeOrderAnnounce,
  decodeOrderReplace,
  decodeSoftCancel,
  encodeOrderAnnounce,
  encodeOrderList,
  encodeStreamMessage,
  FillIndex,
  InMemoryTransport,
  queryOrders,
  StreamKind,
  summarize,
  topicsFor,
  Verifier,
  type AdmissionPolicy,
  type BookEntry,
  type OrderbookConfig,
  type OrderQuery,
  type OrderSummary,
  type SortKey,
} from "@1delta-x/orderbook";
import { encodeFillUpTo, hashOrderStruct, OrderSide, SETTLEMENT_LENS_ABI } from "@1delta-x/sdk";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import websocket from "@fastify/websocket";
import { createPublicClient, http, isAddress, type Address, type Hex, type PublicClient } from "viem";
import type { WebSocket as WsWebSocket } from "ws";

import { createRateLimiter, ROUTE_COST, type RateLimiter, type RateLimitOptions } from "./ratelimit";

const PROTOBUF_CONTENT_TYPES = ["application/x-protobuf", "application/protobuf", "application/octet-stream"];

/** Largest page a caller may ask for. Beyond this, paginate. */
const MAX_PAGE = 500;
const DEFAULT_PAGE = 100;

/** How many evicted orders keep a readable status. */
const TOMBSTONE_CAPACITY = 5_000;

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
   */
  watchChain?: boolean;
  watcher?: ChainWatcher;
  /** {OcoGroupModule} addresses to watch `GroupClaimed` on — retires bracket siblings. */
  ocoModules?: Address[];
  /** Inject the internal bus (tests). */
  transport?: InMemoryTransport;
  /** Inject a preconfigured book (tests: e.g. `revalidateMs: 0`). */
  book?: Book;
  /** Local pre-filter and capacity caps. Defaults to {@link DEFAULT_ADMISSION}. */
  admission?: Partial<AdmissionPolicy>;
  /** Token-bucket limits. Defaults to a read-generous, write-strict profile. */
  rateLimit?: Partial<RateLimitOptions>;
  /** Disable rate limiting entirely. Tests only — never in front of a network. */
  disableRateLimit?: boolean;
  /**
   * Index `OrderFilled` logs so `/fills` can answer. Needs a real RPC. Off by
   * default: it opens a subscription and backfills a log range on start.
   */
  indexFills?: boolean;
  /** Block to backfill fills from. Default: a lookback window from head. */
  fillsFromBlock?: bigint;
  fillIndex?: FillIndex;
  logger?: boolean;
}

export interface OrderbookServer {
  app: FastifyInstance;
  book: Book;
  transport: InMemoryTransport;
  config: OrderbookConfig;
  fills?: FillIndex;
  close: () => Promise<void>;
}

/**
 * The demo backend as an "infra node": an `InMemoryTransport` bus, a verified
 * `Book`, and a Fastify REST + WebSocket access layer bridging browser
 * makers/fillers to that bus. Protobuf on the wire for book traffic, JSON for
 * the human-facing reads. To go P2P, swap the `InMemoryTransport` for a Waku
 * transport — the routes, the Book, and the verification are unchanged.
 *
 * Every write is gated in cost order — body size, then IP budget, then a local
 * structural check, then the maker's budget, and only then the `eth_call` that
 * actually costs money. Rejecting late is how a free endpoint becomes an
 * expensive one.
 *
 * Routes:
 *   POST /orders          protobuf OrderAnnounce → admit → verify (L1+L2) → 202
 *   GET  /orders          protobuf OrderList, or JSON with `?format=json`
 *   GET  /orders/:hash    protobuf OrderAnnounce
 *   GET  /orders/:hash/status  JSON status, including recently-evicted orders
 *   GET  /fills           JSON settlement fills (maker / solver / order), with coverage
 *   POST /cancels         protobuf SoftCancel → verify EIP-712 sig → evict → 202
 *   POST /replaces        protobuf OrderReplace → admit new, retract old → 202
 *   GET  /stream (ws)     SNAPSHOT then live ADD / CANCEL / REPLACE
 *   GET  /quote           JSON fill quote + ready-to-send `fillUpTo` calldata
 *   GET  /health          chain config, book size, limiter and index state
 */
export async function buildServer(opts: BuildServerOptions): Promise<OrderbookServer> {
  const { config } = opts;
  const app = Fastify({ logger: opts.logger ?? false });
  const admission: AdmissionPolicy = { ...DEFAULT_ADMISSION, ...opts.admission };
  const limiter: RateLimiter | null = opts.disableRateLimit ? null : createRateLimiter(opts.rateLimit);

  app.addContentTypeParser(PROTOBUF_CONTENT_TYPES, { parseAs: "buffer" }, (_req, body, done) => done(null, body));
  await app.register(websocket);

  const transport = opts.transport ?? new InMemoryTransport();
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
  book.onError((err: unknown) => app.log.error({ err }, "book revalidate failed"));

  const fills =
    opts.fillIndex ??
    (opts.indexFills
      ? new FillIndex({ client: getClient(), config, onError: (e) => app.log.warn({ err: e }, "fill index") })
      : undefined);

  const { orders: ordersTopic, cancels: cancelsTopic } = topicsFor(config);

  // ── per-maker order counts, for the admission cap ──────
  // Derived on demand from the book rather than kept as a second source of
  // truth: a counter that drifts from the book is worse than an O(n) walk at
  // the rate writes actually arrive.
  const makerCount = (maker: Address): number => {
    const needle = maker.toLowerCase();
    let n = 0;
    for (const e of book.list()) if (e.announce.order.maker.toLowerCase() === needle) n++;
    return n;
  };

  // ── tombstones ────────────────────────────────────────
  // An order leaves the book precisely when it becomes interesting to ask about
  // — filled, cancelled, expired. Answering 404 for those turns "what happened
  // to my order?" into the one question the API cannot answer, so the last known
  // summary is kept for a bounded while after eviction.
  const tombstones = new Map<Hex, OrderSummary & { removedAt: number }>();
  book.onRemove((entry: BookEntry) => {
    tombstones.set(entry.orderHash, { ...summarize(entry), removedAt: Math.floor(Date.now() / 1000) });
    while (tombstones.size > TOMBSTONE_CAPACITY) {
      const oldest = tombstones.keys().next().value;
      if (oldest === undefined) break;
      tombstones.delete(oldest);
    }
  });

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
  if (fills && !opts.fillIndex) {
    // Backfill in the background: a node that cannot serve history yet is far
    // better than one that will not accept orders until it can.
    void fills
      .backfill(opts.fillsFromBlock)
      .then((n) => app.log.info({ fills: n }, "fill backfill complete"))
      .catch((err) => app.log.warn({ err }, "fill backfill failed"));
    fills.watch();
  }

  // ──────────────────── helpers ────────────────────

  const gate = (request: FastifyRequest, reply: FastifyReply, cost: number): boolean =>
    limiter ? limiter.charge(request, reply, cost) : true;

  const gateMaker = (maker: string, reply: FastifyReply, cost: number): boolean =>
    limiter ? limiter.chargeMaker(maker, reply, cost) : true;

  const gateBody = (body: Uint8Array | undefined, reply: FastifyReply): boolean => {
    if (limiter) return limiter.checkBody(body, reply);
    if (!body || body.length === 0) {
      void reply.code(400).send({ error: "empty body" });
      return false;
    }
    return true;
  };

  const address = (value: string | undefined): Address | undefined =>
    value && isAddress(value) ? (value as Address) : undefined;

  /** Translate query parameters into an {@link OrderQuery}. Unknown values are ignored, not guessed. */
  const parseQuery = (raw: Record<string, string | undefined>): OrderQuery | { error: string } => {
    const q: OrderQuery = {};
    for (const [key, param] of [
      ["maker", raw.maker],
      ["token", raw.token],
      ["tokenIn", raw.tokenIn],
      ["tokenOut", raw.tokenOut],
    ] as const) {
      if (param === undefined) continue;
      const parsed = address(param);
      if (!parsed) return { error: `${key} is not an address` };
      (q as Record<string, unknown>)[key] = parsed;
    }

    if (raw.pair) {
      // "0xA-0xB" — one parameter, because a pair is one concept and two
      // parameters invite the half-specified request that silently means "all".
      const [a, b] = raw.pair.split("-");
      const left = address(a);
      const right = address(b);
      if (!left || !right) return { error: "pair must be tokenA-tokenB, both addresses" };
      q.pair = [left, right];
    }
    if (raw.side !== undefined) {
      const side = raw.side.toUpperCase();
      if (side === "SELL" || side === "0") q.side = OrderSide.SELL;
      else if (side === "BUY" || side === "1") q.side = OrderSide.BUY;
      else return { error: "side must be SELL or BUY" };
    }
    if (raw.fillableOnly !== undefined) q.fillableOnly = raw.fillableOnly !== "false";
    if (raw.validatorsPass !== undefined) q.validatorsPass = raw.validatorsPass !== "false";
    if (raw.minFillable !== undefined) {
      try {
        q.minFillable = BigInt(raw.minFillable);
      } catch {
        return { error: "minFillable is not an integer" };
      }
    }
    if (raw.expiresAfter !== undefined) {
      try {
        q.expiresAfter = BigInt(raw.expiresAfter);
      } catch {
        return { error: "expiresAfter is not a unix timestamp" };
      }
    }
    if (raw.sort !== undefined) {
      const allowed: SortKey[] = ["created", "deadline", "fillable", "price"];
      if (!allowed.includes(raw.sort as SortKey)) return { error: `sort must be one of ${allowed.join(", ")}` };
      q.sort = raw.sort as SortKey;
    }
    if (raw.direction !== undefined) {
      if (raw.direction !== "asc" && raw.direction !== "desc") return { error: "direction must be asc or desc" };
      q.direction = raw.direction;
    }
    const limit = raw.limit === undefined ? DEFAULT_PAGE : Number(raw.limit);
    if (!Number.isFinite(limit) || limit <= 0) return { error: "limit must be a positive integer" };
    q.limit = Math.min(limit, MAX_PAGE);
    if (raw.cursor) q.cursor = raw.cursor;
    return q;
  };

  // ──────────────────── routes ────────────────────

  app.post("/orders", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.write)) return reply;
    const body = request.body as Uint8Array | undefined;
    if (!gateBody(body, reply)) return reply;

    let announce;
    try {
      announce = decodeOrderAnnounce(body!);
    } catch {
      return reply.code(400).send({ error: "undecodable OrderAnnounce" });
    }

    // Local checks before the expensive ones. Structure and capacity cost
    // nothing to judge and reject the bulk of abuse, so they go first. The hash
    // is recomputed here rather than trusted from the wire — it decides whether
    // this is a re-announce, which is what exempts it from the capacity cap.
    const orderHash = hashOrderStruct(announce.order);
    const verdict = checkAdmission(
      announce.order,
      {
        size: book.size,
        makerCount,
        now: Math.floor(Date.now() / 1000),
        known: book.get(orderHash) !== undefined,
      },
      admission,
    );
    if (!verdict.ok) {
      return reply.code(verdict.capacity ? 503 : 422).send({ error: verdict.reason ?? "rejected" });
    }

    if (!gateMaker(announce.order.maker, reply, ROUTE_COST.write)) return reply;

    const res = await verifier.verifyAnnounce(announce);
    if (!res.ok) return reply.code(422).send({ error: res.reason ?? "rejected", orderHash: res.orderHash });
    await transport.publish(ordersTopic, body!); // Book ingests (cache hit) → onAdd → broadcast
    return reply.code(202).send({ orderHash: res.orderHash });
  });

  app.get("/orders", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.query)) return reply;
    const raw = request.query as Record<string, string | undefined>;
    const parsed = parseQuery(raw);
    if ("error" in parsed) return reply.code(400).send(parsed);

    const result = queryOrders(book.list(), parsed);
    if (raw.format === "json" || request.headers.accept?.includes("application/json")) {
      return reply.send({
        orders: result.items.map(summarize),
        total: result.total,
        ...(result.nextCursor ? { nextCursor: result.nextCursor } : {}),
      });
    }
    // Protobuf stays the default: this route also feeds book peers, and a peer
    // wants the signed announce, not a summary it cannot verify.
    return reply.type("application/x-protobuf").send(Buffer.from(encodeOrderList(result.items.map((e) => e.announce))));
  });

  app.get("/orders/:hash", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.read)) return reply;
    const { hash } = request.params as { hash: string };
    const entry = book.get(hash as Hex);
    if (!entry) return reply.code(404).send({ error: "not found" });
    return reply.type("application/x-protobuf").send(Buffer.from(encodeOrderAnnounce(entry.announce)));
  });

  app.get("/orders/:hash/status", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.read)) return reply;
    const { hash } = request.params as { hash: string };
    const entry = book.get(hash as Hex);
    if (entry) return reply.send({ live: true, ...summarize(entry) });

    const grave = tombstones.get(hash as Hex);
    if (grave) return reply.send({ live: false, ...grave });
    return reply.code(404).send({ error: "unknown order", hint: "never seen here, or evicted long ago" });
  });

  app.get("/fills", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.query)) return reply;
    if (!fills) {
      return reply.code(501).send({
        error: "fill indexing is not enabled on this node",
        hint: "start with indexFills: true and an RPC that serves eth_getLogs",
      });
    }
    const raw = request.query as Record<string, string | undefined>;
    const maker = address(raw.maker);
    const solver = address(raw.solver);
    if (raw.maker && !maker) return reply.code(400).send({ error: "maker is not an address" });
    if (raw.solver && !solver) return reply.code(400).send({ error: "solver is not an address" });
    const limit = raw.limit === undefined ? DEFAULT_PAGE : Number(raw.limit);
    if (!Number.isFinite(limit) || limit <= 0) return reply.code(400).send({ error: "limit must be a positive integer" });

    const result = fills.query({
      ...(maker ? { maker } : {}),
      ...(solver ? { solver } : {}),
      ...(raw.orderHash ? { orderHash: raw.orderHash as Hex } : {}),
      ...(raw.fromBlock ? { fromBlock: BigInt(raw.fromBlock) } : {}),
      limit: Math.min(limit, MAX_PAGE),
      ...(raw.cursor ? { cursor: raw.cursor } : {}),
    });

    return reply.send({
      fills: result.items.map((f) => ({
        orderHash: f.orderHash,
        maker: f.maker,
        solver: f.solver,
        blockNumber: f.blockNumber.toString(),
        txHash: f.txHash,
        logIndex: f.logIndex,
        at: f.at,
        cumulative: f.cumulative?.toString() ?? null,
        amount: f.amount?.toString() ?? null,
      })),
      total: result.total,
      ...(result.nextCursor ? { nextCursor: result.nextCursor } : {}),
      // Served with every response so an empty list is never mistaken for
      // "nothing was filled" when it means "not indexed that far back".
      coverage: fills.coverage,
    });
  });

  app.post("/cancels", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.cancel)) return reply;
    const body = request.body as Uint8Array | undefined;
    if (!gateBody(body, reply)) return reply;
    let cancel;
    try {
      cancel = decodeSoftCancel(body!);
    } catch {
      return reply.code(400).send({ error: "undecodable SoftCancel" });
    }
    if (!gateMaker(cancel.cancel.maker, reply, ROUTE_COST.cancel)) return reply;

    const verdict = await cancelVerifier.verify(cancel);
    if (!verdict.ok) return reply.code(403).send({ error: verdict.reason ?? "rejected" });

    // Which of the named hashes this maker actually owns here. A verified
    // signature proves who signed, never what they may retract — the book
    // enforces ownership independently on ingest.
    const known = cancel.cancel.orderHashes.filter(
      (h: Hex) => book.get(h)?.announce.order.maker.toLowerCase() === verdict.maker!.toLowerCase(),
    );

    await transport.publish(cancelsTopic, body!);
    broadcast(encodeStreamMessage({ kind: StreamKind.CANCEL, cancel }));
    return reply.code(202).send({ evicted: known, requested: cancel.cancel.orderHashes.length });
  });

  app.post("/replaces", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.write)) return reply;
    const body = request.body as Uint8Array | undefined;
    if (!gateBody(body, reply)) return reply;
    let replace;
    try {
      replace = decodeOrderReplace(body!);
    } catch {
      return reply.code(400).send({ error: "undecodable OrderReplace" });
    }
    if (!gateMaker(replace.announce.order.maker, reply, ROUTE_COST.write)) return reply;

    const verdict = checkAdmission(
      replace.announce.order,
      { size: book.size, makerCount, now: Math.floor(Date.now() / 1000), known: true },
      admission,
    );
    if (!verdict.ok) return reply.code(422).send({ error: verdict.reason ?? "rejected" });

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

  app.get("/quote", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.quote)) return reply;
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
      to: config.settlement,
      data,
      value: "0",
      delta: delta.toString(),
      receiving: order.legsIn.map((l, i) => ({ token: l.token, amount: received[i]!.toString() })),
      paying: order.legsOut.map((l, j) => ({ token: l.token, amount: paid[j]!.toString() })),
      filler: q.filler,
      recipient: q.recipient ?? q.filler,
    });
  });

  app.get("/health", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.free)) return reply;
    return reply.send({
      chainId: config.chainId,
      settlement: config.settlement,
      permit3: config.permit3,
      lens: config.lens,
      orders: book.size,
      tombstones: tombstones.size,
      admission: { maxOrders: admission.maxOrders, maxOrdersPerMaker: admission.maxOrdersPerMaker },
      rateLimit: limiter ? limiter.stats() : null,
      fills: fills ? fills.coverage : null,
    });
  });

  return {
    app,
    book,
    transport,
    config,
    ...(fills ? { fills } : {}),
    close: async () => {
      limiter?.stop();
      fills?.stop();
      watcher?.stop();
      await book.stop();
      await app.close();
    },
  };
}

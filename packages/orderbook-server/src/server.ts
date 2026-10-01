import {
  Book,
  CancelVerifier,
  ChainWatcher,
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
import {
  encodeFillUpTo,
  hashOrderStruct,
  isPriorityAuction,
  isProportional,
  packOrder,
  OrderSide,
  SETTLEMENT_LENS_ABI,
  softCancelTypedData,
} from "@1delta-x/sdk";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import websocket from "@fastify/websocket";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  hashTypedData,
  http,
  isAddress,
  isHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import type { WebSocket as WsWebSocket } from "ws";

import { clientAddress, createRateLimiter, ROUTE_COST, type RateLimiter, type RateLimitOptions } from "./ratelimit";

const PROTOBUF_CONTENT_TYPES = ["application/x-protobuf", "application/protobuf", "application/octet-stream"];

/** Largest page a caller may ask for. Beyond this, paginate. */
const MAX_PAGE = 500;
const DEFAULT_PAGE = 100;

/** How many evicted orders keep a readable status. */
const TOMBSTONE_CAPACITY = 5_000;

/** How many order hashes / cancels are remembered as "already billed to the maker". */
const BILLED_CAPACITY = 100_000;

/**
 * Gas limit for a `/quote` preview run AT A GAS PRICE. A node checks the sender
 * can afford `gas × gasPrice` even on `eth_call`, and its default limit is the
 * block's (30M+), which no filler holds at a real gas price. A preview is two
 * view calls; this is ample.
 */
const QUOTE_GAS = 5_000_000n;

/**
 * Bounds on the WebSocket stream. Every connection costs a socket, a snapshot and
 * a share of every broadcast, and the route used to take any number of them from
 * anyone — with a full-book snapshot each.
 */
export interface StreamLimits {
  /** Open sockets, all clients together. */
  maxConnections: number;
  /** Open sockets per client address. */
  maxPerIp: number;
  /**
   * Browser `Origin`s allowed to connect. Unset: any. A request with no `Origin`
   * (a non-browser client) is not subject to it — the check exists to stop a
   * third-party page riding a visitor's browser, which always sends one.
   */
  allowedOrigins?: readonly string[];
  /** A socket whose unsent backlog exceeds this is dropped rather than buffered for. */
  maxBufferedBytes: number;
  /** Orders in the connect snapshot — the most recent live ones. Page `/orders` for the rest. */
  snapshotLimit: number;
}

export const DEFAULT_STREAM_LIMITS: StreamLimits = {
  maxConnections: 1_000,
  maxPerIp: 16,
  maxBufferedBytes: 1 << 20,
  snapshotLimit: 1_000,
};

/** Insertion-ordered set with a hard size: the oldest member goes first. */
class BoundedSet<K> {
  private readonly items = new Set<K>();
  constructor(private readonly capacity: number) {}
  has(k: K): boolean {
    return this.items.has(k);
  }
  add(k: K): void {
    this.items.delete(k);
    this.items.add(k);
    while (this.items.size > this.capacity) {
      const oldest = this.items.values().next().value;
      if (oldest === undefined) break;
      this.items.delete(oldest);
    }
  }
}

/**
 * What an RPC failure may tell a client. viem puts the request URL — and with it
 * any API key in the path — into its error messages, so an error is never echoed;
 * a revert is reported by its decoded name alone.
 */
function publicRpcError(err: unknown): string {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      return `preview reverted: ${revert.data?.errorName ?? revert.reason ?? revert.signature ?? "unknown"}`;
    }
  }
  return "preview failed";
}

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
  /** WebSocket connection limits. Defaults to {@link DEFAULT_STREAM_LIMITS}. */
  stream?: Partial<StreamLimits>;
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
  const streamLimits: StreamLimits = { ...DEFAULT_STREAM_LIMITS, ...opts.stream };

  // Nothing thrown inside a route reaches the client as-is. The default handler
  // echoed `err.message`, and an RPC error's message carries the RPC URL — API key
  // included. Client errors Fastify raises itself (413, 415, a bad body) keep their
  // message; everything else is logged here and answered generically.
  app.setErrorHandler((err: { statusCode?: number; message?: string }, request, reply) => {
    const status = typeof err.statusCode === "number" && err.statusCode >= 400 && err.statusCode < 500 ? err.statusCode : 500;
    if (status >= 500) request.log.error({ err }, "unhandled route error");
    void reply.code(status).send({ error: status >= 500 ? "internal error" : (err.message ?? "bad request") });
  });

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
  const book =
    opts.book ??
    new Book({ transport, config, verifier, cancelVerifier, admission, ...(watcher ? { watcher } : {}) });
  book.onError((err: unknown) => app.log.error({ err }, "book revalidate failed"));

  const fills =
    opts.fillIndex ??
    (opts.indexFills
      ? new FillIndex({ client: getClient(), config, onError: (e) => app.log.warn({ err: e }, "fill index") })
      : undefined);

  const { orders: ordersTopic, cancels: cancelsTopic } = topicsFor(config);

  // ── tombstones ────────────────────────────────────────
  // An order leaves the book precisely when it becomes interesting to ask about
  // — filled, cancelled, expired. Answering 404 for those turns "what happened
  // to my order?" into the one question the API cannot answer, so the last known
  // summary is kept for a bounded while after eviction.
  const tombstones = new Map<Hex, OrderSummary & { removedAt: number }>();
  // Progress comes from the fill index's `filled` counter when this node indexes
  // fills; the lens's fillable amount is a capacity and cannot stand in for it.
  const summary = (entry: BookEntry): OrderSummary => summarize(entry, fills?.cumulativeOf(entry.orderHash));
  book.onRemove((entry: BookEntry) => {
    tombstones.set(entry.orderHash, { ...summary(entry), removedAt: Math.floor(Date.now() / 1000) });
    while (tombstones.size > TOMBSTONE_CAPACITY) {
      const oldest = tombstones.keys().next().value;
      if (oldest === undefined) break;
      tombstones.delete(oldest);
    }
  });

  const sockets = new Map<WsWebSocket, string>();
  const socketsPerIp = new Map<string, number>();
  const dropSocket = (s: WsWebSocket): void => {
    const ip = sockets.get(s);
    if (ip === undefined) return;
    sockets.delete(s);
    const n = (socketsPerIp.get(ip) ?? 1) - 1;
    if (n <= 0) socketsPerIp.delete(ip);
    else socketsPerIp.set(ip, n);
  };
  const broadcast = (bytes: Uint8Array): void => {
    const buf = Buffer.from(bytes);
    for (const s of [...sockets.keys()]) {
      // Backpressure: a consumer that is not reading must not make this process
      // buffer every broadcast for it indefinitely. Drop it; it can reconnect and
      // take a fresh snapshot when it is ready to keep up.
      if (s.bufferedAmount > streamLimits.maxBufferedBytes) {
        dropSocket(s);
        s.terminate();
        continue;
      }
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

  // A maker is billed once per NEW thing it signed. Anyone holding a maker's
  // signed order or cancel can re-post it at will, and billing every re-post drained
  // the maker's bucket from a stranger's IP — locking the maker out of its own
  // writes. Re-posts still pay the sender's IP budget.
  const billedOrders = new BoundedSet<Hex>(BILLED_CAPACITY);
  const billedCancels = new BoundedSet<Hex>(BILLED_CAPACITY);
  const billOrder = (orderHash: Hex, maker: string, reply: FastifyReply): boolean => {
    if (billedOrders.has(orderHash)) return true;
    if (!gateMaker(maker, reply, ROUTE_COST.write)) return false;
    billedOrders.add(orderHash);
    return true;
  };

  const unixNow = (): number => Math.floor(Date.now() / 1000);

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
    } else if (raw.includeExpired !== "true") {
      // An expired order sits in the book until the next sweep. Serving it in that
      // window hands fillers an order the settler will refuse.
      q.expiresAfter = BigInt(unixNow() + 1);
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
    let orderHash: Hex;
    try {
      orderHash = hashOrderStruct(announce.order);
    } catch {
      return reply.code(400).send({ error: "unhashable order" });
    }
    // A re-post of a live order changes nothing — the book keeps the first-seen
    // announce — so it is answered here: no lens call, no maker charge.
    if (book.get(orderHash)) return reply.code(202).send({ orderHash, duplicate: true });

    // The book's own gate (tombstones, then the admission policy with its
    // displacement rule) — the same one the transport path runs.
    const verdict = book.precheck(announce.order, orderHash, { encodedBytes: body!.length, policy: admission });
    if (!verdict.ok) {
      return reply.code(verdict.capacity ? 503 : 422).send({ error: verdict.reason ?? "rejected" });
    }

    // THE MAKER BUCKET IS CHARGED ONLY FOR AN ORDER THE BOOK WOULD TAKE. Charging
    // before verification let any client name a victim in `order.maker`, fail
    // verification, and still drain that maker's write budget (F29 P3). Charging
    // right after Layer 1 — a PROVEN maker — still let a stranger replay the
    // maker's own genuine but DEAD orders (filled, cancelled, unfunded, or never
    // posted here: a filled order's signature is public in its fill calldata) and
    // bill 10 tokens apiece before Layer 2 rejected them, locking the maker out of
    // its own posts and soft cancels (audit 2026-09-30 G-TS_FILLER-6). So the
    // charge lands only once Layer 2 has said the order is live and fillable.
    // Rejected traffic costs only the sender's IP budget — and so does a replay of
    // an order the maker was already billed for (see {@link billOrder}).
    let res;
    try {
      const l1 = await verifier.verifyLayer1(announce);
      if (!l1.ok) return reply.code(422).send({ error: l1.reason ?? "rejected", orderHash: l1.orderHash });
      res = await verifier.verifyAnnounce(announce);
    } catch (err) {
      request.log.warn({ err }, "order verification failed");
      return reply.code(503).send({ error: "verification unavailable, retry later" });
    }
    if (!res.ok) return reply.code(422).send({ error: res.reason ?? "rejected", orderHash: res.orderHash });
    if (!billOrder(orderHash, announce.order.maker, reply)) return reply;
    // Admitted HERE, synchronously, so the answer is the book's real one: two
    // concurrent POSTs that both passed the precheck before their lens calls cannot
    // both land past a cap and both be told 202. `admit` → onAdd → broadcast; the
    // publish then only relays to other transport subscribers (the book dedupes).
    const admitted = book.admit(res.orderHash, announce, res.state);
    if (!admitted.ok) return reply.code(admitted.capacity ? 503 : 422).send({ error: admitted.reason ?? "rejected" });
    await transport.publish(ordersTopic, body!);
    return reply.code(202).send({ orderHash: res.orderHash });
  });

  app.get("/orders", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.query)) return reply;
    const raw = request.query as Record<string, string | undefined>;
    const parsed = parseQuery(raw);
    if ("error" in parsed) return reply.code(400).send(parsed);

    const result = queryOrders(book.list(), parsed);
    // Paging metadata rides headers too, so a protobuf consumer (a backfilling
    // peer) can walk the whole book instead of stopping at the first page.
    if (result.nextCursor) reply.header("x-next-cursor", result.nextCursor);
    reply.header("x-total-count", String(result.total));
    if (raw.format === "json" || request.headers.accept?.includes("application/json")) {
      return reply.send({
        orders: result.items.map(summary),
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
    if (entry) return reply.send({ live: true, ...summary(entry) });

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
    let fromBlock: bigint | undefined;
    if (raw.fromBlock) {
      if (!/^\d+$/.test(raw.fromBlock)) return reply.code(400).send({ error: "fromBlock must be a block number" });
      fromBlock = BigInt(raw.fromBlock);
    }

    const result = fills.query({
      ...(maker ? { maker } : {}),
      ...(solver ? { solver } : {}),
      ...(raw.orderHash ? { orderHash: raw.orderHash as Hex } : {}),
      ...(fromBlock !== undefined ? { fromBlock } : {}),
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
    let verdict;
    try {
      verdict = await cancelVerifier.verify(cancel);
    } catch (err) {
      request.log.warn({ err }, "cancel verification failed");
      return reply.code(503).send({ error: "verification unavailable, retry later" });
    }
    if (!verdict.ok) return reply.code(403).send({ error: verdict.reason ?? "rejected" });
    // Charged to the PROVEN signer's maker (see /orders): the cancel verifier has
    // just established who signed — and only for a cancel not already billed, keyed
    // by its signed CONTENT so a re-encoded or re-signed copy is the same cancel.
    const cancelKey = hashTypedData(softCancelTypedData(cancel.cancel, { chainId: config.chainId, settlement: config.settlement, permit3: config.permit3 }) as never);
    if (!billedCancels.has(cancelKey)) {
      if (!gateMaker(cancel.cancel.maker, reply, ROUTE_COST.cancel)) return reply;
      billedCancels.add(cancelKey);
    }

    // Applied to the book HERE, so the 202 means the evictions and tombstones exist
    // — a re-post racing the transport round-trip used to find the order still
    // live. A verified signature proves who signed, never what they may retract:
    // the book evicts only the named orders that name this maker.
    const evicted = book.applyVerifiedCancel(cancel, verdict);

    await transport.publish(cancelsTopic, body!);
    broadcast(encodeStreamMessage({ kind: StreamKind.CANCEL, cancel }));
    return reply.code(202).send({ evicted, requested: cancel.cancel.orderHashes.length });
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
    // `known` is EARNED, not assumed: a replacement is exempt from the book-size
    // and per-maker caps only when it really replaces a live order of the same
    // maker. Hard-coding it let a maker name a never-seen predecessor and grow the
    // book without bound, one signature per order (F29 P4). The book applies the
    // same rule again inside `ingestReplace`; this copy just rejects before any RPC.
    let orderHash: Hex;
    try {
      orderHash = hashOrderStruct(replace.announce.order);
    } catch {
      return reply.code(400).send({ error: "unhashable order" });
    }
    const predecessor = book.get(replace.replaces);
    const known =
      predecessor !== undefined &&
      predecessor.announce.order.maker.toLowerCase() === replace.announce.order.maker.toLowerCase();
    const verdict = book.precheck(replace.announce.order, orderHash, { known, policy: admission });
    if (!verdict.ok) return reply.code(verdict.capacity ? 503 : 422).send({ error: verdict.reason ?? "rejected" });

    // Maker bucket only for a replace the book took, as on /orders (G-TS_FILLER-6),
    // and once per new order. The book re-derives the cap exemption itself, after
    // its awaits (G-TS_FILLER-4); `known` above is only the cheap pre-filter.
    let res;
    try {
      const l1 = await verifier.verifyLayer1(replace.announce);
      if (!l1.ok) return reply.code(422).send({ error: l1.reason ?? "rejected", orderHash: l1.orderHash });
      res = await book.ingestReplace(replace);
    } catch (err) {
      request.log.warn({ err }, "replace verification failed");
      return reply.code(503).send({ error: "verification unavailable, retry later" });
    }
    if (!res.ok) return reply.code(422).send({ error: res.reason ?? "rejected" });
    if (!billOrder(orderHash, replace.announce.order.maker, reply)) return reply;

    broadcast(encodeStreamMessage({ kind: StreamKind.REPLACE, replace }));
    return reply.code(202).send({ orderHash: res.orderHash, replaces: replace.replaces });
  });

  app.get("/stream", { websocket: true }, (socket: WsWebSocket, request: FastifyRequest) => {
    // Refusals close with a reason rather than 4xx: by the time this runs the
    // upgrade has happened. 1008 = policy, 1013 = try again later.
    const origin = request.headers.origin;
    if (streamLimits.allowedOrigins && origin !== undefined && !streamLimits.allowedOrigins.includes(origin)) {
      socket.close(1008, "origin not allowed");
      return;
    }
    const ip = limiter ? limiter.clientKey(request) : clientAddress(request, { trustProxy: false, trustedHops: 1 });
    if (sockets.size >= streamLimits.maxConnections || (socketsPerIp.get(ip) ?? 0) >= streamLimits.maxPerIp) {
      socket.close(1013, "too many connections");
      return;
    }
    if (limiter && !limiter.allow(request, ROUTE_COST.stream)) {
      socket.close(1013, "rate limit exceeded");
      return;
    }
    sockets.set(socket, ip);
    socketsPerIp.set(ip, (socketsPerIp.get(ip) ?? 0) + 1);
    socket.on("close", () => dropSocket(socket));

    // A bounded snapshot of the most recent LIVE orders, not the whole book: every
    // connect used to serialise all of it. A client that wants more pages `/orders`.
    const snapshot = queryOrders(book.list(), {
      expiresAfter: BigInt(unixNow() + 1),
      sort: "created",
      direction: "desc",
      limit: streamLimits.snapshotLimit,
    });
    try {
      socket.send(Buffer.from(encodeStreamMessage({ kind: StreamKind.SNAPSHOT, orders: snapshot.items.map((e) => e.announce) })));
    } catch {
      /* client may already be gone */
    }
  });

  /**
   * The quote route publishes calldata a filler can send as-is, so that calldata
   * must BIND what the quote says (audit 2026-09-30 PERIPH-1.v1 / A-FLEX-1.v1 /
   * CORE-FILLER-1.v1 / X-DIFF-CORE-1.v2 / PERIPH-3.v1). It used to bind neither:
   *
   *  • PRICE. The preview was a plain `eth_call` at gas price 0 — for a
   *    priority-auction order that is the NO-BID bump, the filler's best price —
   *    and the calldata carried `minBumpBps = 0`, so the real fill re-priced at the
   *    sender's gas price (or a price module's live answer, or a falling basefee /
   *    descending curve) with no bound, up to the maker's signed `start`. Now the
   *    preview runs at the caller's `gasPrice` (REQUIRED for a priority-auction
   *    order), the route reads `previewBump` under the same call, and that bump is
   *    the calldata's `minBumpBps`: the fill executes at the quoted price or better
   *    on every leg, or reverts `BumpTooLow`.
   *  • SIZE. The raw requested `fillAmount` — the `2^256-1` "any size" sentinel
   *    included — went into the calldata while the response quoted the resolved
   *    `delta`. On a {Proportional} order the sentinel skips the settler's no-trim
   *    rule and executes at whatever the balance is at inclusion, which an
   *    inventory filler (every direct `fillUpTo` sender is one) must never accept.
   *    The calldata now carries the resolved `delta` for every identity order, so a
   *    proportional anchor that moved reverts `OverFill` instead. (A fill-module
   *    order's `fillAmount` is a module-unit proposal, so it passes through.)
   */
  app.get("/quote", async (request, reply) => {
    if (!gate(request, reply, ROUTE_COST.quote)) return reply;
    const q = request.query as {
      hash?: string;
      fillAmount?: string;
      filler?: string;
      recipient?: string;
      takerData?: string;
      gasPrice?: string;
    };
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
    if (!isAddress(q.filler)) return reply.code(400).send({ error: "filler is not an address" });
    if (q.recipient !== undefined && !isAddress(q.recipient)) return reply.code(400).send({ error: "recipient is not an address" });
    if (q.takerData !== undefined && !isHex(q.takerData)) return reply.code(400).send({ error: "takerData is not hex" });
    const takerData = (q.takerData ?? "0x") as Hex;
    let gasPrice: bigint | undefined;
    if (q.gasPrice !== undefined) {
      if (!/^\d+$/.test(q.gasPrice)) return reply.code(400).send({ error: "gasPrice must be a non-negative integer (wei)" });
      gasPrice = BigInt(q.gasPrice);
    }
    // A priority-auction order prices from `tx.gasprice`: without the gas price the
    // filler will send, the preview is the no-bid quote and the floor would be one
    // no real transaction can meet. Refuse rather than publish it.
    if (isPriorityAuction(order) && (gasPrice === undefined || gasPrice === 0n)) {
      return reply.code(400).send({
        error: "gasPrice is required for a priority-auction order",
        hint: "pass the effective gas price (wei) you will send the fill at; the quote and its price floor are computed at it",
      });
    }
    if (!clientInst && !config.rpcUrl) return reply.code(503).send({ error: "no RPC configured for quoting" });

    // Both previews under ONE call context: the caller's gas price, sent as the
    // filler, so a gas-price-reading pricing path sees what the fill will see.
    const callCtx =
      gasPrice !== undefined ? { account: q.filler as Address, gasPrice, gas: QUOTE_GAS } : {};
    let delta: bigint, received: readonly bigint[], paid: readonly bigint[], bump: bigint;
    try {
      [delta, received, paid] = (await getClient().readContract({
        address: config.lens as Address,
        abi: SETTLEMENT_LENS_ABI,
        functionName: "previewFill",
        // The lens takes the WIRE order (packed blobs), never the authoring struct
        // — see `Verifier.verifyLayer2` (F29 P1).
        args: [packOrder(order), fillAmount, q.filler as Address, takerData],
        ...callCtx,
      } as never)) as [bigint, readonly bigint[], readonly bigint[]];
      bump = (await getClient().readContract({
        address: config.lens as Address,
        abi: SETTLEMENT_LENS_ABI,
        functionName: "previewBump",
        args: [packOrder(order), q.filler as Address, takerData],
        ...callCtx,
      } as never)) as bigint;
    } catch (err) {
      request.log.warn({ err }, "quote preview failed");
      return reply.code(422).send({ error: publicRpcError(err) });
    }

    // SIZE: an identity order's calldata carries the resolved delta, never the
    // raw request (see the route note). A Proportional anchor never trims, so
    // this is what makes a moved balance revert rather than re-size the fill.
    const identity = BigInt(order.fillModule) === 0n;
    const proportional =
      order.side === OrderSide.SELL && order.fillTotal === 0n && isProportional(order.legsIn[0]?.start ?? 0n);
    const calldataAmount = identity ? delta : fillAmount;
    const data = encodeFillUpTo({
      order,
      sig: entry.announce.sig,
      fillAmount: calldataAmount,
      recipient: q.recipient as Address | undefined,
      // PRICE: the quoted bump is the floor. `0` only when nothing decays (the
      // lens returns 0) — then there is no price motion to bound.
      minBumpBps: bump,
      takerData,
    });
    return reply.send({
      orderHash: q.hash,
      to: config.settlement,
      data,
      value: "0",
      delta: delta.toString(),
      // What the calldata binds, stated rather than implied.
      fillAmount: calldataAmount.toString(),
      minBumpBps: bump.toString(),
      gasPrice: gasPrice === undefined ? null : gasPrice.toString(),
      proportional,
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
      softCancels: book.tombstoneCount,
      streams: sockets.size,
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

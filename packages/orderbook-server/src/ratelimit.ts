import type { FastifyReply, FastifyRequest } from "fastify";

/**
 * Cost-weighted token buckets.
 *
 * A flat requests-per-minute cap is the wrong shape for an orderbook. The routes
 * are not equally expensive: `GET /health` is free, `GET /orders` walks a map,
 * and `POST /orders` costs a signature recover plus an `eth_call` against a
 * paid RPC endpoint. Charging every route one unit either throttles reads that
 * cost nothing or leaves the write path — the one that spends money — wide open.
 *
 * So each route declares a cost, and callers spend from a refilling budget.
 *
 * Two independent buckets, because they defend against different things:
 *
 *   • **by IP** — the ordinary flood. Cheap to key, trivially defeated by a
 *     botnet, which is why it is not the only one.
 *   • **by maker** — the expensive flood. Every write carries a signature that
 *     names an account, and an account is not free to rotate. A key that costs
 *     something to create is the strongest identity a permissionless book has.
 *
 * Neither is a substitute for an edge proxy. This bounds what one process will
 * spend; it does not stop packets arriving.
 */
export interface Bucket {
  /** Maximum tokens held — the burst a fresh caller may spend at once. */
  capacity: number;
  /** Tokens added per second. Sustained rate. */
  refillPerSecond: number;
}

export interface RateLimitOptions {
  /** Per client IP. */
  ip: Bucket;
  /** Per maker address on write routes. */
  maker: Bucket;
  /** Largest accepted request body, in bytes. */
  maxBodyBytes: number;
  /** Idle buckets are dropped after this long, so the maps do not grow forever. */
  idleEvictionMs: number;
  /**
   * Hard cap on buckets per map. The idle sweep alone let a caller who rotates
   * keys (spoofed forwarding headers, fresh maker keys) grow the map for a full
   * `idleEvictionMs`; past this, the least-recently-used bucket is dropped.
   */
  maxKeys: number;
  /** Trust `x-forwarded-for` — only ever behind a proxy that sets it. */
  trustProxy: boolean;
  /**
   * With `trustProxy`: how many proxies of YOUR OWN sit in front of this process.
   * The client address is the entry that many places from the RIGHT of
   * `x-forwarded-for` — the one your outermost proxy appended. Everything left of
   * it was written by the client and is worth nothing. Default 1.
   */
  trustedHops: number;
  /** Injectable clock for tests. */
  now?: () => number;
}

export const DEFAULT_RATE_LIMIT: RateLimitOptions = {
  // 60 reads/min sustained, 120 burst — generous for a UI, useless for a scraper.
  ip: { capacity: 120, refillPerSecond: 1 },
  // Writes cost 10, so this is ~6 orders/min sustained per maker, 12 burst.
  maker: { capacity: 120, refillPerSecond: 1 },
  maxBodyBytes: 64 * 1024,
  idleEvictionMs: 10 * 60_000,
  maxKeys: 100_000,
  trustProxy: false,
  trustedHops: 1,
};

/** What each route spends. Reads are cheap; anything that hits the chain is not. */
export const ROUTE_COST = {
  read: 1,
  /** Walks and sorts the book. */
  query: 2,
  /** Signature recover + a lens `eth_call`. */
  write: 10,
  /** Signature recover, sometimes an `eth_call` for contract makers. */
  cancel: 5,
  /** A `previewFill` staticcall against the lens. */
  quote: 5,
  /** A WebSocket connect: the connection itself plus a bounded snapshot. */
  stream: 10,
  free: 0,
} as const;

interface Entry {
  tokens: number;
  updatedAt: number;
}

class TokenBuckets {
  private readonly entries = new Map<string, Entry>();

  constructor(
    private readonly bucket: Bucket,
    private readonly now: () => number,
    private readonly maxKeys: number,
  ) {}

  /** Spend `cost`. Returns how long to wait, in seconds, when refused. */
  take(key: string, cost: number): { ok: true } | { ok: false; retryAfter: number } {
    const at = this.now();
    const entry = this.entries.get(key) ?? { tokens: this.bucket.capacity, updatedAt: at };
    const elapsed = Math.max(0, at - entry.updatedAt) / 1000;
    entry.tokens = Math.min(this.bucket.capacity, entry.tokens + elapsed * this.bucket.refillPerSecond);
    entry.updatedAt = at;

    if (entry.tokens < cost) {
      this.touch(key, entry);
      const shortfall = cost - entry.tokens;
      return { ok: false, retryAfter: Math.max(1, Math.ceil(shortfall / this.bucket.refillPerSecond)) };
    }
    entry.tokens -= cost;
    this.touch(key, entry);
    return { ok: true };
  }

  /** Re-insert at the back (most recent), then trim the least recent past `maxKeys`. */
  private touch(key: string, entry: Entry): void {
    this.entries.delete(key);
    this.entries.set(key, entry);
    while (this.entries.size > this.maxKeys) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  /** Drop buckets that have been idle long enough to have fully refilled anyway. */
  evictIdle(olderThanMs: number): void {
    const cutoff = this.now() - olderThanMs;
    for (const [key, entry] of this.entries) {
      if (entry.updatedAt < cutoff) this.entries.delete(key);
    }
  }

  get size(): number {
    return this.entries.size;
  }
}

export interface RateLimiter {
  /** Charge the IP bucket. Replies 429 and returns false when refused. */
  charge(request: FastifyRequest, reply: FastifyReply, cost: number): boolean;
  /** Charge the IP bucket with no HTTP reply to write (a WebSocket upgrade). */
  allow(request: FastifyRequest, cost: number): boolean;
  /** Charge the maker bucket, once a write's signer is known. */
  chargeMaker(maker: string, reply: FastifyReply, cost: number): boolean;
  /** Reject an oversized body before anything parses it. */
  checkBody(body: Uint8Array | undefined, reply: FastifyReply): boolean;
  /** The address this request is billed to (see {@link clientAddress}). */
  clientKey(request: FastifyRequest): string;
  stats(): { ips: number; makers: number };
  stop(): void;
}

export function createRateLimiter(opts?: Partial<RateLimitOptions>): RateLimiter {
  const config: RateLimitOptions = { ...DEFAULT_RATE_LIMIT, ...opts };
  const now = config.now ?? (() => Date.now());
  const ips = new TokenBuckets(config.ip, now, config.maxKeys);
  const makers = new TokenBuckets(config.maker, now, config.maxKeys);

  const sweep = setInterval(() => {
    ips.evictIdle(config.idleEvictionMs);
    makers.evictIdle(config.idleEvictionMs);
  }, 60_000);
  (sweep as { unref?: () => void }).unref?.();

  const clientKey = (request: FastifyRequest): string => clientAddress(request, config);

  const refuse = (reply: FastifyReply, retryAfter: number, scope: string): boolean => {
    reply.header("retry-after", String(retryAfter));
    void reply.code(429).send({ error: `rate limit exceeded (${scope})`, retryAfter });
    return false;
  };

  return {
    charge(request, reply, cost) {
      if (cost <= 0) return true;
      const verdict = ips.take(clientKey(request), cost);
      return verdict.ok ? true : refuse(reply, verdict.retryAfter, "ip");
    },
    allow(request, cost) {
      return cost <= 0 || ips.take(clientKey(request), cost).ok;
    },
    chargeMaker(maker, reply, cost) {
      if (cost <= 0) return true;
      const verdict = makers.take(maker.toLowerCase(), cost);
      return verdict.ok ? true : refuse(reply, verdict.retryAfter, "maker");
    },
    checkBody(body, reply) {
      if (!body || body.length === 0) {
        void reply.code(400).send({ error: "empty body" });
        return false;
      }
      if (body.length > config.maxBodyBytes) {
        void reply.code(413).send({ error: `body exceeds ${config.maxBodyBytes} bytes` });
        return false;
      }
      return true;
    },
    clientKey,
    stats: () => ({ ips: ips.size, makers: makers.size }),
    stop: () => clearInterval(sweep),
  };
}

/**
 * The address a request is billed to.
 *
 * Behind `trustProxy`, it is read from the RIGHT of `x-forwarded-for`: each proxy
 * APPENDS the address it received from, so the entry `trustedHops` from the end is
 * the one your outermost proxy wrote — the real peer. The leftmost entry, which
 * this used to take, is whatever the client sent in its own header: one request
 * per spoofed value was a fresh, full bucket.
 */
export function clientAddress(
  request: FastifyRequest,
  opts: Pick<RateLimitOptions, "trustProxy" | "trustedHops">,
): string {
  if (opts.trustProxy) {
    const raw = request.headers["x-forwarded-for"];
    const hops = (Array.isArray(raw) ? raw.join(",") : raw ?? "")
      .split(",")
      .map((h) => h.trim())
      .filter((h) => h.length > 0);
    const at = hops.length - Math.max(1, opts.trustedHops);
    // Fewer entries than proxies: the chain is not what was configured, so fall
    // back to the socket peer (the nearest proxy) rather than trust any of it.
    if (at >= 0 && hops[at]) return hops[at]!;
  }
  return request.ip;
}

import {
  checkAdmission,
  isOcoGroupLeg,
  OrderStatus,
  summarize,
  type AdmissionVerdict,
  type BookEntry,
  type CancelVerdict,
  type Layer2Result,
  type OrderAnnounce,
  type OrderSummary,
  type SignedSoftCancel,
  type VerifyResult,
} from "@1delta-x/orderbook/pure";
import {
  announceFromJson,
  hashOrderStruct,
  isProportional,
  JsonBodyError,
  orderFromJson,
  orderToJson,
  OrderSide,
  softCancelFromJson,
  softCancelTypedData,
  type Order,
} from "@1delta-x/sdk";
import { hashTypedData, isAddress, type Address, type Hex } from "viem";

import type { ChainLog, ChainReader, WorkerChainEvent } from "./chain";
import type { WorkerConfig } from "./config";
import { ROUTE_COST, SqlRateLimiter } from "./ratelimit";
import { count, getMeta, migrate, setMeta, type Sql, type SqlValue } from "./store";

/** The verifier surface the book needs — `Verifier` from `@1delta-x/orderbook/pure` in production. */
export interface OrderVerifier {
  verifyLayer1(a: OrderAnnounce): Promise<{ ok: boolean; reason?: string; orderHash: Hex }>;
  verifyAnnounce(a: OrderAnnounce): Promise<VerifyResult>;
  refreshStates(entries: readonly { orderHash: Hex; announce: OrderAnnounce }[]): Promise<Map<Hex, Layer2Result>>;
  invalidate(orderHash: Hex): void;
}

/** `CancelVerifier` from `@1delta-x/orderbook/pure` in production. */
export interface SoftCancelVerifier {
  verify(signed: SignedSoftCancel): Promise<CancelVerdict>;
}

export interface CoreDeps {
  verifier: OrderVerifier;
  cancelVerifier: SoftCancelVerifier;
  chain: ChainReader;
  /** Unix seconds. */
  now: () => number;
  nowMs: () => number;
}

const MAX_PAGE = 500;
const DEFAULT_PAGE = 100;
/** An order the lens could not classify on its own this many sweeps in a row is dropped (the Book's default). */
const MAX_INCONCLUSIVE_STRIKES = 3;
const CANCELLED_SENTINEL = (1n << 256n) - 1n;
const HASH = /^0x[0-9a-fA-F]{64}$/;

export type GraveReason = "filled" | "cancelled" | "soft-cancelled" | "expired" | "evicted" | "displaced";

interface OrderRow {
  hash: string;
  maker: string;
  nonce: string;
  added_at: number;
  announce: string;
  state: string | null;
  strikes: number;
  filled: string | null;
}

interface StoredState {
  ok: boolean;
  status: number;
  fillableAmount: string;
  isSignatureValid: boolean;
  validatorsPass: boolean;
}

const STATUS_NAME: Record<number, string> = {
  [OrderStatus.Invalid]: "Invalid",
  [OrderStatus.Fillable]: "Fillable",
  [OrderStatus.Filled]: "Filled",
  [OrderStatus.Cancelled]: "Cancelled",
  [OrderStatus.Expired]: "Expired",
  [OrderStatus.Inconclusive]: "Inconclusive",
};

// ──────────────────── helpers ────────────────────

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body, (_k, v: unknown) => (typeof v === "bigint" ? v.toString() : v)), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

function toStored(s: Layer2Result): StoredState {
  return {
    ok: s.ok,
    status: s.status,
    fillableAmount: s.fillableAmount.toString(),
    isSignatureValid: s.isSignatureValid,
    validatorsPass: s.validatorsPass,
  };
}

function fromStored(s: StoredState): Layer2Result {
  return {
    ok: s.ok,
    status: s.status as OrderStatus,
    fillableAmount: BigInt(s.fillableAmount),
    isSignatureValid: s.isSignatureValid,
    validatorsPass: s.validatorsPass,
  };
}

/** The canonical stored / served form of an announce: `{order, sig}` with the SDK's fixed key order. */
export function canonicalAnnounce(a: { order: Order; sig: Hex }): string {
  return JSON.stringify({ order: orderToJson(a.order), sig: a.sig });
}

function parseAnnounce(text: string): OrderAnnounce {
  return announceFromJson(JSON.parse(text));
}

/** The fill denominator when it is a fixed number; `null` for a proportional anchor. */
export function anchorOf(order: Order): bigint | null {
  if (order.fillTotal > 0n) return order.fillTotal;
  if (order.side === OrderSide.SELL) {
    const s = order.legsIn[0]?.start ?? 0n;
    return isProportional(s) ? null : s;
  }
  return order.legsOut[0]?.start ?? 0n;
}

function tokenList(tokens: readonly Address[]): string {
  return `,${tokens.map((t) => t.toLowerCase()).join(",")},`;
}

function secs(n: bigint): number {
  return n > BigInt(Number.MAX_SAFE_INTEGER) ? Number.MAX_SAFE_INTEGER : Number(n);
}

async function readCapped(request: Request, cap: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > cap) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(out);
}

// ──────────────────── the book ────────────────────

/**
 * The orderbook as one Durable Object's state machine: JSON routes over SQLite,
 * plus the {@link maintain} pass the alarm runs. Runtime-free (the DO wrapper in
 * `do.ts` supplies `sql` and the deps), so the same code serves production and tests.
 *
 * Every write is gated in cost order, as in `orderbook-server`: body size → IP
 * budget → strict parse → local admission (zero RPC) → Layer 1 + Layer 2 → maker
 * budget (only for an order the book will take) → admit.
 */
export class OrderBookCore {
  private readonly limiter: SqlRateLimiter;
  private lastError: string | null = null;

  constructor(
    private readonly sql: Sql,
    private readonly cfg: WorkerConfig,
    private readonly deps: CoreDeps,
  ) {
    migrate(sql);
    this.limiter = new SqlRateLimiter(sql, deps.nowMs);
  }

  // ──────────────────── routing ────────────────────

  async handle(request: Request, ip: string): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    try {
      if (path === "/health") return method === "GET" ? this.health() : json({ error: "method not allowed" }, 405, { allow: "GET" });
      if (path === "/orders") {
        if (method === "POST") return await this.postOrder(request, ip);
        if (method === "GET") return this.gate(ip, ROUTE_COST.query) ?? this.listOrders(url);
        return json({ error: "method not allowed" }, 405, { allow: "GET, POST" });
      }
      if (path === "/cancels") return method === "POST" ? await this.postCancel(request, ip) : json({ error: "method not allowed" }, 405, { allow: "POST" });
      if (path === "/fills") return method === "GET" ? (this.gate(ip, ROUTE_COST.query) ?? this.listFills(url)) : json({ error: "method not allowed" }, 405, { allow: "GET" });
      const m = /^\/orders\/(0x[0-9a-fA-F]{64})(\/status)?$/.exec(path);
      if (m) {
        if (method !== "GET") return json({ error: "method not allowed" }, 405, { allow: "GET" });
        return this.gate(ip, ROUTE_COST.read) ?? (m[2] ? this.status(m[1]!.toLowerCase()) : this.getOrder(m[1]!.toLowerCase()));
      }
      return json({ error: "not found" }, 404);
    } catch (err) {
      // Never echo an error: an RPC error message carries the RPC URL (API key included).
      this.lastError = err instanceof Error ? err.message.split("\n")[0]!.slice(0, 200) : "error";
      return json({ error: "internal error" }, 500);
    }
  }

  private gate(ip: string, cost: number): Response | undefined {
    const r = this.limiter.take(`ip:${ip}`, this.cfg.rate.ip, cost);
    return r.ok ? undefined : json({ error: "rate limit exceeded" }, 429, { "retry-after": String(r.retryAfter) });
  }

  private gateMaker(maker: string, cost: number): Response | undefined {
    const r = this.limiter.take(`mk:${maker.toLowerCase()}`, this.cfg.rate.maker, cost);
    return r.ok ? undefined : json({ error: "maker rate limit exceeded" }, 429, { "retry-after": String(r.retryAfter) });
  }

  /** Read a JSON write body: content type, raw size cap, UTF-8, JSON syntax. */
  private async readJsonBody(request: Request): Promise<unknown | Response> {
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") return json({ error: "content-type must be application/json (this node speaks JSON only)" }, 415);
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > this.cfg.maxBodyBytes) return json({ error: `body exceeds ${this.cfg.maxBodyBytes} bytes` }, 413);
    let text: string | null;
    try {
      text = await readCapped(request, this.cfg.maxBodyBytes);
    } catch {
      return json({ error: "body is not valid UTF-8" }, 400);
    }
    if (text === null) return json({ error: `body exceeds ${this.cfg.maxBodyBytes} bytes` }, 413);
    if (text.length === 0) return json({ error: "empty body" }, 400);
    try {
      return JSON.parse(text) as unknown;
    } catch {
      return json({ error: "body is not valid JSON" }, 400);
    }
  }

  private bill(key: string, maker: string, cost: number): Response | undefined {
    if (count(this.sql, `SELECT COUNT(*) AS n FROM billed WHERE key = ?`, key) > 0) return undefined;
    const refused = this.gateMaker(maker, cost);
    if (refused) return refused;
    this.sql.exec(`INSERT OR REPLACE INTO billed (key, at) VALUES (?, ?)`, key, this.deps.now());
    return undefined;
  }

  // ──────────────────── POST /orders ────────────────────

  private async postOrder(request: Request, ip: string): Promise<Response> {
    const refused = this.gate(ip, ROUTE_COST.write);
    if (refused) return refused;
    const body = await this.readJsonBody(request);
    if (body instanceof Response) return body;
    let announce: OrderAnnounce;
    try {
      announce = announceFromJson(body);
    } catch (err) {
      return json({ error: `invalid JSON OrderAnnounce: ${err instanceof JsonBodyError ? err.message : "not parseable"}` }, 400);
    }
    if (!this.cfg.configured) return json({ error: "orderbook not configured (settlement / lens not deployed yet)" }, 503);

    let orderHash: Hex;
    try {
      orderHash = hashOrderStruct(announce.order).toLowerCase() as Hex;
    } catch {
      return json({ error: "unhashable order" }, 400);
    }
    // A re-post of a live order changes nothing (first-seen announce kept): no lens call, no maker charge.
    if (this.isLive(orderHash)) return json({ orderHash, duplicate: true }, 202);

    const canonical = canonicalAnnounce(announce);
    const pre = this.precheck(announce.order, orderHash, new TextEncoder().encode(canonical).length);
    if (!pre.ok) return json({ error: pre.reason ?? "rejected" }, pre.capacity ? 503 : 422);

    let res: VerifyResult;
    try {
      const l1 = await this.deps.verifier.verifyLayer1(announce);
      if (!l1.ok) return json({ error: l1.reason ?? "rejected", orderHash: l1.orderHash }, 422);
      res = await this.deps.verifier.verifyAnnounce(announce);
    } catch {
      return json({ error: "verification unavailable, retry later" }, 503);
    }
    if (!res.ok) return json({ error: res.reason ?? "rejected", orderHash: res.orderHash }, 422);

    // The maker is billed only for an order the book takes, once per order (see orderbook-server).
    const billed = this.bill(`o:${orderHash}`, announce.order.maker, ROUTE_COST.write);
    if (billed) return billed;

    // Synchronous from here: the caps are re-checked against the state AFTER the
    // awaits above, where another request may have run (DO output/input gates do
    // not hold across an outbound fetch).
    const admitted = this.admit(orderHash, announce, canonical, res.state);
    if (!admitted.ok) return json({ error: admitted.reason ?? "rejected" }, admitted.capacity ? 503 : 422);
    return json({ orderHash }, 202);
  }

  private isLive(hash: string): boolean {
    return count(this.sql, `SELECT COUNT(*) AS n FROM orders WHERE hash = ?`, hash) > 0;
  }

  private size(): number {
    return count(this.sql, `SELECT COUNT(*) AS n FROM orders`);
  }

  private makerCount(maker: string): number {
    return count(this.sql, `SELECT COUNT(*) AS n FROM orders WHERE maker = ?`, maker.toLowerCase());
  }

  private isSoftCancelled(hash: string, maker: string): boolean {
    return (
      count(this.sql, `SELECT COUNT(*) AS n FROM soft_cancels WHERE hash = ? AND maker = ? AND until > ?`, hash, maker.toLowerCase(), this.deps.now()) > 0
    );
  }

  /** Soft-cancel tombstones, then the admission policy (with displacement) — the Book's `precheck`. */
  private precheck(order: Order, hash: string, encodedBytes: number): AdmissionVerdict {
    if (this.isSoftCancelled(hash, order.maker)) return { ok: false, reason: "order was soft-cancelled by its maker" };
    return checkAdmission(
      order,
      {
        size: this.size(),
        makerCount: (m) => this.makerCount(m),
        now: this.deps.now(),
        known: this.isLive(hash),
        encodedBytes,
        canDisplace: (m) => this.displacementVictim(m) !== undefined,
      },
      this.cfg.admission,
    );
  }

  /**
   * A full book first drops an order it already knows is unfillable, else takes a
   * slot from the LARGEST maker while it holds more than one order beyond the
   * newcomer — its furthest-dated order. Same rule as the library `Book`.
   */
  private displacementVictim(maker: string): string | undefined {
    const policy = this.cfg.admission;
    if (policy.maxOrders <= 0 || this.size() < policy.maxOrders) return undefined;
    const dead = this.sql
      .exec<{ hash: string }>(`SELECT hash FROM orders WHERE state IS NOT NULL AND ok = 0 AND status != ? LIMIT 1`, OrderStatus.Inconclusive)
      .toArray()[0];
    if (dead) return dead.hash;
    const top = this.sql.exec<{ maker: string; n: number }>(`SELECT maker, COUNT(*) AS n FROM orders GROUP BY maker ORDER BY n DESC LIMIT 1`).toArray()[0];
    if (!top || top.n <= this.makerCount(maker) + 1) return undefined;
    return this.sql.exec<{ hash: string }>(`SELECT hash FROM orders WHERE maker = ? ORDER BY expiry DESC, hash ASC LIMIT 1`, top.maker).toArray()[0]?.hash;
  }

  private admit(hash: string, announce: OrderAnnounce, canonical: string, state?: Layer2Result): AdmissionVerdict {
    if (this.isLive(hash)) return { ok: true };
    const order = announce.order;
    const maker = order.maker.toLowerCase();
    if (this.isSoftCancelled(hash, maker)) {
      // Seen now: honour the cancel for the order's whole life.
      this.sql.exec(`UPDATE soft_cancels SET until = MAX(until, ?) WHERE hash = ? AND maker = ?`, secs(order.expiry), hash, maker);
      return { ok: false, reason: "order was soft-cancelled by its maker" };
    }
    const policy = this.cfg.admission;
    if (policy.maxOrdersPerMaker > 0 && this.makerCount(maker) >= policy.maxOrdersPerMaker) {
      return { ok: false, reason: `maker is at its order limit (${policy.maxOrdersPerMaker})`, capacity: true };
    }
    if (policy.maxOrders > 0 && this.size() >= policy.maxOrders) {
      const victim = this.displacementVictim(maker);
      if (!victim) return { ok: false, reason: "book is at capacity", capacity: true };
      this.evict(victim, "displaced");
    }
    const now = this.deps.now();
    this.sql.exec(
      `INSERT INTO orders (hash, maker, nonce, side, expiry, added_at, tokens_in, tokens_out, announce, state, ok, status, checked_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      hash,
      maker,
      order.nonce.toString(),
      order.side,
      secs(order.expiry),
      now,
      tokenList(order.legsIn.map((l) => l.token)),
      tokenList(order.legsOut.map((l) => l.token)),
      canonical,
      state ? JSON.stringify(toStored(state)) : null,
      state?.ok ? 1 : 0,
      state ? state.status : -1,
      now,
    );
    return { ok: true };
  }

  // ──────────────────── POST /cancels ────────────────────

  private async postCancel(request: Request, ip: string): Promise<Response> {
    const refused = this.gate(ip, ROUTE_COST.cancel);
    if (refused) return refused;
    const body = await this.readJsonBody(request);
    if (body instanceof Response) return body;
    let signed: SignedSoftCancel;
    try {
      signed = softCancelFromJson(body);
    } catch (err) {
      return json({ error: `invalid JSON SoftCancel: ${err instanceof JsonBodyError ? err.message : "not parseable"}` }, 400);
    }
    if (!this.cfg.configured) return json({ error: "orderbook not configured (settlement / lens not deployed yet)" }, 503);
    let verdict: CancelVerdict;
    try {
      verdict = await this.deps.cancelVerifier.verify(signed);
    } catch {
      return json({ error: "verification unavailable, retry later" }, 503);
    }
    if (!verdict.ok) return json({ error: verdict.reason ?? "rejected" }, 403);

    // Billed to the PROVEN maker, once per cancel CONTENT (a re-signed copy is the same cancel).
    const d = this.cfg.chain;
    const key = hashTypedData(softCancelTypedData(signed.cancel, { chainId: d.chainId, settlement: d.settlement, permit3: d.permit3 }) as never);
    const billed = this.bill(`c:${key}`, signed.cancel.maker, ROUTE_COST.cancel);
    if (billed) return billed;

    const evicted = this.applyVerifiedCancel(signed, verdict);
    return json({ evicted, requested: signed.cancel.orderHashes.length }, 202);
  }

  /**
   * A verified signature proves WHO signed, never what they may retract: only the
   * named orders whose maker is that signer are evicted; every named hash leaves
   * a maker-bound tombstone (until the order's deadline, or — for a hash not seen
   * yet — until the cancel's expiry capped at `maxTtlSeconds`). The Book's rule.
   */
  private applyVerifiedCancel(signed: SignedSoftCancel, verdict: CancelVerdict): Hex[] {
    const maker = signed.cancel.maker.toLowerCase();
    if (!verdict.ok || verdict.maker?.toLowerCase() !== maker) return [];
    const evicted: Hex[] = [];
    const now = this.deps.now();
    for (const raw of signed.cancel.orderHashes) {
      const h = raw.toLowerCase();
      const row = this.sql.exec<{ maker: string; announce: string }>(`SELECT maker, announce FROM orders WHERE hash = ?`, h).toArray()[0];
      if (row) {
        if (row.maker !== maker) continue; // not theirs to retract
        this.softTombstone(h, maker, secs(parseAnnounce(row.announce).order.expiry), false);
        this.evict(h, "soft-cancelled");
        evicted.push(h as Hex);
      } else {
        const ttl = this.cfg.admission.maxTtlSeconds;
        const cap = BigInt(now + ttl);
        const until = ttl > 0 && signed.cancel.expiry > cap ? cap : signed.cancel.expiry;
        this.softTombstone(h, maker, secs(until), true);
      }
    }
    return evicted;
  }

  private softTombstone(hash: string, maker: string, until: number, pending: boolean): void {
    const prior = this.sql.exec<{ until: number; pending: number }>(`SELECT until, pending FROM soft_cancels WHERE hash = ? AND maker = ?`, hash, maker).toArray()[0];
    if (prior) {
      this.sql.exec(
        `UPDATE soft_cancels SET until = MAX(until, ?), pending = ? WHERE hash = ? AND maker = ?`,
        until,
        pending && prior.pending === 1 ? 1 : 0,
        hash,
        maker,
      );
      return;
    }
    if (pending && count(this.sql, `SELECT COUNT(*) AS n FROM soft_cancels WHERE maker = ? AND pending = 1`, maker) >= this.cfg.maxPendingSoftCancelsPerMaker) return;
    this.sql.exec(`INSERT INTO soft_cancels (hash, maker, until, pending) VALUES (?, ?, ?, ?)`, hash, maker, until, pending ? 1 : 0);
    const over = count(this.sql, `SELECT COUNT(*) AS n FROM soft_cancels`) - this.cfg.maxSoftCancels;
    if (over > 0) {
      // Pending (free to mint) go first, oldest first; real ones only after.
      this.sql.exec(`DELETE FROM soft_cancels WHERE rowid IN (SELECT rowid FROM soft_cancels ORDER BY pending DESC, rowid ASC LIMIT ?)`, over);
    }
  }

  // ──────────────────── eviction / tombstones ────────────────────

  private entryOf(row: OrderRow): BookEntry {
    return {
      orderHash: row.hash as Hex,
      announce: parseAnnounce(row.announce),
      addedAt: row.added_at,
      ...(row.state ? { state: fromStored(JSON.parse(row.state) as StoredState) } : {}),
    };
  }

  private summaryOf(row: OrderRow): OrderSummary {
    return summarize(this.entryOf(row), row.filled === null ? undefined : BigInt(row.filled));
  }

  /** Move a live order to the graves, keeping its last summary readable at `/orders/:hash/status`. */
  private evict(hash: string, reason: GraveReason, opts?: { status?: OrderSummary["status"]; txHash?: Hex }): void {
    const row = this.sql.exec<OrderRow>(`SELECT * FROM orders WHERE hash = ?`, hash).toArray()[0];
    if (!row) return;
    const summary = this.summaryOf(row);
    if (opts?.status) summary.status = opts.status;
    summary.fillable = false;
    this.sql.exec(
      `INSERT OR REPLACE INTO graves (hash, maker, reason, removed_at, summary, announce, tx_hash) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      hash,
      row.maker,
      reason,
      this.deps.now(),
      JSON.stringify(summary),
      row.announce,
      opts?.txHash ?? null,
    );
    this.sql.exec(`DELETE FROM orders WHERE hash = ?`, hash);
    this.deps.verifier.invalidate(hash as Hex);
  }

  // ──────────────────── reads ────────────────────

  private listOrders(url: URL): Response {
    const allowed = new Set(["maker", "token", "tokenIn", "tokenOut", "side", "fillableOnly", "includeExpired", "expiresAfter", "limit", "cursor", "format"]);
    for (const k of url.searchParams.keys()) {
      if (!allowed.has(k)) return json({ error: `unsupported filter "${k}" on this node` }, 400);
    }
    const q = url.searchParams;
    const where: string[] = [];
    const args: SqlValue[] = [];
    for (const [key, column, either] of [
      ["maker", "maker", false],
      ["token", "", true],
      ["tokenIn", "tokens_in", false],
      ["tokenOut", "tokens_out", false],
    ] as const) {
      const v = q.get(key);
      if (v === null) continue;
      if (!isAddress(v, { strict: false })) return json({ error: `${key} is not an address` }, 400);
      const a = v.toLowerCase();
      if (key === "maker") {
        where.push(`maker = ?`);
        args.push(a);
      } else if (either) {
        where.push(`(tokens_in LIKE ? OR tokens_out LIKE ?)`);
        args.push(`%,${a},%`, `%,${a},%`);
      } else {
        where.push(`${column} LIKE ?`);
        args.push(`%,${a},%`);
      }
    }
    const side = q.get("side");
    if (side !== null) {
      const s = side.toUpperCase();
      if (s === "SELL" || s === "0") where.push(`side = 0`);
      else if (s === "BUY" || s === "1") where.push(`side = 1`);
      else return json({ error: "side must be SELL or BUY" }, 400);
    }
    if (q.get("fillableOnly") !== null && q.get("fillableOnly") !== "false") where.push(`ok = 1`);
    const expiresAfter = q.get("expiresAfter");
    if (expiresAfter !== null) {
      if (!/^\d+$/.test(expiresAfter)) return json({ error: "expiresAfter is not a unix timestamp" }, 400);
      where.push(`expiry >= ?`);
      args.push(Number(expiresAfter));
    } else if (q.get("includeExpired") !== "true") {
      where.push(`expiry > ?`);
      args.push(this.deps.now());
    }
    const limitRaw = q.get("limit");
    const limit = limitRaw === null ? DEFAULT_PAGE : Number(limitRaw);
    if (!Number.isInteger(limit) || limit <= 0) return json({ error: "limit must be a positive integer" }, 400);
    const pageSize = Math.min(limit, MAX_PAGE);

    const filter = where.length ? `WHERE ${where.join(" AND ")}` : "";
    const total = count(this.sql, `SELECT COUNT(*) AS n FROM orders ${filter}`, ...args);
    // Keyset paging, newest first, ties by hash: `<addedAt>~<hash>` (the server's cursor shape).
    const pageWhere = [...where];
    const pageArgs = [...args];
    const cursor = q.get("cursor");
    if (cursor) {
      const m = /^(\d+)~(0x[0-9a-fA-F]{64})$/.exec(cursor);
      if (!m) return json({ error: "cursor is malformed" }, 400);
      pageWhere.push(`(added_at < ? OR (added_at = ? AND hash > ?))`);
      pageArgs.push(Number(m[1]), Number(m[1]), m[2]!.toLowerCase());
    }
    const rows = this.sql
      .exec<OrderRow>(
        `SELECT * FROM orders ${pageWhere.length ? `WHERE ${pageWhere.join(" AND ")}` : ""} ORDER BY added_at DESC, hash ASC LIMIT ?`,
        ...pageArgs,
        pageSize + 1,
      )
      .toArray();
    const more = rows.length > pageSize;
    const page = rows.slice(0, pageSize);
    const last = page[page.length - 1];
    const nextCursor = more && last ? `${last.added_at}~${last.hash}` : undefined;
    return json(
      {
        orders: page.map((r) => this.served(r)),
        total,
        ...(nextCursor ? { nextCursor } : {}),
      },
      200,
      { "x-total-count": String(total), ...(nextCursor ? { "x-next-cursor": nextCursor } : {}) },
    );
  }

  /** One live order as served: the full signed announce (JSON) plus what the node knows about it. */
  private served(r: OrderRow): Record<string, unknown> {
    const a = JSON.parse(r.announce) as { order: unknown; sig: string };
    const s = r.state ? (JSON.parse(r.state) as StoredState) : null;
    return {
      orderHash: r.hash,
      order: a.order,
      sig: a.sig,
      addedAt: r.added_at,
      filledAmount: this.summaryOf(r).filledAmount,
      state: s
        ? {
            status: STATUS_NAME[s.status] ?? "Unknown",
            ok: s.ok,
            fillableAmount: s.fillableAmount,
            isSignatureValid: s.isSignatureValid,
            validatorsPass: s.validatorsPass,
          }
        : null,
    };
  }

  private getOrder(hash: string): Response {
    const row = this.sql.exec<OrderRow>(`SELECT * FROM orders WHERE hash = ?`, hash).toArray()[0];
    return row ? json(this.served(row)) : json({ error: "not found" }, 404);
  }

  private status(hash: string): Response {
    const row = this.sql.exec<OrderRow>(`SELECT * FROM orders WHERE hash = ?`, hash).toArray()[0];
    if (row) return json({ live: true, ...this.summaryOf(row) });
    const grave = this.sql
      .exec<{ reason: string; removed_at: number; summary: string; tx_hash: string | null }>(
        `SELECT reason, removed_at, summary, tx_hash FROM graves WHERE hash = ?`,
        hash,
      )
      .toArray()[0];
    if (grave) {
      return json({
        live: false,
        ...(JSON.parse(grave.summary) as object),
        reason: grave.reason,
        removedAt: grave.removed_at,
        ...(grave.tx_hash ? { txHash: grave.tx_hash } : {}),
      });
    }
    return json({ error: "unknown order", hint: "never seen here, or evicted long ago" }, 404);
  }

  private listFills(url: URL): Response {
    const q = url.searchParams;
    const where: string[] = [];
    const args: SqlValue[] = [];
    for (const key of ["maker", "solver"] as const) {
      const v = q.get(key);
      if (v === null) continue;
      if (!isAddress(v, { strict: false })) return json({ error: `${key} is not an address` }, 400);
      where.push(`f.${key} = ?`);
      args.push(v.toLowerCase());
    }
    const oh = q.get("orderHash");
    if (oh !== null) {
      if (!HASH.test(oh)) return json({ error: "orderHash is not a 32-byte hash" }, 400);
      where.push(`f.order_hash = ?`);
      args.push(oh.toLowerCase());
    }
    const fromBlock = q.get("fromBlock");
    if (fromBlock !== null) {
      if (!/^\d+$/.test(fromBlock)) return json({ error: "fromBlock must be a block number" }, 400);
      where.push(`f.block_number >= ?`);
      args.push(Number(fromBlock));
    }
    const limitRaw = q.get("limit");
    const limit = limitRaw === null ? DEFAULT_PAGE : Number(limitRaw);
    if (!Number.isInteger(limit) || limit <= 0) return json({ error: "limit must be a positive integer" }, 400);
    const pageSize = Math.min(limit, MAX_PAGE);
    const total = count(this.sql, `SELECT COUNT(*) AS n FROM fills f ${where.length ? `WHERE ${where.join(" AND ")}` : ""}`, ...args);
    const cursor = q.get("cursor");
    if (cursor) {
      const m = /^(\d+)~(\d+)$/.exec(cursor);
      if (!m) return json({ error: "cursor is malformed" }, 400);
      where.push(`(f.block_number < ? OR (f.block_number = ? AND f.log_index < ?))`);
      args.push(Number(m[1]), Number(m[1]), Number(m[2]));
    }
    const rows = this.sql
      .exec<{
        order_hash: string;
        maker: string;
        solver: string;
        block_number: number;
        tx_hash: string;
        log_index: number;
        at: number | null;
        cumulative: string | null;
        amount: string | null;
        live_announce: string | null;
        grave_announce: string | null;
      }>(
        `SELECT f.*, o.announce AS live_announce, g.announce AS grave_announce
           FROM fills f
           LEFT JOIN orders o ON o.hash = f.order_hash
           LEFT JOIN graves g ON g.hash = f.order_hash
           ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
           ORDER BY f.block_number DESC, f.log_index DESC LIMIT ?`,
        ...args,
        pageSize + 1,
      )
      .toArray();
    const more = rows.length > pageSize;
    const page = rows.slice(0, pageSize);
    const last = page[page.length - 1];
    return json({
      fills: page.map((f) => {
        const announce = f.live_announce ?? f.grave_announce;
        return {
          orderHash: f.order_hash,
          maker: f.maker,
          solver: f.solver,
          blockNumber: String(f.block_number),
          txHash: f.tx_hash,
          logIndex: f.log_index,
          at: f.at,
          cumulative: f.cumulative,
          amount: f.amount,
          // The signed order when this node held it — lets a client place the fill in its market.
          ...(announce ? { order: (JSON.parse(announce) as { order: unknown }).order } : {}),
        };
      }),
      total,
      ...(more && last ? { nextCursor: `${last.block_number}~${last.log_index}` } : {}),
      coverage: this.coverage(),
    });
  }

  private coverage(): Record<string, unknown> {
    const from = getMeta(this.sql, "logFrom");
    const cursor = getMeta(this.sql, "logCursor");
    const dropped = Number(getMeta(this.sql, "fillsDropped") ?? "0");
    const oldest = dropped > 0 ? this.sql.exec<{ b: number | null }>(`SELECT MIN(block_number) AS b FROM fills`).toArray()[0]?.b : undefined;
    return {
      fromBlock: oldest != null ? String(oldest) : (from ?? null),
      toBlock: cursor ? String(BigInt(cursor) - 1n) : null,
      records: count(this.sql, `SELECT COUNT(*) AS n FROM fills`),
      live: this.cfg.configured,
      dropped,
    };
  }

  private health(): Response {
    const c = this.cfg;
    return json({
      chainId: c.chain.chainId,
      settlement: c.chain.settlement,
      permit3: c.chain.permit3,
      lens: c.chain.lens,
      configured: c.configured,
      orders: this.size(),
      tombstones: count(this.sql, `SELECT COUNT(*) AS n FROM graves`),
      softCancels: count(this.sql, `SELECT COUNT(*) AS n FROM soft_cancels`),
      admission: { maxOrders: c.admission.maxOrders, maxOrdersPerMaker: c.admission.maxOrdersPerMaker },
      fills: this.coverage(),
      lastAlarm: getMeta(this.sql, "lastAlarm") ?? null,
      lastError: this.lastError ?? getMeta(this.sql, "lastError") ?? null,
    });
  }

  // ──────────────────── maintenance (the alarm) ────────────────────

  /**
   * One maintenance pass. Returns the delay (ms) until the next one: the normal
   * interval, or 1s while the log cursor is still catching up.
   *
   *   1. prune tombstones, soft cancels, rate buckets, bills (TTL + caps);
   *   2. evict orders past their deadline;
   *   3. read Settlement logs from the cursor, at most `maxLogRange` blocks, to
   *      `head − confirmations`: index fills, evict on-chain cancels and nonce
   *      invalidations (zero lens calls), mark partially filled orders dirty;
   *   4. re-check dirty orders, then the stalest, on the lens (bounded per pass).
   */
  async maintain(): Promise<number> {
    const now = this.deps.now();
    const errors: string[] = [];
    this.prune(now);

    for (const r of this.sql.exec<{ hash: string }>(`SELECT hash FROM orders WHERE expiry <= ?`, now).toArray()) {
      this.evict(r.hash, "expired", { status: "Expired" });
    }

    let behind = false;
    if (this.cfg.configured) {
      try {
        behind = await this.scanLogs();
      } catch (err) {
        errors.push(`logs: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
      }
      try {
        await this.recheck(now);
      } catch (err) {
        errors.push(`recheck: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
      }
    }
    setMeta(this.sql, "lastAlarm", String(now));
    if (errors.length) setMeta(this.sql, "lastError", `${now} ${errors.join("; ").slice(0, 300)}`);
    return behind ? 1_000 : this.cfg.alarmIntervalMs;
  }

  private prune(now: number): void {
    const c = this.cfg;
    this.sql.exec(`DELETE FROM soft_cancels WHERE until <= ?`, now);
    this.sql.exec(`DELETE FROM graves WHERE removed_at < ?`, now - c.tombstoneTtlSeconds);
    this.sql.exec(`DELETE FROM graves WHERE hash IN (SELECT hash FROM graves ORDER BY removed_at DESC LIMIT -1 OFFSET ?)`, c.maxTombstones);
    this.sql.exec(`DELETE FROM billed WHERE key IN (SELECT key FROM billed ORDER BY at DESC LIMIT -1 OFFSET ?)`, c.maxBilled);
    const over = count(this.sql, `SELECT COUNT(*) AS n FROM fills`) - c.maxFills;
    if (over > 0) {
      this.sql.exec(
        `DELETE FROM fills WHERE rowid IN (SELECT rowid FROM fills ORDER BY block_number ASC, log_index ASC LIMIT ?)`,
        over,
      );
      setMeta(this.sql, "fillsDropped", String(Number(getMeta(this.sql, "fillsDropped") ?? "0") + over));
    }
    this.limiter.prune(c.rate.idleSeconds, c.rate.maxKeys);
  }

  /** @returns true when the cursor is still behind the confirmed head. */
  private async scanLogs(): Promise<boolean> {
    const head = await this.deps.chain.blockNumber();
    const safe = head > this.cfg.confirmations ? head - this.cfg.confirmations : 0n;
    const stored = getMeta(this.sql, "logCursor");
    let from: bigint;
    if (stored !== undefined) from = BigInt(stored);
    else {
      from = this.cfg.startBlock ?? (safe > this.cfg.initialLookback ? safe - this.cfg.initialLookback : 0n);
      setMeta(this.sql, "logFrom", from.toString());
    }
    if (from > safe) return false;
    const to = from + this.cfg.maxLogRange - 1n < safe ? from + this.cfg.maxLogRange - 1n : safe;
    const logs = await this.deps.chain.logs(from, to);
    await this.applyLogs(logs);
    // Advanced only after the whole range applied: a failure re-reads it, and the
    // fill table's (txHash, logIndex) key makes the re-read idempotent.
    setMeta(this.sql, "logCursor", (to + 1n).toString());
    return to < safe;
  }

  /** Apply one range of logs in chain order. Exposed for tests through {@link maintain}. */
  private async applyLogs(logs: readonly ChainLog[]): Promise<void> {
    // The block that carries the LAST fill of an order within a block gets the
    // delta; same-block siblings report `null` (one cumulative covers them all).
    const lastInBlock = new Map<string, number>();
    logs.forEach((l, i) => {
      if (l.event.kind === "filled") lastInBlock.set(`${l.event.orderHash.toLowerCase()}@${l.blockNumber}`, i);
    });
    const cumCache = new Map<string, bigint | null>();
    const times = new Map<bigint, number | null>();

    for (let i = 0; i < logs.length; i++) {
      const log = logs[i]!;
      const e = log.event;
      if (e.kind !== "filled") {
        this.applyCancelEvent(e);
        continue;
      }
      const hash = e.orderHash.toLowerCase();
      const known = count(this.sql, `SELECT COUNT(*) AS n FROM fills WHERE tx_hash = ? AND log_index = ?`, log.txHash.toLowerCase(), log.logIndex);
      if (known > 0) continue;

      const cum = await this.cumulativeAt(hash as Hex, log.blockNumber, cumCache);
      let amount: bigint | null = null;
      if (cum !== null && lastInBlock.get(`${hash}@${log.blockNumber}`) === i) {
        const prev = await this.cumulativeBefore(hash as Hex, log.blockNumber, cumCache);
        if (prev !== null && cum > prev) amount = cum - prev;
      }
      if (!times.has(log.blockNumber)) times.set(log.blockNumber, await this.deps.chain.blockTime(log.blockNumber));
      this.sql.exec(
        `INSERT OR IGNORE INTO fills (tx_hash, log_index, order_hash, maker, solver, block_number, at, cumulative, amount)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        log.txHash.toLowerCase(),
        log.logIndex,
        hash,
        e.maker.toLowerCase(),
        e.solver.toLowerCase(),
        Number(log.blockNumber),
        times.get(log.blockNumber) ?? null,
        cum === null ? null : cum.toString(),
        amount === null ? null : amount.toString(),
      );
      this.applyFillProgress(hash, cum, log.txHash.toLowerCase() as Hex);
    }
  }

  /**
   * `filled(hash)` at a block, `null` when it does not carry a size: the
   * cancelled sentinel, or `0` (a fill-once order keeps progress in its nonce).
   * A node that cannot serve the historical read falls back to latest.
   */
  private async cumulativeAt(hash: Hex, block: bigint, cache: Map<string, bigint | null>): Promise<bigint | null> {
    const key = `${hash}@${block}`;
    if (cache.has(key)) return cache.get(key)!;
    let v: bigint | null;
    try {
      v = await this.deps.chain.filledAt(hash, block);
    } catch {
      try {
        v = await this.deps.chain.filledAt(hash);
      } catch {
        v = null;
      }
    }
    if (v === CANCELLED_SENTINEL || v === 0n) v = null;
    cache.set(key, v);
    return v;
  }

  /** The cumulative before `block`: the newest indexed row below it, else `filled(hash)` at `block − 1`. */
  private async cumulativeBefore(hash: Hex, block: bigint, cache: Map<string, bigint | null>): Promise<bigint | null> {
    const row = this.sql
      .exec<{ cumulative: string | null }>(
        `SELECT cumulative FROM fills WHERE order_hash = ? AND block_number < ? ORDER BY block_number DESC, log_index DESC LIMIT 1`,
        hash,
        Number(block),
      )
      .toArray()[0];
    if (row) return row.cumulative === null ? null : BigInt(row.cumulative);
    if (block === 0n) return 0n;
    const key = `${hash}@${block - 1n}`;
    if (cache.has(key)) return cache.get(key) ?? 0n;
    let v: bigint;
    try {
      v = await this.deps.chain.filledAt(hash, block - 1n);
    } catch {
      return null; // no historical state: the amount stays unknown, never a guess
    }
    if (v === CANCELLED_SENTINEL) return null;
    cache.set(key, v);
    return v;
  }

  /** A fill moved an order: a full fill tombstones it (with the tx), a partial updates progress and marks it dirty. */
  private applyFillProgress(hash: string, cum: bigint | null, txHash: Hex): void {
    const row = this.sql.exec<OrderRow>(`SELECT * FROM orders WHERE hash = ?`, hash).toArray()[0];
    if (row) {
      const order = parseAnnounce(row.announce).order;
      const anchor = anchorOf(order);
      if (cum !== null) {
        const prior = row.filled === null ? -1n : BigInt(row.filled);
        if (cum > prior) this.sql.exec(`UPDATE orders SET filled = ? WHERE hash = ?`, cum.toString(), hash);
        if (anchor !== null && anchor > 0n && cum >= anchor) {
          this.evict(hash, "filled", { status: "Filled", txHash });
          return;
        }
      }
      // Partial, fill-once or proportional: only the lens knows what is left.
      this.sql.exec(`UPDATE orders SET dirty = 1 WHERE hash = ?`, hash);
      return;
    }
    // Already evicted (soft-cancelled, displaced, …) but it still filled on-chain:
    // keep the tombstone truthful.
    const grave = this.sql.exec<{ summary: string; announce: string }>(`SELECT summary, announce FROM graves WHERE hash = ?`, hash).toArray()[0];
    if (!grave || cum === null) return;
    const summary = JSON.parse(grave.summary) as OrderSummary;
    summary.filledAmount = cum.toString();
    const anchor = anchorOf(parseAnnounce(grave.announce).order);
    const full = anchor !== null && anchor > 0n && cum >= anchor;
    if (full) summary.status = "Filled";
    this.sql.exec(
      `UPDATE graves SET summary = ?, reason = CASE WHEN ? THEN 'filled' ELSE reason END, tx_hash = COALESCE(?, tx_hash) WHERE hash = ?`,
      JSON.stringify(summary),
      full ? 1 : 0,
      full ? txHash : null,
      hash,
    );
  }

  /** The four on-chain cancellations and a bracket claim: evict with zero RPC, maker re-checked on every branch. */
  private applyCancelEvent(e: Exclude<WorkerChainEvent, { kind: "filled" }>): void {
    const maker = e.maker.toLowerCase();
    if (e.kind === "cancelledByHash") {
      const h = e.orderHash.toLowerCase();
      if (count(this.sql, `SELECT COUNT(*) AS n FROM orders WHERE hash = ? AND maker = ?`, h, maker) > 0) {
        this.evict(h, "cancelled", { status: "Cancelled" });
      }
      return;
    }
    const rows = this.sql.exec<{ hash: string; nonce: string; announce: string }>(`SELECT hash, nonce, announce FROM orders WHERE maker = ?`, maker).toArray();
    for (const r of rows) {
      const nonce = BigInt(r.nonce);
      let dead = false;
      switch (e.kind) {
        case "cancelledNonces":
          dead = e.nonces.some((n) => n === nonce);
          break;
        case "rolledBack":
          dead = nonce < e.minValidNonce;
          break;
        case "wordInvalidated":
          dead = nonce >> 8n === e.wordIndex;
          break;
        case "groupClaimed":
          dead = nonce !== e.nonce && isOcoGroupLeg(parseAnnounce(r.announce).order.validators, e.module, e.groupId);
          break;
      }
      if (dead) this.evict(r.hash, "cancelled", { status: "Cancelled" });
    }
  }

  /** Dirty orders first, then the stalest; one batched `getOrderRelevantStates` sweep. */
  private async recheck(now: number): Promise<void> {
    const rows = this.sql
      .exec<OrderRow>(
        `SELECT * FROM orders WHERE dirty = 1 OR checked_at <= ? ORDER BY dirty DESC, checked_at ASC LIMIT ?`,
        now - this.cfg.revalidateSeconds,
        this.cfg.maxRecheckPerAlarm,
      )
      .toArray();
    if (rows.length === 0) return;
    const entries = rows.map((r) => ({ orderHash: r.hash as Hex, announce: parseAnnounce(r.announce) }));
    // Throws only when NO lens call worked — then nothing is evicted (the RPC is the problem).
    const states = await this.deps.verifier.refreshStates(entries);
    for (const r of rows) {
      const s = states.get(r.hash as Hex);
      if (!s) continue;
      if (s.status === OrderStatus.Inconclusive) {
        if (s.isolated) {
          const strikes = r.strikes + 1;
          if (strikes >= MAX_INCONCLUSIVE_STRIKES) this.evict(r.hash, "evicted");
          else this.sql.exec(`UPDATE orders SET strikes = ?, checked_at = ?, dirty = 0 WHERE hash = ?`, strikes, now, r.hash);
        } else {
          this.sql.exec(`UPDATE orders SET checked_at = ?, dirty = 0 WHERE hash = ?`, now, r.hash);
        }
        continue;
      }
      this.sql.exec(
        `UPDATE orders SET state = ?, ok = ?, status = ?, strikes = 0, checked_at = ?, dirty = 0 WHERE hash = ?`,
        JSON.stringify(toStored(s)),
        s.ok ? 1 : 0,
        s.status,
        now,
        r.hash,
      );
      if (!s.ok) {
        const reason: GraveReason =
          s.status === OrderStatus.Filled ? "filled" : s.status === OrderStatus.Cancelled ? "cancelled" : s.status === OrderStatus.Expired ? "expired" : "evicted";
        // A fill the log scan saw but could not size (fill-once, proportional) still names its tx.
        const tx = reason === "filled" ? this.latestFillTx(r.hash) : undefined;
        this.evict(r.hash, reason, tx ? { txHash: tx } : undefined);
      }
    }
  }

  private latestFillTx(hash: string): Hex | undefined {
    return this.sql
      .exec<{ tx_hash: string }>(`SELECT tx_hash FROM fills WHERE order_hash = ? ORDER BY block_number DESC, log_index DESC LIMIT 1`, hash)
      .toArray()[0]?.tx_hash as Hex | undefined;
  }
}

/** Re-export for the node-side parity test and clients. */
export { orderFromJson };

import { hashOrderStruct, orderFromJson, OrderSide, type Order } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import type { Fill, RestingOrder } from "../lib/types";
import type {
  MarketObservation,
  OrderbookApi,
  PlaceOrderRequest,
  RecordTakeRequest,
  SignedCancel,
  SignedOrder,
} from "./api";
import type { RowResolver } from "./restore";

/**
 * A REAL order distribution client: `@1delta-x/orderbook-server` over REST.
 *
 *   POST /orders               JSON `{order, sig}`    → 202 | 4xx/5xx `{ error }`
 *   POST /cancels              JSON `{cancel, sig}`   → 202 | 403 `{ error }`
 *   GET  /orders/:hash/status  `{ live, ...OrderSummary }` (tombstone once evicted)
 *   GET  /fills?maker=…        `{ fills: [{ orderHash, txHash, cumulative, amount, order?, … }] }`
 *                              (501 when the node indexes no fills)
 *   GET  /orders?maker=…       `{ orders: [{ orderHash, order, sig, addedAt, filledAmount }], nextCursor? }`
 *                              — read once per maker by {@link RemoteOrderbook.restore}
 *                              so a page reload brings back resting orders and fills
 *
 * Unlike the mock it simulates NOTHING. A row exists only once the server
 * answered 202 for its signed order; `filled` moves only on what the server
 * reports from the chain; a fill row is created only for a fill the server
 * reported, carrying the settlement transaction hash from the server's fill
 * index — or no hash at all when the node indexes no fills (G-TS_SIGN-15).
 *
 * Only the maker's own orders are tracked. Other makers' orders are not
 * fetched, so the ladder shows pool depth plus your own resting orders.
 *
 * Bodies are the server's JSON form (bigints as decimal strings), NOT the
 * protobuf wire: protobufjs compiles its encoders with `new Function`, which this
 * app's CSP (`script-src 'self'`, no `'unsafe-eval'`) forbids. The server parses
 * the JSON strictly, re-encodes it to protobuf and runs every check unchanged —
 * so nothing from `@1delta-x/orderbook` is needed at runtime here.
 */

/** How often the maker's live orders are re-checked against the server. */
export const POLL_MS = 6_000;

/** How long a fill the book called `Filled` waits for the fill index before it is shown without a hash. */
const INDEX_GRACE_TICKS = 20;

/** Fills kept in memory — the same bound the mock uses. */
const MAX_FILLS = 60;

/** A non-2xx answer from the orderbook server. `reason` is the server's own `error` text. */
export class OrderbookHttpError extends Error {
  constructor(
    readonly status: number,
    readonly reason: string,
    message: string,
  ) {
    super(message);
    this.name = "OrderbookHttpError";
  }
}

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface RemoteOrderbookOptions {
  /** e.g. `https://book.example` or a same-origin path such as `/api/book`. No trailing slash needed. */
  baseUrl: string;
  /** Injectable for tests; defaults to the global `fetch`. */
  fetch?: FetchLike;
  pollMs?: number;
  /** Injectable clock (ms). */
  now?: () => number;
  /**
   * Maps an order from the book back to a market row, for {@link RemoteOrderbook.restore}.
   * Without it nothing is restored (the client cannot tell which market an order is on).
   */
  resolveRow?: RowResolver;
}

/** Pages of `GET /orders?maker=` read on restore, at most (500 orders each). */
const RESTORE_MAX_PAGES = 10;

// ──────────────────── wire encoding ────────────────────

/** JSON with every bigint as a decimal string — the server's JSON body convention. */
function toJson(v: unknown): string {
  return JSON.stringify(v, (_k, x: unknown) => (typeof x === "bigint" ? x.toString() : x));
}

/**
 * The body of `POST /orders`: `{order, sig}`. Only the SDK `Order` fields are
 * sent — the server rejects unknown keys.
 */
export function encodeOrderBody(signed: Pick<SignedOrder, "order" | "sig">): string {
  const o = signed.order;
  const order = {
    maker: o.maker,
    side: o.side,
    nonce: o.nonce,
    expiry: o.expiry,
    legsIn: o.legsIn.map((l) => ({ token: l.token, start: l.start, end: l.end })),
    legsOut: o.legsOut.map((l) => ({ token: l.token, start: l.start, end: l.end, recipient: l.recipient })),
    timing: o.timing,
    exclusiveFiller: o.exclusiveFiller,
    minFillAnchor: o.minFillAnchor,
    exclusivityOverrideBps: o.exclusivityOverrideBps,
    curve: o.curve.map((c) => ({ timeDelta: c.timeDelta, bumpBps: c.bumpBps })),
    gasBumpBps: o.gasBumpBps,
    gasPriceRef: o.gasPriceRef,
    priorityScale: o.priorityScale,
    ...(o.baselinePriorityFeeWei !== undefined ? { baselinePriorityFeeWei: o.baselinePriorityFeeWei } : {}),
    items: o.items.map((i) => ({ op: i.op, module: i.module, amount: i.amount, recipient: i.recipient, data: i.data })),
    validators: o.validators.map((v) => ({ target: v.target, data: v.data })),
    invariants: o.invariants.map((v) => ({ target: v.target, data: v.data })),
    fillModule: o.fillModule,
    fillTotal: o.fillTotal,
    pricingModule: o.pricingModule,
  };
  return toJson({ order, sig: signed.sig });
}

/** The body of `POST /cancels`: `{cancel, sig}`. */
export function encodeCancelBody(signed: SignedCancel): string {
  const c = signed.cancel;
  return toJson({
    cancel: { maker: c.maker, orderHashes: [...c.orderHashes], issuedAt: c.issuedAt, expiry: c.expiry },
    sig: signed.sig,
  });
}

function joinUrl(base: string, path: string): string {
  return `${base.replace(/\/+$/, "")}${path}`;
}

async function readError(res: Response): Promise<string> {
  try {
    const text = await res.text();
    try {
      const j = JSON.parse(text) as { error?: unknown };
      if (typeof j.error === "string" && j.error) return j.error;
    } catch {
      /* not JSON */
    }
    return text.slice(0, 200) || res.statusText || "no reason given";
  } catch {
    return res.statusText || "no reason given";
  }
}

/** Turn a non-2xx answer into an error a maker can act on. */
async function httpError(res: Response, what: "order" | "cancel"): Promise<OrderbookHttpError> {
  const reason = await readError(res);
  const s = res.status;
  const msg =
    s === 503
      ? `The orderbook is temporarily unavailable (${reason}). The ${what} was NOT posted — try again.`
      : s === 429
        ? `The orderbook is rate-limiting this address (${reason}). The ${what} was NOT posted — wait and try again.`
        : s === 422
          ? `The orderbook rejected the ${what}: ${reason}`
          : s === 403
            ? `The orderbook refused the ${what}: ${reason}`
            : `The orderbook answered ${s} (${reason}). The ${what} was NOT posted.`;
  return new OrderbookHttpError(s, reason, msg);
}

async function send(doFetch: FetchLike, url: string, body: string): Promise<Response> {
  try {
    return await doFetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
  } catch (e) {
    throw new Error(`Could not reach the orderbook at ${url}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/** POST a signed order. Resolves with the server's order hash on 202; throws on anything else. */
export async function postOrder(
  doFetch: FetchLike,
  baseUrl: string,
  signed: Pick<SignedOrder, "order" | "sig" | "hash">,
): Promise<{ orderHash: Hex; duplicate: boolean }> {
  const body = encodeOrderBody(signed);
  const res = await send(doFetch, joinUrl(baseUrl, "/orders"), body);
  if (res.status !== 202 && !res.ok) throw await httpError(res, "order");
  const j = (await res.json().catch(() => ({}))) as { orderHash?: string; duplicate?: boolean };
  // The server re-hashes the order itself. A different hash means it admitted a
  // different order than the one signed here — never track that as ours.
  if (typeof j.orderHash !== "string" || j.orderHash.toLowerCase() !== signed.hash.toLowerCase()) {
    throw new Error(`The orderbook acknowledged a different order hash (${String(j.orderHash)}); not tracking it`);
  }
  return { orderHash: signed.hash, duplicate: j.duplicate === true };
}

/** POST a signed soft cancel. Throws on anything but 202. */
export async function postCancel(
  doFetch: FetchLike,
  baseUrl: string,
  signed: SignedCancel,
): Promise<{ evicted: number; requested: number }> {
  const body = encodeCancelBody(signed);
  const res = await send(doFetch, joinUrl(baseUrl, "/cancels"), body);
  if (res.status !== 202 && !res.ok) throw await httpError(res, "cancel");
  const j = (await res.json().catch(() => ({}))) as { evicted?: unknown; requested?: unknown };
  const evicted = Array.isArray(j.evicted) ? j.evicted.length : typeof j.evicted === "number" ? j.evicted : 0;
  return { evicted, requested: typeof j.requested === "number" ? j.requested : signed.cancel.orderHashes.length };
}

// ──────────────────── status / fills shapes (server JSON) ────────────────────

interface StatusBody {
  live?: boolean;
  status?: string;
  filledAmount?: string | null;
}

interface FillBody {
  orderHash: string;
  /** The signed order, when the node held it (the Worker orderbook serves it). */
  order?: unknown;
  solver?: string;
  txHash?: string;
  logIndex?: number;
  at?: number | null;
  cumulative?: string | null;
  amount?: string | null;
}

function toBig(v: unknown): bigint | null {
  if (typeof v !== "string" || !/^\d+$/.test(v)) return null;
  return BigInt(v);
}

/**
 * The amount a fill is counted in (the settlement's `filled(hash)` unit): the
 * fill total when one is signed, else the input (SELL) or output (BUY) anchor.
 * For every order this app builds that is the market's BASE token.
 */
export function anchorOf(order: Order): bigint {
  if (order.fillTotal > 0n) return order.fillTotal;
  return order.side === OrderSide.SELL ? (order.legsIn[0]?.start ?? 0n) : (order.legsOut[0]?.start ?? 0n);
}

/** One signed order the maker posted, as the poller follows it. */
interface Tracked {
  rowId: string;
  hash: Hex;
  maker: Address;
  anchor: bigint;
  /** Anchor wei the chain says is filled, as far as the server has told us. */
  filledWei: bigint;
  /** Anchor wei already shown as fill rows. */
  shownWei: bigint;
  /** The status endpoint has nothing more to say (tombstoned / unknown): only fills are polled. */
  statusDone: boolean;
  /** The book reported `Filled` but the fill index has not caught up: ticks waited. */
  awaitingIndex?: number;
}

function shortAddr(a: string | undefined): string {
  return a && a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : (a ?? "unknown");
}

export class RemoteOrderbook implements OrderbookApi {
  private rows: RestingOrder[] = [];
  private settled: Fill[] = [];
  private readonly tracked = new Map<string, Tracked>();
  private readonly seenFills = new Set<string>();
  private readonly listeners = new Set<() => void>();
  private readonly baseUrl: string;
  private readonly doFetch: FetchLike;
  private readonly pollMs: number;
  private readonly now: () => number;
  private timer: ReturnType<typeof setInterval> | undefined;
  private polling = false;
  /** False once the server answered 501: it indexes no fills, so no transaction hash is available. */
  private fillIndex = true;
  private pausedUntil = 0;
  private readonly resolveRow: RowResolver | undefined;
  /** Makers already restored (lower-cased) — restore runs once per maker per tab. */
  private readonly restored = new Set<string>();

  constructor(opts: RemoteOrderbookOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, "");
    const f = opts.fetch ?? (globalThis.fetch ? (globalThis.fetch.bind(globalThis) as FetchLike) : undefined);
    if (!f) throw new Error("no fetch available");
    this.doFetch = f;
    this.pollMs = opts.pollMs ?? POLL_MS;
    this.now = opts.now ?? (() => Date.now());
    this.resolveRow = opts.resolveRow;
  }

  orders(marketId?: string): RestingOrder[] {
    const all = marketId ? this.rows.filter((o) => o.marketId === marketId) : this.rows;
    return [...all].sort((a, b) => b.createdAt - a.createdAt);
  }

  fills(marketId?: string): Fill[] {
    const all = marketId ? this.settled.filter((f) => f.marketId === marketId) : this.settled;
    return [...all].sort((a, b) => b.at - a.at);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    this.start();
    return () => {
      this.listeners.delete(listener);
      if (!this.listeners.size) this.stop();
    };
  }

  async place(req: PlaceOrderRequest): Promise<RestingOrder> {
    if (!req.signed) throw new Error("the book only holds signed orders");
    if (!req.signed.deployed) {
      throw new Error("No Settlement is deployed on this chain — the order was signed but cannot be posted to the orderbook");
    }
    // Throws on anything but 202 — so a rejected order never becomes a row.
    await postOrder(this.doFetch, this.baseUrl, req.signed);

    const now = this.now();
    const row: RestingOrder = {
      id: req.signed.hash,
      marketId: req.marketId,
      side: req.side,
      type: req.type,
      size: req.size,
      // NOTHING is filled until the chain says so. `req.filled` is what the
      // ticket expected to cross immediately; a real filler has not taken it yet.
      filled: 0,
      price: req.price,
      createdAt: now,
      expiresAt: now + req.ttlMs,
      mine: true,
      signed: req.signed,
      signedOrders: [req.signed],
      sliceSpec: req.sliceSpec,
      slices: req.slices ? { done: 0, total: req.slices.total, everyMin: req.slices.everyMin, signed: 1 } : undefined,
      book: "remote",
    };
    this.rows = this.rows.filter((r) => r.id !== row.id);
    this.rows.push(row);
    this.track(row.id, req.signed);
    this.emit();
    return row;
  }

  async cancel(orderHash: string, signed: SignedCancel): Promise<void> {
    if (!signed || !signed.cancel.orderHashes.some((h) => h.toLowerCase() === orderHash.toLowerCase())) {
      throw new Error("a soft cancel must be signed and name the order");
    }
    // Throws on 403 / 503 / …: the row is left exactly as it was.
    await postCancel(this.doFetch, this.baseUrl, signed);
    const o = this.rows.find((x) => x.id === orderHash);
    if (!o) return;
    // Retracted from distribution, NOT from existence (G-TS_SIGN-4).
    o.cancelled = "soft";
    this.emit();
  }

  confirmHardCancel(orderHash: string): void {
    this.dropRow(orderHash);
    this.emit();
  }

  async addSlice(orderHash: string, signed: SignedOrder): Promise<void> {
    const o = this.rows.find((x) => x.id === orderHash);
    if (!o?.slices || o.cancelled || o.slices.signed >= o.slices.total) return;
    if (!signed.deployed) throw new Error("No Settlement is deployed on this chain — the slice cannot be posted");
    await postOrder(this.doFetch, this.baseUrl, signed);
    o.signedOrders = [...(o.signedOrders ?? []), signed];
    o.slices.signed += 1;
    this.track(o.id, signed);
    this.emit();
  }

  /**
   * No-op. The crossing part of a ticket is part of the SIGNED order this book
   * received; it fills when a real filler fills it, and shows up then.
   */
  recordTake(_req: RecordTakeRequest): void {}

  /** No-op: progress comes from the server, not from the pool mid. */
  observe(_obs: MarketObservation): void {}

  /**
   * Bring back what the book holds for `maker` after a page reload: every live
   * order it signed (`GET /orders?maker=`) becomes a tracked row again, with the
   * progress the book reports, and its indexed fills (`GET /fills?maker=`) become
   * fill rows — including fills of orders that already left the book, when the
   * node served the signed order with the fill.
   *
   * Nothing is taken on trust: each order is parsed strictly, must hash to the
   * `orderHash` the node gave and must be this maker's. Orders this app cannot
   * place in a market are skipped. Runs once per maker; a failed read is retried
   * on the next call.
   */
  async restore(maker: Address): Promise<void> {
    const key = maker.toLowerCase();
    if (this.restored.has(key) || !this.resolveRow) return;
    let changed = false;
    let cursor: string | undefined;
    for (let page = 0; page < RESTORE_MAX_PAGES; page++) {
      const res = await this.get(`/orders?maker=${key}&limit=500${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
      if (!res || !res.ok) return; // unreachable / rate-limited: try again on the next call
      const body = (await res.json().catch(() => null)) as { orders?: unknown[]; nextCursor?: unknown } | null;
      for (const raw of body?.orders ?? []) if (this.restoreOrder(raw, key)) changed = true;
      cursor = typeof body?.nextCursor === "string" ? body.nextCursor : undefined;
      if (!cursor) break;
    }
    this.restored.add(key);

    if (this.fillIndex) {
      const res = await this.get(`/fills?maker=${key}&limit=500`);
      if (res?.status === 501) this.fillIndex = false;
      else if (res?.ok) {
        const body = (await res.json().catch(() => null)) as { fills?: FillBody[] } | null;
        if (this.applyFills(body?.fills ?? [], true)) changed = true;
      }
    }
    if (this.settle()) changed = true;
    if (changed) this.emit();
  }

  /** One `GET /orders` item → a tracked row. @returns whether a row was added. */
  private restoreOrder(raw: unknown, maker: string): boolean {
    const item = raw as { orderHash?: unknown; order?: unknown; sig?: unknown; addedAt?: unknown; filledAmount?: unknown };
    let order: Order;
    try {
      order = orderFromJson(item?.order);
    } catch {
      return false;
    }
    const hash = hashOrderStruct(order);
    if (typeof item.orderHash !== "string" || item.orderHash.toLowerCase() !== hash.toLowerCase()) return false;
    if (order.maker.toLowerCase() !== maker) return false;
    if (typeof item.sig !== "string" || !/^0x(?:[0-9a-fA-F]{2})*$/.test(item.sig)) return false;
    if (this.tracked.has(hash.toLowerCase()) || this.rows.some((r) => r.id.toLowerCase() === hash.toLowerCase())) return false;
    const placed = this.resolveRow?.(order);
    if (!placed) return false;

    const addedAt = typeof item.addedAt === "number" ? item.addedAt * 1000 : this.now();
    const signed: SignedOrder = { order, sig: item.sig as Hex, hash, deployment: placed.deployment, deployed: true };
    const row: RestingOrder = {
      id: hash,
      marketId: placed.marketId,
      side: placed.side,
      type: "limit",
      size: placed.size,
      filled: 0,
      price: placed.price,
      createdAt: addedAt,
      expiresAt: Number(order.expiry) * 1000,
      mine: true,
      signed,
      signedOrders: [signed],
      book: "remote",
    };
    this.rows.push(row);
    this.track(row.id, signed);
    const t = this.tracked.get(hash.toLowerCase())!;
    const filled = toBig(item.filledAmount);
    // Progress the book already knows; the fill rows that explain it arrive from
    // `/fills` (or, after the index grace period, as a fill without a hash).
    if (filled !== null) t.filledWei = filled > t.anchor ? t.anchor : filled;
    return true;
  }

  /** One poll pass. Public so tests can drive it without timers. */
  async poll(): Promise<void> {
    if (this.polling || this.now() < this.pausedUntil) return;
    this.polling = true;
    try {
      let changed = false;
      for (const t of [...this.tracked.values()]) {
        if (t.statusDone) continue;
        if (await this.pollStatus(t)) changed = true;
        if (this.now() < this.pausedUntil) break;
      }
      if (this.tracked.size && this.now() >= this.pausedUntil && (await this.pollFills())) changed = true;
      if (this.settle()) changed = true;
      if (changed) this.emit();
    } finally {
      this.polling = false;
    }
  }

  // ── internals ──────────────────────────────────────────

  private track(rowId: string, signed: SignedOrder): void {
    this.tracked.set(signed.hash.toLowerCase(), {
      rowId,
      hash: signed.hash,
      maker: signed.order.maker,
      anchor: anchorOf(signed.order),
      filledWei: 0n,
      shownWei: 0n,
      statusDone: false,
    });
  }

  private dropRow(rowId: string): void {
    this.rows = this.rows.filter((o) => o.id !== rowId);
    for (const [k, t] of this.tracked) if (t.rowId === rowId) this.tracked.delete(k);
  }

  private rowOf(t: Tracked): RestingOrder | undefined {
    return this.rows.find((r) => r.id === t.rowId);
  }

  private async get(path: string): Promise<Response | null> {
    try {
      const res = await this.doFetch(joinUrl(this.baseUrl, path), { headers: { accept: "application/json" } });
      if (res.status === 429) {
        const after = Number(res.headers.get("retry-after"));
        this.pausedUntil = this.now() + (Number.isFinite(after) && after > 0 ? after * 1000 : this.pollMs * 2);
        return null;
      }
      return res;
    } catch {
      return null; // unreachable this tick; try again next
    }
  }

  /** @returns whether anything visible changed. */
  private async pollStatus(t: Tracked): Promise<boolean> {
    const res = await this.get(`/orders/${t.hash}/status`);
    if (!res) return false;
    const row = this.rowOf(t);
    if (res.status === 404) {
      // Unknown here: the (in-memory) server restarted or evicted it long ago.
      t.statusDone = true;
      if (row && !row.cancelled && !row.offBook) {
        row.offBook = "the orderbook no longer knows this order (server restarted?) — it is still fillable on-chain until expiry";
        return true;
      }
      return false;
    }
    if (!res.ok) return false;
    const body = (await res.json().catch(() => null)) as StatusBody | null;
    if (!body) return false;
    let changed = false;
    const filled = toBig(body.filledAmount);
    if (filled !== null && filled > t.filledWei) {
      t.filledWei = filled > t.anchor ? t.anchor : filled;
      changed = true;
    }
    if (body.live === false) {
      t.statusDone = true;
      if (body.status === "Filled") {
        if (t.filledWei < t.anchor) {
          t.filledWei = t.anchor;
          changed = true;
        }
      } else if (body.status === "Cancelled") {
        // Cancelled ON-CHAIN (from this or another device): final, nothing left to show.
        if (row) {
          this.dropRow(row.id);
          return true;
        }
      } else if (row && !row.cancelled && !row.offBook) {
        // Evicted for another reason (expired, unfunded, invalidated). The last
        // known summary does not say which, and the signature may still be
        // fillable if the maker re-funds — so the row says what is known.
        row.offBook =
          "no longer distributed by the orderbook (expired, unfunded or invalidated) — cancel on-chain to be sure it cannot fill";
        changed = true;
      }
    }
    return changed;
  }

  /** One `/fills?maker=` read per maker covers every tracked order. @returns whether anything changed. */
  private async pollFills(): Promise<boolean> {
    if (!this.fillIndex) return false;
    let changed = false;
    const makers = new Set([...this.tracked.values()].map((t) => t.maker.toLowerCase()));
    for (const maker of makers) {
      const res = await this.get(`/fills?maker=${maker}&limit=100`);
      if (!res) continue;
      if (res.status === 501) {
        this.fillIndex = false;
        return changed;
      }
      if (!res.ok) continue;
      const body = (await res.json().catch(() => null)) as { fills?: FillBody[] } | null;
      if (this.applyFills(body?.fills ?? [], false)) changed = true;
    }
    return changed;
  }

  /**
   * Fold `/fills` rows in, oldest first so per-order cumulatives grow
   * monotonically. A fill of a tracked order advances it; with `history`, a fill
   * of an order no longer tracked (it left the book before this page loaded) is
   * shown as a past fill when the node served its signed order.
   * @returns whether anything changed.
   */
  private applyFills(fills: readonly FillBody[], history: boolean): boolean {
    let changed = false;
    for (const f of [...fills].reverse()) {
      if (typeof f.orderHash !== "string") continue;
      const tx = typeof f.txHash === "string" && /^0x[0-9a-fA-F]{64}$/.test(f.txHash) ? f.txHash : "";
      const key = `${tx}:${f.logIndex ?? ""}:${f.orderHash.toLowerCase()}`;
      if (!tx || this.seenFills.has(key)) continue;
      const t = this.tracked.get(f.orderHash.toLowerCase());
      if (!t) {
        if (history && this.pushHistoricalFill(f, tx)) {
          this.seenFills.add(key);
          changed = true;
        }
        continue;
      }
      this.seenFills.add(key);
      const cumulative = toBig(f.cumulative);
      const amount = toBig(f.amount);
      let delta = amount ?? (cumulative !== null && cumulative > t.shownWei ? cumulative - t.shownWei : null);
      if (delta !== null && t.shownWei + delta > t.anchor) delta = t.anchor - t.shownWei;
      if (cumulative !== null && cumulative > t.filledWei) t.filledWei = cumulative > t.anchor ? t.anchor : cumulative;
      if (delta !== null) {
        t.shownWei += delta;
        if (t.shownWei > t.filledWei) t.filledWei = t.shownWei;
      }
      const row = this.rowOf(t);
      if (row) this.pushFill(row, t, delta, tx, f.solver, typeof f.at === "number" ? f.at * 1000 : this.now());
      changed = true;
    }
    return changed;
  }

  /** A fill of an order that is no longer tracked, placed by its served order. @returns whether it was shown. */
  private pushHistoricalFill(f: FillBody, tx: string): boolean {
    if (!this.resolveRow || f.order === undefined) return false;
    let order: Order;
    try {
      order = orderFromJson(f.order);
    } catch {
      return false;
    }
    if (hashOrderStruct(order).toLowerCase() !== f.orderHash.toLowerCase()) return false;
    const placed = this.resolveRow(order);
    const amount = toBig(f.amount);
    const anchor = anchorOf(order);
    if (!placed) return false;
    this.settled.push({
      id: `${tx}-${f.orderHash.toLowerCase()}`,
      marketId: placed.marketId,
      side: placed.side,
      size: amount === null || anchor === 0n ? 0 : fraction(amount > anchor ? anchor : amount, anchor) * placed.size,
      price: placed.price,
      source: "LMT",
      filler: shortAddr(f.solver),
      tx,
      at: typeof f.at === "number" ? f.at * 1000 : this.now(),
      mine: true,
      simulated: false,
    });
    if (this.settled.length > MAX_FILLS) this.settled = this.fills().slice(0, MAX_FILLS);
    return true;
  }

  private pushFill(row: RestingOrder, t: Tracked, deltaWei: bigint | null, tx: string, solver: string | undefined, at: number): void {
    const perOrder = row.size / (row.slices?.total ?? 1);
    const size = deltaWei === null || t.anchor === 0n ? 0 : fraction(deltaWei, t.anchor) * perOrder;
    this.settled.push({
      id: tx ? `${tx}-${t.hash}-${this.settled.length}` : `${t.hash}-${at}`,
      marketId: row.marketId,
      side: row.side,
      size,
      // The SIGNED limit price — the floor the fill had to meet. An auction may
      // have filled better; the transaction is the authority.
      price: row.price,
      source: "LMT",
      filler: tx ? shortAddr(solver) : "unknown",
      tx,
      at,
      mine: true,
      simulated: false,
    });
    if (this.settled.length > MAX_FILLS) this.settled = this.fills().slice(0, MAX_FILLS);
  }

  /** Fold tracked progress into the rows; retire finished and expired rows. @returns whether anything changed. */
  private settle(): boolean {
    let changed = false;
    const now = this.now();
    for (const t of this.tracked.values()) {
      if (t.filledWei <= t.shownWei) {
        t.awaitingIndex = undefined;
        continue;
      }
      // The chain moved but no indexed fill explains it (yet). With an index,
      // give it time; without one there will never be a hash, so show the
      // fill as a fill whose transaction is unknown — never an invented one.
      if (this.fillIndex && (t.awaitingIndex = (t.awaitingIndex ?? 0) + 1) < INDEX_GRACE_TICKS) continue;
      const row = this.rowOf(t);
      if (row) this.pushFill(row, t, t.filledWei - t.shownWei, "", undefined, now);
      t.shownWei = t.filledWei;
      t.awaitingIndex = undefined;
      changed = true;
    }
    for (const row of [...this.rows]) {
      const mine = [...this.tracked.values()].filter((t) => t.rowId === row.id);
      const perOrder = row.size / (row.slices?.total ?? 1);
      const filled = Math.min(
        row.size,
        mine.reduce((s, t) => s + (t.anchor === 0n ? 0 : fraction(t.filledWei, t.anchor) * perOrder), 0),
      );
      if (Math.abs(filled - row.filled) > row.size * 1e-9) {
        row.filled = filled;
        changed = true;
      }
      if (row.slices) {
        const done = mine.filter((t) => t.anchor > 0n && t.filledWei >= t.anchor).length;
        if (done !== row.slices.done) {
          row.slices.done = done;
          changed = true;
        }
      }
      const pendingIndex = mine.some((t) => t.filledWei > t.shownWei);
      const fullyFilled = row.size - row.filled <= row.size * 1e-6;
      if ((fullyFilled && !pendingIndex) || row.expiresAt <= now) {
        this.dropRow(row.id);
        changed = true;
      }
    }
    return changed;
  }

  private start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.poll(), this.pollMs);
  }

  private stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = undefined;
  }

  private emit(): void {
    for (const l of this.listeners) l();
  }
}

/** `num / den` as a float in [0, 1], exact enough for display. */
function fraction(num: bigint, den: bigint): number {
  if (den === 0n) return 0;
  return Number((num * 1_000_000_000n) / den) / 1e9;
}

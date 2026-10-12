import { erc2612PermitToJson, hashOrderStruct, isFillOnce, orderFromJson, OrderSide, type Order } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import type { ChainFillState } from "../lib/chain";
import { chainFillOutcome, isFull, outcomeEntry, retireReason, type Outcome } from "../lib/orderLifecycle";
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
 *   (optional, consumed when present) `pendingFill: { txHash, sentAt }` on a status /
 *   order item, or a `/fills` record with `status: "pending"` — a filler's SENT fill.
 *
 * When an order leaves the book it moves to Recent fills, never just vanishes: a
 * fill shows with its transaction (from `/fills`, or the grave's `txHash`), or
 * without one until the index catches up (then it gets it); an expiry or an
 * on-chain cancel gets an entry of its own. Orders the book stops listing without
 * saying they filled are checked against `Settlement.filled(hash)` through the
 * wallet ({@link RemoteOrderbook.setFillReader}).
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
  /** `Settlement.filled(hash)` reader for orders that leave the book (see {@link RemoteOrderbook.setFillReader}). */
  readFilled?: FillReader;
}

/** Pages of `GET /orders?maker=` read on restore, at most (500 orders each). */
const RESTORE_MAX_PAGES = 10;

// ──────────────────── wire encoding ────────────────────

/** JSON with every bigint as a decimal string — the server's JSON body convention. */
function toJson(v: unknown): string {
  return JSON.stringify(v, (_k, x: unknown) => (typeof x === "bigint" ? x.toString() : x));
}

/**
 * The body of `POST /orders`: `{order, sig, erc2612Permit?}`. Only the SDK `Order`
 * fields are sent — the server rejects unknown keys. The permit (gasless funding,
 * lib/permit.ts) is appended only when the order carries one.
 */
export function encodeOrderBody(signed: Pick<SignedOrder, "order" | "sig" | "erc2612Permit">): string {
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
  return toJson({ order, sig: signed.sig, ...(signed.erc2612Permit ? { erc2612Permit: erc2612PermitToJson(signed.erc2612Permit) } : {}) });
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
  signed: Pick<SignedOrder, "order" | "sig" | "hash" | "erc2612Permit">,
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

/** A filler's fill transaction the book knows was SENT but not yet mined (optional; degrades when absent). */
interface PendingFillBody {
  txHash?: unknown;
  sentAt?: unknown;
}

interface StatusBody {
  live?: boolean;
  status?: string;
  filledAmount?: string | null;
  /** Graves: why it left the book (`filled` / `cancelled` / `expired` / `evicted` / …). */
  reason?: string;
  /** Graves of filled orders: the (latest) fill transaction. */
  txHash?: string;
  pendingFill?: PendingFillBody | null;
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
  /** `"pending"` = sent by a filler, not mined yet. Absent / anything else = mined. */
  status?: string;
}

const TX_HASH = /^0x[0-9a-fA-F]{64}$/;

function toBig(v: unknown): bigint | null {
  if (typeof v !== "string" || !/^\d+$/.test(v)) return null;
  return BigInt(v);
}

function pendingOf(p: PendingFillBody | null | undefined): { txHash: string; sentAt?: number } | undefined {
  if (!p || typeof p.txHash !== "string" || !TX_HASH.test(p.txHash)) return undefined;
  return { txHash: p.txHash, ...(typeof p.sentAt === "number" ? { sentAt: p.sentAt } : {}) };
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

/**
 * A restored order's type: this app signs market orders with a 300 s life and
 * limit orders with ≥ 1 h, so anything living under 15 minutes was a market ticket.
 */
export function inferType(createdAtMs: number, expiresAtMs: number): "market" | "limit" {
  return expiresAtMs - createdAtMs <= 15 * 60_000 ? "market" : "limit";
}

/** One signed order the maker posted, as the poller follows it — kept after its row leaves, for the tx upgrade. */
interface Tracked {
  rowId: string;
  hash: Hex;
  maker: Address;
  anchor: bigint;
  signed: SignedOrder;
  /** Anchor wei the chain says is filled, as far as the server (or the chain read) has told us. */
  filledWei: bigint;
  /** Anchor wei shown as fill rows WITH a transaction hash. */
  indexedWei: bigint;
  /** Anchor wei shown as a fill row WITHOUT one (the index had not caught up), and that row's id. */
  hashlessWei: bigint;
  hashlessId?: string;
  /** The status endpoint has nothing more to say (tombstoned / unknown): only fills are polled. */
  statusDone: boolean;
  /** A live row's fill the index has not explained yet: ticks waited. */
  awaitingIndex?: number;
  /** The grave's fill transaction (the book's own record of the filling tx). */
  statusTx?: string;
  cancelledOnChain?: boolean;
  /**
   * A FILL-ONCE order the book tombstoned as `Cancelled`. For that shape the book's
   * lens cannot tell a fill from a nonce cancel (both only set the nonce bit), so the
   * verdict waits for the chain read (`chainFillOutcome`); it stands only when there
   * is none to be had.
   */
  bookCancelled?: boolean;
  /** What the chain read was last done for. */
  chainChecked?: "gone" | "expired";
  /** Row snapshot, so fills can still be placed once the row is gone. */
  snap: { marketId: string; side: RestingOrder["side"]; price: number; perOrder: number; type: RestingOrder["type"]; size: number };
  /** Finished orders: keep polling fills (for a hash upgrade) until then. */
  keepUntil?: number;
}

/** How long the open-orders view waits for the fill index to explain a LIVE row's partial fill. */
const INDEX_GRACE_TICKS = 20;
/** How long a finished order's hashless fill keeps waiting for its transaction from `/fills`. */
const FINISHED_KEEP_MS = 30 * 60_000;

function shortAddr(a: string | undefined): string {
  return a && a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : (a ?? "unknown");
}

/**
 * Reads a signed order's on-chain fill state, or null when it cannot: either just
 * `Settlement.filled(hash)` (anchor wei; max = cancelled), or — what the app wires
 * (lib/chain.ts `readFillState`) — that plus, for a fill-once order, whether its
 * nonce is consumed.
 */
export type FillReader = (signed: SignedOrder) => Promise<bigint | ChainFillState | null>;

export class RemoteOrderbook implements OrderbookApi {
  private rows: RestingOrder[] = [];
  private settled: Fill[] = [];
  private readonly tracked = new Map<string, Tracked>();
  /** Orders whose row is gone but whose fill rows may still get their transaction. */
  private readonly finished = new Map<string, Tracked>();
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
  private fillReader: FillReader | null;
  /** Order hashes (lower-cased) this app sent an ON-CHAIN cancel for — see {@link markHardCancelSent}. */
  private readonly userCancelled = new Set<string>();

  constructor(opts: RemoteOrderbookOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, "");
    const f = opts.fetch ?? (globalThis.fetch ? (globalThis.fetch.bind(globalThis) as FetchLike) : undefined);
    if (!f) throw new Error("no fetch available");
    this.doFetch = f;
    this.pollMs = opts.pollMs ?? POLL_MS;
    this.now = opts.now ?? (() => Date.now());
    this.resolveRow = opts.resolveRow;
    this.fillReader = opts.readFilled ?? null;
  }

  /**
   * The on-chain fallback for orders that leave the book: `Settlement.filled(hash)`
   * through the wallet's provider (the CSP allows no direct RPC). Null = no wallet.
   */
  setFillReader(reader: FillReader | null): void {
    this.fillReader = reader;
    // A reader arriving (the wallet reconnected after a reload) can settle rows that
    // finished while the tab was closed: look now, not one poll interval later.
    if (reader && this.timer) this.pollSoon();
  }

  /** Run a poll right away (coalesced: a poll already running covers it). */
  private pollSoon(): void {
    queueMicrotask(() => void this.poll());
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
    this.track(row, req.signed);
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

  /**
   * The app BROADCAST `cancelOrders` for this row's nonces. Recorded before the
   * receipt, so a chain read that already sees the nonce consumed is not mistaken for
   * a fill-once order's fill ({@link chainFillOutcome}); kept even if the receipt
   * wait then fails, since the tx may still land.
   */
  markHardCancelSent(orderHash: string): void {
    const row = this.rows.find((o) => o.id === orderHash);
    for (const s of row?.signedOrders ?? (row?.signed ? [row.signed] : [])) this.userCancelled.add(s.hash.toLowerCase());
    this.userCancelled.add(orderHash.toLowerCase());
  }

  confirmHardCancel(orderHash: string): void {
    this.markHardCancelSent(orderHash);
    const row = this.rows.find((o) => o.id === orderHash);
    if (row) this.retire(row, "cancelled");
    else this.dropRow(orderHash);
    this.emit();
  }

  async addSlice(orderHash: string, signed: SignedOrder): Promise<void> {
    const o = this.rows.find((x) => x.id === orderHash);
    if (!o?.slices || o.cancelled || o.slices.signed >= o.slices.total) return;
    if (!signed.deployed) throw new Error("No Settlement is deployed on this chain — the slice cannot be posted");
    await postOrder(this.doFetch, this.baseUrl, signed);
    o.signedOrders = [...(o.signedOrders ?? []), signed];
    o.slices.signed += 1;
    this.track(o, signed);
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
    // Restored rows get their live status (pending fill, chain state) right away.
    if (changed && this.timer) this.pollSoon();
  }

  /** One `GET /orders` item → a tracked row. @returns whether a row was added. */
  private restoreOrder(raw: unknown, maker: string): boolean {
    const item = raw as { orderHash?: unknown; order?: unknown; sig?: unknown; addedAt?: unknown; filledAmount?: unknown; pendingFill?: PendingFillBody };
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
    const expiresAt = Number(order.expiry) * 1000;
    const signed: SignedOrder = { order, sig: item.sig as Hex, hash, deployment: placed.deployment, deployed: true };
    const pending = pendingOf(item.pendingFill);
    const row: RestingOrder = {
      id: hash,
      marketId: placed.marketId,
      side: placed.side,
      type: inferType(addedAt, expiresAt),
      size: placed.size,
      filled: 0,
      price: placed.price,
      createdAt: addedAt,
      expiresAt,
      mine: true,
      signed,
      signedOrders: [signed],
      book: "remote",
      ...(pending ? { pendingFill: pending } : {}),
    };
    this.rows.push(row);
    this.track(row, signed);
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
      if ((this.tracked.size || this.finished.size) && this.now() >= this.pausedUntil && (await this.pollFills())) changed = true;
      if (await this.checkChain()) changed = true;
      if (this.settle()) changed = true;
      if (changed) this.emit();
    } finally {
      this.polling = false;
    }
  }

  // ── internals ──────────────────────────────────────────

  private track(row: RestingOrder, signed: SignedOrder): void {
    this.tracked.set(signed.hash.toLowerCase(), {
      rowId: row.id,
      hash: signed.hash,
      maker: signed.order.maker,
      anchor: anchorOf(signed.order),
      signed,
      filledWei: 0n,
      indexedWei: 0n,
      hashlessWei: 0n,
      statusDone: false,
      snap: {
        marketId: row.marketId,
        side: row.side,
        price: row.price,
        perOrder: row.size / (row.slices?.total ?? 1),
        type: row.type,
        size: row.size,
      },
    });
  }

  /** Drop a row; its tracked orders move to `finished` while a fill row still lacks its transaction. */
  private dropRow(rowId: string): void {
    this.rows = this.rows.filter((o) => o.id !== rowId);
    for (const [k, t] of this.tracked) {
      if (t.rowId !== rowId) continue;
      this.tracked.delete(k);
      if (this.fillIndex && t.hashlessWei > 0n) {
        t.keepUntil = this.now() + FINISHED_KEEP_MS;
        this.finished.set(k, t);
      }
    }
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
    if (row) {
      const pending = pendingOf(body.pendingFill);
      if (pending?.txHash !== row.pendingFill?.txHash) {
        if (pending) row.pendingFill = pending;
        else delete row.pendingFill;
        changed = true;
      }
    }
    if (typeof body.txHash === "string" && TX_HASH.test(body.txHash)) t.statusTx = body.txHash;
    if (body.live === false) {
      t.statusDone = true;
      if (body.status === "Filled" || body.reason === "filled") {
        if (t.filledWei < t.anchor) {
          t.filledWei = t.anchor;
          changed = true;
        }
      } else if (body.status === "Cancelled" || body.reason === "cancelled") {
        if (isFillOnce(t.signed.order) && this.fillReader !== null && !this.userCancelled.has(t.hash.toLowerCase())) {
          // A fill-once order: the book's "Cancelled" may be its FILL (a nonce bit
          // either way). The chain read below decides (`chainFillOutcome`).
          t.bookCancelled = true;
        } else {
          // Cancelled ON-CHAIN (from this or another device): it ends in Recent fills as Cancelled.
          t.cancelledOnChain = true;
        }
        changed = true;
      } else if (body.reason === "expired") {
        // The book dropped it at expiry; `settle` retires it (after the chain read).
        changed = true;
      } else if (row && !row.cancelled && !row.offBook) {
        // Evicted for another reason (unfunded, invalidated). The last known summary
        // does not say which, and the signature may still be fillable if the maker
        // re-funds — so the row says what is known.
        row.offBook =
          "no longer distributed by the orderbook (expired, unfunded or invalidated) — cancel on-chain to be sure it cannot fill";
        changed = true;
      }
    }
    return changed;
  }

  /**
   * `Settlement.filled(hash)` for orders the book stopped listing without saying
   * they filled — off book, or past expiry — so a fill the book missed still ends
   * as a fill, and an expiry is called an expiry only once the chain agrees.
   */
  private async checkChain(): Promise<boolean> {
    const read = this.fillReader;
    if (!read) return false;
    let changed = false;
    const now = this.now();
    for (const t of this.tracked.values()) {
      if (t.filledWei >= t.anchor || t.cancelledOnChain) continue;
      const row = this.rowOf(t);
      if (!row) continue;
      const phase: Tracked["chainChecked"] = row.expiresAt <= now ? "expired" : t.statusDone ? "gone" : undefined;
      if (!phase || t.chainChecked === phase) continue;
      t.chainChecked = phase;
      let raw: bigint | ChainFillState | null = null;
      try {
        raw = await read(t.signed);
      } catch {
        raw = null;
      }
      if (raw === null) {
        // No chain to ask: the book's verdict stands.
        if (t.bookCancelled) {
          t.cancelledOnChain = true;
          changed = true;
        }
        continue;
      }
      const v = typeof raw === "bigint" ? { filled: raw, nonceConsumed: false } : raw;
      const fillOnce = isFillOnce(t.signed.order);
      const out = chainFillOutcome({ ...v, fillOnce, anchor: t.anchor, userCancelled: this.userCancelled.has(t.hash.toLowerCase()) });
      if (out.cancelled) {
        t.cancelledOnChain = true;
        changed = true;
      } else if (out.filledWei > t.filledWei) {
        t.filledWei = out.filledWei;
        changed = true;
      } else if (t.bookCancelled && fillOnce && !v.nonceConsumed) {
        // The book saw the nonce consumed; this provider does not (yet). Ask again
        // next poll — until expiry, when the book's verdict stands.
        if (phase === "expired") {
          t.cancelledOnChain = true;
          changed = true;
        } else t.chainChecked = undefined;
      }
    }
    return changed;
  }

  /** One `/fills?maker=` read per maker covers every tracked order. @returns whether anything changed. */
  private async pollFills(): Promise<boolean> {
    if (!this.fillIndex) return false;
    const now = this.now();
    for (const [k, t] of this.finished) if ((t.keepUntil ?? 0) <= now || t.hashlessWei === 0n) this.finished.delete(k);
    let changed = false;
    const makers = new Set([...this.tracked.values(), ...this.finished.values()].map((t) => t.maker.toLowerCase()));
    for (const maker of makers) {
      const res = await this.get(`/fills?maker=${maker}&limit=100`);
      if (!res) continue;
      if (res.status === 501) {
        this.fillIndex = false;
        this.finished.clear();
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
   * monotonically. A fill of a tracked (or recently finished) order advances it
   * and, when a fill row for it was shown WITHOUT a transaction, gives that size
   * its transaction; with `history`, a fill of an order no longer tracked (it left
   * the book before this page loaded) is shown when the node served its order.
   * A record marked `status: "pending"` is a SENT fill: it flags the row, nothing more.
   * @returns whether anything changed.
   */
  private applyFills(fills: readonly FillBody[], history: boolean): boolean {
    let changed = false;
    for (const f of [...fills].reverse()) {
      if (typeof f.orderHash !== "string") continue;
      const tx = typeof f.txHash === "string" && TX_HASH.test(f.txHash) ? f.txHash : "";
      if (!tx) continue;
      const h = f.orderHash.toLowerCase();
      const t = this.tracked.get(h) ?? this.finished.get(h);
      if (f.status === "pending") {
        const row = t && this.rowOf(t);
        if (row && row.pendingFill?.txHash !== tx) {
          row.pendingFill = { txHash: tx, ...(typeof f.at === "number" ? { sentAt: f.at } : {}) };
          changed = true;
        }
        continue;
      }
      const key = `${tx}:${f.logIndex ?? ""}:${h}`;
      if (this.seenFills.has(key)) continue;
      if (!t) {
        if (history && this.pushHistoricalFill(f, tx)) {
          this.seenFills.add(key);
          changed = true;
        }
        continue;
      }
      this.seenFills.add(key);
      const row = this.rowOf(t);
      if (row?.pendingFill?.txHash === tx) delete row.pendingFill;
      const cumulative = toBig(f.cumulative);
      const amount = toBig(f.amount);
      let delta = amount ?? (cumulative !== null && cumulative > t.indexedWei ? cumulative - t.indexedWei : null);
      // A fill whose size the index does not say, for an order with a hashless row: it is that row's transaction.
      if (delta === null && t.hashlessWei > 0n) delta = t.hashlessWei;
      if (delta !== null && t.indexedWei + delta > t.anchor) delta = t.anchor - t.indexedWei;
      if (cumulative !== null && cumulative > t.filledWei) t.filledWei = cumulative > t.anchor ? t.anchor : cumulative;
      const at = typeof f.at === "number" ? f.at * 1000 : this.now();
      if (delta !== null) {
        // The part of this fill already on screen without a hash: shrink (or drop) that row.
        const convert = delta < t.hashlessWei ? delta : t.hashlessWei;
        if (convert > 0n) this.shrinkHashless(t, convert);
        t.indexedWei += delta;
        if (t.indexedWei > t.filledWei) t.filledWei = t.indexedWei;
        if (delta === 0n) continue; // nothing left to show (already counted)
      }
      this.pushFill(t, delta, tx, f.solver, at);
      changed = true;
    }
    return changed;
  }

  private shrinkHashless(t: Tracked, wei: bigint): void {
    t.hashlessWei -= wei;
    const i = this.settled.findIndex((x) => x.id === t.hashlessId);
    if (i < 0) return;
    if (t.hashlessWei <= 0n) {
      t.hashlessWei = 0n;
      this.settled.splice(i, 1);
      t.hashlessId = undefined;
      return;
    }
    const f = this.settled[i]!;
    this.settled[i] = { ...f, size: Math.max(0, f.size - fraction(wei, t.anchor) * t.snap.perOrder) };
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
    const cumulative = toBig(f.cumulative);
    const anchor = anchorOf(order);
    if (!placed) return false;
    this.settled.push({
      id: `${tx}-${f.orderHash.toLowerCase()}`,
      orderHash: f.orderHash,
      marketId: placed.marketId,
      side: placed.side,
      size: amount === null || anchor === 0n ? 0 : fraction(amount > anchor ? anchor : amount, anchor) * placed.size,
      orderSize: placed.size,
      price: placed.price,
      source: "LMT",
      filler: shortAddr(f.solver),
      tx,
      at: typeof f.at === "number" ? f.at * 1000 : this.now(),
      mine: true,
      simulated: false,
      status: cumulative !== null && anchor > 0n && cumulative >= anchor ? "filled" : "partial",
    });
    this.trimFills();
    return true;
  }

  /**
   * One fill row for `deltaWei` of `t`. With a `tx` it counts as indexed (the
   * caller has already moved `indexedWei`); without, it grows the order's single
   * hashless row — the one a later `/fills` record gives its transaction.
   */
  private pushFill(t: Tracked, deltaWei: bigint | null, tx: string, solver: string | undefined, at: number): void {
    const size = deltaWei === null || t.anchor === 0n ? 0 : fraction(deltaWei, t.anchor) * t.snap.perOrder;
    const status: Fill["status"] = t.filledWei >= t.anchor ? "filled" : "partial";
    if (!tx && t.hashlessId) {
      const i = this.settled.findIndex((x) => x.id === t.hashlessId);
      if (i >= 0) {
        const f = this.settled[i]!;
        this.settled[i] = { ...f, size: f.size + size, at, status };
        return;
      }
    }
    const id = tx ? `${tx}-${t.hash}-${this.settled.length}` : `${t.hash}-${at}`;
    if (!tx) t.hashlessId = id;
    this.settled.push({
      id,
      orderHash: t.hash,
      orderType: t.snap.type,
      marketId: t.snap.marketId,
      side: t.snap.side,
      size,
      orderSize: t.snap.size,
      // The SIGNED limit price — the floor the fill had to meet. An auction may
      // have filled better; the transaction is the authority.
      price: t.snap.price,
      source: "LMT",
      filler: tx ? shortAddr(solver) : "unknown",
      tx,
      at,
      mine: true,
      simulated: false,
      status,
    });
    this.trimFills();
  }

  private trimFills(): void {
    if (this.settled.length > MAX_FILLS) this.settled = this.fills().slice(0, MAX_FILLS);
  }

  /** Show every not-yet-shown filled wei of `t` now: with the grave's transaction when the book named one. */
  private flushUnshown(t: Tracked, at: number): void {
    const shown = t.indexedWei + t.hashlessWei;
    if (t.filledWei <= shown) return;
    const delta = t.filledWei - shown;
    if (t.statusTx && !t.indexedWei && !t.hashlessWei) {
      t.indexedWei += delta;
      this.pushFill(t, delta, t.statusTx, undefined, at);
    } else {
      t.hashlessWei += delta;
      this.pushFill(t, delta, "", undefined, at);
    }
    t.awaitingIndex = undefined;
  }

  /** A row is done: show what it filled, say how it ended, and take it off the open orders. */
  private retire(row: RestingOrder, outcome: Outcome): void {
    const now = this.now();
    const mine = [...this.tracked.values()].filter((t) => t.rowId === row.id);
    for (const t of mine) {
      delete row.pendingFill;
      this.flushUnshown(t, now);
    }
    // A filled order's fill rows say it all; an expiry / cancel gets its own entry.
    if (outcome !== "filled") {
      this.settled.push(outcomeEntry(row, outcome === "partially-filled" ? "expired" : outcome, now));
      this.trimFills();
    }
    this.dropRow(row.id);
  }

  /** Fold tracked progress into the rows; retire finished and expired rows. @returns whether anything changed. */
  private settle(): boolean {
    let changed = false;
    const now = this.now();
    for (const t of this.tracked.values()) {
      if (t.filledWei <= t.indexedWei + t.hashlessWei) {
        t.awaitingIndex = undefined;
        continue;
      }
      // A LIVE row moved but no indexed fill explains it (yet). With an index,
      // give it time; without one there will never be a hash, so show the fill
      // now as a fill whose transaction is unknown — never an invented one.
      // (A row that is done is flushed by `retire` without waiting.)
      if (this.fillIndex && (t.awaitingIndex = (t.awaitingIndex ?? 0) + 1) < INDEX_GRACE_TICKS) continue;
      this.flushUnshown(t, now);
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
      if (row.pendingFill && isFull(row.filled, row.size)) {
        delete row.pendingFill;
        changed = true;
      }
      // Past expiry with a chain reader that has not had its say yet: wait one poll.
      const awaitingChain = row.expiresAt <= now && this.fillReader !== null && mine.some((t) => t.filledWei < t.anchor && !t.cancelledOnChain && t.chainChecked !== "expired");
      const outcome = retireReason(row, { now, cancelledOnChain: mine.some((t) => t.cancelledOnChain) });
      if (outcome && !(awaitingChain && outcome !== "filled" && outcome !== "cancelled")) {
        this.retire(row, outcome);
        changed = true;
      }
    }
    return changed;
  }

  private start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.poll(), this.pollMs);
    // First look immediately: after a reload the open rows (a fill confirming, an
    // order that filled meanwhile) must not wait a whole interval to update.
    this.pollSoon();
    if (typeof document !== "undefined") {
      this.onVisible = () => {
        if (document.visibilityState === "visible") this.pollSoon();
      };
      document.addEventListener("visibilitychange", this.onVisible);
    }
  }

  private stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = undefined;
    if (this.onVisible && typeof document !== "undefined") document.removeEventListener("visibilitychange", this.onVisible);
    this.onVisible = undefined;
  }

  private onVisible: (() => void) | undefined;

  private emit(): void {
    for (const l of this.listeners) l();
  }
}

/** `num / den` as a float in [0, 1], exact enough for display. */
function fraction(num: bigint, den: bigint): number {
  if (den === 0n) return 0;
  return Number((num * 1_000_000_000n) / den) / 1e9;
}

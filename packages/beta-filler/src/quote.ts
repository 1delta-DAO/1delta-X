import type { Order } from "@1delta-x/sdk";
import { getAddress, isAddress, type Address, type Hex } from "viem";

import { ROOTSTOCK_POOLS, type Config, type QuotePolicy, type RoutePool } from "./config";
import type { Filler } from "./filler";
import type { Guard } from "./guard";
import { isDeltaVerify, type Verdict } from "./policy";
import type { RouteFiller } from "./routeFiller";

/**
 * INDICATIVE QUOTES (2026-10-07) — what the filler would deliver for a market ticket
 * right now, served by the Worker's public `POST /quote` (the app reaches it through
 * its Pages worker at `/api/quote`).
 *
 *     amountOut = grossOut − ⌈gasCostOut × (1 + QUOTE_GAS_MARGIN_BPS / 1e4)⌉ − grossOut × QUOTE_TOLERANCE_BPS / 1e4
 *
 *   • grossOut — the filler's real pricing for that order shape: the best route output
 *     for `amountIn` (every configured Oku path on QuoterV2; a Sushi API route too when
 *     the delivery is PULL), ranked by output net of each route's own gas — or, on the
 *     USDRIF→USDT0 pull market, the inventory strategy's price when it is better.
 *   • gasCostOut — one fill's gas in the output token, exactly as the fill gate prices
 *     it: estimate × r (the receipt/estimate ratio learned per fill shape, gasRatio.ts)
 *     × the send gas price (block minimumGasPrice × GAS_PRICE_MIN_MULT_BPS), grossed up
 *     for the solver's maker/protocol surplus split (route) or plus the fill's share of
 *     the rebalance it causes (inventory). No order exists yet, so there is nothing to
 *     simulate: the estimate is the largest one learned for the shape from our own
 *     receipts, or QUOTE_GAS_ESTIMATE_DIRECT / _PULL / INVENTORY_GAS_ESTIMATE before any.
 *   • the margin on the gas (default +20 %) is the cushion; there is NO quote haircut —
 *     the quote is fresh, and the on-chain floor of the fill's plan (minOut /
 *     amountInMaximum) bounds any move before inclusion to a revert, never a loss.
 *
 * The app signs a short DUTCH order that starts AT the quote and decays to the maker's
 * slippage floor (UniswapX-style indicative quoting): the filler fills it on its next
 * tick when the price held, or a little later down the decay when it moved. An order
 * signed from one of OUR quotes is recognised by its terms ({@link quoteMatches}) and
 * gated WITHOUT the route haircut (RouteFiller): the quote's gas margin is the cushion,
 * so a quote the filler itself issued is not then refused for a haircut it never
 * charged. Everything else keeps the normal gate.
 */

export type Delivery = "direct" | "pull";
export type QuoteSide = "sell" | "buy";

export interface QuoteRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  /** Exact input, wei of `tokenIn` (the app's pay amount, for a SELL and a BUY alike). */
  amountIn: bigint;
  side: QuoteSide;
  marketId?: string;
  /** Optional: when given, only an order by this maker matches the quote. */
  maker?: Address;
  /** How the app will sign the order (its deployment config): direct = delta-verify to our solver. */
  delivery: Delivery;
}

/** One priced way to fill: before the gas margin and tolerance. */
export interface PricedCandidate {
  strategy: "route" | "inventory";
  /** What the fill would deliver before gas (route output, or the inventory price), wei of tokenOut. */
  grossOut: bigint;
  /** A hard cap on the delivered amount independent of gas (inventory: MAX_BUY_PRICE / exit edge). */
  capOut?: bigint;
  /** One fill's cost in tokenOut (gas + min profit, grossed up / + rebalance share). */
  costOut: bigint;
  /** The gas units the cost is priced at (estimate × r). */
  gasUnits: bigint;
  /** Where the price comes from: `oku` (n hops), `sushi`, `inventory`. */
  source: string;
  hops?: number;
}

export interface QuoteResult {
  quoteId: string;
  chainId: number;
  side: QuoteSide;
  marketId?: string;
  delivery: Delivery;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  /** Net: what the order should ask for. */
  amountOut: bigint;
  grossOut: bigint;
  gasUnits: bigint;
  gasPriceWei: bigint;
  /** The fill's cost in tokenOut, before the margin. */
  gasCostOut: bigint;
  /** What the quote charges for it: ⌈gasCostOut × (1 + margin)⌉. */
  gasChargeOut: bigint;
  gasMarginBps: bigint;
  toleranceBps: bigint;
  toleranceOut: bigint;
  issuedAt: number;
  /** Unix seconds. */
  validUntil: number;
  strategy: "route" | "inventory";
  route: { source: string; hops?: number };
}

/**
 * The quote arithmetic. `capOut` (inventory) bounds the result independently of gas.
 * Returns `amountOut` 0 when the costs eat the whole output (unquotable).
 */
export function netQuote(a: { grossOut: bigint; costOut: bigint; gasMarginBps: bigint; toleranceBps: bigint; capOut?: bigint }): {
  amountOut: bigint;
  chargeOut: bigint;
  toleranceOut: bigint;
} {
  const chargeOut = (a.costOut * (10_000n + a.gasMarginBps) + 9_999n) / 10_000n;
  const toleranceOut = (a.grossOut * a.toleranceBps + 9_999n) / 10_000n;
  let amountOut = a.grossOut - chargeOut - toleranceOut;
  if (a.capOut !== undefined && amountOut > a.capOut) amountOut = a.capOut;
  return { amountOut: amountOut > 0n ? amountOut : 0n, chargeOut, toleranceOut };
}

// ──────────────────── request parsing ────────────────────

const KEYS = new Set(["chainId", "marketId", "tokenIn", "tokenOut", "side", "amountIn", "maker", "delivery"]);
const MAX_AMOUNT = 2n ** 128n;
const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** Market id → (base, quote): the app's market ids on the configured pools (`tokenA` is the base). */
export function quoteMarkets(cfg: Pick<Config, "route">): Map<string, { base: Address; quote: Address }> {
  const out = new Map<string, { base: Address; quote: Address }>();
  const pools: readonly RoutePool[] = cfg.route?.pools?.some((p) => p.market) ? cfg.route.pools : ROOTSTOCK_POOLS;
  for (const p of pools) if (p.market) out.set(p.market, { base: getAddress(p.tokenA), quote: getAddress(p.tokenB) });
  return out;
}

/**
 * Strict request validation: a JSON object with only the known keys; `chainId` this
 * filler's; `side` and `delivery` from their enums; `amountIn` a positive decimal
 * string below 2^128; tokens either given or derived from a known `marketId` (`sell`
 * pays the base) — and consistent when both are.
 */
export function parseQuoteRequest(raw: unknown, cfg: Pick<Config, "chainId" | "route">): Verdict<{ req: QuoteRequest }> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, reason: "body must be a JSON object" };
  const o = raw as Record<string, unknown>;
  const extra = Object.keys(o).find((k) => !KEYS.has(k));
  if (extra) return { ok: false, reason: `unknown field ${JSON.stringify(extra.slice(0, 40))}` };
  if (o.chainId !== cfg.chainId) return { ok: false, reason: `chainId must be ${cfg.chainId}` };
  if (o.side !== "sell" && o.side !== "buy") return { ok: false, reason: 'side must be "sell" or "buy"' };
  if (o.delivery !== "direct" && o.delivery !== "pull") return { ok: false, reason: 'delivery must be "direct" or "pull"' };
  if (typeof o.amountIn !== "string" || !/^\d{1,40}$/.test(o.amountIn)) return { ok: false, reason: "amountIn must be a decimal string (wei)" };
  const amountIn = BigInt(o.amountIn);
  if (amountIn === 0n || amountIn >= MAX_AMOUNT) return { ok: false, reason: "amountIn out of range" };
  const addr = (v: unknown): Address | undefined => (typeof v === "string" && isAddress(v, { strict: false }) ? getAddress(v) : undefined);
  let maker: Address | undefined;
  if (o.maker !== undefined) {
    maker = addr(o.maker);
    if (!maker) return { ok: false, reason: "maker must be an address" };
  }
  let tokenIn: Address | undefined;
  let tokenOut: Address | undefined;
  if (o.tokenIn !== undefined || o.tokenOut !== undefined) {
    tokenIn = addr(o.tokenIn);
    tokenOut = addr(o.tokenOut);
    if (!tokenIn || !tokenOut) return { ok: false, reason: "tokenIn and tokenOut must both be addresses" };
  }
  let marketId: string | undefined;
  if (o.marketId !== undefined) {
    if (typeof o.marketId !== "string" || o.marketId.length > 64) return { ok: false, reason: "marketId must be a string" };
    const m = quoteMarkets(cfg).get(o.marketId);
    if (!m) return { ok: false, reason: "unknown marketId" };
    marketId = o.marketId;
    const [mi, mo] = o.side === "sell" ? [m.base, m.quote] : [m.quote, m.base];
    if (tokenIn && tokenOut && (!eq(tokenIn, mi) || !eq(tokenOut, mo))) return { ok: false, reason: "tokens do not match marketId/side" };
    tokenIn = mi;
    tokenOut = mo;
  }
  if (!tokenIn || !tokenOut) return { ok: false, reason: "give tokenIn/tokenOut or a marketId" };
  if (eq(tokenIn, tokenOut)) return { ok: false, reason: "tokenIn equals tokenOut" };
  return {
    ok: true,
    req: { chainId: cfg.chainId, tokenIn, tokenOut, amountIn, side: o.side, delivery: o.delivery, ...(marketId ? { marketId } : {}), ...(maker ? { maker } : {}) },
  };
}

// ──────────────────── the registry of issued quotes ────────────────────

/** One issued quote as the registry keeps (and persists) it. */
export interface IssuedQuote {
  id: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: string;
  amountOut: string;
  maker?: string;
  delivery: Delivery;
  issuedAt: number;
  validUntil: number;
  /** The order this quote was matched to (one quote → one order). */
  order?: string;
  /** That order's expiry (unix s): a bound quote is kept until then. */
  orderExpiry?: number;
}

export type QuoteBookState = IssuedQuote[];

/** Issued quotes kept, at most (unbound and oldest are evicted first). */
export const MAX_QUOTES = 300;

/**
 * Whether `order` was signed from quote `q`: same tokens, same maker (when the quote
 * named one), the quoted delivery mode, first seen within the quote's validity + grace,
 * no larger than quoted (the input never exceeds `amountIn`), and its START price no
 * better for the maker than the quote's rate (1 bp slack for the app's float rounding).
 * The Dutch decay below the start only makes the order cheaper for the filler.
 */
export function quoteMatches(q: IssuedQuote, order: Order, nowS: number, graceS: number): boolean {
  if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return false;
  const legIn = order.legsIn[0]!;
  const legOut = order.legsOut[0]!;
  if (!eq(legIn.token, q.tokenIn) || !eq(legOut.token, q.tokenOut)) return false;
  if (q.maker && !eq(order.maker, q.maker)) return false;
  if ((q.delivery === "direct") !== isDeltaVerify(order)) return false;
  if (nowS > q.validUntil + graceS) return false;
  const qIn = BigInt(q.amountIn);
  const qOut = BigInt(q.amountOut);
  const inMax = legIn.end > legIn.start ? legIn.end : legIn.start;
  if (inMax === 0n || inMax > qIn || legIn.start === 0n) return false;
  return legOut.start * qIn * 10_000n <= qOut * legIn.start * 10_001n;
}

export class QuoteBook {
  private readonly quotes: IssuedQuote[];
  private readonly byOrder = new Map<string, IssuedQuote>();

  constructor(
    state: QuoteBookState = [],
    private readonly persist: () => void = () => {},
  ) {
    this.quotes = (Array.isArray(state) ? state : []).filter((q) => q && typeof q.id === "string" && typeof q.amountIn === "string").slice(-MAX_QUOTES);
    for (const q of this.quotes) if (q.order) this.byOrder.set(q.order, q);
  }

  get size(): number {
    return this.quotes.length;
  }

  issue(q: IssuedQuote, nowMs: number, graceS: number): void {
    this.prune(nowMs, graceS);
    this.quotes.push(q);
    this.evict();
    this.persist();
  }

  /**
   * The quote `order` was signed from, if any: its existing binding, else the first
   * unbound live quote it matches, NEWEST first — which is then bound to it (a quote prices ONE order).
   */
  match(orderHash: Hex, order: Order, nowMs: number, graceS: number): IssuedQuote | undefined {
    const h = orderHash.toLowerCase();
    const bound = this.byOrder.get(h);
    if (bound) return bound;
    const nowS = Math.floor(nowMs / 1000);
    // Newest first: the app re-quotes every ~15 s and right before signing.
    let q: IssuedQuote | undefined;
    for (let i = this.quotes.length - 1; i >= 0 && !q; i--) {
      const x = this.quotes[i]!;
      if (!x.order && quoteMatches(x, order, nowS, graceS)) q = x;
    }
    if (!q) return undefined;
    q.order = h;
    q.orderExpiry = Number(order.expiry);
    this.byOrder.set(h, q);
    this.persist();
    return q;
  }

  /** Drop unbound quotes past validUntil + grace and bound ones whose order has expired. */
  prune(nowMs: number, graceS: number): void {
    const nowS = Math.floor(nowMs / 1000);
    const keep = this.quotes.filter((q) => (q.order ? (q.orderExpiry ?? 0) >= nowS : q.validUntil + graceS >= nowS));
    if (keep.length === this.quotes.length) return;
    for (const q of this.quotes) if (q.order && !keep.includes(q)) this.byOrder.delete(q.order);
    this.quotes.splice(0, this.quotes.length, ...keep);
    this.persist();
  }

  private evict(): void {
    while (this.quotes.length > MAX_QUOTES) {
      const i = this.quotes.findIndex((q) => !q.order);
      const [gone] = this.quotes.splice(i >= 0 ? i : 0, 1);
      if (gone?.order) this.byOrder.delete(gone.order);
    }
  }

  toJSON(): QuoteBookState {
    return this.quotes.map((q) => ({ ...q }));
  }
}

// ──────────────────── the quoter ────────────────────

function randomId(): string {
  const b = new Uint8Array(12);
  crypto.getRandomValues(b);
  return `q_${[...b].map((x) => x.toString(16).padStart(2, "0")).join("")}`;
}

/**
 * Prices a {@link QuoteRequest} with the engine's own strategies and records the
 * issued quote in the {@link QuoteBook}. Stateless otherwise (a short result cache).
 */
export class Quoter {
  private readonly cache = new Map<string, { at: number; priced: PricedCandidate[]; gasPrice: bigint }>();

  constructor(
    private readonly cfg: Config,
    private readonly chain: { pub: { getGasPrice(): Promise<bigint> } },
    private readonly guard: Pick<Guard, "checkGasPrice">,
    readonly book: QuoteBook,
    private readonly strategies: { route?: RouteFiller; inventory?: Filler },
    private readonly now: () => number = Date.now,
  ) {}

  private policy(): QuotePolicy {
    return this.cfg.quote;
  }

  /** Price every applicable strategy for `req` (cached for QUOTE_CACHE_MS per identical request). */
  private async price(req: QuoteRequest): Promise<{ priced: PricedCandidate[]; gasPrice: bigint; reasons: string[] }> {
    const key = `${req.tokenIn}:${req.tokenOut}:${req.amountIn}:${req.delivery}`.toLowerCase();
    const at = this.now();
    const hit = this.cache.get(key);
    if (hit && at - hit.at < this.policy().cacheMs) return { priced: hit.priced, gasPrice: hit.gasPrice, reasons: [] };
    const gasPrice = await this.chain.pub.getGasPrice();
    const err = this.guard.checkGasPrice(gasPrice);
    if (err) return { priced: [], gasPrice, reasons: [err] };
    const priced: PricedCandidate[] = [];
    const reasons: string[] = [];
    const { route, inventory } = this.strategies;
    if (route) {
      const r = await route.quoteRoute({ tokenIn: req.tokenIn, tokenOut: req.tokenOut, amountIn: req.amountIn, direct: req.delivery === "direct", gasPrice }).catch((e: unknown) => ({ ok: false as const, reason: `route: ${(e as Error).message?.split("\n")[0] ?? e}` }));
      if (r.ok) priced.push(r.candidate);
      else reasons.push(r.reason);
    }
    // The inventory EOA fills PULL orders only (an EOA cannot run a delta-verify callback).
    if (inventory && req.delivery === "pull") {
      const r = await inventory.quoteInventory(req.tokenIn, req.tokenOut, req.amountIn, gasPrice).catch((e: unknown) => ({ ok: false as const, reason: `inventory: ${(e as Error).message?.split("\n")[0] ?? e}` }));
      if (r.ok) priced.push(r.candidate);
      else reasons.push(r.reason);
    }
    if (this.cache.size > 200) this.cache.clear();
    if (priced.length) this.cache.set(key, { at, priced, gasPrice });
    return { priced, gasPrice, reasons };
  }

  async quote(req: QuoteRequest): Promise<Verdict<{ quote: QuoteResult }>> {
    const p = this.policy();
    if (!p.enabled) return { ok: false, reason: "quotes disabled" };
    if (req.chainId !== this.cfg.chainId) return { ok: false, reason: `chainId must be ${this.cfg.chainId}` };
    const { priced, gasPrice, reasons } = await this.price(req);
    let best: { c: PricedCandidate; n: ReturnType<typeof netQuote> } | undefined;
    for (const c of priced) {
      const n = netQuote({ grossOut: c.grossOut, costOut: c.costOut, gasMarginBps: p.gasMarginBps, toleranceBps: p.toleranceBps, capOut: c.capOut });
      if (n.amountOut === 0n) {
        reasons.push(`${c.strategy}: gas ${n.chargeOut} exceeds the output ${c.grossOut}`);
        continue;
      }
      if (!best || n.amountOut > best.n.amountOut) best = { c, n };
    }
    if (!best) return { ok: false, reason: reasons.length ? reasons.join("; ") : "no route" };
    const issuedAt = this.now();
    const validUntil = Math.floor(issuedAt / 1000) + p.ttlSeconds;
    const quote: QuoteResult = {
      quoteId: randomId(),
      chainId: this.cfg.chainId,
      side: req.side,
      ...(req.marketId ? { marketId: req.marketId } : {}),
      delivery: req.delivery,
      tokenIn: req.tokenIn,
      tokenOut: req.tokenOut,
      amountIn: req.amountIn,
      amountOut: best.n.amountOut,
      grossOut: best.c.grossOut,
      gasUnits: best.c.gasUnits,
      gasPriceWei: gasPrice,
      gasCostOut: best.c.costOut,
      gasChargeOut: best.n.chargeOut,
      gasMarginBps: p.gasMarginBps,
      toleranceBps: p.toleranceBps,
      toleranceOut: best.n.toleranceOut,
      issuedAt,
      validUntil,
      strategy: best.c.strategy,
      route: { source: best.c.source, ...(best.c.hops !== undefined ? { hops: best.c.hops } : {}) },
    };
    this.book.issue(
      {
        id: quote.quoteId,
        tokenIn: req.tokenIn.toLowerCase(),
        tokenOut: req.tokenOut.toLowerCase(),
        amountIn: req.amountIn.toString(),
        amountOut: quote.amountOut.toString(),
        ...(req.maker ? { maker: req.maker.toLowerCase() } : {}),
        delivery: req.delivery,
        issuedAt,
        validUntil,
      },
      issuedAt,
      p.matchGraceSeconds,
    );
    return { ok: true, quote };
  }
}

/** A quote as JSON (bigints as decimal strings) — the `POST /quote` response body. */
export function quoteToJson(q: QuoteResult): Record<string, unknown> {
  return JSON.parse(JSON.stringify(q, (_k, v) => (typeof v === "bigint" ? v.toString() : v))) as Record<string, unknown>;
}

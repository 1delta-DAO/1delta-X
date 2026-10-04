import { SOURCES, dueSlices, type Fill, type RestingOrder, type Side } from "../lib/types";
import type {
  MarketObservation,
  OrderbookApi,
  PlaceOrderRequest,
  RecordTakeRequest,
  SignedCancel,
  SignedOrder,
} from "./api";

/**
 * In-memory stand-in for order distribution.
 *
 * It is deliberately NOT a simulation of the settlement contract: it holds
 * SIGNED orders, marks them soft-cancelled on a signed retraction (keeping the
 * row, since the signature stays valid on-chain), and advances SIMULATED fills
 * as the live pool mid moves through resting prices — a TWAP only through the
 * slices the maker has signed. That is the part of the system the interface reacts
 * to. Signing, verification and on-chain state live behind
 * `@1delta-x/orderbook` and arrive when this class is replaced by a real client
 * of the same `OrderbookApi` interface.
 */

/** Deterministic PRNG, so a market seeds the same book on every mount. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedOf(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return h >>> 0;
}

function hex(rand: () => number, bytes: number): string {
  let out = "0x";
  for (let i = 0; i < bytes * 2; i++) out += "0123456789abcdef"[Math.floor(rand() * 16)];
  return out;
}

/** How often resting orders are re-evaluated against the live mid. */
const TICK_MS = 4_000;

/** Resting orders seeded per side when a market is first observed. */
const SEED_PER_SIDE = 7;

export class MockOrderbook implements OrderbookApi {
  private restingOrders: RestingOrder[] = [];
  private settled: Fill[] = [];
  private readonly listeners = new Set<() => void>();
  private readonly latest = new Map<string, MarketObservation>();
  private readonly seeded = new Set<string>();
  private readonly rand = mulberry32(0xc0ffee);
  private timer: ReturnType<typeof setInterval> | undefined;
  private counter = 0;

  orders(marketId?: string): RestingOrder[] {
    const all = marketId ? this.restingOrders.filter((o) => o.marketId === marketId) : this.restingOrders;
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
    // The wallet round-trip already happened in the caller: an order arrives
    // here signed, or not at all.
    if (!req.signed) throw new Error("the book only holds signed orders");
    const now = Date.now();
    const order: RestingOrder = {
      // Keyed by the contract's own order hash, so this id is the same string a
      // filler and the chain would use.
      id: req.signed.hash,
      marketId: req.marketId,
      side: req.side,
      type: req.type,
      size: req.size,
      filled: Math.min(req.size, Math.max(0, req.filled ?? 0)),
      price: req.price,
      createdAt: now,
      expiresAt: now + req.ttlMs,
      mine: true,
      signed: req.signed,
      signedOrders: [req.signed],
      sliceSpec: req.sliceSpec,
      slices: req.slices
        ? { done: 0, total: req.slices.total, everyMin: req.slices.everyMin, signed: 1 }
        : undefined,
    };
    this.restingOrders.push(order);
    this.emit();
    return order;
  }

  async cancel(orderHash: string, signed: SignedCancel): Promise<void> {
    // A real book verifies the signature before acting. The mock trusts its own
    // tab, but it still refuses a cancel that does not carry one or does not
    // name this order — an unsigned eviction is not a cancel of anything.
    if (!signed || !signed.cancel.orderHashes.includes(orderHash as `0x${string}`)) {
      throw new Error("a soft cancel must be signed and name the order");
    }
    const o = this.restingOrders.find((x) => x.id === orderHash);
    if (!o) return;
    // Retracted from distribution, NOT from existence: the order is still
    // fillable on-chain until it expires, so it stays listed as such.
    o.cancelled = "soft";
    this.emit();
  }

  confirmHardCancel(orderHash: string): void {
    this.restingOrders = this.restingOrders.filter((o) => o.id !== orderHash);
    this.emit();
  }

  addSlice(orderHash: string, signed: SignedOrder): void {
    const o = this.restingOrders.find((x) => x.id === orderHash);
    if (!o?.slices || o.cancelled || o.slices.signed >= o.slices.total) return;
    o.signedOrders = [...(o.signedOrders ?? []), signed];
    o.slices.signed += 1;
    this.emit();
  }

  recordTake(req: RecordTakeRequest): void {
    const now = Date.now();
    // One row per source the sweep touched, because "filled from the pool" and
    // "filled against a resting order" are different settlements, not one blend.
    const parts = SOURCES.map((source) => ({ source, size: req.bySource[source] ?? 0 })).filter((p) => p.size > 0);
    const rows = parts.length ? parts : [{ source: "UNI" as const, size: req.size }];
    for (const p of rows) {
      this.settled.push({
        id: `${now}-${this.counter++}`,
        marketId: req.marketId,
        side: req.side,
        size: req.side === "sell" ? p.size : p.size / req.price,
        price: req.price,
        source: p.source,
        filler: this.filler(),
        tx: hex(this.rand, 32),
        at: now,
        mine: true,
        simulated: true,
      });
    }
    this.emit();
  }

  observe(obs: MarketObservation): void {
    this.latest.set(obs.marketId, obs);
    if (!this.seeded.has(obs.marketId)) {
      this.seeded.add(obs.marketId);
      this.seedMarket(obs);
      this.emit();
    }
  }

  // ── internals ──────────────────────────────────────────

  private start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), TICK_MS);
  }

  private stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = undefined;
  }

  private emit(): void {
    for (const l of this.listeners) l();
  }

  private filler(): string {
    const pool = ["0x8f3a", "0x2e77", "0xb904", "0x51c0"];
    return `${pool[Math.floor(this.rand() * pool.length)]}…${hex(this.rand, 2).slice(2)}`;
  }

  /**
   * Give a freshly-opened market a book to sit in.
   *
   * Placement is in rungs of the pool's own price grid rather than a percentage
   * of mid: a percentage lands the whole seeded book outside the visible ladder
   * on a tight pair and stacks it all on one rung on a coarse one. Sizes are a
   * fraction of measured pool depth, so the result is proportionate on a $2bn
   * pair and on a thin one alike.
   */
  private seedMarket(obs: MarketObservation): void {
    const rand = mulberry32(seedOf(obs.marketId));
    const now = Date.now();
    const step = obs.step > 0 ? obs.step : Math.pow(10, -obs.tick);
    const unit = Math.max(obs.depth / 400, 1e-6);

    for (const side of ["buy", "sell"] as Side[]) {
      for (let i = 0; i < SEED_PER_SIDE; i++) {
        const away = (1 + i + rand() * 1.4) * step;
        const price = side === "buy" ? obs.mid - away : obs.mid + away;
        if (price <= 0) continue;
        const size = unit * (0.6 + rand() * 2.6) * (1 + i * 0.35);
        this.restingOrders.push({
          id: hex(rand, 32),
          marketId: obs.marketId,
          side,
          type: "limit",
          size,
          filled: size * (rand() < 0.35 ? rand() * 0.5 : 0),
          price: roundToStep(price, step),
          createdAt: now - Math.floor(rand() * 6 * 3600_000),
          expiresAt: now + Math.floor((2 + rand() * 22) * 3600_000),
          mine: false,
        });
      }
    }
  }

  /**
   * One pass over every resting order: expire, execute due TWAP slices, and
   * fill anything the live mid has moved through. Progress is driven by the
   * real pool price rather than a timer, so the book reacts to the market the
   * user is watching instead of drifting on its own.
   */
  private tick(): void {
    const now = Date.now();
    let changed = false;
    const keep: RestingOrder[] = [];

    for (const o of this.restingOrders) {
      if (o.expiresAt <= now) {
        changed = true;
        continue;
      }
      const obs = this.latest.get(o.marketId);
      if (!obs) {
        keep.push(o);
        continue;
      }

      const remaining = o.size - o.filled;
      if (remaining <= o.size * 1e-6) {
        // Fully worked: it leaves the book the same way a filled order does.
        changed = true;
        continue;
      }

      let take = 0;
      if (o.cancelled) {
        // Retracted from this book: it no longer works here. (On-chain it is
        // still fillable by anyone holding it — which the row says.)
      } else if (o.slices) {
        // Only a SIGNED slice can fill. A due slice the maker has not signed
        // yet waits for its signature instead of filling on schedule.
        const due = Math.min(dueSlices(o, now), o.slices.signed);
        if (due > o.slices.done && o.slices.done < o.slices.total) {
          const n = due - o.slices.done;
          o.slices.done = due;
          take = Math.min(remaining, (o.size / o.slices.total) * n);
        }
      } else {
        const crossed = o.side === "sell" ? obs.mid >= o.price : obs.mid <= o.price;
        // A crossed rung does not clear in one go — a filler takes what its
        // inventory covers, which is what makes partial fills the normal case.
        if (crossed && this.rand() < 0.7) take = remaining * (0.2 + this.rand() * 0.6);
      }

      if (take > 0) {
        o.filled = Math.min(o.size, o.filled + take);
        changed = true;
        if (o.mine) {
          this.settled.push({
            id: `${now}-${this.counter++}`,
            marketId: o.marketId,
            side: o.side,
            size: take,
            price: o.price,
            source: "LMT",
            filler: this.filler(),
            tx: hex(this.rand, 32),
            at: now,
            mine: true,
            simulated: true,
          });
        }
      }
      keep.push(o);
    }

    this.restingOrders = keep;
    // Recent fills only — an unbounded list would grow for as long as the tab is open.
    if (this.settled.length > 60) this.settled = this.fills().slice(0, 60);
    if (changed) this.emit();
  }
}

/** Snap to the pool's price grid, and shed the float noise that snapping leaves. */
function roundToStep(n: number, step: number): number {
  const dp = Math.max(0, Math.min(12, Math.ceil(-Math.log10(step))));
  return Number((Math.round(n / step) * step).toFixed(dp));
}

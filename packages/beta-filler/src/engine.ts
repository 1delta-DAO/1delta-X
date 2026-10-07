import { withGasPriceCache, type Chain } from "./chain";
import { AUCTION_RECHECK_MS, type Config } from "./config";
import { dispatch, type Strategy } from "./dispatch";
import { Filler, type FillOutcome } from "./filler";
import { GAS, Guard, resolvePending as resolveTx, type PendingTx, type Resolution } from "./guard";
import type { BookEntry } from "./intake";
import { Budget, isFixedPrice, windowEndMs } from "./policy";
import { Rebalancer, type RebalanceOutcome } from "./rebalance";
import { ROUTE_FILLS, RouteFiller } from "./routeFiller";
import { sanitize } from "./sanitize";
import { STATE_KEY, type FillerState, type RecentEvent, type StateStore } from "./state";

export type Log = (m: string) => void;

/** What the engine reports to its host (the Worker's fills log and alerts). */
export type EngineEvent =
  | { type: "sent"; pending: PendingTx }
  | { type: "resolved"; resolution: Resolution }
  | { type: "outcome"; outcome: FillOutcome }
  | { type: "rebalance"; outcome: RebalanceOutcome };

export interface EngineOptions {
  cfg: Config;
  chain: Chain;
  store: StateStore;
  log: Log;
  /** Clock for receipt resolution (tests shift it). Default `Date.now`. */
  now?: () => number;
  onEvent?: (e: EngineEvent) => void | Promise<void>;
  /** In dry-run, an order that dry-ran is not re-evaluated for this long (default 60 s). */
  dryRunRecheckMs?: number;
}

/** Per-tick work bounds. */
export interface TickLimits {
  /**
   * Orders evaluated per tick, at most — counting only orders a strategy accepts
   * (the ones that cost RPC); the rest are skipped for free. 0 / unset = all.
   */
  maxOrders?: number;
  /** Checked before every order and before the rebalancer: `false` stops the tick (time, subrequests, pause). */
  canContinue?: () => boolean;
}

export interface TickOptions {
  /** The book's current entries. Unset: no sweep this tick (pending resolution and rebalancing only). */
  fetchEntries?: () => Promise<BookEntry[]>;
  limits?: TickLimits;
  /** Paused: resolve the outstanding tx, but send nothing new. */
  paused?: boolean;
  /** Run the rebalancer step if nothing was sent (default true; the Worker throttles it). */
  rebalance?: boolean;
}

export interface TickReport {
  resolution?: Resolution;
  /** Orders skipped this tick without any RPC: a resting verdict / own-fill hold still valid, or expiring too soon. */
  held?: number;
  /** A tx is outstanding after this tick (sent now, or still unresolved). */
  pending: boolean;
  /** The tx this tick sent. */
  sent?: PendingTx;
  paused?: boolean;
  /** Book entries fetched this tick. */
  entries?: number;
  /** Orders evaluated (accepted by a strategy) this tick. */
  evaluated: number;
  outcomes: FillOutcome[];
  rebalance?: RebalanceOutcome;
  /** The rebalancer step ran this tick. */
  rebalanced?: boolean;
  /** Errors caught this tick (intake, RPC, …), sanitized. */
  errors: string[];
  /** The sweep stopped early on the per-tick bound. */
  bounded?: boolean;
}

const RECENT_MAX = 100;

/**
 * An order not to re-quote yet: every strategy passed on it ("passed"), or we just
 * filled it ("filled" — the book indexes a fill ~60–80 s later on Rootstock and
 * serves the order until then). Valid until `until` while the book's fillable for
 * it is still `fillable`.
 */
interface Hold {
  until: number;
  fillable: string;
  why: "passed" | "filled";
}

/** Own-fill holds as persisted: `[orderHash, until, fillable]`. */
type SavedHold = [string, number, string];

/**
 * Order the book round-robin: by order hash, starting just after `cursor` (the
 * last hash evaluated) and wrapping. A changing book needs no index bookkeeping.
 */
export function roundRobin<T extends { orderHash: string }>(entries: readonly T[], cursor?: string): T[] {
  const sorted = [...entries].sort((a, b) => (a.orderHash.toLowerCase() < b.orderHash.toLowerCase() ? -1 : 1));
  if (!cursor) return sorted;
  const c = cursor.toLowerCase();
  const i = sorted.findIndex((e) => e.orderHash.toLowerCase() > c);
  return i <= 0 ? sorted : [...sorted.slice(i), ...sorted.slice(0, i)];
}

const errMsg = (e: unknown) => sanitize(e instanceof Error ? e.message.split("\n")[0] : e);

/**
 * The platform-agnostic filler. One {@link tick}:
 *
 *   1. RESOLVE the outstanding tx (one `getTransactionReceipt`, never a wait):
 *      charge its real gas, back the order off on a revert, time it out, or drop it;
 *   2. if a tx is still outstanding → stop (nothing else is sent);
 *   3. SWEEP: the book round-robin, at most `maxOrders` evaluated, through the
 *      strategies (inventory, then route); stop at the first tx sent;
 *   4. if nothing was sent: one REBALANCER step (inventory only), which may send one tx.
 *
 * So a tick sends at most ONE tx and there is never more than one outstanding.
 * State (budgets, backoff, the pending tx, the MoC op, the cursor) lives in the
 * injected {@link StateStore}; the pending tx is committed before its broadcast.
 */
export class Engine {
  readonly cfg: Config;
  readonly chain: Chain;
  readonly guard: Guard;
  /** Inventory outflow budget. */
  readonly budget: Budget;
  /** Route fill counter. */
  readonly routeBudget: Budget;
  readonly filler?: Filler;
  readonly route?: RouteFiller;
  readonly rebalancer: Rebalancer;
  readonly strategies: Strategy[] = [];
  private cursor: string | undefined;
  private recentEvents: RecentEvent[];
  private dirty = false;
  private readonly dryRunSeen = new Map<string, number>();
  /** Resting verdicts and own-fill holds, by lower-case order hash (see {@link Hold}). */
  private readonly holds = new Map<string, Hold>();
  /** Orders dispatched at least once (in memory): never-seen orders are evaluated first. */
  private readonly seen = new Set<string>();
  private readonly now: () => number;

  private constructor(private readonly o: EngineOptions, state: FillerState) {
    const { cfg, log } = o;
    this.cfg = cfg;
    this.now = o.now ?? Date.now;
    // One eth_gasPrice per ~10 s for every strategy and the rebalancer (it was asked
    // again for every order by every strategy).
    const chain = withGasPriceCache(o.chain, undefined, this.now);
    this.chain = chain;
    const mark = () => {
      this.dirty = true;
    };
    this.guard = new Guard(cfg.gas, state.guard ?? {}, mark, () => this.save());
    this.budget = new Budget(
      { [cfg.tokens.usdt0.toLowerCase()]: cfg.policy.hourlyUsdt0, [cfg.tokens.usdrif.toLowerCase()]: cfg.policy.hourlyUsdrif },
      state.spends ?? [],
    );
    this.routeBudget = new Budget({ [ROUTE_FILLS]: cfg.route?.hourlyFills ?? 0n }, state.routeSpends ?? []);
    this.guard.register("inventory", this.budget);
    this.guard.register("route", this.routeBudget);
    // Strategy order: inventory first, route second (see dispatch.ts). Both share
    // ONE guard: the hourly RBTC gas budget, MAX_GAS_PRICE_GWEI, the backoff.
    if (cfg.strategies.inventory) {
      const f = new Filler(cfg, chain, this.budget, log, mark, this.guard);
      this.filler = f;
      this.strategies.push({ name: "inventory", consider: (e) => f.consider(e), accepts: (e) => f.accepts(e) });
    }
    if (cfg.strategies.route) {
      const r = new RouteFiller(cfg, chain, this.routeBudget, log, mark, this.guard);
      this.route = r;
      this.strategies.push({ name: "route", consider: (e) => r.consider(e), accepts: (e) => r.accepts(e), beginSweep: () => r.beginSweep() });
    }
    this.rebalancer = new Rebalancer(cfg, chain, log, this.guard, { ...(state.rebalance ?? {}) }, mark);
    this.cursor = state.cursor;
    this.recentEvents = [...(state.recent ?? [])];
    for (const [h, until, fillable] of state.ownFills ?? []) this.holds.set(h, { until, fillable, why: "filled" });
  }

  static async create(o: EngineOptions): Promise<Engine> {
    const state = (await o.store.get<FillerState>(STATE_KEY)) ?? {};
    return new Engine(o, state);
  }

  /** The outstanding tx, if any. */
  get pending(): PendingTx | undefined {
    return this.guard.pending;
  }

  /** Most recent first. */
  get recent(): readonly RecentEvent[] {
    return [...this.recentEvents].reverse();
  }

  snapshot(): FillerState {
    // Own-fill holds are persisted (few, short-lived); "passed" verdicts are not — after
    // a restart the resting book is simply re-quoted once.
    const now = this.now();
    const ownFills: SavedHold[] = [];
    for (const [h, x] of this.holds) if (x.why === "filled" && x.until > now) ownFills.push([h, x.until, x.fillable]);
    return {
      spends: this.budget.toJSON(),
      routeSpends: this.routeBudget.toJSON(),
      guard: this.guard.toJSON(),
      rebalance: this.rebalancer.state,
      ...(this.cursor ? { cursor: this.cursor } : {}),
      recent: this.recentEvents,
      ...(ownFills.length ? { ownFills } : {}),
    };
  }

  async save(): Promise<void> {
    this.dirty = false;
    await this.o.store.put(STATE_KEY, this.snapshot());
  }

  async saveIfDirty(): Promise<void> {
    if (this.dirty) await this.save();
  }

  /** Budgets left right now (status). */
  budgetsLeft(now: number = this.now()): { gasWei: bigint; usdt0: bigint; usdrif: bigint; routeFills: bigint } {
    return {
      gasWei: this.guard.gas.remaining(GAS, now),
      usdt0: this.budget.remaining(this.cfg.tokens.usdt0, now),
      usdrif: this.budget.remaining(this.cfg.tokens.usdrif, now),
      routeFills: this.routeBudget.remaining(ROUTE_FILLS, now),
    };
  }

  private record(e: Omit<RecentEvent, "at">): void {
    // A skip repeated every tick for the same order and reason is recorded once.
    if (e.type === "skip" && this.recentEvents.some((r) => r.type === "skip" && r.orderHash === e.orderHash && r.reason === e.reason)) return;
    this.recentEvents.push({ at: this.now(), ...e });
    if (this.recentEvents.length > RECENT_MAX) this.recentEvents.splice(0, this.recentEvents.length - RECENT_MAX);
    this.dirty = true;
  }

  private async emit(e: EngineEvent): Promise<void> {
    try {
      await this.o.onEvent?.(e);
    } catch (err) {
      this.o.log(`event hook failed: ${errMsg(err)}`);
    }
  }

  /** Read the outstanding tx's status once and apply it (see guard.ts `resolvePending`). */
  async resolvePending(): Promise<Resolution | undefined> {
    const now = this.now();
    const res = await resolveTx(this.chain, this.guard, now);
    if (!res) return undefined;
    const p = res.pending;
    const who = `[${p.strategy}]`;
    const what = p.kind === "fill" ? `${p.orderHash} fill` : `${p.kind}${p.info?.note ? ` (${p.info.note})` : ""}`;
    if (res.rebroadcast) {
      const rb = res.rebroadcast;
      this.o.log(`↻ ${who} ${what} ${p.hash} unknown to the node — re-broadcast the signed bytes (#${rb.attempt}, nonce ${p.nonce})${rb.error ? `: ${rb.error}` : ""}`);
      this.record({ type: "rebroadcast", strategy: p.strategy, kind: p.kind, orderHash: p.orderHash, tx: p.hash, reason: rb.error ?? `attempt ${rb.attempt}` });
    }
    switch (res.status) {
      case "success":
        if (p.kind === "fill") this.o.log(`✓ ${who} filled ${p.info?.tag ?? p.orderHash} tx ${p.hash} gas ${res.gasUsed}`);
        else this.o.log(`✓ ${who} ${what} tx ${p.hash} mined, gas ${res.gasUsed}`);
        // Do not re-quote the order we just filled while the book still serves it
        // (it indexes the fill a minute or so later): hold it until its fillable changes.
        if (p.kind === "fill" && p.orderHash && p.bookFillable !== undefined) {
          this.holds.set(p.orderHash.toLowerCase(), { until: now + this.cfg.sweep.restingRecheckMs, fillable: p.bookFillable, why: "filled" });
          this.dirty = true;
        }
        if (p.kind === "redeem") {
          try {
            await this.rebalancer.onRedeemMined(now);
          } catch (e) {
            this.o.log(`MoC op id read failed: ${errMsg(e)}`);
          }
        }
        this.record({ type: p.kind === "fill" ? "filled" : "sent", strategy: p.strategy, kind: p.kind, orderHash: p.orderHash, tx: p.hash, reason: p.kind === "fill" ? undefined : "mined" });
        break;
      case "reverted":
        this.o.log(`✗ ${who} ${what} ${p.hash} reverted on-chain — ${p.kind === "fill" ? "order" : "action"} backed off`);
        this.record({ type: "reverted", strategy: p.strategy, kind: p.kind, orderHash: p.orderHash, tx: p.hash });
        break;
      case "timeout":
        this.o.log(`… ${who} ${what} ${p.hash} has no receipt after ${this.cfg.gas.receiptTimeoutMs} ms — pending (charged at its gas limit)`);
        this.record({ type: "timeout", strategy: p.strategy, kind: p.kind, orderHash: p.orderHash, tx: p.hash });
        break;
      case "dropped":
        this.o.log(
          res.replaced
            ? `✗ ${who} ${what} ${p.hash} replaced (nonce ${p.nonce} mined by another tx) — retry after a short backoff`
            : `✗ ${who} ${what} ${p.hash} dropped (not mined and not in the mempool after 15 min) — retry after a short backoff`,
        );
        this.record({ type: "dropped", strategy: p.strategy, kind: p.kind, orderHash: p.orderHash, tx: p.hash, ...(res.replaced ? { reason: "replaced" } : {}) });
        break;
      case "waiting":
        break;
    }
    if (res.status !== "waiting") await this.emit({ type: "resolved", resolution: res });
    await this.saveIfDirty();
    return res;
  }

  /** Call once per sweep (per-sweep caps such as SUSHI_MAX_PER_SWEEP). */
  beginSweep(): void {
    for (const s of this.strategies) s.beginSweep?.();
  }

  private async noteOutcome(out: FillOutcome): Promise<void> {
    if (out.status === "skipped") this.record({ type: "skip", strategy: out.strategy, orderHash: out.orderHash, reason: out.reason });
    else if (out.status === "dry-run") this.record({ type: "dry-run", strategy: out.strategy, orderHash: out.orderHash });
    else if (out.status === "failed") this.record({ type: "failed", strategy: out.strategy, orderHash: out.orderHash, reason: out.reason });
    else return;
    await this.emit({ type: "outcome", outcome: out });
  }

  /**
   * One pass over (part of) the book, stopping at the first tx sent:
   *
   *   1. orders expiring within EXPIRY_MARGIN_SECONDS are skipped (a tx cannot land
   *      in time), as is every order under a still-valid {@link Hold} — a resting
   *      verdict or an own fill whose book fillable has not changed: zero RPC;
   *   2. NEVER-SEEN orders go first, oldest first (the book's `addedAt`), so a new
   *      order is picked up on the next tick however many rest in the book;
   *   3. then the rest, round-robin from the stored cursor;
   *   4. at most `maxOrders` evaluated (orders a strategy accepts — the ones that cost RPC).
   */
  async sweep(entries: readonly BookEntry[], limits: TickLimits = {}): Promise<{ evaluated: number; outcomes: FillOutcome[]; sent?: PendingTx; bounded?: boolean; held: number }> {
    const outcomes: FillOutcome[] = [];
    let evaluated = 0;
    let bounded = false;
    let held = 0;
    if (this.guard.pending) return { evaluated, outcomes, sent: undefined, held };
    this.beginSweep();
    const recheck = this.o.dryRunRecheckMs ?? 60_000;
    const now = this.now();
    const nowS = BigInt(Math.floor(now / 1000));
    const key = (e: BookEntry) => e.orderHash.toLowerCase();
    // Forget orders the book no longer serves (bounds both maps by the book).
    const inBook = new Set(entries.map(key));
    for (const h of this.holds.keys()) if (!inBook.has(h)) this.holds.delete(h);
    for (const h of this.seen) if (!inBook.has(h)) this.seen.delete(h);
    // Never-seen orders: oldest first (the book's `addedAt`), ties by hash.
    const fresh = entries
      .filter((e) => !this.seen.has(key(e)))
      .sort((a, b) => (a.addedAt ?? 0) - (b.addedAt ?? 0) || (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
    const known = roundRobin(
      entries.filter((e) => this.seen.has(key(e))),
      this.cursor,
    );
    for (const e of [...fresh, ...known]) {
      if (limits.canContinue && !limits.canContinue()) {
        bounded = true;
        break;
      }
      const h = key(e);
      const expiry = e.announce.order.expiry;
      if (expiry !== 0n && expiry - nowS < BigInt(this.cfg.sweep.expiryMarginS)) {
        held++;
        continue;
      }
      const fillable = (e.state?.fillableAmount ?? 0n).toString();
      const hold = this.holds.get(h);
      if (hold) {
        if (now < hold.until && hold.fillable === fillable) {
          held++;
          continue;
        }
        this.holds.delete(h);
        if (hold.why === "filled") this.dirty = true;
      }
      const wasSeen = this.seen.has(h);
      const accepted = this.strategies.some((s) => (s.accepts ? s.accepts(e) : true));
      if (accepted) {
        const seen = this.dryRunSeen.get(e.orderHash);
        if (this.cfg.dryRun && seen !== undefined && this.now() - seen < recheck) continue;
        if (limits.maxOrders && evaluated >= limits.maxOrders) {
          bounded = true;
          break;
        }
        evaluated++;
        if (wasSeen) {
          this.cursor = e.orderHash;
          this.dirty = true;
        }
      }
      this.seen.add(h);
      const out = await dispatch(e, this.strategies);
      if (out) {
        outcomes.push(out);
        await this.noteOutcome(out);
        if (out.status === "dry-run") this.dryRunSeen.set(e.orderHash, this.now());
        if (out.status === "skipped" && out.rest && this.cfg.sweep.restingRecheckMs > 0) {
          const at = this.now();
          const ttl = isFixedPrice(e.announce.order) ? this.cfg.sweep.restingRecheckMs : Math.min(this.cfg.sweep.restingRecheckMs, AUCTION_RECHECK_MS);
          // Never hold past the end of a running exclusivity window: that is when an
          // outsider's price steps (the soft premium drops, a hard window opens), and
          // the app's pull markets end theirs ~2 blocks in (B13).
          const winEnd = windowEndMs(e.announce.order, at);
          this.holds.set(h, { until: winEnd !== undefined ? Math.min(at + ttl, winEnd) : at + ttl, fillable, why: "passed" });
        }
      }
      // (Read through a widened reference: TS narrowed `this.guard.pending` to
      // undefined at the top, but dispatch may have sent a tx since.)
      const sent: PendingTx | undefined = (this.guard as Guard).pending;
      if (sent) {
        let p = sent;
        // Remember the book's fillable for the own-fill hold once this fill mines.
        if (p.kind === "fill" && p.orderHash?.toLowerCase() === h && e.state) {
          p = { ...p, bookFillable: fillable };
          this.guard.setPending(p);
        }
        await this.emit({ type: "sent", pending: p });
        return { evaluated, outcomes, sent: p, held };
      }
    }
    if (this.dryRunSeen.size > 10_000) this.dryRunSeen.clear();
    return { evaluated, outcomes, bounded, held };
  }

  /** One rebalancer step (redeem USDRIF / sell RIF), at most one tx. Inventory strategy only. */
  async rebalanceStep(): Promise<RebalanceOutcome | undefined> {
    if (!this.cfg.strategies.inventory || this.guard.pending) return undefined;
    const r = await this.rebalancer.step();
    if (r) await this.emit({ type: "rebalance", outcome: r });
    if (this.guard.pending) await this.emit({ type: "sent", pending: this.guard.pending });
    return r;
  }

  async tick(o: TickOptions = {}): Promise<TickReport> {
    const rep: TickReport = { pending: false, evaluated: 0, outcomes: [], errors: [] };
    const limits = o.limits ?? {};
    try {
      try {
        rep.resolution = await this.resolvePending();
      } catch (e) {
        rep.errors.push(`resolve: ${errMsg(e)}`);
      }
      if (this.guard.pending) {
        rep.pending = true;
        return rep;
      }
      if (o.paused) {
        rep.paused = true;
        return rep;
      }
      if (o.fetchEntries) {
        let entries: BookEntry[] | undefined;
        try {
          entries = await o.fetchEntries();
          rep.entries = entries.length;
        } catch (e) {
          rep.errors.push(`intake: ${errMsg(e)}`);
        }
        if (entries) {
          try {
            const sw = await this.sweep(entries, limits);
            rep.evaluated = sw.evaluated;
            rep.outcomes = sw.outcomes;
            rep.bounded = sw.bounded;
            rep.held = sw.held;
            if (sw.sent) {
              rep.sent = sw.sent;
              rep.pending = true;
              return rep;
            }
          } catch (e) {
            rep.errors.push(`sweep: ${errMsg(e)}`);
          }
        }
      }
      if (limits.canContinue && !limits.canContinue()) return rep;
      if (o.rebalance === false || !this.cfg.strategies.inventory) return rep;
      try {
        rep.rebalanced = true;
        rep.rebalance = await this.rebalanceStep();
      } catch (e) {
        rep.errors.push(`rebalance: ${errMsg(e)}`);
      }
      if (this.guard.pending) {
        rep.sent = this.guard.pending;
        rep.pending = true;
      }
      return rep;
    } finally {
      await this.saveIfDirty();
    }
  }
}

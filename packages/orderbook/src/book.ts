import { recoverMessageAddress, type Hex } from "viem";

import type { OrderbookConfig } from "./config";
import { decodeOrderAnnounce, decodeOrderSoftCancel } from "./proto/codec";
import { topicsFor } from "./topics";
import type { Transport, Unsubscribe } from "./transport";
import type { Layer2Result, Verifier } from "./verify";
import type { OrderAnnounce } from "./messages";

export interface BookEntry {
  orderHash: Hex;
  announce: OrderAnnounce;
  /** Unix seconds this node first admitted the order. */
  addedAt: number;
  /** Most recent Layer-2 state (fillable amount, status). */
  state?: Layer2Result;
}

export type BookListener = (entry: BookEntry) => void;

export interface BookOptions {
  transport: Transport;
  config: OrderbookConfig;
  verifier: Verifier;
  /** Periodic on-chain re-check interval (ms). `0` disables the timer. Default 30s. */
  revalidateMs?: number;
  /** Backfill from `transport.queryHistory` on `start()`. Default true. */
  backfill?: boolean;
  /** Injectable clock (unix seconds) for deterministic tests. */
  now?: () => number;
}

/**
 * The reconstructed order book: Store backfill → live Relay stream → the L1+L2
 * verification pipeline → an in-memory `Map` keyed by `orderHash`, with
 * deadline-expiry, signed-soft-cancel eviction, and a periodic on-chain re-check
 * that drops orders that went Filled/Cancelled off-book. There is no canonical
 * book object and no consensus — this is one node's eventually-consistent view,
 * and the chain is the tiebreaker. The SAME class runs behind the demo backend
 * (over `InMemoryTransport`) and behind a Waku filler (over a Waku transport),
 * unchanged.
 */
export class Book {
  private readonly entries = new Map<Hex, BookEntry>();
  private readonly addListeners = new Set<BookListener>();
  private readonly removeListeners = new Set<BookListener>();
  private readonly unsubs: Unsubscribe[] = [];
  private timer: ReturnType<typeof setInterval> | undefined;
  private readonly now: () => number;

  constructor(private readonly opts: BookOptions) {
    this.now = opts.now ?? (() => Math.floor(Date.now() / 1000));
  }

  /** Backfill, subscribe to live orders + cancels, and start the re-check timer. */
  async start(): Promise<void> {
    const { transport, config } = this.opts;
    const { orders, cancels } = topicsFor(config);

    if (this.opts.backfill !== false && transport.queryHistory) {
      const history = await transport.queryHistory(orders);
      for (const bytes of history) await this.ingestAnnounceBytes(bytes);
    }

    this.unsubs.push(await transport.subscribe(orders, (b) => void this.ingestAnnounceBytes(b)));
    this.unsubs.push(await transport.subscribe(cancels, (b) => void this.ingestCancelBytes(b)));

    const period = this.opts.revalidateMs ?? 30_000;
    if (period > 0) {
      this.timer = setInterval(() => {
        // A failed on-chain re-check must not become an unhandled rejection.
        void this.revalidate().catch(() => undefined);
      }, period);
      // Don't keep a Node process (or test) alive just for the re-check.
      (this.timer as { unref?: () => void }).unref?.();
    }
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    for (const u of this.unsubs.splice(0)) u();
  }

  // ──────────────────── reads ────────────────────

  list(): BookEntry[] {
    return [...this.entries.values()];
  }
  get(orderHash: Hex): BookEntry | undefined {
    return this.entries.get(orderHash);
  }
  get size(): number {
    return this.entries.size;
  }

  onAdd(cb: BookListener): Unsubscribe {
    this.addListeners.add(cb);
    return () => this.addListeners.delete(cb);
  }
  onRemove(cb: BookListener): Unsubscribe {
    this.removeListeners.add(cb);
    return () => this.removeListeners.delete(cb);
  }

  // ──────────────────── ingest ────────────────────

  /** Decode + verify (L1+L2) + admit one order-announce payload. Returns the verdict. */
  async ingestAnnounceBytes(bytes: Uint8Array): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    let announce: OrderAnnounce;
    try {
      announce = decodeOrderAnnounce(bytes);
    } catch {
      return { ok: false, reason: "undecodable OrderAnnounce" };
    }
    try {
      return await this.ingestAnnounce(announce);
    } catch {
      // An RPC hiccup during Layer 2 must not crash the ingest loop.
      return { ok: false, reason: "verification error (RPC?)" };
    }
  }

  async ingestAnnounce(announce: OrderAnnounce): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    const res = await this.opts.verifier.verifyAnnounce(announce);
    if (!res.ok) return { ok: false, reason: res.reason, orderHash: res.orderHash };
    this.admit(res.orderHash, announce, res.state);
    return { ok: true, orderHash: res.orderHash };
  }

  /** Admit an already-verified announce (server fast-path after its POST-time check). */
  admit(orderHash: Hex, announce: OrderAnnounce, state?: Layer2Result): void {
    const existing = this.entries.get(orderHash);
    if (existing) {
      // Dedup: same order re-announced — refresh state, no duplicate onAdd.
      existing.announce = announce;
      if (state) existing.state = state;
      return;
    }
    const entry: BookEntry = { orderHash, announce, addedAt: this.now(), ...(state ? { state } : {}) };
    this.entries.set(orderHash, entry);
    this.emit(this.addListeners, entry);
  }

  private async ingestCancelBytes(bytes: Uint8Array): Promise<void> {
    let cancel: { orderHash: Hex; makerSig: Hex };
    try {
      cancel = decodeOrderSoftCancel(bytes);
    } catch {
      return;
    }
    const entry = this.entries.get(cancel.orderHash);
    if (!entry) return; // nothing to cancel (or not in our view)
    // Spoofing guard: the cancel must be signed by the order's maker over the
    // orderHash. An unsigned/mis-signed cancel is silently dropped, so a maker
    // can only ever evict its own orders (EOA makers; a contract maker needs a
    // 1271 path — out of scope for the demo).
    try {
      const signer = await recoverMessageAddress({ message: { raw: cancel.orderHash }, signature: cancel.makerSig });
      if (signer.toLowerCase() !== entry.announce.order.maker.toLowerCase()) return;
    } catch {
      return;
    }
    this.evict(cancel.orderHash);
  }

  private evict(orderHash: Hex): void {
    const entry = this.entries.get(orderHash);
    if (!entry) return;
    this.entries.delete(orderHash);
    this.emit(this.removeListeners, entry);
  }

  // ──────────────────── maintenance ────────────────────

  /** Drop expired orders, then re-check the rest on-chain and drop any that went un-fillable. */
  async revalidate(): Promise<void> {
    const now = BigInt(this.now());
    for (const entry of [...this.entries.values()]) {
      if (entry.announce.order.deadline <= now) this.evict(entry.orderHash);
    }
    const live = this.list();
    if (live.length === 0) return;
    const states = await this.opts.verifier.refreshStates(live.map((e) => ({ orderHash: e.orderHash, announce: e.announce })));
    for (const entry of live) {
      const s = states.get(entry.orderHash);
      if (!s) continue;
      if (!s.ok) this.evict(entry.orderHash);
      else entry.state = s;
    }
  }

  private emit(listeners: Set<BookListener>, entry: BookEntry): void {
    for (const cb of [...listeners]) {
      try {
        cb(entry);
      } catch {
        /* listener error is its own problem */
      }
    }
  }
}

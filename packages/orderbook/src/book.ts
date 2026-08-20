import type { Hex } from "viem";

import { CancelVerifier, evictableHashes } from "./cancels";
import type { OrderbookConfig } from "./config";
import { decodeOrderAnnounce, decodeOrderReplace, decodeSoftCancel } from "./proto/codec";
import { topicsFor } from "./topics";
import type { Transport, Unsubscribe } from "./transport";
import type { Layer2Result, Verifier } from "./verify";
import { isOcoGroupLeg, type ChainEvent, type ChainWatcher } from "./watcher";
import type { OrderAnnounce, OrderReplace, SignedSoftCancel } from "./messages";

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
  /**
   * Soft-cancel signature verification. Required rather than defaulted: a book
   * that silently accepted unverified cancels would let anyone evict anyone's
   * orders, and "I forgot to pass it" must not be a way to end up there.
   */
  cancelVerifier: CancelVerifier;
  /**
   * Watches Settlement logs so cancellations evict immediately and with no RPC,
   * instead of waiting up to a full `revalidateMs` for the sweep to notice.
   * Optional — without it the book still converges, just later and at O(n) cost.
   */
  watcher?: ChainWatcher;
  /** Periodic on-chain re-check interval (ms). `0` disables the timer. Default 30s. */
  revalidateMs?: number;
  /**
   * How soon after a chain event the targeted re-check runs (ms). Only orders the
   * event marked dirty are re-checked, so this can be aggressive. Default 250ms —
   * enough to coalesce a block's worth of `OrderFilled` logs into one call.
   */
  dirtyDebounceMs?: number;
  /**
   * Should this entry leave the book? Default: `!state.ok`.
   *
   * The hook exists because `validatorsPass` is deliberately NOT part of `ok`.
   * A filler-conditional order (whitelist, attestation) fails validation for
   * everyone except its target filler and is still perfectly book-worthy, so a
   * general book must not evict on it. A book serving only unconditional orders
   * knows better about its own inventory and can pass
   * `(_, s) => !s.ok || !s.validatorsPass` to drop dead legs eagerly.
   */
  evictWhen?: (entry: BookEntry, state: Layer2Result) => boolean;
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
  private readonly errorListeners = new Set<(err: unknown) => void>();
  private readonly unsubs: Unsubscribe[] = [];
  private timer: ReturnType<typeof setInterval> | undefined;
  /** Orders a chain event touched but could not resolve — re-checked on their own. */
  private readonly dirty = new Set<Hex>();
  private dirtyTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly now: () => number;

  constructor(private readonly opts: BookOptions) {
    this.now = opts.now ?? (() => Math.floor(Date.now() / 1000));
  }

  private shouldEvict(entry: BookEntry, state: Layer2Result): boolean {
    return this.opts.evictWhen ? this.opts.evictWhen(entry, state) : !state.ok;
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
    // Replaces ride the ORDER topic (they carry an announce), cancels their own.
    this.unsubs.push(await transport.subscribe(cancels, (b) => void this.ingestCancelBytes(b)));

    if (this.opts.watcher) this.unsubs.push(this.opts.watcher.on((e) => this.applyChainEvent(e)));

    const period = this.opts.revalidateMs ?? 30_000;
    if (period > 0) {
      this.timer = setInterval(() => {
        // A failed on-chain re-check must not become an unhandled rejection —
        // but it must not vanish either. Swallowing it meant a book that had
        // silently stopped self-cleaning looked exactly like a healthy one.
        void this.revalidate().catch((err) => this.emitError(err));
      }, period);
      // Don't keep a Node process (or test) alive just for the re-check.
      (this.timer as { unref?: () => void }).unref?.();
    }
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    if (this.dirtyTimer) clearTimeout(this.dirtyTimer);
    this.dirtyTimer = undefined;
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

  /**
   * Failures of the periodic re-check and of chain-event handling. Subscribe:
   * the failure mode this replaced was a book that had quietly stopped
   * self-cleaning and was indistinguishable from a healthy one.
   */
  onError(cb: (err: unknown) => void): Unsubscribe {
    this.errorListeners.add(cb);
    return () => this.errorListeners.delete(cb);
  }

  private emitError(err: unknown): void {
    for (const cb of [...this.errorListeners]) {
      try {
        cb(err);
      } catch {
        /* an error handler that throws is its own problem */
      }
    }
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

  private async ingestCancelBytes(bytes: Uint8Array): Promise<{ ok: boolean; reason?: string; evicted?: Hex[] }> {
    let cancel: SignedSoftCancel;
    try {
      cancel = decodeSoftCancel(bytes);
    } catch {
      return { ok: false, reason: "undecodable SoftCancel" };
    }
    try {
      return await this.ingestCancel(cancel);
    } catch {
      return { ok: false, reason: "cancel verification error (RPC?)" };
    }
  }

  /**
   * Verify a soft cancel and evict what it is entitled to evict.
   *
   * TWO independent checks, and both are load-bearing:
   *   • the SIGNATURE says who signed (EOA / delegate / 1271 — see
   *     {@link CancelVerifier}),
   *   • {@link evictableHashes} says what that signer may retract, by requiring
   *     each named order to actually name them as maker.
   *
   * Without the second, a perfectly valid signature over somebody else's order
   * hash would evict it. Hashes this node has never seen are skipped rather than
   * remembered: a cancel is advisory, and pre-empting an order that may never
   * arrive would hand an attacker a free denial channel against orders the node
   * has not even verified yet.
   */
  async ingestCancel(signed: SignedSoftCancel): Promise<{ ok: boolean; reason?: string; evicted: Hex[] }> {
    const verdict = await this.opts.cancelVerifier.verify(signed);
    if (!verdict.ok) return { ok: false, reason: verdict.reason, evicted: [] };

    const evicted = evictableHashes(signed.cancel, (h) => this.entries.get(h)?.announce.order.maker);
    for (const h of evicted) this.evict(h);
    return { ok: true, evicted };
  }

  /**
   * Cancel-and-replace, applied as one step: the retraction lands ONLY if the
   * replacement verifies. The ordering is deliberate — admit first, evict second
   * — so a book never passes through a state where the maker has neither order
   * live. A failed replacement leaves the predecessor exactly where it was.
   */
  async ingestReplace(replace: OrderReplace): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    if (!replace.cancel.cancel.orderHashes.includes(replace.replaces)) {
      return { ok: false, reason: "replace: the cancel does not name the replaced order" };
    }
    if (replace.cancel.cancel.maker.toLowerCase() !== replace.announce.order.maker.toLowerCase()) {
      return { ok: false, reason: "replace: cancel and replacement have different makers" };
    }

    const added = await this.ingestAnnounce(replace.announce);
    if (!added.ok) return added; // predecessor untouched

    await this.ingestCancel(replace.cancel);
    return added;
  }

  async ingestReplaceBytes(bytes: Uint8Array): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    let replace: OrderReplace;
    try {
      replace = decodeOrderReplace(bytes);
    } catch {
      return { ok: false, reason: "undecodable OrderReplace" };
    }
    try {
      return await this.ingestReplace(replace);
    } catch {
      return { ok: false, reason: "replace verification error (RPC?)" };
    }
  }

  private evict(orderHash: Hex): void {
    const entry = this.entries.get(orderHash);
    if (!entry) return;
    this.entries.delete(orderHash);
    this.emit(this.removeListeners, entry);
  }

  // ──────────────────── chain events ────────────────────

  /**
   * Apply one on-chain fact. Pure and synchronous for the four cancellation
   * kinds plus `groupClaimed` — they carry maker + which orders died, so the
   * book evicts with **no RPC at all**. `filled` is the exception: the event
   * says an order moved but not how far, so it only marks the order dirty for a
   * targeted re-check.
   *
   * Every branch re-checks the MAKER. A log is a fact about one account's book,
   * and matching a nonce without matching the maker who cancelled it would evict
   * unrelated orders that merely share a number.
   *
   * @returns the hashes evicted, and the hashes marked for re-check.
   */
  applyChainEvent(e: ChainEvent): { evicted: Hex[]; dirty: Hex[] } {
    const evicted: Hex[] = [];
    const dirty: Hex[] = [];

    const evictMatching = (pred: (entry: BookEntry) => boolean): void => {
      for (const entry of [...this.entries.values()]) {
        if (!pred(entry)) continue;
        evicted.push(entry.orderHash);
        this.evict(entry.orderHash);
      }
    };
    const sameMaker = (entry: BookEntry, maker: string): boolean =>
      entry.announce.order.maker.toLowerCase() === maker.toLowerCase();

    switch (e.kind) {
      case "cancelledByHash": {
        const entry = this.entries.get(e.orderHash);
        if (entry && sameMaker(entry, e.maker)) {
          evicted.push(e.orderHash);
          this.evict(e.orderHash);
        }
        break;
      }
      case "cancelledNonces": {
        const nonces = new Set(e.nonces);
        evictMatching((entry) => sameMaker(entry, e.maker) && nonces.has(entry.announce.order.nonce));
        break;
      }
      case "rolledBack":
        evictMatching((entry) => sameMaker(entry, e.maker) && entry.announce.order.nonce < e.minValidNonce);
        break;
      case "wordInvalidated":
        evictMatching((entry) => sameMaker(entry, e.maker) && entry.announce.order.nonce >> 8n === e.wordIndex);
        break;
      case "groupClaimed":
        // The bracket's WINNER keeps its claim and stays fillable; every other
        // leg of the group is retired. Same rule the on-chain validator applies,
        // evaluated against the order's own signed validator list.
        evictMatching(
          (entry) =>
            sameMaker(entry, e.maker) &&
            entry.announce.order.nonce !== e.nonce &&
            isOcoGroupLeg(entry.announce.order.validators, e.module, e.groupId),
        );
        break;
      case "filled": {
        // Could be a partial. Only a lens read knows whether anything is left.
        if (this.entries.has(e.orderHash)) {
          dirty.push(e.orderHash);
          this.dirty.add(e.orderHash);
          this.scheduleDirtySweep();
        }
        break;
      }
    }
    return { evicted, dirty };
  }

  private scheduleDirtySweep(): void {
    if (this.dirtyTimer) return; // already coalescing this window
    const delay = this.opts.dirtyDebounceMs ?? 250;
    this.dirtyTimer = setTimeout(() => {
      this.dirtyTimer = undefined;
      void this.revalidateDirty().catch((err) => this.emitError(err));
    }, delay);
    (this.dirtyTimer as { unref?: () => void }).unref?.();
  }

  /**
   * Re-check ONLY the orders chain events touched. This is the whole point of
   * watching: the sweep below is O(book), this is O(what actually changed).
   */
  async revalidateDirty(): Promise<void> {
    const hashes = [...this.dirty];
    this.dirty.clear();
    const live = hashes.map((h) => this.entries.get(h)).filter((e): e is BookEntry => e !== undefined);
    if (live.length === 0) return;
    await this.recheck(live);
  }

  // ──────────────────── maintenance ────────────────────

  /**
   * Drop expired orders, then re-check the rest on-chain and drop any that went
   * un-fillable. The safety net, not the primary signal: with a
   * {@link ChainWatcher} attached, cancellations and bracket retirements have
   * already evicted themselves for free, and this sweep exists for the things no
   * log can announce — a maker's balance or allowance falling away underneath a
   * still-valid order.
   */
  async revalidate(): Promise<void> {
    const now = BigInt(this.now());
    for (const entry of [...this.entries.values()]) {
      if (entry.announce.order.expiry <= now) this.evict(entry.orderHash);
    }
    const live = this.list();
    if (live.length === 0) return;
    await this.recheck(live);
  }

  /** Shared body of the full sweep and the targeted dirty re-check. */
  private async recheck(entries: readonly BookEntry[]): Promise<void> {
    const states = await this.opts.verifier.refreshStates(
      entries.map((e) => ({ orderHash: e.orderHash, announce: e.announce })),
    );
    for (const entry of entries) {
      const s = states.get(entry.orderHash);
      if (!s) continue;
      entry.state = s;
      if (this.shouldEvict(entry, s)) this.evict(entry.orderHash);
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

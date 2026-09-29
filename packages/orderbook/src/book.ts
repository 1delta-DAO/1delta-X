import { hashOrderStruct, type Order } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import { checkAdmission, DEFAULT_ADMISSION, type AdmissionPolicy, type AdmissionVerdict } from "./admission";
import { CancelVerifier, type CancelVerdict } from "./cancels";
import type { OrderbookConfig } from "./config";
import { decodeOrderAnnounce, decodeOrderReplace, decodeSoftCancel, encodeOrderAnnounce } from "./proto/codec";
import { topicsFor } from "./topics";
import type { Transport, Unsubscribe } from "./transport";
import { OrderStatus, type Layer2Result, type Verifier } from "./verify";
import { isOcoGroupLeg, type ChainEvent, type ChainWatcher } from "./watcher";
import type { OrderAnnounce, OrderReplace, SignedSoftCancel } from "./messages";

export interface BookEntry {
  orderHash: Hex;
  announce: OrderAnnounce;
  /** Unix seconds this node first admitted the order. */
  addedAt: number;
  /** Most recent Layer-2 state (fillable amount, status). */
  state?: Layer2Result;
  /** Consecutive re-checks that could not classify this order even on its own. */
  inconclusiveStrikes?: number;
}

/** A soft cancel the book keeps honouring after the eviction it caused. */
interface SoftCancelTombstone {
  /** Lower-cased — the only maker whose order this tombstone blocks. */
  maker: string;
  /** Unix seconds after which the tombstone may be forgotten. */
  until: bigint;
  /** The hash was not live here when the cancel arrived (a cancel-before-order). */
  pending: boolean;
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
  /**
   * What the book will hold, applied on EVERY admission path — transport ingest,
   * backfill, replaces and {@link Book.admit} — not only behind the REST route.
   * Defaults to {@link DEFAULT_ADMISSION}.
   */
  admission?: Partial<AdmissionPolicy>;
  /**
   * An order the lens could not classify even when asked about it alone is kept
   * (an `Inconclusive` is not a verdict) — but not forever: after this many
   * consecutive isolated failures it is evicted. Default 3.
   */
  maxInconclusiveStrikes?: number;
  /** Soft-cancel tombstones held at most. Default 100,000. */
  maxTombstones?: number;
  /**
   * Tombstones for hashes this node had NOT seen (cancel-before-order), per maker.
   * They are maker-bound, so they cannot pre-empt anyone else's order, but each is
   * memory a maker can mint with one signature. Default 1,024.
   */
  maxPendingTombstonesPerMaker?: number;
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
  private readonly admission: AdmissionPolicy;
  /** Live orders per lower-cased maker, maintained on admit/evict — the cap check is O(1). */
  private readonly makerCounts = new Map<string, number>();
  /** Soft-cancelled hashes, insertion-ordered so the oldest go first past the cap. */
  private readonly tombstones = new Map<Hex, SoftCancelTombstone>();
  private readonly pendingPerMaker = new Map<string, number>();

  constructor(private readonly opts: BookOptions) {
    this.now = opts.now ?? (() => Math.floor(Date.now() / 1000));
    this.admission = { ...DEFAULT_ADMISSION, ...opts.admission };
  }

  private shouldEvict(entry: BookEntry, state: Layer2Result): boolean {
    return this.opts.evictWhen ? this.opts.evictWhen(entry, state) : !state.ok;
  }

  /** Backfill, subscribe to live orders + cancels, and start the re-check timer. */
  async start(): Promise<void> {
    const { transport, config } = this.opts;
    const { orders, cancels, replaces } = topicsFor(config);

    if (this.opts.backfill !== false && transport.queryHistory) {
      const history = await transport.queryHistory(orders);
      for (const bytes of history) await this.ingestAnnounceBytes(bytes);
    }

    this.unsubs.push(await transport.subscribe(orders, (b) => void this.ingestAnnounceBytes(b)));
    this.unsubs.push(await transport.subscribe(cancels, (b) => void this.ingestCancelBytes(b)));
    // Replaces have their own topic — see {replaceTopic} for why they cannot share
    // the order topic.
    this.unsubs.push(await transport.subscribe(replaces, (b) => void this.ingestReplaceBytes(b)));

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
  /** Live orders this maker holds here. O(1). */
  makerCount(maker: Address | string): number {
    return this.makerCounts.get(maker.toLowerCase()) ?? 0;
  }
  /** True when a verified soft cancel by `order.maker` still covers this hash. */
  isSoftCancelled(orderHash: Hex, maker: Address | string): boolean {
    const t = this.tombstones.get(orderHash);
    return t !== undefined && t.maker === maker.toLowerCase() && t.until > BigInt(this.now());
  }
  /** Soft-cancel tombstones held (bounded by `maxTombstones`). */
  get tombstoneCount(): number {
    return this.tombstones.size;
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
      return await this.ingestAnnounce(announce, bytes.length);
    } catch {
      // An RPC hiccup during Layer 2 must not crash the ingest loop.
      return { ok: false, reason: "verification error (RPC?)" };
    }
  }

  /**
   * The cheap, local gate every admission path runs BEFORE paying for a lens call:
   * the soft-cancel tombstones, then {@link checkAdmission} (structure, TTL window,
   * size, token list, capacity — with displacement). The transport path used to
   * skip all of it, so anything a peer relayed went straight to an `eth_call`.
   *
   * @param policy override the book's own policy (the server applies its configured one).
   */
  precheck(
    order: Order,
    orderHash: Hex,
    opts?: { encodedBytes?: number; known?: boolean; policy?: AdmissionPolicy },
  ): AdmissionVerdict {
    if (this.isSoftCancelled(orderHash, order.maker)) return { ok: false, reason: "order was soft-cancelled by its maker" };
    const policy = opts?.policy ?? this.admission;
    return checkAdmission(
      order,
      {
        size: this.entries.size,
        makerCount: (m) => this.makerCount(m),
        now: this.now(),
        known: opts?.known ?? this.entries.has(orderHash),
        ...(opts?.encodedBytes !== undefined ? { encodedBytes: opts.encodedBytes } : {}),
        canDisplace: (m) => this.displacementVictim(m, policy) !== undefined,
      },
      policy,
    );
  }

  async ingestAnnounce(
    announce: OrderAnnounce,
    encodedBytes?: number,
  ): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    let orderHash: Hex;
    try {
      orderHash = hashOrderStruct(announce.order);
    } catch {
      return { ok: false, reason: "unhashable order" };
    }
    // A re-announce of a live order changes nothing (the first-seen announce is
    // kept — see {@link admit}), so it costs nothing either: no lens call.
    if (this.entries.has(orderHash)) return { ok: true, orderHash };

    const size = encodedBytes ?? (this.admission.maxOrderBytes > 0 ? encodeOrderAnnounce(announce).length : undefined);
    const gate = this.precheck(announce.order, orderHash, size !== undefined ? { encodedBytes: size } : undefined);
    if (!gate.ok) return { ok: false, reason: gate.reason, orderHash };

    const res = await this.opts.verifier.verifyAnnounce(announce);
    if (!res.ok) return { ok: false, reason: res.reason, orderHash: res.orderHash };
    const admitted = this.admit(res.orderHash, announce, res.state);
    return admitted.ok ? { ok: true, orderHash: res.orderHash } : { ok: false, reason: admitted.reason, orderHash: res.orderHash };
  }

  /**
   * Admit an already-verified announce. Synchronous, so the capacity and tombstone
   * checks here are the authoritative ones — two concurrent ingests that both
   * passed {@link precheck} before their lens calls cannot both squeeze past a cap.
   *
   * A re-announce of a live order keeps the FIRST-SEEN announce and refreshes only
   * the state. The announce is not wholly signed — `permitBatch` in particular is
   * relay-supplied — so letting any later announcer overwrite it let a third party
   * strip or garble what fillers are served.
   *
   * @param opts.exempt skip the capacity caps (a replacement taking its live
   *        predecessor's slot).
   */
  admit(
    orderHash: Hex,
    announce: OrderAnnounce,
    state?: Layer2Result,
    opts?: { exempt?: boolean },
  ): AdmissionVerdict {
    const existing = this.entries.get(orderHash);
    if (existing) {
      if (state) existing.state = state;
      return { ok: true };
    }
    const maker = announce.order.maker;
    if (this.isSoftCancelled(orderHash, maker)) {
      // The order has now been seen: honour the cancel for its whole life.
      const t = this.tombstones.get(orderHash)!;
      if (announce.order.expiry > t.until) t.until = announce.order.expiry;
      return { ok: false, reason: "order was soft-cancelled by its maker" };
    }
    if (!opts?.exempt) {
      const policy = this.admission;
      if (policy.maxOrdersPerMaker > 0 && this.makerCount(maker) >= policy.maxOrdersPerMaker) {
        return { ok: false, reason: `maker is at its order limit (${policy.maxOrdersPerMaker})`, capacity: true };
      }
      if (policy.maxOrders > 0 && this.entries.size >= policy.maxOrders) {
        const victim = this.displacementVictim(maker, policy);
        if (!victim) return { ok: false, reason: "book is at capacity", capacity: true };
        this.evict(victim);
      }
    }
    const entry: BookEntry = { orderHash, announce, addedAt: this.now(), ...(state ? { state } : {}) };
    this.entries.set(orderHash, entry);
    const key = maker.toLowerCase();
    this.makerCounts.set(key, (this.makerCounts.get(key) ?? 0) + 1);
    this.emit(this.addListeners, entry);
    return { ok: true };
  }

  /**
   * Which order a full book gives up for one from `maker`, if any.
   *
   * A hard "full ⇒ 503" made the book's capacity a prize: whoever filled it first
   * held it for the whole TTL. Now a full book first drops an order it already
   * knows is not fillable, and otherwise takes a slot from the LARGEST maker —
   * only while that maker holds more than one order beyond the newcomer, so the
   * book drifts toward an even split between makers instead of first-come
   * ownership. Within that maker, the order with the furthest deadline goes: it is
   * the one squatting longest. O(n) — but only ever run when the book is full.
   */
  private displacementVictim(maker: Address | string, policy: AdmissionPolicy): Hex | undefined {
    if (policy.maxOrders <= 0 || this.entries.size < policy.maxOrders) return undefined;
    for (const e of this.entries.values()) if (e.state && !e.state.ok && e.state.status !== OrderStatus.Inconclusive) return e.orderHash;

    let top: string | undefined;
    let topCount = 0;
    for (const [m, n] of this.makerCounts) {
      if (n > topCount) {
        top = m;
        topCount = n;
      }
    }
    if (top === undefined || topCount <= this.makerCount(maker) + 1) return undefined;
    let victim: BookEntry | undefined;
    for (const e of this.entries.values()) {
      if (e.announce.order.maker.toLowerCase() !== top) continue;
      if (!victim || e.announce.order.expiry > victim.announce.order.expiry) victim = e;
    }
    return victim?.orderHash;
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
   *   • each tombstone is bound to that signer as maker, so a live order is evicted
   *     — and an arriving one refused — only when it actually names them.
   *
   * Without the second, a perfectly valid signature over somebody else's order
   * hash would evict it.
   *
   * The cancel then STICKS. It used to evict and be forgotten, so re-announcing
   * the order (by anyone — it is still validly signed) simply re-listed it, and a
   * cancel that arrived before its order was dropped outright. Every named hash
   * now leaves a maker-bound tombstone: until the order's own deadline for a live
   * order, until the cancel's expiry for one not seen yet (extended to the order's
   * deadline if it turns up). Maker-binding is what keeps the cancel-before-order
   * case from being a denial channel: a tombstone blocks only an order whose maker
   * signed it.
   */
  async ingestCancel(signed: SignedSoftCancel): Promise<{ ok: boolean; reason?: string; evicted: Hex[] }> {
    const verdict = await this.opts.cancelVerifier.verify(signed);
    if (!verdict.ok) return { ok: false, reason: verdict.reason, evicted: [] };
    return { ok: true, evicted: this.applyVerifiedCancel(signed, verdict) };
  }

  /**
   * The synchronous half of {@link ingestCancel}, for a caller that already holds
   * the {@link CancelVerifier} verdict (the server, which verifies before billing).
   * Like {@link admit}, it trusts that verdict — pass only one the verifier
   * returned for THIS message; a verdict for another maker applies nothing.
   */
  applyVerifiedCancel(signed: SignedSoftCancel, verdict: CancelVerdict): Hex[] {
    if (!verdict.ok || verdict.maker?.toLowerCase() !== signed.cancel.maker.toLowerCase()) return [];
    const maker = signed.cancel.maker.toLowerCase();
    const evicted: Hex[] = [];
    for (const h of signed.cancel.orderHashes) {
      const entry = this.entries.get(h);
      if (entry) {
        if (entry.announce.order.maker.toLowerCase() !== maker) continue; // not theirs to retract
        this.tombstone(h, maker, entry.announce.order.expiry, false);
        this.evict(h);
        evicted.push(h);
      } else {
        this.tombstone(h, maker, signed.cancel.expiry, true);
      }
    }
    return evicted;
  }

  private tombstone(orderHash: Hex, maker: string, until: bigint, pending: boolean): void {
    const prior = this.tombstones.get(orderHash);
    if (prior) {
      // First maker to cancel a hash owns its tombstone; a second maker's cancel
      // over the same hash (not their order) must not rebind it.
      if (prior.maker === maker && until > prior.until) prior.until = until;
      if (prior.maker === maker && !pending && prior.pending) {
        prior.pending = false;
        this.bumpPending(maker, -1);
      }
      return;
    }
    if (pending) {
      const cap = this.opts.maxPendingTombstonesPerMaker ?? 1_024;
      if ((this.pendingPerMaker.get(maker) ?? 0) >= cap) return;
      this.bumpPending(maker, 1);
    }
    this.tombstones.set(orderHash, { maker, until, pending });
    const max = this.opts.maxTombstones ?? 100_000;
    for (const [h, t] of this.tombstones) {
      if (this.tombstones.size <= max) break;
      this.dropTombstone(h, t);
    }
  }

  private dropTombstone(orderHash: Hex, t: SoftCancelTombstone): void {
    this.tombstones.delete(orderHash);
    if (t.pending) this.bumpPending(t.maker, -1);
  }

  private bumpPending(maker: string, by: number): void {
    const n = (this.pendingPerMaker.get(maker) ?? 0) + by;
    if (n <= 0) this.pendingPerMaker.delete(maker);
    else this.pendingPerMaker.set(maker, n);
  }

  /** Forget tombstones whose order (or cancel) can no longer matter. Run by every sweep. */
  pruneTombstones(): void {
    const now = BigInt(this.now());
    for (const [h, t] of this.tombstones) if (t.until <= now) this.dropTombstone(h, t);
  }

  /**
   * Cancel-and-replace, applied as one step: the retraction lands ONLY if the
   * replacement verifies, and the replacement lands ONLY if the retraction does.
   * Both signatures are proven first; then the admit and the eviction happen in the
   * same synchronous step, so a book never passes through a state where the maker
   * has neither order live — or, with an unverifiable cancel, both. A failure of
   * either half leaves the predecessor exactly where it was.
   */
  async ingestReplace(replace: OrderReplace): Promise<{ ok: boolean; reason?: string; orderHash?: Hex }> {
    if (!replace.cancel.cancel.orderHashes.includes(replace.replaces)) {
      return { ok: false, reason: "replace: the cancel does not name the replaced order" };
    }
    if (replace.cancel.cancel.maker.toLowerCase() !== replace.announce.order.maker.toLowerCase()) {
      return { ok: false, reason: "replace: cancel and replacement have different makers" };
    }

    let orderHash: Hex;
    try {
      orderHash = hashOrderStruct(replace.announce.order);
    } catch {
      return { ok: false, reason: "unhashable order" };
    }
    // A replacement only takes its predecessor's slot when it really has one here:
    // naming a never-seen predecessor must not be a way past the caps (F29 P4).
    const predecessor = this.entries.get(replace.replaces);
    const exempt =
      predecessor !== undefined &&
      predecessor.announce.order.maker.toLowerCase() === replace.announce.order.maker.toLowerCase();
    const gate = this.precheck(replace.announce.order, orderHash, { known: exempt || this.entries.has(orderHash) });
    if (!gate.ok) return { ok: false, reason: gate.reason, orderHash };

    const cancelVerdict = await this.opts.cancelVerifier.verify(replace.cancel);
    if (!cancelVerdict.ok) return { ok: false, reason: `replace: ${cancelVerdict.reason ?? "cancel rejected"}`, orderHash };
    const res = await this.opts.verifier.verifyAnnounce(replace.announce);
    if (!res.ok) return { ok: false, reason: res.reason, orderHash: res.orderHash }; // predecessor untouched

    const admitted = this.admit(res.orderHash, replace.announce, res.state, { exempt });
    if (!admitted.ok) return { ok: false, reason: admitted.reason, orderHash: res.orderHash };
    this.applyVerifiedCancel(replace.cancel, cancelVerdict);
    return { ok: true, orderHash: res.orderHash };
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
    const key = entry.announce.order.maker.toLowerCase();
    const n = (this.makerCounts.get(key) ?? 1) - 1;
    if (n <= 0) this.makerCounts.delete(key);
    else this.makerCounts.set(key, n);
    // Whatever retired the order — a chain event above all — the verifier's short
    // cache must not keep a fresh `ok` verdict that would re-admit a re-announce.
    this.opts.verifier.invalidate?.(orderHash);
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
    this.pruneTombstones();
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
    const maxStrikes = this.opts.maxInconclusiveStrikes ?? 3;
    for (const entry of entries) {
      const s = states.get(entry.orderHash);
      if (!s) continue;
      if (s.status === OrderStatus.Inconclusive) {
        // Not a verdict — keep the last real state. Only an order that failed ON ITS
        // OWN counts against itself; one merely not reached this sweep does not.
        if (s.isolated) {
          entry.inconclusiveStrikes = (entry.inconclusiveStrikes ?? 0) + 1;
          if (entry.inconclusiveStrikes >= maxStrikes) this.evict(entry.orderHash);
        }
        continue;
      }
      entry.inconclusiveStrikes = 0;
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

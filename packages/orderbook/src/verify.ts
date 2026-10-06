import {
  hashOrderStruct,
  orderTypedData,
  packOrder,
  permitWitnessTypedData,
  OrderSide,
  SETTLEMENT_LENS_ABI,
  type Order,
} from "@1delta-x/sdk";
import { hashTypedData, keccak256, type Hex, type PublicClient, type TypedDataDefinition } from "viem";

import { fillerOf, toDeployment, type OrderbookConfig } from "./config";
import { recoverEcdsa } from "./ecdsa";
import type { OrderAnnounce } from "./messages";

/** Mirrors {SettlementLens.OrderStatus}. `Fillable` (1) is the admit gate. */
export enum OrderStatus {
  Invalid = 0,
  Fillable = 1,
  Filled = 2,
  Cancelled = 3,
  Expired = 4,
  /**
   * NOT a verdict: the order could not be evaluated — its preflight spent the
   * lens's per-order gas budget, the call ran short before reaching it, or the
   * call failed outright. Never a reason to evict. Also produced off-chain for
   * rows a failed chunk never answered, so it works against a lens that predates
   * the on-chain value.
   */
  Inconclusive = 5,
}

/** The full on-chain relevant-state for one order (one row of `getOrderRelevantStates`). */
export interface Layer2Result {
  /** Admit into the book? `Fillable && sig valid && fillable > 0`. Note: NOT gated on
   *  `validatorsPass` — a filler-conditional order is still book-worthy for the
   *  filler it targets, which runs its own per-filler preflight before filling. */
  ok: boolean;
  status: OrderStatus;
  /** Live fillable amount in anchor units, capped by the maker's Permit3 allowance + balance. */
  fillableAmount: bigint;
  /**
   * ECDSA / EIP-1271 / EIP-7702 signature validity, as the lens attests it — or,
   * for a single-signature `fillWithPermit` announce, as Layer 1 proved it locally
   * against the Permit3 witness digest (the lens only knows order signatures).
   */
  isSignatureValid: boolean;
  validatorsPass: boolean;
  /**
   * Set on an `Inconclusive` row that was evaluated ON ITS OWN — alone in a lens
   * call, then through the uncapped single-order view — and still could not be
   * classified. That is evidence about the order, not about its neighbours, so a
   * book may count it against the order ({@link BookOptions.maxInconclusiveStrikes}).
   * An `Inconclusive` without it only means "not reached this time".
   */
  isolated?: boolean;
}

export interface VerifierOptions {
  /** Verdict cache lifetime (ms). Default 15s. */
  cacheTtlMs?: number;
  /** Verdict cache size bound; oldest entries go first. Default 20,000. */
  maxCacheEntries?: number;
  /** Injectable clock (unix seconds) for the Layer-1 deadline check. */
  now?: () => number;
  /** Injectable millisecond clock for the cache. */
  nowMs?: () => number;
  /** Orders per `getOrderRelevantStates` call. Default 100. */
  batchSize?: number;
  /**
   * Extra lens calls one `verifyLayer2` may spend isolating rows that a chunk
   * could not classify (bisection + single-order re-checks). Past it, the rest
   * stay `Inconclusive` — kept, never evicted. Default 64.
   */
  maxRecheckCalls?: number;
  /**
   * Wall-clock budget of one `verifyLayer2` sweep, ms (read on `nowMs`). Once it is
   * spent no further lens call is STARTED — first-level chunks included, which
   * `maxRecheckCalls` does not count — and every row not answered yet stays
   * `Inconclusive` (never `isolated`: kept, never a strike). It bounds a sweep
   * against a hanging RPC: without it, `batches + maxRecheckCalls` calls, each up
   * to the transport timeout × its retries, ran back to back (a Durable Object
   * alarm has a 15-minute wall-clock limit). A call already in flight still runs
   * to its own timeout. Default: unbounded.
   */
  maxSweepMs?: number;
  /**
   * How long an ingest waits for others to share its lens call (ms). Every
   * announce used to fire its own `eth_call`, unbatched and unbounded. Default 5.
   */
  batchWindowMs?: number;
  /** Lens calls the ingest queue may have in flight at once. Default 4. */
  maxConcurrentCalls?: number;
  /** Ingests allowed to wait for a lens call; past it they fail fast. Default 2,000. */
  maxQueued?: number;
}

export interface VerifyResult {
  ok: boolean;
  reason?: string;
  orderHash: Hex;
  state?: Layer2Result;
}

interface CacheEntry {
  res: Layer2Result;
  at: number;
  orderHash: Hex;
}

/** One row for Layer 2. `permit` = the sig is a Permit3 witness sig Layer 1 already proved. */
interface Layer2Entry {
  order: Order;
  sig: Hex;
  sigless?: boolean;
  permit?: boolean;
}

interface Queued {
  key: Hex;
  entry: Layer2Entry;
  resolve: (r: Layer2Result) => void;
  reject: (e: unknown) => void;
}

/** Shared by every chunk of one {@link Verifier.verifyLayer2}: the re-check budget and whether ANY call worked. */
interface SweepBudget {
  calls: number;
  succeeded: number;
  lastError: unknown;
  /** `nowMs` past which no lens call is started (Infinity = unbounded). */
  deadline: number;
}

const INCONCLUSIVE: Layer2Result = {
  ok: false,
  status: OrderStatus.Inconclusive,
  fillableAmount: 0n,
  isSignatureValid: false,
  validatorsPass: false,
};

type LensRows = readonly [readonly number[], readonly bigint[], readonly boolean[], readonly boolean[]];

/**
 * The self-authenticating ingest pipeline (design doc §"verification pipeline").
 *
 * - **Layer 1** (local, zero RPC): recompute the order hash, structural sanity,
 *   deadline, and a cheap ECDSA recover for 65-byte sigs. Non-EOA sigs defer.
 * - **Layer 2** (one lens `readContract`): {SettlementLens.getOrderRelevantStates}
 *   returns status + live-fillable + signature validity (incl. EIP-1271/7702) +
 *   validators for a whole batch in a single view call — collapsing the design
 *   doc's "batched multicall" into one call. Since the 2026-09-30 audit the lens
 *   reports `Invalid` for structurally dead shapes every fill reverts on (a
 *   reserved nonce, a misplaced proportional marker, a wrong-way auction leg, an
 *   unknown item op, a malformed blob — `SettlementLensChecks.deadShape`) and
 *   `Filled` for a completed proportional sweep, so both are evicted here with
 *   no code of their own. A short-TTL cache keyed by
 *   `orderHash` means a POST-then-ingest round-trip costs one eth_call, not two.
 *
 * The per-maker negative cache + `Transfer`/`Approval` event invalidation from
 * the design doc are a further optimization, deferred: at testnet volume a
 * per-ingest lens call is fine.
 */
export class Verifier {
  /** Insertion-ordered, so the first key is always the oldest write — see {@link remember}. */
  private readonly cache = new Map<Hex, CacheEntry>();
  /** orderHash → its cache keys, so an eviction can drop every verdict for that order. */
  private readonly keysByHash = new Map<Hex, Set<Hex>>();
  private readonly cacheTtlMs: number;
  private readonly maxCacheEntries: number;
  private readonly now: () => number;
  private readonly nowMs: () => number;
  private readonly batchSize: number;
  private readonly maxRecheckCalls: number;
  private readonly maxSweepMs: number;
  private readonly batchWindowMs: number;
  private readonly maxConcurrentCalls: number;
  private readonly maxQueued: number;

  /** One lens call per distinct announce at a time — a burst of the same announce shares it. */
  private readonly inflight = new Map<Hex, Promise<Layer2Result>>();
  private queue: Queued[] = [];
  private flushTimer: ReturnType<typeof setTimeout> | undefined;
  private activeCalls = 0;

  constructor(
    private readonly client: PublicClient,
    private readonly config: OrderbookConfig,
    opts?: VerifierOptions,
  ) {
    this.cacheTtlMs = opts?.cacheTtlMs ?? 15_000;
    this.maxCacheEntries = Math.max(1, opts?.maxCacheEntries ?? 20_000);
    this.now = opts?.now ?? (() => Math.floor(Date.now() / 1000));
    this.nowMs = opts?.nowMs ?? (() => Date.now());
    this.batchSize = Math.max(1, opts?.batchSize ?? 100);
    this.maxRecheckCalls = Math.max(0, opts?.maxRecheckCalls ?? 64);
    this.maxSweepMs = opts?.maxSweepMs !== undefined && opts.maxSweepMs >= 0 ? opts.maxSweepMs : Infinity;
    this.batchWindowMs = Math.max(0, opts?.batchWindowMs ?? 5);
    this.maxConcurrentCalls = Math.max(1, opts?.maxConcurrentCalls ?? 4);
    this.maxQueued = Math.max(1, opts?.maxQueued ?? 2_000);
  }

  /**
   * Layer 1 — local, no RPC. `deferSig` means the sig can only be judged by Layer 2.
   * `permit` means the announce is a single-signature `fillWithPermit` one whose
   * Permit3 witness signature was proven here.
   */
  async verifyLayer1(
    a: OrderAnnounce,
  ): Promise<{ ok: boolean; reason?: string; orderHash: Hex; deferSig: boolean; permit?: boolean }> {
    const { order, sig } = a;
    const orderHash = hashOrderStruct(order);

    const hasDenominator =
      order.fillTotal > 0n ||
      (order.side === OrderSide.SELL && order.legsIn.length > 0) ||
      (order.side === OrderSide.BUY && order.legsOut.length > 0);
    if (!hasDenominator) return { ok: false, reason: "no fill denominator (empty anchor leg)", orderHash, deferSig: false };

    if (order.expiry <= BigInt(this.now())) return { ok: false, reason: "order expired", orderHash, deferSig: false };

    // sigless = on-chain approveOrder path; confirmed on-chain, never by recover.
    if (a.sigless) return { ok: true, orderHash, deferSig: true };

    // SINGLE-SIGNATURE `fillWithPermit` (audit 2026-09-30 A-FLEX-2). The maker's
    // only signature is then Permit3's `PermitBatchWitness` signature over the
    // batch WITH the order (and this settlement) as witness — not an Order
    // EIP-712 signature, which is all the rest of this pipeline and the lens know
    // how to check. Every such announce used to defer here and come back from the
    // lens as "invalid signature", so the permit path was dead end to end. It is
    // proven here instead, and only for an ECDSA maker: Permit3 accepts no
    // delegate, and a 1271 maker cannot be judged off-chain.
    if (a.permitBatch) {
      const batch = a.permitBatch;
      if (batch.deadline <= BigInt(this.now())) return { ok: false, reason: "permit batch expired", orderHash, deferSig: false };
      // Every grant, token AND taker, must name this settlement. A taker grant to
      // a foreign spender left the TAKE item unfunded on-chain, and the announce
      // sat in the book until a sweep evicted it (signature review F1).
      const settlement = this.config.settlement.toLowerCase();
      if (
        batch.tokens.some((t) => t.spender.toLowerCase() !== settlement) ||
        batch.takers.some((t) => t.spender.toLowerCase() !== settlement)
      ) {
        return { ok: false, reason: "permit batch grants a spender other than this settlement", orderHash, deferSig: false };
      }
      // `ecrecover` semantics, as Permit3 applies them: 65 bytes with v ∈ {27, 28}
      // or 64-byte EIP-2098. viem's recover also took v = 0/1, which Permit3
      // rejects, and Layer 2 trusts this verdict for the signature, so such an
      // announce read `Fillable` until expiry (F2); a compact signature Permit3
      // fills was refused (F3). Any other length is a 1271 maker — not judgeable.
      let standardLength: boolean, signer: Hex | undefined;
      try {
        ({ standardLength, signer } = await recoverEcdsa(
          hashTypedData(permitWitnessTypedData(batch, order, toDeployment(this.config)) as unknown as TypedDataDefinition),
          sig,
        ));
      } catch {
        // A batch the Permit3 types cannot encode (e.g. a malformed `ref`).
        return { ok: false, reason: "permit signature does not recover", orderHash, deferSig: false };
      }
      if (!standardLength) {
        return { ok: false, reason: "permit announce: only an ECDSA maker signature (65 or 64 bytes) is verifiable", orderHash, deferSig: false };
      }
      if (!signer) return { ok: false, reason: "permit signature does not recover", orderHash, deferSig: false };
      if (signer.toLowerCase() !== order.maker.toLowerCase()) {
        return { ok: false, reason: "permit signature is not the maker's", orderHash, deferSig: false };
      }
      return { ok: true, orderHash, deferSig: false, permit: true };
    }

    // 65-byte or 64-byte (EIP-2098) ECDSA sig: recover here, with the settler's
    // `ecrecover` semantics, and require the maker. Any other length is a contract
    // wallet (EIP-1271) or 7702 account — unrecoverable locally, so defer the
    // verdict to the lens.
    let standardLength: boolean, signer: Hex | undefined;
    try {
      ({ standardLength, signer } = await recoverEcdsa(
        hashTypedData(orderTypedData(order, toDeployment(this.config)) as unknown as TypedDataDefinition),
        sig,
      ));
    } catch {
      return { ok: false, reason: "signature does not recover", orderHash, deferSig: false };
    }
    if (standardLength) {
      // No signer = `ecrecover` yields address(0) (e.g. v = 0/1). The lens would
      // say "invalid" too; refuse here and save the call (F2).
      if (!signer) return { ok: false, reason: "signature does not recover", orderHash, deferSig: false };
      // A recover to someone other than the maker is not a rejection: the settler
      // (and the lens) accept a maker-NOMINATED delegate (`orderSignerExpiry`),
      // which this local step cannot see. Defer to Layer 2, which reads the
      // registry, instead of refusing every session-key-signed order (F29 lead).
      if (signer.toLowerCase() !== order.maker.toLowerCase()) {
        return { ok: true, orderHash, deferSig: true };
      }
      return { ok: true, orderHash, deferSig: false };
    }
    return { ok: true, orderHash, deferSig: true };
  }

  /**
   * Layer 2 — `getOrderRelevantStates` over the batch, CHUNKED. No cache.
   *
   * The chunking is not a micro-optimization, it is a correctness bound. Each
   * order in the call costs an external call, an order hash, cold
   * balance/allowance reads and one staticcall per validator — roughly 25–60k of
   * view gas. An unchunked call over a growing book therefore walks into the
   * provider's `eth_call` gas cap (30–50M, so somewhere past a few hundred to a
   * couple of thousand orders) and starts reverting WHOLESALE. Every order in
   * the book would then read as un-fillable at once, which is the worst possible
   * failure: a periodic re-check that evicts the entire book. Chunks keep one
   * bad or oversized order's blast radius to its own chunk.
   *
   * And a chunk's answer is not taken at face value where it cannot be a verdict.
   * The orders are maker-authored: one whose token or 1271 wallet burns all gas
   * used to starve every order after it in the same lens call, and each of those
   * came back `Invalid` and was evicted. So:
   *   • a chunk whose call FAILS is bisected, never read as "all invalid", and
   *     never stops the chunks after it;
   *   • `Inconclusive` rows, and a RUN of `Invalid` rows (a lone `Invalid` is
   *     believable; several at once is what starvation looks like on a lens
   *     without the per-order gas cap), are re-checked in smaller calls until
   *     each order has been asked on its own;
   *   • an order still `Inconclusive` alone gets one uncapped single-order call.
   * All of it is bounded by `maxRecheckCalls`, and the whole sweep by `maxSweepMs`;
   * what the budget does not reach stays `Inconclusive`. If NO call in the sweep
   * succeeded the RPC is the problem, not the orders, and the last error is thrown
   * instead of a book's worth of verdicts.
   */
  async verifyLayer2(entries: readonly Layer2Entry[]): Promise<Layer2Result[]> {
    if (entries.length === 0) return [];
    const out: Layer2Result[] = new Array<Layer2Result>(entries.length);
    const budget: SweepBudget = { calls: this.maxRecheckCalls, succeeded: 0, lastError: undefined, deadline: this.nowMs() + this.maxSweepMs };
    for (let i = 0; i < entries.length; i += this.batchSize) {
      const idx: number[] = [];
      for (let k = i; k < Math.min(i + this.batchSize, entries.length); k++) idx.push(k);
      await this.resolveRows(entries, idx, out, budget, false);
    }
    if (budget.succeeded === 0 && budget.lastError !== undefined) throw budget.lastError;
    return out;
  }

  /** Whether the sweep's wall-clock budget is spent (no new lens call may start). */
  private outOfTime(budget: SweepBudget): boolean {
    return this.nowMs() >= budget.deadline;
  }

  /** Classify `idx`, recursing into smaller calls wherever an answer is not a verdict. */
  private async resolveRows(
    entries: readonly Layer2Entry[],
    idx: readonly number[],
    out: Layer2Result[],
    budget: SweepBudget,
    isRecheck: boolean,
  ): Promise<void> {
    if (this.outOfTime(budget) || (isRecheck && budget.calls <= 0)) {
      // Not reached this sweep: kept as `Inconclusive` (not `isolated`), never evicted.
      for (const i of idx) out[i] = INCONCLUSIVE;
      return;
    }
    if (isRecheck) budget.calls--;

    let rows: Layer2Result[];
    try {
      rows = await this.callLens(idx.map((i) => entries[i]!));
      budget.succeeded++;
    } catch (err) {
      budget.lastError = err;
      if (idx.length === 1) {
        out[idx[0]!] = INCONCLUSIVE;
        return;
      }
      const mid = idx.length >> 1;
      await this.resolveRows(entries, idx.slice(0, mid), out, budget, true);
      await this.resolveRows(entries, idx.slice(mid), out, budget, true);
      return;
    }

    idx.forEach((i, k) => {
      out[i] = rows[k]!;
    });

    if (idx.length === 1) {
      const only = idx[0]!;
      if (out[only]!.status === OrderStatus.Inconclusive) out[only] = await this.resolveAlone(entries[only]!, budget);
      return;
    }

    const doubtful = idx.filter((i) => out[i]!.status === OrderStatus.Inconclusive || out[i]!.status === OrderStatus.Invalid);
    const invalids = doubtful.filter((i) => out[i]!.status === OrderStatus.Invalid).length;
    // A single Invalid among real verdicts is believable; two or more is the shape
    // of starvation, so every one of them is asked again.
    const suspects = invalids >= 2 ? doubtful : doubtful.filter((i) => out[i]!.status === OrderStatus.Inconclusive);
    if (suspects.length === 0) return;
    if (suspects.length < idx.length) {
      await this.resolveRows(entries, suspects, out, budget, true);
    } else {
      // Nothing in this call was believable — split it, or the re-check repeats it.
      const mid = idx.length >> 1;
      await this.resolveRows(entries, idx.slice(0, mid), out, budget, true);
      await this.resolveRows(entries, idx.slice(mid), out, budget, true);
    }
  }

  /**
   * The last resort for one order the capped batch could not finish: the
   * single-order view, which runs under the whole call's gas. An order that
   * legitimately needs more than the lens's per-order budget is classified here;
   * one that still cannot be is reported `Inconclusive` + `isolated`.
   */
  private async resolveAlone(e: Layer2Entry, budget: SweepBudget): Promise<Layer2Result> {
    if (budget.calls <= 0 || this.outOfTime(budget)) return INCONCLUSIVE;
    budget.calls--;
    try {
      const [status, fillableAmount, isSignatureValid, vp] = (await this.client.readContract({
        address: this.config.lens,
        abi: SETTLEMENT_LENS_ABI,
        functionName: "getOrderRelevantState",
        args: [packOrder(e.order), e.sig, fillerOf(this.config), "0x"],
      })) as readonly [number, bigint, boolean, boolean];
      budget.succeeded++;
      return toResult(status, fillableAmount, isSignatureValid, vp, e.permit);
    } catch (err) {
      budget.lastError = err;
      return { ...INCONCLUSIVE, isolated: true };
    }
  }

  /** One `getOrderRelevantStates` call. Throws on any call failure — the caller decides what that means. */
  private async callLens(entries: readonly Layer2Entry[]): Promise<Layer2Result[]> {
    // PACK FIRST. The lens ABI takes the WIRE order (`bytes legsIn/legsOut/curve/
    // items/…`, `uint256 params`), not the authoring `Order` the book holds. This
    // used to pass the authoring struct straight through; viem's encoder threw on
    // the first `bytes` field, so against a real lens no order could ever be
    // admitted and the periodic re-check never evicted anything — only stubbed
    // `readContract`s kept the tests green (F29 P1; the same drift the SDK's
    // `sdk-packed-order-sync` closed). Every other lens/settlement call site in
    // the SDK packs; this one now does too.
    const orders = entries.map((e) => packOrder(e.order));
    const sigs = entries.map((e) => e.sig);
    const takerDatas = entries.map(() => "0x" as Hex);

    const result = (await this.client.readContract({
      address: this.config.lens,
      abi: SETTLEMENT_LENS_ABI,
      functionName: "getOrderRelevantStates",
      args: [orders, sigs, fillerOf(this.config), takerDatas],
    })) as LensRows;

    const [statuses, fillableAmounts, sigValids, validatorsPass] = result;
    // A short answer is not "the rest are invalid": the missing rows were never
    // evaluated.
    return entries.map((e, i): Layer2Result =>
      statuses[i] === undefined
        ? INCONCLUSIVE
        : toResult(statuses[i]!, fillableAmounts[i] ?? 0n, sigValids[i] ?? false, validatorsPass[i] ?? false, e.permit),
    );
  }

  /** Full ingest verdict for one announce: Layer 1, then a cached Layer 2. */
  async verifyAnnounce(a: OrderAnnounce): Promise<VerifyResult> {
    const l1 = await this.verifyLayer1(a);
    if (!l1.ok) return { ok: false, reason: l1.reason, orderHash: l1.orderHash };
    const state = await this.layer2Cached(l1.orderHash, a, l1.permit === true);
    return { ok: state.ok, reason: state.ok ? undefined : reasonFor(state), orderHash: l1.orderHash, state };
  }

  /** Fresh Layer-2 states for orders already in the book (periodic re-check); refreshes the cache. */
  async refreshStates(entries: readonly { orderHash: Hex; announce: OrderAnnounce }[]): Promise<Map<Hex, Layer2Result>> {
    // Book entries were admitted through {verifyAnnounce}, so a `permitBatch` on one
    // means Layer 1 already proved its witness signature — the stored announce is
    // first-seen and never overwritten (see `Book.admit`).
    const states = await this.verifyLayer2(
      entries.map((e) => ({
        order: e.announce.order,
        sig: e.announce.sig,
        sigless: e.announce.sigless,
        permit: e.announce.permitBatch !== undefined && !e.announce.sigless,
      })),
    );
    const out = new Map<Hex, Layer2Result>();
    entries.forEach((e, i) => {
      const s = states[i];
      if (s) {
        this.remember(Verifier.cacheKey(e.orderHash, e.announce, e.announce.permitBatch !== undefined && !e.announce.sigless), e.orderHash, s);
        out.set(e.orderHash, s);
      }
    });
    return out;
  }

  /**
   * Forget every cached verdict for `orderHash`. The book calls this whenever it
   * evicts: a chain event that retires an order must not leave a fresh `ok`
   * verdict behind for a re-announce to be admitted on until the TTL runs out.
   */
  invalidate(orderHash: Hex): void {
    const keys = this.keysByHash.get(orderHash);
    if (!keys) return;
    for (const k of keys) this.cache.delete(k);
    this.keysByHash.delete(orderHash);
  }

  /** Cached verdicts currently held (bounded by `maxCacheEntries`). */
  get cacheSize(): number {
    return this.cache.size;
  }

  /**
   * The cache key is the ANNOUNCE, not the order hash. A verdict proves the pair
   * `(order, sig)` the lens saw; served for any other `sig` under the same hash it
   * let an unauthenticated re-announce carrying garbage (or `sigless`) inherit the
   * honest announce's verdict, overwrite the served signature and get the order
   * evicted on the next sweep (F29 P2). A permit announce (the sig is a Permit3
   * witness sig, proven by Layer 1) is its own mode, so its verdict is never served
   * to the same bytes presented as an order signature, or the reverse.
   */
  private static cacheKey(orderHash: Hex, a: { sig: Hex; sigless?: boolean }, permit = false): Hex {
    const mode = a.sigless ? "01" : permit ? "02" : "00";
    return keccak256(`${orderHash}${mode}${keccak256(a.sig).slice(2)}` as Hex);
  }

  /**
   * Store a verdict. One entry per distinct `(hash, sig)` means a stranger can mint
   * entries at will, so the map is bounded twice: by age (expired entries are
   * dropped from the front — re-inserting moves a key to the back, so the front is
   * always the oldest) and by size (the oldest go first past `maxCacheEntries`).
   * `Inconclusive` is not a verdict and is never cached.
   */
  private remember(key: Hex, orderHash: Hex, res: Layer2Result): void {
    if (res.status === OrderStatus.Inconclusive) return;
    const at = this.nowMs();
    this.cache.delete(key);
    this.cache.set(key, { res, at, orderHash });
    let keys = this.keysByHash.get(orderHash);
    if (!keys) this.keysByHash.set(orderHash, (keys = new Set()));
    keys.add(key);

    for (const [k, e] of this.cache) {
      if (this.cache.size <= this.maxCacheEntries && at - e.at < this.cacheTtlMs) break;
      this.forget(k, e.orderHash);
    }
  }

  private forget(key: Hex, orderHash: Hex): void {
    this.cache.delete(key);
    const keys = this.keysByHash.get(orderHash);
    keys?.delete(key);
    if (keys && keys.size === 0) this.keysByHash.delete(orderHash);
  }

  private async layer2Cached(orderHash: Hex, a: OrderAnnounce, permit: boolean): Promise<Layer2Result> {
    const key = Verifier.cacheKey(orderHash, a, permit);
    const hit = this.cache.get(key);
    if (hit && this.nowMs() - hit.at < this.cacheTtlMs) return hit.res;
    const pending = this.inflight.get(key);
    if (pending) return pending;

    // Bounded, not best-effort: a flood of announces used to become the same number
    // of concurrent `eth_call`s. Past `maxQueued` an ingest fails fast (the book
    // and server both read a throw as "verification unavailable", never as a verdict).
    if (this.queue.length >= this.maxQueued) throw new Error("verifier queue full");
    const p = new Promise<Layer2Result>((resolve, reject) => {
      this.queue.push({ key, entry: { order: a.order, sig: a.sig, sigless: a.sigless, permit }, resolve, reject });
    });
    this.inflight.set(key, p);
    const done = () => {
      if (this.inflight.get(key) === p) this.inflight.delete(key);
    };
    p.then(
      (r) => {
        done();
        this.remember(key, orderHash, r);
      },
      done,
    );
    this.scheduleFlush();
    return p;
  }

  private scheduleFlush(): void {
    if (this.queue.length >= this.batchSize) {
      this.flush();
      return;
    }
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = undefined;
      this.flush();
    }, this.batchWindowMs);
    (this.flushTimer as { unref?: () => void }).unref?.();
  }

  /** Drain the queue into lens calls, at most `maxConcurrentCalls` at a time. */
  private flush(): void {
    while (this.activeCalls < this.maxConcurrentCalls && this.queue.length > 0) {
      const batch = this.queue.splice(0, this.batchSize);
      this.activeCalls++;
      void this.verifyLayer2(batch.map((q) => q.entry))
        .then(
          (rows) => batch.forEach((q, i) => q.resolve(rows[i] ?? INCONCLUSIVE)),
          (err) => batch.forEach((q) => q.reject(err)),
        )
        .finally(() => {
          this.activeCalls--;
          if (this.queue.length > 0) this.flush();
        });
    }
  }
}

function toResult(
  status: number,
  fillableAmount: bigint,
  isSignatureValid: boolean,
  validatorsPass: boolean,
  permit = false,
): Layer2Result {
  // No sigless special case: the lens reads the settler's own `orderApproved`
  // record for an empty sig, so an on-chain-authorized order is attested here
  // on exactly the terms the settler applies. Previously this branch trusted
  // the announcer's own `sigless` claim, which is not evidence of anything.
  // NOTE: requires a lens deployed at or after that change — an older one
  // reports every sigless order invalid.
  const s = status as OrderStatus;
  if (permit) {
    // A permit announce: the signature was proven by Layer 1 against the witness
    // digest (the lens's order-signature check cannot see it), and the maker's
    // Permit3 allowance is exactly what the permit GRANTS at fill time — so the
    // lens's allowance-capped `fillableAmount` is legitimately 0 before the fill
    // and is reported, not gated on. Lifecycle (filled / cancelled / expired /
    // malformed) still comes from the lens.
    return { ok: s === OrderStatus.Fillable, status: s, fillableAmount, isSignatureValid: true, validatorsPass };
  }
  const ok = s === OrderStatus.Fillable && isSignatureValid && fillableAmount > 0n;
  return { ok, status: s, fillableAmount, isSignatureValid, validatorsPass };
}

function reasonFor(s: Layer2Result): string {
  switch (s.status) {
    case OrderStatus.Expired:
      return "order expired (on-chain)";
    case OrderStatus.Cancelled:
      return "nonce cancelled";
    case OrderStatus.Filled:
      return "order fully filled";
    case OrderStatus.Invalid:
      return "malformed order";
    case OrderStatus.Inconclusive:
      return "order could not be evaluated (verification ran out of gas or failed) — retry later";
    default:
      if (!s.isSignatureValid) return "invalid signature";
      if (s.fillableAmount === 0n) return "maker has no allowance/balance for this order";
      return "not fillable";
  }
}

import { assertOrderNonce, randomOrderNonce } from "@1delta-x/sdk";

/**
 * WORD-PACKED ORDER NONCES.
 *
 * Settlement's nonce bitmap is `nonceBitmap[maker][nonce >> 8]`, bit `nonce & 0xff`
 * (packages/core/src/settlement/NonceManager.sol). A nonce is dead when that bit is
 * set (a `cancelOrders`, an `invalidateNonceWord`, or a completed FILL-ONCE order —
 * `timing` bit 100 consumes the nonce instead of writing `filled[orderHash]`) or when
 * it is below the maker's `minValidNonce` watermark. Bit 255 of the NONCE is the
 * reserved delegated-signer half (`SIGNER_NONCE_NS`): every order nonce must be
 * `< 2^255` — the SDK's `assertOrderNonce` refuses anything else at build time and
 * the settler reverts `OrderNonceReserved` on fill.
 *
 * Instead of a uniform 255-bit draw, the app hands a maker's orders consecutive bits
 * of ONE word: the lowest bit, at or above a floor, that is
 *   (a) clear on-chain in the maker's bitmap word,
 *   (b) not carried by any of the maker's still-open signed orders the app knows of
 *       (its own rows, plus what `restore()` brought back from `GET /orders?maker=`),
 *   (c) not already handed out — by this tab (in-memory) or, through
 *       `localStorage`, by any other tab of this browser (a persisted high-water mark).
 * When the word is full the search moves to the next one. Every TWAP slice signs its
 * own order, so each slice gets its own bit.
 *
 * WHAT IT BUYS (measured, `packages/core` Foundry bench, see the app README):
 *   • On its own: a short nonce — 1–2 non-zero bytes of fill calldata instead of ~31
 *     (−327 gas at EIP-2028's 16 gas/byte; about −1.9k at rskj's 68 gas/byte).
 *   • With FILL-ONCE orders (market tickets — see {@link fillOnceFor}):
 *     a repeat maker's fill flips a bit in an already-non-zero, already-loaded word
 *     instead of writing a fresh `filled[orderHash]` slot: −16.9k per fill measured
 *     (151,382 → 134,460 for a plain fill). A random nonce gets nothing from
 *     fill-once — each fill still pays a zero→non-zero write, just in a different slot.
 *
 * THE MULTI-TAB / MULTI-DEVICE RACE. Two clients can still pick the same bit: two
 * browsers (no shared storage) whose newest orders are not on the book yet, or two
 * tabs inside the read-modify-write window of the high-water mark. The consequence is
 * bounded and costs no funds: the two orders share a nonce, so a HARD cancel
 * (`cancelOrders([n])`) of one also kills the other, and — for fill-once orders only —
 * filling one makes the other unfillable (`NonceCancelled`). Neither can move funds
 * the maker did not sign for. Mitigations: the persisted high-water mark (shared by
 * every tab of the origin, written BEFORE the wallet prompt), the in-tab lock
 * ({@link NonceAllocator.allocate} serialises), and the allocation running right
 * before signing, after a fresh bitmap read.
 *
 * FALLBACK: when the bitmap cannot be read (no wallet / RPC error), the old uniform
 * draw above the watermark ({@link randomOrderNonce}) — never a guess at a packed bit.
 * A failed WATERMARK read still fails the ticket, exactly as before: a nonce below
 * `minValidNonce` is dead on arrival, so drawing from 0 would be worse than stopping.
 */

/**
 * Which tickets the app signs as FILL-ONCE orders (`timing` bit 100): MARKET tickets
 * only — the quoted short Dutch auction and its gas-floor fallback alike. The packed
 * nonce above is only HALF of the repeat-maker gas win; this is the other half.
 *
 * Fill-once is what makes a fill touch the nonce bitmap at all: without it a fill
 * writes `filled[orderHash]` (a fresh slot, ~22.1k, whatever the nonce) and only
 * READS the bitmap word for the cancel gate. With it, the fill sets the nonce's bit
 * instead, and a packed nonce lands that write on a word an earlier fill already
 * made non-zero (measured −16.9k per fill, see the app README).
 *
 * The price: a fill-once order is ALL-OR-NOTHING (the core reverts
 * `FillOnceMustBeFull` on a partial). A market ticket is meant to fill whole or not
 * at all, so it loses nothing; LIMIT and TWAP orders keep partial fills and the
 * classic per-hash counter.
 *
 * What had to be true first, and now is:
 *   1. The book calls a fill-once fill FILLED. `SettlementLens` reports a completed
 *      fill-once order as `Cancelled` (fill and nonce-cancel leave identical state);
 *      orderbook-worker (and the @1delta-x/orderbook Book) tombstone the order as
 *      Filled from its indexed `OrderFilled` — log scan or `/fills/report` — and a
 *      lens `Cancelled` with a fill row maps to `filled`.
 *   2. The app's on-chain fallback reads the nonce bit for a fill-once order
 *      (lib/chain.ts `readFillState`): consumed and not the app's own on-chain cancel
 *      → filled (lib/orderLifecycle.ts `chainFillOutcome`).
 *   3. The beta filler never sends a partial for one: a budget-capped fill
 *      (`capFillAmount`) or an under-funded maker is a skip with a reason.
 */
export function fillOnceFor(kind: "market" | "limit" | "twap"): boolean {
  return kind === "market";
}

/**
 * Nonces carried by the maker's signed orders the app still holds as rows — open,
 * soft-cancelled (still fillable on-chain until expiry) or restored from the book.
 */
export function openOrderNonces(
  rows: Iterable<{ signed?: { order: { maker: string; nonce: bigint } }; signedOrders?: readonly { order: { maker: string; nonce: bigint } }[] }>,
  maker: string,
): bigint[] {
  const me = maker.toLowerCase();
  const out: bigint[] = [];
  for (const r of rows) {
    for (const s of [...(r.signedOrders ?? []), ...(r.signed ? [r.signed] : [])]) {
      if (s.order.maker.toLowerCase() === me) out.push(s.order.nonce);
    }
  }
  return out;
}

/** One past the largest legal order nonce: bit 255 is the reserved signer half. */
export const ORDER_NONCE_LIMIT = 1n << 255n;
/** Bits per bitmap word. */
export const WORD_BITS = 256n;
/**
 * The word a maker with no watermark starts in: nonces 256..511. Word 0 is avoided so
 * the conventional "nonce 0 / 1" of hand-rolled scripts never collides with the app.
 */
export const DEFAULT_NONCE_WORD = 1n;
/** How many full words a single allocation may skip before it gives up (→ random). */
export const MAX_WORDS_SCANNED = 16;

export interface PickNoncesArgs {
  /** How many nonces (one per order / TWAP slice). */
  count: number;
  /** The maker's on-chain `minValidNonce`: nothing below it. */
  minValidNonce: bigint;
  /** The maker's bitmap word `wordPos` (`Settlement.nonceBitmap(maker, wordPos)`). */
  readWord: (wordPos: bigint) => bigint | Promise<bigint>;
  /** Nonces already taken: open signed orders the app knows of, and session reservations. */
  taken?: Iterable<bigint>;
  /** Hand out nothing below this — the persisted high-water mark + 1. */
  floor?: bigint;
  /** The first word to search when nothing else lifts the start. */
  baseWord?: bigint;
  /** Give up (throw) after this many words. */
  maxWords?: number;
}

/**
 * The lowest `count` free order nonces — pure apart from `readWord`.
 *
 * Starts at `max(minValidNonce, floor, baseWord·256)`, walks that word bit by bit,
 * skipping bits set on-chain and nonces in `taken`, and moves to the next word when
 * one runs out. Every result is `< 2^255` (checked through `assertOrderNonce`).
 * Throws when the search would cross into the reserved half or scans more than
 * `maxWords` words — the caller then falls back to a random nonce.
 */
export async function pickOrderNonces(a: PickNoncesArgs): Promise<bigint[]> {
  if (!Number.isSafeInteger(a.count) || a.count < 1) throw new Error(`nonce count ${a.count} must be a positive integer`);
  if (a.minValidNonce < 0n || a.minValidNonce >= ORDER_NONCE_LIMIT) {
    throw new Error(`minValidNonce ${a.minValidNonce} leaves no order nonce below 2^255`);
  }
  const taken = new Set(a.taken ?? []);
  const baseStart = (a.baseWord ?? DEFAULT_NONCE_WORD) * WORD_BITS;
  let start = a.minValidNonce;
  if ((a.floor ?? 0n) > start) start = a.floor!;
  if (baseStart > start) start = baseStart;
  const maxWords = a.maxWords ?? MAX_WORDS_SCANNED;

  const out: bigint[] = [];
  let word = start >> 8n;
  let bit = start & 0xffn;
  for (let scanned = 0; scanned < maxWords; scanned++, word++, bit = 0n) {
    if (word * WORD_BITS >= ORDER_NONCE_LIMIT) break;
    const bitmap = await a.readWord(word);
    for (; bit < WORD_BITS; bit++) {
      if ((bitmap >> bit) & 1n) continue;
      const nonce = (word << 8n) | bit;
      if (taken.has(nonce)) continue;
      out.push(assertOrderNonce(nonce));
      taken.add(nonce);
      if (out.length === a.count) return out;
    }
  }
  throw new Error(`no free order nonce within ${maxWords} bitmap words from ${start}`);
}

/** Where the per-maker high-water mark lives (any `Storage`; tests pass a Map shim). */
export interface NonceStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface AllocateArgs {
  chainId: number;
  settlement: string;
  maker: string;
  count: number;
  /**
   * Reads `minValidNonce` and the bitmap. `null` = no reader (no wallet / undeployed):
   * the random fallback runs.
   */
  chain: { minValidNonce(): Promise<bigint>; word(wordPos: bigint): Promise<bigint> } | null;
  /** Nonces of the maker's still-open signed orders the app knows of. */
  open?: Iterable<bigint>;
}

export interface Allocation {
  nonces: bigint[];
  /** `packed` = word-packed; `random` = the fallback draw (the read failed). */
  mode: "packed" | "random";
  /** The watermark the allocation respected (0 without a chain reader). */
  minValidNonce: bigint;
}

/**
 * Session-wide nonce reservations — one per app (see `appNonces` below).
 *
 * `allocate` is serialised per (chain, settlement, maker), so two tickets signed in
 * quick succession cannot both read the bitmap before either reserves; a reservation
 * is recorded in memory and in the persisted high-water mark BEFORE it is returned
 * (i.e. before the wallet prompt), so a declined signature leaves a harmless gap
 * rather than a nonce another order could reuse.
 */
export class NonceAllocator {
  private readonly reserved = new Map<string, Set<bigint>>();
  private readonly locks = new Map<string, Promise<unknown>>();

  constructor(private readonly store: () => NonceStore | undefined = defaultStore) {}

  static key(chainId: number, settlement: string, maker: string): string {
    return `1dx:nonce-hw:${chainId}:${settlement.toLowerCase()}:${maker.toLowerCase()}`;
  }

  /** The persisted high-water mark (largest nonce this browser handed out), or undefined. */
  highWater(key: string): bigint | undefined {
    try {
      const raw = this.store()?.getItem(key);
      return raw && /^\d+$/.test(raw) ? BigInt(raw) : undefined;
    } catch {
      return undefined;
    }
  }

  /** Nonces reserved in this tab for `key`. */
  reservedFor(key: string): ReadonlySet<bigint> {
    return this.reserved.get(key) ?? new Set();
  }

  allocate(a: AllocateArgs): Promise<Allocation> {
    const key = NonceAllocator.key(a.chainId, a.settlement, a.maker);
    const prev = this.locks.get(key) ?? Promise.resolve();
    const run = prev.then(
      () => this.allocateNow(key, a),
      () => this.allocateNow(key, a),
    );
    this.locks.set(key, run);
    return run;
  }

  private async allocateNow(key: string, a: AllocateArgs): Promise<Allocation> {
    // The watermark read is NOT optional when a chain is there: a nonce below it is
    // dead on arrival, so its failure fails the ticket (as before) rather than
    // silently drawing from 0. Only the BITMAP read has a fallback.
    const minValidNonce = a.chain ? await a.chain.minValidNonce() : 0n;
    try {
      if (!a.chain) throw new Error("no chain reader");
      const hw = this.highWater(key);
      const nonces = await pickOrderNonces({
        count: a.count,
        minValidNonce,
        readWord: (w) => a.chain!.word(w),
        taken: [...(a.open ?? []), ...this.reservedFor(key)],
        floor: hw === undefined ? undefined : hw + 1n,
      });
      this.reserve(key, nonces);
      return { nonces, mode: "packed", minValidNonce };
    } catch {
      // No bitmap: the uniform draw above whatever watermark is known. Nothing is
      // persisted — a random nonce says nothing about the packed word.
      const nonces = Array.from({ length: a.count }, () => randomOrderNonce(minValidNonce));
      return { nonces, mode: "random", minValidNonce };
    }
  }

  private reserve(key: string, nonces: readonly bigint[]): void {
    const set = this.reserved.get(key) ?? new Set<bigint>();
    for (const n of nonces) set.add(n);
    this.reserved.set(key, set);
    let hw = this.highWater(key) ?? -1n;
    for (const n of nonces) if (n > hw) hw = n;
    try {
      this.store()?.setItem(key, hw.toString());
    } catch {
      // Private window / blocked storage: the in-memory reservation still holds for this tab.
    }
  }
}

function defaultStore(): NonceStore | undefined {
  try {
    return typeof window === "undefined" ? undefined : window.localStorage;
  } catch {
    return undefined;
  }
}

/** The app's one allocator. */
export const appNonces = new NonceAllocator();

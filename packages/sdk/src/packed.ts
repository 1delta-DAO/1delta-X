import { getAddress, numberToHex, zeroAddress, type Address, type Hex } from "viem";
import {
  BLOCK_CLOCK_BIT,
  DELTA_VERIFY_OUTPUTS_BIT,
  FILLER_SET_SENTINEL,
  ItemOp,
  OrderSide,
  assertOrderNonce,
  packParams,
  unpackParams,
  unpackTiming,
} from "./types";
import type { CurvePoint, Item, LegIn, LegOut, Order, Validator } from "./types";

/**
 * TypeScript mirror of Solidity's `PackedArrays` — the wire encoding of an order.
 *
 * The contract does NOT take `LegIn[]` / `Item[]` / `Validator[]` as struct
 * arrays. Each is an opaque packed `bytes` blob, because an EIP-712
 * array-of-struct member must be hashed element by element (one `keccak256` per
 * element, then one over the concatenation) whereas a `bytes` member is a single
 * `keccak256` over the whole blob. That is what the order typehash commits to,
 * and therefore what a signature has to cover.
 *
 * The authoring {@link Order} stays structured — it is far easier to build and
 * to read — and everything crossing the wire goes through {@link packOrder}.
 * Signing, hashing and calldata encoding all do that for you.
 *
 * ⚠ KEEP IN LOCKSTEP WITH `packages/core/src/settlement/PackedArrays.sol`.
 * A mismatch here does not fail loudly: it produces a well-formed order that
 * hashes to something the contract will not recognise. `test/eip712.test.ts`
 * pins the canonical hash against the Solidity golden for exactly this reason.
 *
 * LAYOUT — every blob starts with a `uint8` element count, so an empty array is
 * the single byte `0x00`.
 *
 *   fixed stride:
 *     LegIn       84 = token(20) | start(32) | end(32)
 *     LegOut     104 = token(20) | start(32) | end(32) | recipient(20)
 *     CurvePoint   8 = timeDelta(4) | bumpBps(4)
 *
 *   length-prefixed records:
 *     Item           = op(1) | module(20) | amount(32) | recipient(20) | len(2) | data
 *     Validator      = target(20) | len(2) | data
 */

const MAX_ELEMENTS = 255;

/** Hex body (no `0x`) of `value` in exactly `bytes` bytes. */
function u(value: bigint | number, bytes: number): string {
  return numberToHex(value, { size: bytes }).slice(2);
}

/** Hex body of a 20-byte address. */
function addr(a: Hex): string {
  const body = a.slice(2);
  if (body.length !== 40) throw new Error(`not a 20-byte address: ${a}`);
  return body.toLowerCase();
}

/** Hex body of a `bytes` value, plus its length in bytes. */
function blob(d: Hex): { body: string; len: number } {
  const body = d.slice(2);
  if (body.length % 2 !== 0) throw new Error(`odd-length hex: ${d}`);
  return { body, len: body.length / 2 };
}

function count(n: number): string {
  if (n > MAX_ELEMENTS) throw new Error(`packed arrays hold at most ${MAX_ELEMENTS} elements, got ${n}`);
  return u(n, 1);
}

export function packLegsIn(legs: readonly LegIn[]): Hex {
  let out = count(legs.length);
  for (const l of legs) out += addr(l.token) + u(l.start, 32) + u(l.end, 32);
  return `0x${out}`;
}

export function packLegsOut(legs: readonly LegOut[]): Hex {
  let out = count(legs.length);
  for (const l of legs) out += addr(l.token) + u(l.start, 32) + u(l.end, 32) + addr(l.recipient);
  return `0x${out}`;
}

/**
 * Encode a filler SET into the `curve` bytes for a {@link FILLER_SET_SENTINEL}
 * order: `[0x00] ‖ [20-byte filler]×N`. The leading zero is the blob's count
 * byte — the decay clock reads "no curve points" and prices the order on the
 * plain linear ramp, never parsing the set. Sign the window into `timing` bits
 * [64:96) (`packTiming`'s exclusivityEndTime) and, for a SOFT set, a non-zero
 * `exclusivityOverrideBps`.
 */
export function packFillerSet(fillers: readonly Address[]): Hex {
  if (fillers.length === 0) throw new Error("a filler set needs at least one filler");
  let out = "0x00";
  for (const f of fillers) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(f)) throw new Error(`not an address: ${f}`);
    out += f.slice(2);
  }
  return out.toLowerCase() as Hex;
}

export function packCurve(points: readonly CurvePoint[]): Hex {
  let out = count(points.length);
  for (const p of points) out += u(p.timeDelta, 4) + u(p.bumpBps, 4);
  return `0x${out}`;
}

export function packItems(items: readonly Item[]): Hex {
  let out = count(items.length);
  for (const i of items) {
    const d = blob(i.data);
    out += u(i.op, 1) + addr(i.module) + u(i.amount, 32) + addr(i.recipient) + u(d.len, 2) + d.body;
  }
  return `0x${out}`;
}

export function packValidators(vs: readonly Validator[]): Hex {
  let out = count(vs.length);
  for (const v of vs) {
    const d = blob(v.data);
    out += addr(v.target) + u(d.len, 2) + d.body;
  }
  return `0x${out}`;
}

/**
 * The order exactly as the contract's ABI and typehash see it: packed blobs, and
 * no `side` member — `side` is bit 101 of `timing`.
 */
export interface WireOrder {
  maker: Hex;
  nonce: bigint;
  // `expiry` (the order timeout) is folded into `timing` bits [160:208) — not a wire field.
  legsIn: Hex;
  legsOut: Hex;
  timing: bigint;
  exclusiveFiller: Hex;
  minFillAnchor: bigint;
  /// Packed auction scalars — see `packParams`.
  params: bigint;
  curve: Hex;
  items: Hex;
  validators: Hex;
  invariants: Hex;
  fillModule: Hex;
  fillTotal: bigint;
  pricingModule: Hex;
}

/** `Order.side` lives in bit 101 of the packed `timing` word — see `DutchAuction.side`. */
export const SIDE_BIT = 101n;

/** `Order.expiry` (unix seconds, uint48) rides in `timing` bits [160:208) — see
 *  `DutchAuction.expiry`. Folded in by `packOrder`, so authors keep a friendly
 *  `expiry` field on {@link Order} and never touch these bits by hand. */
export const EXPIRY_OFFSET = 160n;

/** First `timing` bit an author may never set. Everything below it is either the
 *  caller's (clocks, item policy, fill-once, the three mode flags at 102–104) or
 *  `side` at bit 101; everything at or above it is reserved — today that is the
 *  `expiry` window at [160:208), which {@link packOrder} writes. */
export const RESERVED_FROM_BIT = 105n;

/**
 * Convert an authoring {@link Order} into the form the contract actually takes.
 *
 * Two shape changes, both mirroring the Solidity struct:
 *  - the five struct arrays become packed `bytes` blobs;
 *  - `side` is folded into `timing` bit 101, because it did not justify a whole
 *    32-byte word in the calldata and the hash preimage for one bit;
 *  - the four auction scalars (override bps, gas bump, gas price ref, priority
 *    scale) fold into one `params` word, for the same reason.
 *
 * `timing`'s lower bits stay the caller's: [0:32) decay start, [32:64) decay
 * duration, [64:96) exclusivity end, [96:100) item policy, bit 100 fill-once,
 * and the three MODE FLAGS at bits 102–104 (block clock, priority auction,
 * delta-verify outputs — set them with {@link withBlockClock} /
 * {@link withPriorityAuction} / {@link withDeltaVerifyOutputs}).
 *
 * This function owns exactly two regions and rejects a caller that has written
 * either: bit 101 (`side`) and bits [160:208) (`expiry`), both of which it folds
 * in from the friendly {@link Order} fields.
 *
 * ⚠ THE GUARD USED TO BE `timing >> 101 != 0`, i.e. "bit 101 and above must be
 * clear". That was wrong, and it made the three mode flags UNREACHABLE: bits 102,
 * 103 and 104 are the caller's to set, `withDeltaVerifyOutputs` has always
 * returned a word with bit 104 on, and `pricing.ts` reads bit 103 — yet any such
 * order threw here before it could be signed. A priority auction, a block-clock
 * order and a delta-verify order were all unbuildable through the SDK. The guard
 * now names the two regions it actually owns.
 */
export function packOrder(order: Order): WireOrder {
  if ((order.timing >> SIDE_BIT) & 1n) {
    throw new Error(
      "Order.timing must leave bit 101 clear — `side` is folded in by packOrder, not set by hand",
    );
  }
  if (order.timing >> RESERVED_FROM_BIT !== 0n) {
    throw new Error(
      "Order.timing must leave bit 105 and above clear — `expiry` is folded into bits [160:208) by packOrder",
    );
  }
  // The nonce bitmap is ONE space shared by two signed artifacts: orders, and the
  // `OrderSignerPermit` that nominates a delegated signer. The settler keeps them
  // apart by consuming a permit at `nonce | SIGNER_NONCE_NS` (bit 255), and every
  // fill reverts `OrderNonceReserved` on an order nonce with bit 255 set
  // (`Base._gateOrderPost`). This build-time guard catches the mistake earlier —
  // before a maker signs an order that could never fill. See
  // `NonceManager.SIGNER_NONCE_NS` and `docs/reference-audits.md` §F17/§F24.
  assertOrderNonce(order.nonce);
  // The two fields this function folds into bit positions must be in range, or
  // the fold writes a NEIGHBOURING flag: `side = 2` would set bit 102 (the BLOCK
  // clock) and read back as SELL, and an `expiry` above 2^48 would wrap into a
  // dead order — every sibling packer throws on overflow; these two silently did
  // not (F29 leads, encoder/interpreter drift class B4).
  if (order.side !== OrderSide.SELL && order.side !== OrderSide.BUY) {
    throw new Error(`packOrder: side must be SELL (0) or BUY (1), got ${order.side}`);
  }
  if (order.expiry < 0n || order.expiry >> 48n !== 0n) {
    throw new Error(`packOrder: expiry ${order.expiry} exceeds uint48`);
  }
  // A delta-verify order is fillable ONLY by its named `exclusiveFiller`, for its
  // whole life (the settler reverts `NotExclusiveFiller` otherwise): the balance
  // delta it measures cannot tell this fill's delivery from an inflow the maker paid
  // for elsewhere, so the maker must name who runs the callback. Zero and the
  // FILLER_SET sentinel can never equal a caller, so such an order would be signed
  // and never fill — refuse it here instead (re-audit 2026-09-25).
  if ((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) {
    const f = order.exclusiveFiller.toLowerCase();
    if (f === zeroAddress || f === FILLER_SET_SENTINEL) {
      throw new Error(
        "packOrder: a delta-verify order (timing bit 104) must name a single exclusiveFiller — only that filler can ever fill it",
      );
    }
  }
  assertInvariantConsideration(order);
  return {
    maker: order.maker,
    nonce: order.nonce,
    legsIn: packLegsIn(order.legsIn),
    legsOut: packLegsOut(order.legsOut),
    timing: order.timing | (BigInt(order.side) << SIDE_BIT) | (order.expiry << EXPIRY_OFFSET),
    exclusiveFiller: order.exclusiveFiller,
    minFillAnchor: order.minFillAnchor,
    params: packParams(
      order.exclusivityOverrideBps,
      order.gasBumpBps,
      order.gasPriceRef,
      order.priorityScale,
      order.baselinePriorityFeeWei ?? 0n,
    ),
    curve: packCurve(order.curve),
    items: packItems(order.items),
    validators: packValidators(order.validators),
    invariants: packValidators(order.invariants),
    fillModule: order.fillModule,
    fillTotal: order.fillTotal,
    pricingModule: order.pricingModule,
  };
}

/** Reads the packed blobs of {@link packOrder} back, front to back. */
class BlobReader {
  private i = 0;
  constructor(private readonly hex: string) {}
  private take(bytes: number): string {
    const s = this.hex.slice(this.i, this.i + bytes * 2);
    if (s.length !== bytes * 2) throw new Error("unpackOrder: packed blob too short");
    this.i += bytes * 2;
    return s;
  }
  int(bytes: number): bigint {
    return BigInt(`0x${this.take(bytes)}`);
  }
  addr(): Address {
    return getAddress(`0x${this.take(20)}`);
  }
  data(): Hex {
    return `0x${this.take(Number(this.int(2)))}`;
  }
  static all<T>(blob: Hex, one: (r: BlobReader) => T): T[] {
    const r = new BlobReader(blob.slice(2).toLowerCase());
    const out = Array.from({ length: Number(r.int(1)) }, () => one(r));
    if (r.i !== r.hex.length) throw new Error("unpackOrder: trailing bytes in packed blob");
    return out;
  }
}

const U48 = (1n << 48n) - 1n;

/**
 * Inverse of {@link packOrder}: the authoring {@link Order} behind a wire order, e.g.
 * one decoded from a fill transaction's calldata. `side` and `expiry` come back out
 * of `timing`; `baselinePriorityFeeWei` is set only when non-zero. Throws on a
 * malformed blob. `hashOrderStruct(unpackOrder(w))` is the wire order's hash.
 */
export function unpackOrder(w: WireOrder): Order {
  const p = unpackParams(w.params);
  return {
    maker: getAddress(w.maker),
    side: Number((w.timing >> SIDE_BIT) & 1n) as OrderSide,
    nonce: w.nonce,
    expiry: (w.timing >> EXPIRY_OFFSET) & U48,
    legsIn: BlobReader.all(w.legsIn, (r) => ({ token: r.addr(), start: r.int(32), end: r.int(32) })),
    legsOut: BlobReader.all(w.legsOut, (r) => ({ token: r.addr(), start: r.int(32), end: r.int(32), recipient: r.addr() })),
    timing: w.timing & ~(1n << SIDE_BIT) & ~(U48 << EXPIRY_OFFSET),
    exclusiveFiller: getAddress(w.exclusiveFiller),
    minFillAnchor: w.minFillAnchor,
    exclusivityOverrideBps: p.overrideBps,
    curve: BlobReader.all(w.curve, (r) => ({ timeDelta: Number(r.int(4)), bumpBps: Number(r.int(4)) })),
    gasBumpBps: p.gasBumpBps,
    gasPriceRef: p.gasPriceRef,
    priorityScale: p.priorityScale,
    ...(p.baselinePriorityFeeWei > 0n ? { baselinePriorityFeeWei: p.baselinePriorityFeeWei } : {}),
    items: BlobReader.all(w.items, (r) => ({ op: Number(r.int(1)) as ItemOp, module: r.addr(), amount: r.int(32), recipient: r.addr(), data: r.data() })),
    validators: BlobReader.all(w.validators, (r) => ({ target: r.addr(), data: r.data() })),
    invariants: BlobReader.all(w.invariants, (r) => ({ target: r.addr(), data: r.data() })),
    fillModule: getAddress(w.fillModule),
    fillTotal: w.fillTotal,
    pricingModule: getAddress(w.pricingModule),
  };
}

/**
 * Mirror of `SettlementLensChecks._consideration` (audit 2026-09-30 VAL-1.v2):
 * an order whose ONLY consideration is a post-execution invariant — no output
 * leg, or `SETTLE` items (which are not consideration) — proves an END STATE,
 * not delivery. If the maker obtains the asset any other way, ANY filler can
 * collect the maker's payment without delivering. Such an order is sound only
 * when a single named HARD `exclusiveFiller` (not 0, not the FILLER_SET
 * sentinel, no soft override) holds a window covering the order's whole life;
 * the shipped invariants enforce this on-chain too (`InvariantReceiptGuard`).
 * Applies to `fillTotal` orders as well. With NO output leg the settler enforces
 * the named-filler rule itself for ANY invariant (`Base._runInvariants`), so a
 * position item (MAKE/TAKE/TAKE_FOR) does not lift it there; beside an output
 * leg a position item still lifts the advisory SETTLE-hand-over case.
 */
export function assertInvariantConsideration(order: Order): void {
  if ((order.invariants ?? []).length === 0) return;
  const items = order.items ?? [];
  const settles = items.filter((it) => it.op === ItemOp.SETTLE).length;
  const positionItem = items.length !== settles;
  // With no output leg the CORE refuses every filler but the named one whenever an
  // invariant is present (`Base._runInvariants`, VAL-1), position items or not.
  if (order.legsOut.length !== 0 && (settles === 0 || positionItem)) return;
  const ex = order.exclusiveFiller.toLowerCase();
  const blockClock = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n;
  const end = BigInt(unpackTiming(order.timing).exclusivityEndTime);
  const lifelong = end >= (blockClock ? 0xffff_ffffn : order.expiry);
  if (ex === zeroAddress || ex === FILLER_SET_SENTINEL.toLowerCase() || order.exclusivityOverrideBps !== 0n || !lifelong) {
    throw new Error(
      "packOrder: invariant-only consideration needs a single hard exclusiveFiller for the order's life " +
        "(an invariant proves an end state, not delivery) — audit 2026-09-30 VAL-1",
    );
  }
}

import { numberToHex, type Hex } from "viem";
import { packParams } from "./types";
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
 * duration, [64:96) exclusivity end, [96:100) item policy, bit 100 fill-once.
 * Bit 101 and above must be clear — that space is this function's to write.
 */
export function packOrder(order: Order): WireOrder {
  if (order.timing >> SIDE_BIT !== 0n) {
    throw new Error(
      "Order.timing must leave bit 101 and above clear — `side` is folded in by packOrder, not set by hand",
    );
  }
  return {
    maker: order.maker,
    nonce: order.nonce,
    legsIn: packLegsIn(order.legsIn),
    legsOut: packLegsOut(order.legsOut),
    timing:
      order.timing |
      (BigInt(order.side) << SIDE_BIT) |
      (BigInt.asUintN(48, order.expiry) << EXPIRY_OFFSET),
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

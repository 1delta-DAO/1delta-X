import {
  OrderSide,
  hashOrderStruct,
  packTiming,
  randomOrderNonce as sdkRandomOrderNonce,
  withDeltaVerifyOutputs,
  type LegIn,
  type LegOut,
  type Order,
} from "@1delta-x/sdk";
import { parseUnits, zeroAddress, type Address, type Hex } from "viem";

import type { Side } from "./types";

export interface TokenSpec {
  address: Address;
  decimals: number;
}

export interface BuildOrderArgs {
  maker: Address;
  /** The app's side, always against the market's BASE. */
  side: Side;
  pay: TokenSpec;
  recv: TokenSpec;
  /** Human amount of the PAY token the ticket is worth. */
  amountIn: number;
  /** Best-case RECEIVE amount — the auction's starting ambition. */
  targetOut: number;
  /** Guaranteed RECEIVE amount — the auction's floor, or the limit price itself. */
  minOut: number;
  /** Seconds until the order expires. */
  ttlSeconds: number;
  /** Auction length in seconds. `0` signs fixed legs — a plain limit order. */
  decaySeconds: number;
  /**
   * The operator-gated solver to name as `exclusiveFiller`. When set, the order
   * uses DIRECT delivery (timing bit 104) and ONLY this filler can fill it; when
   * unset (zero / omitted), it signs plain pull delivery, fillable by anyone.
   */
  solver?: Address;
  /**
   * The most PAY wei this order may commit — the maker's raw balance, or its
   * share for one TWAP slice. The input leg never commits more than this (see
   * {@link inputWei}); when it binds, the OUTPUT legs are scaled by the same
   * ratio so the signed price never gets worse (G-TS_SIGN-7).
   */
  maxIn?: bigint;
  /** The maker's on-chain `minValidNonce`; a drawn nonce lands at or above it. */
  minValidNonce?: bigint;
  /** Injectable so tests and the golden-hash check can pin them. */
  nonce?: bigint;
  now?: number;
}

/**
 * A JS number as a plain decimal string, independent of the browser's locale.
 *
 * `Number.prototype.toString` is specified by ECMAScript, not by ICU: it is the
 * shortest round-trip form, always with `.` as the separator and ASCII digits.
 * The previous `toLocaleString("fullwide", …)` resolved to the HOST locale
 * ("fullwide" is not a locale), so a de/fr/es/pt-BR browser rendered `1,5` and
 * `parseUnits` threw during render, blanking the app (G-TS_SIGN-6). The only
 * thing `toString` does that `parseUnits` rejects is exponent notation
 * (`1e+21`, `1e-7`), which is expanded here by moving the decimal point.
 */
export function decimalString(n: number): string {
  if (!Number.isFinite(n)) throw new Error(`not a finite number: ${n}`);
  const s = String(Math.abs(n));
  const sign = n < 0 ? "-" : "";
  const m = /^(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(s);
  if (!m) return sign + s;
  const frac = m[2] ?? "";
  const digits = m[1]! + frac; // JS never renders a leading zero in an exponent mantissa
  const point = m[1]!.length + Number(m[3]); // position of the decimal point in `digits`
  if (point >= digits.length) return sign + digits + "0".repeat(point - digits.length);
  if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`;
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

/** Plain non-negative decimal: digits, at most one `.`, nothing else. */
const DECIMAL = /^(\d*)(?:\.(\d*))?$/;

/**
 * A human amount — a JS number or, exactly, a decimal string — to token wei.
 *
 * Precision beyond the token's own decimals is truncated rather than rounded
 * up: rounding up would sign away more input than the user typed. A STRING is
 * converted exactly, which is what an amount read from the chain (a balance,
 * "max") must use — a balance pushed through a double can come back larger
 * than it was (G-TS_SIGN-7). Locale-independent either way (G-TS_SIGN-6).
 */
export function toWei(amount: number | string, decimals: number): bigint {
  let text: string;
  if (typeof amount === "number") {
    if (!Number.isFinite(amount) || amount <= 0) return 0n;
    text = decimalString(amount);
  } else {
    text = amount.trim();
  }
  const m = DECIMAL.exec(text);
  if (!m || (!m[1] && !m[2])) return 0n;
  const whole = m[1] || "0";
  const truncated = (m[2] ?? "").slice(0, decimals);
  const wei = parseUnits(truncated ? `${whole}.${truncated}` : whole, decimals);
  return wei > 0n ? wei : 0n;
}

/**
 * The wei an input leg commits, never more than `maxIn` when it is known.
 *
 * `maxIn` is the maker's raw on-chain balance. A ticket's amount is a JS
 * number derived from that balance, and for 18-decimal tokens the double
 * rounds above the true balance about half the time — so "max" signed an
 * input the wallet does not hold and the order could never fill in full
 * (G-TS_SIGN-7). Clamping at the source balance makes "max" mean max.
 */
export function inputWei(amountIn: number | string, decimals: number, maxIn?: bigint): bigint {
  const wei = toWei(amountIn, decimals);
  return maxIn !== undefined && maxIn >= 0n && wei > maxIn ? maxIn : wei;
}

export interface InputClamp {
  /** The wei the ticket asked for. */
  raw: bigint;
  /** The wei actually committed: `min(raw, maxIn)`. */
  capped: bigint;
  /** True when `maxIn` bound, so the order's outputs must be scaled to match. */
  clamped: boolean;
}

/**
 * {@link inputWei}, plus whether the cap bound. Throws when the cap leaves
 * nothing to commit: an order with zero input cannot be scaled to the ticket's
 * price, so it is refused rather than signed.
 */
export function clampInput(amountIn: number | string, decimals: number, maxIn?: bigint): InputClamp {
  const raw = toWei(amountIn, decimals);
  const capped = inputWei(amountIn, decimals, maxIn);
  if (raw > 0n && capped === 0n) throw new Error("insufficient balance: nothing left to sign for this order");
  return { raw, capped, clamped: capped < raw };
}

function ceilDiv(a: bigint, b: bigint): bigint {
  return (a + b - 1n) / b;
}

/**
 * A random UNORDERED order nonce: uniform in `[minValid, 2^255)`.
 *
 * Bit 255 is reserved for delegated-signer permits (`SIGNER_NONCE_NS`), and the
 * SDK's `assertOrderNonce` — run inside `hashOrderStruct` — throws for any
 * nonce that has it set. Drawing a full 256 bits therefore broke half of all
 * tickets before the wallet prompt (G-TS_SIGN-3). `minValid` is the maker's
 * on-chain `minValidNonce` watermark: after a `rollbackNonces`, a draw below it
 * is dead on arrival, so the draw is shifted above it. Delegates to the SDK's
 * `randomOrderNonce` (exactly uniform, rejection-sampled).
 */
export function randomOrderNonce(minValid: bigint = 0n): bigint {
  return sdkRandomOrderNonce(minValid);
}

/** @deprecated kept for callers of the old name; draws a legal (< 2^255) order nonce. */
export function randomNonce(): bigint {
  return randomOrderNonce();
}

export interface OrderDraft {
  order: Order;
  /** Domain-independent struct hash — the contract's `filledAmountIn` key. */
  hash: Hex;
  /** True when `maxIn` bound and the order was scaled down to it (same price, smaller size). */
  clamped: boolean;
}

/**
 * Turn a ticket into the order the maker actually signs.
 *
 * The two sides are not mirror images. A SELL fixes what the maker gives and
 * lets the output decay: the maker names an ambition and a floor, and a filler
 * that acts early pays closer to the ambition. A BUY fixes what the maker gets
 * and lets the input rise, so the guaranteed amount is the OUTPUT leg. Getting
 * this backwards produces an order that hashes and signs perfectly and settles
 * for the wrong quantity.
 */
export function buildOrder(args: BuildOrderArgs): OrderDraft {
  const { maker, side, pay, recv, amountIn, targetOut, minOut, ttlSeconds, decaySeconds } = args;
  const now = args.now ?? Math.floor(Date.now() / 1000);
  const decaying = decaySeconds > 0 && targetOut > minOut;
  const cap = clampInput(amountIn, pay.decimals, args.maxIn);
  // When the cap binds, every output amount shrinks by the SAME ratio as the
  // input (rounded UP, so the maker's price is never worse than typed). Only
  // clamping the input would sign less for the same output — a strictly worse
  // limit price that, for a later TWAP slice, can never fill (G-TS_SIGN-7).
  const scaleOut = (out: bigint): bigint => (cap.clamped ? ceilDiv(out * cap.capped, cap.raw) : out);

  let legsIn: LegIn[];
  let legsOut: LegOut[];
  let sdkSide: OrderSide;

  if (side === "sell") {
    sdkSide = OrderSide.SELL;
    legsIn = [{ token: pay.address, start: cap.capped, end: 0n }];
    legsOut = [
      {
        token: recv.address,
        start: scaleOut(toWei(decaying ? targetOut : minOut, recv.decimals)),
        // `end == 0` is the fixed sentinel, not "decays to nothing".
        end: decaying ? scaleOut(toWei(minOut, recv.decimals)) : 0n,
        recipient: zeroAddress,
      },
    ];
  } else {
    sdkSide = OrderSide.BUY;
    // The maker is guaranteed `minOut` of the base; the quote spend rises toward
    // the ceiling they typed, so an early filler charges less than the maximum.
    const ceiling = cap.capped;
    const rawFloor = decaying ? inputWei(amountIn * (minOut / Math.max(targetOut, minOut)), pay.decimals, cap.raw) : cap.raw;
    // Scaled DOWN (floor division): a smaller spend never worsens a BUY.
    const floor = cap.clamped ? (rawFloor * cap.capped) / cap.raw : rawFloor;
    legsIn = [{ token: pay.address, start: floor, end: decaying && floor < ceiling ? ceiling : 0n }];
    legsOut = [
      { token: recv.address, start: scaleOut(toWei(minOut, recv.decimals)), end: 0n, recipient: zeroAddress },
    ];
  }

  const timing = decaying ? packTiming(now, decaySeconds, 0) : packTiming(0, 0, 0);
  const solver = args.solver ?? zeroAddress;
  const direct = solver !== zeroAddress;

  const order: Order = {
    maker,
    side: sdkSide,
    nonce: args.nonce ?? randomOrderNonce(args.minValidNonce ?? 0n),
    // Order EXPIRY — always unix seconds, and distinct from a Permit3 deadline,
    // which bounds a signature rather than the order.
    expiry: BigInt(now + ttlSeconds),
    legsIn,
    legsOut,
    // DIRECT DELIVERY (timing bit 104): the filler's route pays this maker
    // straight from the venue and the contract verifies the balance delta,
    // instead of pulling a nominal amount from the filler afterwards. Same
    // guarantee — the delta must cover the priced amount — but ~30k gas less
    // per fill for the solver, which on a gas-expensive chain is the difference
    // between a fill being worth racing for or not. Every order here is a plain
    // one-in/one-out swap, which is the shape the mode is defined for.
    //
    // ⚠ ONLY WITH A NAMED SOLVER. A balance delta cannot tell this fill's
    // delivery from an inflow the maker paid for elsewhere (their other open
    // order on another venue), so the settler lets ONLY the order's
    // `exclusiveFiller` fill a delta-verify order. We name our operator-gated
    // solver; without one configured we sign plain pull delivery, open to all.
    timing: direct ? withDeltaVerifyOutputs(timing) : timing,
    exclusiveFiller: direct ? solver : zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };

  return { order, hash: hashOrderStruct(order), clamped: cap.clamped };
}

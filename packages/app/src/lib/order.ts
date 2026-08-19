import {
  OrderSide,
  hashOrderStruct,
  packTiming,
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
  /** Injectable so tests and the golden-hash check can pin them. */
  nonce?: bigint;
  now?: number;
}

/**
 * A JS number to token wei.
 *
 * `toFixed` flips to exponential notation above 1e21 and `parseUnits` rejects
 * that, so the value is rendered wide first. Precision beyond the token's own
 * decimals is truncated rather than rounded up — rounding up would sign away
 * more input than the user typed.
 */
export function toWei(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n;
  const wide = amount.toLocaleString("fullwide", { useGrouping: false, maximumFractionDigits: 20 });
  const [whole, fraction = ""] = wide.split(".");
  const truncated = fraction.slice(0, decimals);
  return parseUnits(truncated ? `${whole}.${truncated}` : whole, decimals);
}

/** A 256-bit unordered nonce. Permit3's nonce book is a bitmap, so any word works. */
export function randomNonce(): bigint {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let out = 0n;
  for (const b of bytes) out = (out << 8n) | BigInt(b);
  return out;
}

export interface OrderDraft {
  order: Order;
  /** Domain-independent struct hash — the contract's `filledAmountIn` key. */
  hash: Hex;
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

  let legsIn: LegIn[];
  let legsOut: LegOut[];
  let sdkSide: OrderSide;

  if (side === "sell") {
    sdkSide = OrderSide.SELL;
    legsIn = [{ token: pay.address, start: toWei(amountIn, pay.decimals), end: 0n }];
    legsOut = [
      {
        token: recv.address,
        start: toWei(decaying ? targetOut : minOut, recv.decimals),
        // `end == 0` is the fixed sentinel, not "decays to nothing".
        end: decaying ? toWei(minOut, recv.decimals) : 0n,
        recipient: zeroAddress,
      },
    ];
  } else {
    sdkSide = OrderSide.BUY;
    // The maker is guaranteed `minOut` of the base; the quote spend rises toward
    // the ceiling they typed, so an early filler charges less than the maximum.
    const ceiling = toWei(amountIn, pay.decimals);
    const floor = decaying ? toWei(amountIn * (minOut / Math.max(targetOut, minOut)), pay.decimals) : ceiling;
    legsIn = [{ token: pay.address, start: floor, end: decaying && floor < ceiling ? ceiling : 0n }];
    legsOut = [
      { token: recv.address, start: toWei(minOut, recv.decimals), end: 0n, recipient: zeroAddress },
    ];
  }

  const order: Order = {
    maker,
    side: sdkSide,
    nonce: args.nonce ?? randomNonce(),
    // Order EXPIRY — always unix seconds, and distinct from a Permit3 deadline,
    // which bounds a signature rather than the order.
    expiry: BigInt(now + ttlSeconds),
    legsIn,
    legsOut,
    timing: decaying ? packTiming(now, decaySeconds, 0) : packTiming(0, 0, 0),
    exclusiveFiller: zeroAddress,
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

  return { order, hash: hashOrderStruct(order) };
}

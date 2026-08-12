import { hashStruct, hashTypedData, type Address, type Hex } from "viem";

import { settlementDomain } from "./eip712";
import { hashOrderStruct, type TypedDataSigner } from "./orders";
import type { Deployment, Order } from "./types";

/**
 * The signed soft cancel — a maker retracting its own orders from off-chain
 * books, for free.
 *
 * Why this exists next to four on-chain cancels
 * ─────────────────────────────────────────────
 * The settlement already offers `cancelOrder` (one order, by hash),
 * `cancelOrders` (by nonce), `invalidateNonceWord` (256 at once) and
 * `rollbackNonces` (a watermark). All four are AUTHORITATIVE — they bind every
 * filler, forever — and all four cost a transaction. In a permissionless system
 * that price is not an accident: an order is fillable by anyone, so the only way
 * to make it un-fillable *for everyone* is to write that fact where everyone
 * looks.
 *
 * A quoting UI cancels constantly — a market maker re-prices, a user edits a
 * limit price — and almost none of those cancels need to bind a filler that
 * already has the order. They need to stop the order being SERVED. That is what
 * this message is: a maker-authenticated instruction to every book holding the
 * order to drop it. Free, instant, and gossipable.
 *
 * ⚠ ADVISORY, NOT AUTHORITATIVE. A soft cancel does not stop a filler that
 * already holds the signed order and chooses to submit it, and it cannot: no
 * off-chain message can. Anything that MUST NOT fill needs an on-chain cancel.
 * The honest framing is that the two are complements — soft cancel for the
 * hundreds of routine retractions, hard cancel for the one that matters.
 *
 * Why EIP-712 rather than a `personal_sign` string
 * ────────────────────────────────────────────────
 * The domain is the Settlement's own — same `name`/`version`/`chainId`/
 * `verifyingContract` as an `Order` — so a cancel signed for one deployment can
 * never be replayed against another chain or another settlement, and the wallet
 * renders named fields instead of an opaque 32-byte blob. It also means the
 * SAME signer set the settlement accepts for an order verifies a cancel:
 * EOA → EIP-1271 contract maker → maker-nominated delegate.
 *
 * `maker` is carried explicitly (not inferred from the order) so a book can
 * verify a cancel for an order it has never seen — cancels routinely arrive
 * before, or without, the order they retract.
 */
export interface SoftCancel {
  maker: Address;
  /** The orders being retracted. Batched so one signature retires a whole quote set. */
  orderHashes: readonly Hex[];
  /** Unix seconds. Orders a maker's own cancels; the newest wins on replace. */
  issuedAt: bigint;
  /**
   * Unix seconds after which a node should ignore this message. Replay of a
   * cancel is harmless (eviction is idempotent and monotonic), but a bound keeps
   * ancient gossip from re-evicting a hash a maker has since re-signed.
   */
  expiry: bigint;
}

export const SOFT_CANCEL_TYPE = [
  { name: "maker", type: "address" },
  { name: "orderHashes", type: "bytes32[]" },
  { name: "issuedAt", type: "uint256" },
  { name: "expiry", type: "uint256" },
] as const;

export const SOFT_CANCEL_TYPES = { SoftCancel: SOFT_CANCEL_TYPE } as const;

/**
 * The literal typestring for `SoftCancel`. Nothing on-chain hashes it today —
 * the message is off-chain only — but it is pinned here for the same reason
 * {@link ORDER_TYPESTRING} is: a non-TS verifier (a Rust/Go Waku node) needs the
 * canonical string, and a field added to {@link SOFT_CANCEL_TYPE} without
 * updating it is caught by a test rather than by a silently-diverging signature.
 */
export const SOFT_CANCEL_TYPESTRING =
  "SoftCancel(address maker,bytes32[] orderHashes,uint256 issuedAt,uint256 expiry)";

/** EIP-712 payload for signing a soft cancel (Settlement domain). */
export function softCancelTypedData(cancel: SoftCancel, d: Deployment) {
  return {
    domain: settlementDomain(d.chainId, d.settlement),
    types: SOFT_CANCEL_TYPES,
    primaryType: "SoftCancel" as const,
    message: {
      maker: cancel.maker,
      orderHashes: [...cancel.orderHashes],
      issuedAt: cancel.issuedAt,
      expiry: cancel.expiry,
    },
  };
}

/** Domain-independent struct hash — the dedup key for a cancel on the wire. */
export function hashSoftCancelStruct(cancel: SoftCancel): Hex {
  return hashStruct({
    data: {
      maker: cancel.maker,
      orderHashes: [...cancel.orderHashes],
      issuedAt: cancel.issuedAt,
      expiry: cancel.expiry,
    },
    primaryType: "SoftCancel",
    types: SOFT_CANCEL_TYPES,
  } as never);
}

/** Full EIP-712 digest the maker signs. */
export function softCancelDigest(cancel: SoftCancel, d: Deployment): Hex {
  return hashTypedData(softCancelTypedData(cancel, d) as never);
}

/** Default validity window for a soft cancel, in seconds. */
export const SOFT_CANCEL_TTL_SECONDS = 300n;

/**
 * Build a soft cancel over orders or raw hashes. `now` is injectable so a
 * caller can pin the clock (tests, or a signer whose host clock is skewed).
 */
export function buildSoftCancel(
  maker: Address,
  orders: readonly (Order | Hex)[],
  opts?: { now?: bigint; ttlSeconds?: bigint },
): SoftCancel {
  const now = opts?.now ?? BigInt(Math.floor(Date.now() / 1000));
  const ttl = opts?.ttlSeconds ?? SOFT_CANCEL_TTL_SECONDS;
  return {
    maker,
    orderHashes: orders.map((o) => (typeof o === "string" ? o : hashOrderStruct(o))),
    issuedAt: now,
    expiry: now + ttl,
  };
}

/** Sign a soft cancel (maker, a nominated delegate, or a contract wallet). */
export function signSoftCancel(signer: TypedDataSigner, cancel: SoftCancel, d: Deployment): Promise<Hex> {
  return signer.signTypedData(softCancelTypedData(cancel, d));
}

/** Build + sign in one step — the shape a UI's "cancel" button wants. */
export async function softCancelOrders(
  signer: TypedDataSigner,
  maker: Address,
  orders: readonly (Order | Hex)[],
  d: Deployment,
  opts?: { now?: bigint; ttlSeconds?: bigint },
): Promise<{ cancel: SoftCancel; sig: Hex }> {
  const cancel = buildSoftCancel(maker, orders, opts);
  return { cancel, sig: await signSoftCancel(signer, cancel, d) };
}

import type { Hex } from "viem";

import { hashOrderStruct, signOrder, type TypedDataSigner } from "./orders";
import { buildSoftCancel, signSoftCancel, type SoftCancel } from "./softcancel";
import type { Deployment, Order } from "./types";

/**
 * Cancel-and-replace — "amend" as one operation.
 *
 * A signed order is immutable: changing a limit price, a size, an expiry or a
 * decay curve changes the EIP-712 hash, so there is no such thing as editing one
 * in place. What a trading UI actually wants is nonetheless a single gesture —
 * *this order, but at a different price* — and the honest primitive underneath
 * it is: sign a new order, retract the old one, and keep the two associated so a
 * book can present them as one lineage rather than as an unrelated add and
 * remove.
 *
 * {@link amendOrder} is that gesture. It produces:
 *
 *   • `order` — the replacement, on a FRESH nonce (see below),
 *   • `sig`   — the maker's signature over it,
 *   • `cancel` + `cancelSig` — a signed {@link SoftCancel} retracting the
 *     previous hash,
 *   • `replaces` — the previous order hash, so the book can emit one REPLACE
 *     rather than a remove followed by an add.
 *
 * Why a fresh nonce, and what that costs
 * ──────────────────────────────────────
 * Reusing the previous order's nonce is tempting — it would make the on-chain
 * hard cancel of one retire both. It is also wrong for the common case: nonce
 * cancellation is retroactive and total, so a partially-filled predecessor and
 * its replacement would share a single kill switch, and cancelling the amended
 * order would also invalidate the fills the predecessor is still owed. A fresh
 * nonce keeps the two orders independent on-chain, which is what "replace"
 * means everywhere else.
 *
 * The consequence is stated plainly: after an amend, the OLD order is retracted
 * only from books that honour the soft cancel. A filler that already holds it
 * can still submit it until its expiry. When that is unacceptable — a real
 * re-price in a fast market, not a cosmetic edit — pair the amend with an
 * on-chain `cancelOrder(prev)` (one order, by hash, leaving nonce siblings
 * alone) via {@link encodeCancelOrder}. {@link amendOrder} deliberately does not
 * decide that for the caller; it returns `replaces` so the caller can.
 *
 * Alternatively, sign the pair as an OCO group (`docs/oco.md`) — then the
 * predecessor is retired ON-CHAIN by the replacement's first fill, with no
 * transaction and no trust in any book.
 */
export interface AmendResult {
  /** The replacement order (fresh nonce, patched fields). */
  order: Order;
  /** Maker signature over `order`. */
  sig: Hex;
  /** Hash of `order` — the new id. */
  orderHash: Hex;
  /** Hash of the order being replaced — the previous id. */
  replaces: Hex;
  /** Signed retraction of `replaces`. */
  cancel: SoftCancel;
  cancelSig: Hex;
}

/**
 * The fields an amend may change. Everything else is inherited verbatim from the
 * previous order, so an amend is a diff rather than a re-authoring.
 *
 * `maker` is deliberately absent: an amend re-prices an order, it never re-homes
 * it. Sign a new order for that.
 */
export type OrderPatch = Partial<Omit<Order, "maker" | "nonce">> & { nonce?: bigint };

/**
 * Apply `patch` to `prev` on a fresh nonce. Pure — no signing, no clock.
 * Exposed separately so a caller can inspect (or price-preview) the replacement
 * before asking a wallet to sign it.
 *
 * `nextNonce` is required rather than derived: nonce allocation is the caller's
 * book-keeping (a desk numbering sequentially, a UI drawing random 256-bit
 * values), and silently guessing `prev.nonce + 1` would collide the moment two
 * amends race.
 */
export function patchOrder(prev: Order, nextNonce: bigint, patch: OrderPatch = {}): Order {
  return { ...prev, ...patch, maker: prev.maker, nonce: patch.nonce ?? nextNonce };
}

/**
 * Build, sign, and pair a replacement with the retraction of its predecessor.
 *
 * Two signature prompts, not one: the wallet shows the new order (which the
 * maker must actually read) and the cancel. There is no way to collapse them
 * without asking the maker to authorize an order and a retraction under a single
 * opaque digest, which is exactly the confusion EIP-712 exists to prevent.
 */
export async function amendOrder(
  signer: TypedDataSigner,
  prev: Order,
  nextNonce: bigint,
  patch: OrderPatch,
  d: Deployment,
  opts?: { now?: bigint; ttlSeconds?: bigint },
): Promise<AmendResult> {
  const replaces = hashOrderStruct(prev);
  const order = patchOrder(prev, nextNonce, patch);
  const orderHash = hashOrderStruct(order);
  if (orderHash === replaces) throw new Error("amendOrder: patch is a no-op (identical order hash)");

  const sig = await signOrder(signer, order, d);
  const cancel = buildSoftCancel(prev.maker, [replaces], opts);
  const cancelSig = await signSoftCancel(signer, cancel, d);

  return { order, sig, orderHash, replaces, cancel, cancelSig };
}

import type { Hex } from "viem";

import { hashOrderStruct, signOrder, type TypedDataSigner } from "./orders";
import { isFillOnce, renonceOcoItems } from "./oco";
import { buildSoftCancel, signSoftCancel, type SoftCancel } from "./softcancel";
import { assertOrderNonce, type Deployment, type Order } from "./types";

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
 *   • `order` — the replacement, on a FRESH nonce (a fill-once order keeps its
 *     nonce — see below),
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
 * means everywhere else. So for an ordinary order the fresh nonce is ENFORCED:
 * {@link patchOrder} throws when the replacement would reuse `prev.nonce`. Two
 * same-nonce orders also share an `OcoGroupModule` claim slot, so a reused nonce
 * lets predecessor AND replacement both fill despite the group (audit 2026-09-30,
 * PRICE-5).
 *
 * The one exception: FILL-ONCE orders (timing bit 100)
 * ───────────────────────────────────────────────────
 * A fill-once order cannot be partially filled, so the kill-switch argument above
 * does not apply — and a fill-once order is usually a leg of a zero-contract
 * {@link ocoNonceGroup} bracket, which is held together by NOTHING BUT the shared
 * nonce. A replacement on a fresh nonce silently leaves the bracket, and then a
 * sibling and the replacement can both fill (audit 2026-09-30, G-TS_SIGN-2). So a
 * fill-once replacement KEEPS `prev.nonce`: it stays in the bracket, and the first
 * full fill of ANY member — predecessor, replacement or sibling — consumes the
 * nonce and retires the rest on-chain, with no transaction and no trust in a
 * book. Pass `nextNonce = prev.nonce`; a different nonce throws unless you opt
 * out explicitly with `{ leaveNonceGroup: true }`.
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
 * transaction and no trust in any book. For an `OcoGroupModule` leg that needs
 * the fresh nonce this function enforces (the claim item is re-homed for you);
 * for a shared-nonce leg it needs the SAME nonce, which is the fill-once rule above.
 */
export interface AmendResult {
  /** The replacement order (patched fields; fresh nonce, or `prev.nonce` for a fill-once order). */
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

/** Options for {@link patchOrder} / {@link amendOrder}. */
export interface AmendOptions {
  /**
   * FILL-ONCE predecessors only: move the replacement to the fresh `nextNonce`
   * anyway, deliberately taking it OUT of any shared-nonce bracket it was in. Both
   * the replacement and a former sibling can then fill.
   */
  leaveNonceGroup?: boolean;
}

/**
 * Apply `patch` to `prev`. Pure — no signing, no clock. Exposed separately so a
 * caller can inspect (or price-preview) the replacement before asking a wallet to
 * sign it.
 *
 * Nonce rule (see the module header):
 *   • ordinary order — the replacement MUST take a fresh nonce; `nextNonce` (or
 *     `patch.nonce`) equal to `prev.nonce` throws;
 *   • fill-once order — the replacement KEEPS `prev.nonce` so it stays in its
 *     shared-nonce bracket; a different nonce throws unless
 *     `opts.leaveNonceGroup` is set.
 *
 * `nextNonce` is required rather than derived: nonce allocation is the caller's
 * book-keeping (a desk numbering sequentially, a UI drawing random values with
 * {@link randomOrderNonce} — order nonces must stay below 2^255, the settler
 * reverts `OrderNonceReserved` otherwise), and silently guessing `prev.nonce + 1`
 * would collide the moment two amends race.
 */
export function patchOrder(prev: Order, nextNonce: bigint, patch: OrderPatch = {}, opts: AmendOptions = {}): Order {
  const requested = patch.nonce ?? nextNonce;
  let nonce: bigint;
  if (isFillOnce(prev) && !opts.leaveNonceGroup) {
    if (requested !== prev.nonce) {
      throw new Error(
        `patchOrder: prev is FILL-ONCE (timing bit 100) — likely a shared-nonce OCO leg — so the replacement keeps ` +
          `nonce ${prev.nonce} to stay in its bracket. Pass nextNonce = prev.nonce, or { leaveNonceGroup: true } ` +
          `to deliberately leave the group (siblings and the replacement could then both fill).`,
      );
    }
    nonce = prev.nonce;
  } else {
    if (requested === prev.nonce) {
      throw new Error(
        `patchOrder: the replacement must carry a FRESH nonce, not prev.nonce ${prev.nonce} — two same-nonce orders ` +
          `share one OcoGroupModule claim slot and one kill switch, so predecessor and replacement could both fill.`,
      );
    }
    nonce = assertOrderNonce(requested);
  }
  // An OCO claim item names the order's nonce a second time; carrying the
  // predecessor's copy onto the replacement is exactly the cancel-and-replace
  // shape that revived a soft-cancelled leg (F29 finding 3). Re-home it unless
  // the patch supplies its own items.
  const items = patch.items ?? renonceOcoItems(prev.items, prev.nonce, nonce);
  return { ...prev, ...patch, items, maker: prev.maker, nonce };
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
  opts?: { now?: bigint; ttlSeconds?: bigint } & AmendOptions,
): Promise<AmendResult> {
  const replaces = hashOrderStruct(prev);
  const order = patchOrder(prev, nextNonce, patch, { leaveNonceGroup: opts?.leaveNonceGroup });
  const orderHash = hashOrderStruct(order);
  if (orderHash === replaces) throw new Error("amendOrder: patch is a no-op (identical order hash)");

  const sig = await signOrder(signer, order, d);
  const cancel = buildSoftCancel(prev.maker, [replaces], opts);
  const cancelSig = await signSoftCancel(signer, cancel, d);

  return { order, sig, orderHash, replaces, cancel, cancelSig };
}

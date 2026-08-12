import type { Order, PermitBatch, SoftCancel } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

/**
 * A signed order in flight — the self-authenticating transport unit. `(order,
 * sig)` verifies against the Settlement EIP-712 domain with zero trust in
 * whoever relayed it (see `docs/waku-orderbook.md`).
 */
export interface OrderAnnounce {
  order: Order;
  /** Maker's EIP-712 order signature. Empty (`0x`) when `sigless`. */
  sig: Hex;
  /** Optional single-signature `fillWithPermit` allowances. */
  permitBatch?: PermitBatch;
  /** On-chain `approveOrder` path — the maker cannot ECDSA-sign (rare). */
  sigless?: boolean;
}

/**
 * Maker-signed soft cancel — the free retraction, and the counterpart to the
 * settlement's four on-chain cancels.
 *
 * `sig` is an EIP-712 signature over the SDK's `SoftCancel` struct in the
 * SETTLEMENT domain (`chainId` + `verifyingContract`), so a cancel is bound to
 * one deployment and cannot be replayed onto another chain — the same property
 * the order signature has, obtained the same way. It also means the same signer
 * set verifies: an EOA maker, an EIP-1271 contract maker, or a maker-nominated
 * delegate (`setOrderSigner`).
 *
 * ⚠ ADVISORY. A soft cancel evicts an order from the books that honour it; it
 * does NOT bind a filler that already holds the signed order. Anything that must
 * not fill needs `cancelOrder` / `cancelOrders` / `invalidateNonceWord` /
 * `rollbackNonces` on-chain. Spec: `docs/soft-cancel.md`.
 */
export interface SignedSoftCancel {
  cancel: SoftCancel;
  /** EIP-712 signature by the maker, a delegate, or the maker contract (1271). */
  sig: Hex;
}

/**
 * Cancel-and-replace as ONE message: retract `replaces` and admit `announce`
 * together, so a book emits a single replace instead of a remove racing an add.
 *
 * Both halves are independently self-authenticating — the announce carries the
 * maker's order signature, the cancel carries the maker's cancel signature — so
 * a relay can neither forge a replacement nor strip the retraction and leave two
 * live orders. A node that fails to verify either half applies NEITHER.
 *
 * The replacement always carries a FRESH nonce (see the SDK's `amendOrder`), so
 * the two orders stay independent on-chain: cancelling the replacement does not
 * retroactively invalidate fills the predecessor already earned.
 */
export interface OrderReplace {
  /** Retraction of the previous order; its `orderHashes` must contain `replaces`. */
  cancel: SignedSoftCancel;
  /** The replacement order. */
  announce: OrderAnnounce;
  /** Hash of the order being replaced — the previous id in this lineage. */
  replaces: Hex;
}

/** Advisory "I'm taking this" hint. `filled[orderHash]` on-chain is authoritative. */
export interface FillNotice {
  orderHash: Hex;
  filler: Address;
}

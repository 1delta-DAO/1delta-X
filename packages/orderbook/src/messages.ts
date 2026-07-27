import type { Order, PermitBatch } from "@1delta-x/sdk";
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
 * Maker-signed soft cancel. `makerSig` is an EIP-191 signature over the 32-byte
 * `orderHash`; an unsigned or mis-signed cancel is dropped, so a maker can only
 * evict its own orders. The hard cancel (on-chain nonce) stays ground truth.
 */
export interface OrderSoftCancel {
  orderHash: Hex;
  makerSig: Hex;
}

/** Advisory "I'm taking this" hint. `filled[orderHash]` on-chain is authoritative. */
export interface FillNotice {
  orderHash: Hex;
  filler: Address;
}

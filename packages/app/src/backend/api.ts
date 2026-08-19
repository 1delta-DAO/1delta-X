import type { Deployment, Order, SoftCancel } from "@1delta-x/sdk";
import type { Hex } from "viem";

import type { Fill, RestingOrder, Side, Source } from "../lib/types";

/**
 * The maker-signed artefact the book actually distributes. `hash` is the SDK's
 * domain-independent struct hash — the contract's `filledAmountIn` key — so it
 * identifies the order whether or not a Settlement exists to fill it.
 */
export interface SignedOrder {
  order: Order;
  sig: Hex;
  hash: Hex;
  /** The EIP-712 domain the signature is bound to. */
  deployment: Deployment;
  /** False when no Settlement is deployed on this chain: the signature is real, but no filler can use it. */
  deployed: boolean;
}

/** Maker-signed retraction. Advisory — it evicts from books that honour it. */
export interface SignedCancel {
  cancel: SoftCancel;
  sig: Hex;
}

export interface PlaceOrderRequest {
  marketId: string;
  side: Side;
  type: "limit" | "twap";
  /** BASE amount to work. */
  size: number;
  price: number;
  ttlMs: number;
  slices?: { total: number; everyMin: number };
  /** The signed order this ticket produced. Absent only if signing was skipped. */
  signed?: SignedOrder;
}

export interface RecordTakeRequest {
  marketId: string;
  side: Side;
  /** BASE amount that crossed. */
  size: number;
  price: number;
  /** BASE consumed per source, so a fill row can name where it came from. */
  bySource: Record<Source, number>;
}

/** What a market looks like right now, fed back in from the live pool ladder. */
export interface MarketObservation {
  marketId: string;
  mid: number;
  tick: number;
  /** One rung of the pool's price grid — seeded orders are placed in these units. */
  step: number;
  /** Cumulative pool depth in BASE, used to size seeded resting orders. */
  depth: number;
}

/**
 * The seam between the UI and order distribution.
 *
 * Everything below the interface is synchronous reads plus a change
 * notification, which is exactly the shape `@1delta-x/orderbook`'s `Book`
 * exposes (an in-memory map with add/remove listeners). Swapping the mock for a
 * real client — a REST/WS session against `@1delta-x/orderbook-server`, or a
 * Waku transport — is an implementation of this interface, not a UI change.
 */
export interface OrderbookApi {
  /** Live resting orders, newest first. */
  orders(marketId?: string): RestingOrder[];
  /** Settled fills, newest first. */
  fills(marketId?: string): Fill[];
  /** Called on any change to either list. Returns an unsubscribe. */
  subscribe(listener: () => void): () => void;
  /** Sign and broadcast. Resolves once the book has admitted the order. */
  place(req: PlaceOrderRequest): Promise<RestingOrder>;
  /**
   * Free retraction — the soft cancel, no transaction. The signed message is
   * what a real book verifies before evicting; passing it keeps this call site
   * the shape a transport-backed client already needs.
   */
  cancel(orderHash: string, signed?: SignedCancel): Promise<void>;
  /** Record an order that crossed immediately and never rested. */
  recordTake(req: RecordTakeRequest): void;
  /** Feed the current market state in; drives expiry and fill progress. */
  observe(obs: MarketObservation): void;
}

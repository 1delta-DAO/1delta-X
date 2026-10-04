import type { Deployment, Order, SoftCancel } from "@1delta-x/sdk";
import type { Hex } from "viem";

import type { Fill, RestingOrder, Side, SliceSpec, Source } from "../lib/types";

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
  /** For a TWAP: what each later slice signs. */
  sliceSpec?: SliceSpec;
  /** BASE amount of this signed order that already crossed the book when it was placed. */
  filled?: number;
  /**
   * The signed order this ticket produced. REQUIRED: the book only ever holds
   * orders a maker signed, so nothing can be shown as resting — or as filling —
   * that no signature backs (G-TS_SIGN-15).
   */
  signed: SignedOrder;
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
 * `backend/book.ts` picks one: `RemoteOrderbook` when `VITE_ORDERBOOK_URL` is
 * set, else `MockOrderbook`.
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
   * Soft cancel: a SIGNED off-chain retraction, no transaction. It is advisory
   * — a book that honours it stops distributing the order, but the order's
   * signature stays valid on-chain until expiry, so anyone already holding it
   * can still fill it. The signature is therefore required (an unsigned
   * "cancel" proves nothing to a real book), and the row is kept and marked
   * `cancelled: "soft"` rather than evicted (G-TS_SIGN-4). Only an on-chain
   * cancel makes the order unfillable — see `confirmHardCancel`.
   */
  cancel(orderHash: string, signed: SignedCancel): Promise<void>;
  /** Drop a row whose orders were cancelled ON-CHAIN (the transaction is mined). */
  confirmHardCancel(orderHash: string): void;
  /**
   * Attach a newly signed TWAP slice to its row; only signed slices can fill.
   * A real book POSTs the slice first and rejects (throws) when the server does.
   */
  addSlice(orderHash: string, signed: SignedOrder): void | Promise<void>;
  /**
   * Record the part of a SIGNED order that crossed immediately. Mock fills are
   * `simulated`; a real book ignores this — the crossing part fills when a real
   * filler fills the signed order, and is shown then.
   */
  recordTake(req: RecordTakeRequest): void;
  /** Feed the current market state in; drives expiry and fill progress. */
  observe(obs: MarketObservation): void;
  /**
   * Re-load what the book already holds for this maker — their live resting
   * orders and indexed fills — so a page reload does not forget them. A real
   * book reads `GET /orders?maker=` and `GET /fills?maker=`; the mock has
   * nothing to restore. Idempotent per maker.
   */
  restore?(maker: `0x${string}`): Promise<void>;
}

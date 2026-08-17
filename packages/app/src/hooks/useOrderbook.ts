import { useMemo, useSyncExternalStore } from "react";

import { orderbook } from "../backend/mock";
import type { Fill, RestingOrder } from "../lib/types";

/**
 * The book is an external mutable store, so subscribe to it rather than
 * mirroring it into component state — every consumer then sees the same
 * snapshot, and swapping the mock for a transport-backed client of the same
 * interface changes nothing here.
 *
 * `useSyncExternalStore` compares snapshots by identity, so the arrays must be
 * stable between notifications. One cache holds the whole book and is rebuilt
 * only when the book actually changes; per-market views are memoised in the
 * components, which keeps this cache single-keyed and impossible to thrash.
 */
interface Snapshot {
  orders: RestingOrder[];
  fills: Fill[];
}

let snapshot: Snapshot = { orders: orderbook.orders(), fills: orderbook.fills() };

orderbook.subscribe(() => {
  snapshot = { orders: orderbook.orders(), fills: orderbook.fills() };
});

const subscribe = (cb: () => void) => orderbook.subscribe(cb);
const getSnapshot = () => snapshot;

export function useBookSnapshot(): Snapshot {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export function useRestingOrders(marketId?: string): RestingOrder[] {
  const { orders } = useBookSnapshot();
  return useMemo(
    () => (marketId ? orders.filter((o) => o.marketId === marketId) : orders),
    [orders, marketId],
  );
}

export function useFills(marketId?: string): Fill[] {
  const { fills } = useBookSnapshot();
  return useMemo(
    () => (marketId ? fills.filter((f) => f.marketId === marketId) : fills),
    [fills, marketId],
  );
}

import type { OrderbookApi } from "./api";
import { MockOrderbook } from "./mock";
import { deploymentFor } from "../config/deployments";
import { RemoteOrderbook } from "./remote";
import { rowResolver } from "./restore";

/**
 * Which order distribution this build talks to.
 *
 *   VITE_ORDERBOOK_URL=https://book.example      (or a same-origin path, e.g. /api/book)
 *
 * Set: signed orders and soft cancels are POSTED to that
 * `@1delta-x/orderbook-server`, and the maker's rows follow what the server
 * reports from the chain — nothing is simulated. Unset: the in-browser
 * {@link MockOrderbook}, which broadcasts nothing and flags every fill it
 * produces `simulated`.
 */
export function orderbookUrl(raw: string | undefined): string | null {
  const url = raw?.trim().replace(/\/+$/, "");
  return url ? url : null;
}

export const ORDERBOOK_URL = orderbookUrl(import.meta.env.VITE_ORDERBOOK_URL);

/** True when orders go to a real orderbook server rather than the in-browser mock. */
export const BOOK_IS_REMOTE = ORDERBOOK_URL !== null;

/** One book per tab. */
export const orderbook: OrderbookApi = ORDERBOOK_URL
  ? new RemoteOrderbook({ baseUrl: ORDERBOOK_URL, resolveRow: rowResolver(deploymentFor) })
  : new MockOrderbook();

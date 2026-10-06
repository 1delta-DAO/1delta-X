import { hashOrderStruct, orderFromJson, type Order } from "@1delta-x/sdk";
import type { Hex } from "viem";

/**
 * One order as the filler sees it — the shape `Filler.consider` takes. It used
 * to be `@1delta-x/orderbook`'s `BookEntry` from a verified `Book` over the
 * protobuf `HttpTransport`; the Worker orderbook speaks JSON only, and the
 * filler re-checks every order on the lens (`previewFill` + simulation) before
 * it sends anything, so the Book's own Layer 1/2 verification was redundant.
 */
export interface BookEntry {
  orderHash: Hex;
  announce: { order: Order; sig: Hex; permitBatch?: unknown; sigless?: boolean };
  /** The book's last lens reading. `fillableAmount` sizes the first preview. */
  state?: { ok: boolean; status: string; fillableAmount: bigint; validatorsPass: boolean };
  /** When the book first took the order (unix seconds), if it says: never-seen orders are evaluated oldest first. */
  addedAt?: number;
}

type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

export interface IntakeResult {
  entries: BookEntry[];
  /** Items dropped: unparseable, wrong hash, or not fillable for us. */
  skipped: number;
}

/** Pages of `GET /orders?limit=500` per poll, at most (default). */
const MAX_PAGES = 20;
const PAGE_SIZE = 500;

export interface IntakeOptions {
  /** Pages per poll, at most (default 20). */
  maxPages?: number;
  /** `limit` per page (default 500, the book's maximum). */
  pageSize?: number;
  /** Extra request headers (the Worker's service-binding key). */
  headers?: Record<string, string>;
}

/**
 * Poll the orderbook's `GET /orders` (JSON) — every live order, paged by keyset
 * cursor. Each order is parsed STRICTLY (the SDK's `orderFromJson`) and must hash
 * to the `orderHash` the node gave; the node's state is advisory only (the
 * filler previews on the lens anyway) but an order the node itself reports as
 * unfillable — not `ok`, or validators failing for the open filler — is dropped,
 * as the old `Book({ evictWhen: !ok || !validatorsPass })` did.
 */
export async function fetchOrders(baseUrl: string, doFetch: FetchLike = fetch, opts: IntakeOptions = {}): Promise<IntakeResult> {
  const entries: BookEntry[] = [];
  let skipped = 0;
  let cursor: string | undefined;
  const maxPages = opts.maxPages ?? MAX_PAGES;
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  for (let page = 0; page < maxPages; page++) {
    const url = `${baseUrl.replace(/\/+$/, "")}/orders?limit=${pageSize}&fillableOnly=true${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
    const res = await doFetch(url, { headers: { accept: "application/json", ...(opts.headers ?? {}) } });
    if (!res.ok) throw new Error(`orderbook answered ${res.status} for GET /orders`);
    const body = (await res.json()) as { orders?: unknown[]; nextCursor?: unknown };
    for (const raw of body.orders ?? []) {
      const e = toEntry(raw);
      if (e) entries.push(e);
      else skipped++;
    }
    cursor = typeof body.nextCursor === "string" ? body.nextCursor : undefined;
    if (!cursor) break;
  }
  return { entries, skipped };
}

function toEntry(raw: unknown): BookEntry | undefined {
  const item = raw as { orderHash?: unknown; order?: unknown; sig?: unknown; state?: unknown; addedAt?: unknown };
  let order: Order;
  try {
    order = orderFromJson(item?.order);
  } catch {
    return undefined;
  }
  const orderHash = hashOrderStruct(order);
  if (typeof item.orderHash !== "string" || item.orderHash.toLowerCase() !== orderHash.toLowerCase()) return undefined;
  if (typeof item.sig !== "string" || !/^0x(?:[0-9a-fA-F]{2})+$/.test(item.sig)) return undefined;
  const s = item.state as { ok?: unknown; status?: unknown; fillableAmount?: unknown; validatorsPass?: unknown } | null | undefined;
  if (!s || s.ok !== true || s.validatorsPass !== true || typeof s.fillableAmount !== "string" || !/^\d+$/.test(s.fillableAmount)) return undefined;
  return {
    orderHash,
    announce: { order, sig: item.sig as Hex },
    state: { ok: true, status: String(s.status ?? "Fillable"), fillableAmount: BigInt(s.fillableAmount), validatorsPass: true },
    ...(typeof item.addedAt === "number" && Number.isFinite(item.addedAt) ? { addedAt: item.addedAt } : {}),
  };
}

/**
 * One order from a local JSON file — `{order, sig, fillAmount?}` with the order in
 * the SDK's strict JSON form (`orderToJson`). For operator smoke tests and the fork
 * e2e: it bypasses the book, so the fillable amount defaults to the whole order
 * (`fillTotal`, else the anchor leg: `legsIn[0]` for SELL, `legsOut[0]` for BUY).
 */
export function entryFromJson(raw: unknown): BookEntry {
  const item = raw as { order?: unknown; sig?: unknown; fillAmount?: unknown };
  const order = orderFromJson(item?.order);
  if (typeof item.sig !== "string" || !/^0x(?:[0-9a-fA-F]{2})*$/.test(item.sig)) throw new Error("sig: expected 0x hex");
  const anchor = order.fillTotal !== 0n ? order.fillTotal : order.side === 0 ? order.legsIn[0]!.start : order.legsOut[0]!.start;
  const fillableAmount =
    typeof item.fillAmount === "string" && /^\d+$/.test(item.fillAmount) ? BigInt(item.fillAmount) : anchor;
  return {
    orderHash: hashOrderStruct(order),
    announce: { order, sig: item.sig as Hex },
    state: { ok: true, status: "Fillable", fillableAmount, validatorsPass: true },
  };
}

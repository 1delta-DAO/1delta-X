/**
 * Restore the order on `/fills` rows that lost it (2026-11-02).
 *
 * Before `fills.order_json`, `/fills` joined a fill's order from the book's tombstones,
 * which are pruned after TOMBSTONE_TTL_SECONDS: older fills came back without `order`
 * (the app dashboard's "? → ?" rows, no size). Every fill was sent as an
 * AggregatorFillSolver or Settlement call, so its order is in the tx's calldata. This script:
 *
 *   1. pages `GET {BOOK_URL}/fills` and keeps the rows without `order`;
 *   2. reads each row's tx (`eth_getTransactionByHash`) and decodes it against the solver
 *      and Settlement ABIs (`executeFill`, `fill*`, `batchFill`, …);
 *   3. unpacks every order in the arguments and keeps the one that hashes to the row's `orderHash`;
 *   4. with `--post`, sends them to `POST {POST_URL}/fills/orders` (the worker re-checks
 *      the hash and writes only rows that have no order).
 *
 *   BOOK_URL=https://1delta-x.pages.dev/api/book RPC_URL=https://public-node.rsk.co \
 *     npx tsx scripts/recover-fill-orders.ts                       # dry run
 *   … POST_URL=https://orderbook-1delta-rsk.<account>.workers.dev \
 *     ADMIN_TOKEN=<RAFFLE_ADMIN_TOKEN> npx tsx scripts/recover-fill-orders.ts --post
 *
 * `POST_URL` defaults to `BOOK_URL`; the app's `/api/book` proxy does not forward
 * `authorization`, so post to the worker's own URL.
 */
import {
  AGGREGATOR_FILL_SOLVER_ABI,
  EXPIRY_OFFSET,
  hashOrderStruct,
  orderToJson,
  SETTLEMENT_ABI,
  SIDE_BIT,
  unpackParams,
  type Order,
  type WireOrder,
} from "@1delta-x/sdk";
import { decodeFunctionData, getAddress, type Address, type Hex } from "viem";

const BOOK_URL = (process.env.BOOK_URL ?? "https://1delta-x.pages.dev/api/book").replace(/\/+$/, "");
const POST_URL = (process.env.POST_URL ?? BOOK_URL).replace(/\/+$/, "");
const RPC_URL = process.env.RPC_URL ?? "https://public-node.rsk.co";
const POST = process.argv.includes("--post");

interface FillRow {
  orderHash: string;
  txHash: string;
  order?: unknown;
}

// ─── wire order → Order (inverse of the SDK's packOrder / packed.ts layout) ───

class Reader {
  private i = 0;
  constructor(private readonly hex: string) {}
  take(bytes: number): string {
    const s = this.hex.slice(this.i, this.i + bytes * 2);
    if (s.length !== bytes * 2) throw new Error("packed blob too short");
    this.i += bytes * 2;
    return s;
  }
  int(bytes: number): bigint {
    return BigInt(`0x${this.take(bytes)}`);
  }
  addr(): Address {
    return getAddress(`0x${this.take(20)}`);
  }
  data(): Hex {
    return `0x${this.take(Number(this.int(2)))}`;
  }
  done(): void {
    if (this.i !== this.hex.length) throw new Error("trailing bytes in packed blob");
  }
}

function unpack<T>(blob: Hex, one: (r: Reader) => T): T[] {
  const r = new Reader(blob.slice(2));
  const n = Number(r.int(1));
  const out = Array.from({ length: n }, () => one(r));
  r.done();
  return out;
}

const U48 = (1n << 48n) - 1n;

export function unpackOrder(w: WireOrder): Order {
  const p = unpackParams(w.params);
  return {
    maker: getAddress(w.maker),
    side: Number((w.timing >> SIDE_BIT) & 1n),
    nonce: w.nonce,
    expiry: (w.timing >> EXPIRY_OFFSET) & U48,
    legsIn: unpack(w.legsIn, (r) => ({ token: r.addr(), start: r.int(32), end: r.int(32) })),
    legsOut: unpack(w.legsOut, (r) => ({ token: r.addr(), start: r.int(32), end: r.int(32), recipient: r.addr() })),
    // Everything packOrder folds in (side, expiry) comes back out.
    timing: w.timing & ~(1n << SIDE_BIT) & ~(U48 << EXPIRY_OFFSET),
    exclusiveFiller: getAddress(w.exclusiveFiller),
    minFillAnchor: w.minFillAnchor,
    exclusivityOverrideBps: p.overrideBps,
    curve: unpack(w.curve, (r) => ({ timeDelta: Number(r.int(4)), bumpBps: Number(r.int(4)) })),
    gasBumpBps: p.gasBumpBps,
    gasPriceRef: p.gasPriceRef,
    priorityScale: p.priorityScale,
    ...(p.baselinePriorityFeeWei > 0n ? { baselinePriorityFeeWei: p.baselinePriorityFeeWei } : {}),
    items: unpack(w.items, (r) => ({ op: Number(r.int(1)), module: r.addr(), amount: r.int(32), recipient: r.addr(), data: r.data() })),
    validators: unpack(w.validators, (r) => ({ target: r.addr(), data: r.data() })),
    invariants: unpack(w.invariants, (r) => ({ target: r.addr(), data: r.data() })),
    fillModule: getAddress(w.fillModule),
    fillTotal: w.fillTotal,
    pricingModule: getAddress(w.pricingModule),
  };
}

// ─── IO ───

async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = (await res.json()) as { result?: T; error?: { message: string } };
  if (body.error || body.result === undefined) throw new Error(`${method}: ${body.error?.message ?? "no result"}`);
  return body.result;
}

async function orphanFills(): Promise<FillRow[]> {
  const out: FillRow[] = [];
  let cursor: string | undefined;
  do {
    const q = new URLSearchParams({ limit: "500", ...(cursor ? { cursor } : {}) });
    const res = await fetch(`${BOOK_URL}/fills?${q}`, { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`GET /fills → ${res.status}`);
    const body = (await res.json()) as { fills: FillRow[]; nextCursor?: string };
    out.push(...body.fills.filter((f) => f.order === undefined));
    cursor = body.nextCursor;
  } while (cursor);
  return out;
}

const ABIS = [AGGREGATOR_FILL_SOLVER_ABI, SETTLEMENT_ABI] as const;

/** Every wire order among decoded call arguments (an order is a tuple with `maker` and a packed `legsIn`). */
function wireOrders(v: unknown, out: WireOrder[] = []): WireOrder[] {
  if (Array.isArray(v)) for (const x of v) wireOrders(x, out);
  else if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (typeof o.maker === "string" && typeof o.legsIn === "string" && typeof o.timing === "bigint") out.push(o as unknown as WireOrder);
    else for (const x of Object.values(o)) wireOrders(x, out);
  }
  return out;
}

/** The order a fill tx carried: the one in its calldata that hashes to `orderHash`. */
async function orderOf(f: FillRow): Promise<Order | string> {
  const tx = await rpc<{ input: Hex } | null>("eth_getTransactionByHash", [f.txHash]);
  if (!tx) return "tx not found";
  let args: unknown;
  for (const abi of ABIS) {
    try {
      args = decodeFunctionData({ abi, data: tx.input }).args;
      break;
    } catch {
      // not this contract's call
    }
  }
  if (args === undefined) return `calldata is neither a solver nor a Settlement call (${tx.input.slice(0, 10)})`;
  for (const w of wireOrders(args)) {
    try {
      const order = unpackOrder(w);
      if (hashOrderStruct(order).toLowerCase() === f.orderHash.toLowerCase()) return order;
    } catch {
      // a malformed blob: not this order
    }
  }
  return "no order in the calldata hashes to the fill's orderHash";
}

async function main(): Promise<void> {
  const rows = await orphanFills();
  console.log(`${rows.length} fill row(s) without an order`);
  const found = new Map<string, Order>();
  for (const f of rows) {
    const key = f.orderHash.toLowerCase();
    if (found.has(key)) continue;
    const r = await orderOf(f);
    if (typeof r === "string") console.log(`  ✗ ${f.txHash} ${f.orderHash}: ${r}`);
    else {
      found.set(key, r);
      console.log(`  ✓ ${f.txHash} ${f.orderHash}`);
    }
  }
  console.log(`${found.size} order(s) recovered`);
  if (!POST) {
    console.log("dry run: pass --post (with ADMIN_TOKEN and POST_URL) to write them");
    return;
  }
  const token = process.env.ADMIN_TOKEN;
  if (!token) throw new Error("--post needs ADMIN_TOKEN (the worker's RAFFLE_ADMIN_TOKEN)");
  const orders = [...found.values()].map(orderToJson);
  for (let i = 0; i < orders.length; i += 50) {
    const res = await fetch(`${POST_URL}/fills/orders`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify(orders.slice(i, i + 50)),
    });
    console.log(`POST /fills/orders → ${res.status}`, JSON.stringify(await res.json()));
  }
}

await main();

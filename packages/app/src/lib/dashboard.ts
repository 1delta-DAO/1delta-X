import {
  hashOrderStruct,
  nativeBalanceOf,
  orderFromJson,
  OrderSide,
  type Order,
} from "@1delta-x/sdk";

import { NATIVE_SYMBOL, TOKENS } from "../config/markets";

/**
 * THE DASHBOARD (2026-10-20): every fill the orderbook has indexed (`GET /fills`, no
 * maker filter), turned into volume figures. A fill's size is exact on its ANCHOR leg
 * only — `amount` is the settlement's `filled(hash)` delta, counted in the input token
 * of a SELL and the output token of a BUY (every order this app builds) — so volume is
 * that leg's amount at its USD price. The other leg moved with the order's decay curve
 * and is not in the fill row: it is never summed.
 */

/** One row of `GET /fills` (orderbook-worker README). */
export interface FillWire {
  orderHash: string;
  maker?: string;
  solver?: string;
  blockNumber?: string;
  txHash?: string;
  logIndex?: number;
  at?: number | null;
  cumulative?: string | null;
  amount?: string | null;
  order?: unknown;
}

/** A fill the dashboard counts. `amount` / `usd` are absent when the row cannot size it. */
export interface DashFill {
  id: string;
  tx: string;
  at: number | null;
  maker: string;
  solver: string;
  /** Token symbols, the maker's view: what they paid → what they received. */
  pay: string;
  recv: string;
  /** The anchor leg (the exactly-sized one): its symbol and amount in whole tokens. */
  anchor?: { symbol: string; amount: number };
  usd?: number;
}

/** Display symbol of a token on a chain: the pinned symbol, the native coin for the NativeBalance view, else a short address. */
export function symbolOf(chainId: number, address: string): string {
  const a = address.toLowerCase();
  const nb = nativeBalanceOf(chainId);
  if (nb && nb.toLowerCase() === a) return NATIVE_SYMBOL[chainId] ?? "native";
  for (const [sym, t] of Object.entries(TOKENS[chainId] ?? {}))
    if (t.address === a) return sym;
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

function decimalsOf(chainId: number, address: string): number | undefined {
  const a = address.toLowerCase();
  const nb = nativeBalanceOf(chainId);
  if (nb && nb.toLowerCase() === a) return 18;
  return Object.values(TOKENS[chainId] ?? {}).find((t) => t.address === a)
    ?.decimals;
}

/** USD of `wei` of `token` (pinned decimals, priced by symbol), or `undefined` for a token we cannot price. */
export function tokenUsd(
  chainId: number,
  token: string,
  wei: bigint,
  usdOf: (symbol: string) => number | undefined,
): number | undefined {
  const dec = decimalsOf(chainId, token);
  if (dec === undefined || wei < 0n) return undefined;
  const px = usdOf(symbolOf(chainId, token));
  return px === undefined ? undefined : (Number(wei) / 10 ** dec) * px;
}

const toWei = (v: unknown): bigint | null =>
  typeof v === "string" && /^\d+$/.test(v) ? BigInt(v) : null;

/** The anchor leg of an order: the fill total's unit is not a token, else SELL = input, BUY = output. */
function anchorLeg(order: Order): { token: string; start: bigint } | undefined {
  if (order.fillTotal > 0n) return undefined;
  const leg =
    order.side === OrderSide.SELL ? order.legsIn[0] : order.legsOut[0];
  return leg ? { token: leg.token, start: leg.start } : undefined;
}

/**
 * One wire row → a dashboard fill. Rows without the served order (older than the book's
 * tombstones), whose order does not hash to `orderHash`, or without an amount are still
 * counted as fills, but without a size.
 */
export function toDashFill(
  chainId: number,
  f: FillWire,
  usdOf: (symbol: string) => number | undefined,
): DashFill {
  const tx = f.txHash ?? "";
  const base: DashFill = {
    id: `${tx}:${f.logIndex ?? 0}:${f.orderHash.toLowerCase()}`,
    tx,
    at: typeof f.at === "number" ? f.at * 1000 : null,
    maker: (f.maker ?? "").toLowerCase(),
    solver: (f.solver ?? "").toLowerCase(),
    pay: "?",
    recv: "?",
  };
  if (f.order === undefined) return base;
  let order: Order;
  try {
    order = orderFromJson(f.order);
  } catch {
    return base;
  }
  if (hashOrderStruct(order).toLowerCase() !== f.orderHash.toLowerCase())
    return base;
  const out: DashFill = {
    ...base,
    maker: base.maker || order.maker.toLowerCase(),
    pay: order.legsIn[0] ? symbolOf(chainId, order.legsIn[0].token) : "?",
    recv: order.legsOut[0] ? symbolOf(chainId, order.legsOut[0].token) : "?",
  };
  const leg = anchorLeg(order);
  const wei = toWei(f.amount);
  const dec = leg ? decimalsOf(chainId, leg.token) : undefined;
  if (!leg || wei === null || dec === undefined) return out;
  const capped = wei > leg.start && leg.start > 0n ? leg.start : wei;
  const amount = Number(capped) / 10 ** dec;
  const symbol = symbolOf(chainId, leg.token);
  const px = usdOf(symbol);
  return {
    ...out,
    anchor: { symbol, amount },
    ...(px !== undefined ? { usd: amount * px } : {}),
  };
}

/** Who filled it, by the `OrderFilled` taker: the beta's known fillers by name, else the address. */
const FILLERS: Record<number, Record<string, string>> = {
  30: {
    "0xcafe35944e3195d59b4a354ea23d60a0445c083a": "1delta inventory",
    "0x5987a4afe1b680dac657506b69c56b06ffe86cd1": "1delta solver v3",
    "0x48dbdc43507767bd51ec0af2cb9bfa5e35b332f1": "1delta solver v2",
  },
};

export function fillerName(chainId: number, solver: string): string {
  const s = solver.toLowerCase();
  return (
    FILLERS[chainId]?.[s] ?? (s ? `${s.slice(0, 6)}…${s.slice(-4)}` : "unknown")
  );
}

export interface Breakdown {
  key: string;
  fills: number;
  /** Netted USD exchanged ({@link nettedUsd}). */
  volume: number;
  /** Every fill's USD, summed. */
  turnover: number;
}

/**
 * VOLUME vs TURNOVER (2026-10-20). TURNOVER is every conversion that ran: each pool hop
 * of a routed fill (lib/turnover.ts — a two-hop route counts ~2×), and the fills of a
 * transaction without one (an inventory fill; two matched orders count twice). VOLUME is the USD that
 * really changed hands: per transaction and per token pair, the two directions net —
 * only the larger side counts (opposite flows offset each other; fills in the same
 * direction add up). Outside a matched transaction every fill is volume and turnover
 * alike. Returns each fill's share of the volume, by `id` (the larger side keeps its
 * USD, the smaller side 0).
 */
export function nettedUsd(fills: readonly DashFill[]): Map<string, number> {
  const groups = new Map<
    string,
    { a: DashFill[]; b: DashFill[]; ua: number; ub: number }
  >();
  for (const f of fills) {
    if (f.usd === undefined) continue;
    const [x, y] = f.pay < f.recv ? [f.pay, f.recv] : [f.recv, f.pay];
    const key = `${f.tx || f.id}|${x}|${y}`;
    const g = groups.get(key) ?? { a: [], b: [], ua: 0, ub: 0 };
    if (f.pay === x) {
      g.a.push(f);
      g.ua += f.usd;
    } else {
      g.b.push(f);
      g.ub += f.usd;
    }
    groups.set(key, g);
  }
  const out = new Map<string, number>();
  for (const g of groups.values()) {
    const keep = g.ua >= g.ub ? g.a : g.b;
    for (const f of [...g.a, ...g.b])
      out.set(f.id, keep.includes(f) ? f.usd! : 0);
  }
  return out;
}

export interface DashStats {
  fills: number;
  /** Fills with a USD size (the rest: no served order / no amount / no price). */
  sized: number;
  volume: number;
  turnover: number;
  volume24h: number;
  turnover24h: number;
  fills24h: number;
  makers: number;
  /** Daily USD, oldest first, one entry per UTC day in the window (zeros included). */
  daily: { day: number; volume: number; turnover: number; fills: number }[];
  pairs: Breakdown[];
  fillers: Breakdown[];
}

const DAY = 86_400_000;

function tally(
  map: Map<string, Breakdown>,
  key: string,
  volume: number,
  turnover: number,
) {
  const b = map.get(key) ?? { key, fills: 0, volume: 0, turnover: 0 };
  b.fills += 1;
  b.volume += volume;
  b.turnover += turnover;
  map.set(key, b);
}

/**
 * Each fill's share of its transaction's TURNOVER (lib/turnover.ts): a transaction whose
 * pool hops are known (`txTurnover`, USD by lowercase tx hash) splits that figure over
 * its fills by their USD (evenly when none is sized); any other fill is its own turnover.
 */
export function turnoverShares(
  fills: readonly DashFill[],
  txTurnover?: ReadonlyMap<string, number>,
): Map<string, number> {
  const out = new Map<string, number>();
  if (!txTurnover || txTurnover.size === 0) return out;
  const byTx = new Map<string, DashFill[]>();
  for (const f of fills) {
    const tx = f.tx.toLowerCase();
    if (!txTurnover.has(tx)) continue;
    byTx.set(tx, [...(byTx.get(tx) ?? []), f]);
  }
  for (const [tx, group] of byTx) {
    const total = txTurnover.get(tx)!;
    const sized = group.reduce((a, f) => a + (f.usd ?? 0), 0);
    for (const f of group)
      out.set(
        f.id,
        sized > 0 ? (total * (f.usd ?? 0)) / sized : total / group.length,
      );
  }
  return out;
}

/**
 * Aggregate `fills` as of `now` (ms): totals, the last 24 h, `days` daily buckets, per pair
 * and per filler. `txTurnover`: the pool-hop turnover of the transactions read so far.
 */
export function dashStats(
  chainId: number,
  fills: readonly DashFill[],
  now: number,
  days = 30,
  txTurnover?: ReadonlyMap<string, number>,
): DashStats {
  const today = Math.floor(now / DAY) * DAY;
  const first = today - (days - 1) * DAY;
  const daily = Array.from({ length: days }, (_, i) => ({
    day: first + i * DAY,
    volume: 0,
    turnover: 0,
    fills: 0,
  }));
  const netted = nettedUsd(fills);
  const pairs = new Map<string, Breakdown>();
  const fillers = new Map<string, Breakdown>();
  const makers = new Set<string>();
  const st = {
    volume: 0,
    turnover: 0,
    volume24h: 0,
    turnover24h: 0,
    fills24h: 0,
    sized: 0,
  };
  const share = turnoverShares(fills, txTurnover);
  for (const f of fills) {
    const t = share.get(f.id) ?? f.usd ?? 0;
    const v = netted.get(f.id) ?? 0;
    if (f.usd !== undefined) st.sized++;
    st.volume += v;
    st.turnover += t;
    if (f.maker) makers.add(f.maker);
    if (f.at !== null) {
      if (now - f.at < DAY) {
        st.fills24h++;
        st.volume24h += v;
        st.turnover24h += t;
      }
      const i = Math.floor((f.at - first) / DAY);
      if (i >= 0 && i < days) {
        daily[i]!.fills++;
        daily[i]!.volume += v;
        daily[i]!.turnover += t;
      }
    }
    tally(pairs, `${f.pay} → ${f.recv}`, v, t);
    tally(fillers, fillerName(chainId, f.solver), v, t);
  }
  const byVolume = (a: Breakdown, b: Breakdown) =>
    b.volume - a.volume || b.turnover - a.turnover || b.fills - a.fills;
  return {
    fills: fills.length,
    ...st,
    makers: makers.size,
    daily,
    pairs: [...pairs.values()].sort(byVolume),
    fillers: [...fillers.values()].sort(byVolume),
  };
}

import { concat, keccak256, toBytes, type Hex } from "viem";

import { TOKENS } from "@app/config/markets";
import { nettedUsd, toDashFill, type FillWire } from "@app/lib/dashboard";

/**
 * The prize draw's rules — who qualifies for a UTC day, and who is drawn — shared by
 * the admin page (components/admin) and the CLI (scripts/raffle-draw.ts), so a
 * published result can be re-derived from its snapshot by either.
 */

/** The beta's own fillers: never a qualifying "maker" even if one ever signs an order. */
export const ALWAYS_EXCLUDED = [
  "0xcafe35944e3195d59b4a354ea23d60a0445c083a",
  "0x5987a4afe1b680dac657506b69c56b06ffe86cd1",
  "0x48dbdc43507767bd51ec0af2cb9bfa5e35b332f1",
];
const STABLES = ["USD₮0", "USDT", "USDC.e", "USDRIF"];
/** A draw block must be this deep before it is used. */
export const DRAW_CONFIRMATIONS = 12n;
/** Default distance of the draw block from the head when the snapshot is taken (~1 h at 29.3 s). */
export const DRAW_DELAY_BLOCKS = 120n;

export interface Volume {
  address: string;
  usd: number;
  fills: number;
  /** Fills the book could not size (no served order / no price): review before publishing. */
  unsized: number;
}

/** One day's draw record — what is published, and later its result. */
export interface Snapshot {
  promotion: string;
  day: string;
  /** Unix seconds: [from, to) of the UTC day. */
  window: [number, number];
  /** Entrants who had entered by this time are in. */
  cutoff: number;
  qualifierUsd: number;
  prices: Record<string, number>;
  excluded: string[];
  /** Every entrant's volume that day (qualifying or not), for the record. */
  volumes: Volume[];
  /** The draw list: qualifying addresses, sorted. */
  list: string[];
  listHash: Hex;
  drawBlock: string;
  result?: { blockHash: Hex; winners: string[]; skipped: string[]; drawnAt: number };
}

/** Unix seconds [from, to) of a `YYYY-MM-DD` UTC day. */
export function dayWindow(day: string): [number, number] {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error("day must be YYYY-MM-DD");
  const from = Date.parse(`${day}T00:00:00Z`) / 1000;
  if (!Number.isFinite(from)) throw new Error("not a date");
  return [from, from + 86_400];
}

/** Symbol → USD for the pinned Rootstock tokens: stables at 1, the rest from a price table (address → USD). */
export function pricesFrom(table: Record<string, number>, chainId = 30): Record<string, number> {
  const prices: Record<string, number> = {};
  for (const [sym, t] of Object.entries(TOKENS[chainId] ?? {})) {
    if (STABLES.includes(sym)) prices[sym] = 1;
    else if (table[t.address] !== undefined) prices[sym] = table[t.address]!;
  }
  if (prices.WRBTC !== undefined) prices.RBTC = prices.WRBTC;
  return prices;
}

/**
 * Each eligible entrant's USD maker volume in `window`, valued the way the Dashboard
 * does (anchor leg × price; opposite fills in one tx netted).
 */
export function volumesFor(args: { fills: readonly FillWire[]; eligible: ReadonlySet<string>; window: [number, number]; prices: Record<string, number>; chainId?: number }): Volume[] {
  const [from, to] = args.window;
  const inDay = args.fills.filter((f) => typeof f.at === "number" && f.at >= from && f.at < to);
  const dash = inDay.map((f) => toDashFill(args.chainId ?? 30, f, (s) => args.prices[s]));
  const share = nettedUsd(dash);
  const byMaker = new Map<string, { usd: number; fills: number; unsized: number }>();
  for (const f of dash) {
    if (!args.eligible.has(f.maker)) continue;
    const m = byMaker.get(f.maker) ?? { usd: 0, fills: 0, unsized: 0 };
    m.fills++;
    if (f.usd === undefined) m.unsized++;
    else m.usd += share.get(f.id) ?? 0;
    byMaker.set(f.maker, m);
  }
  return [...byMaker.entries()].map(([address, v]) => ({ address, usd: Math.round(v.usd * 100) / 100, fills: v.fills, unsized: v.unsized })).sort((a, b) => b.usd - a.usd || a.address.localeCompare(b.address));
}

/** Build a day's snapshot (without the draw block, which the caller fixes from the chain head). */
export function buildSnapshot(args: {
  promotion: string;
  day: string;
  fills: readonly FillWire[];
  entrants: ReadonlyArray<{ address: string; enteredAt: number }>;
  cutoff: number;
  qualifierUsd: number;
  prices: Record<string, number>;
  exclude: readonly string[];
  drawBlock: bigint;
}): Snapshot {
  const window = dayWindow(args.day);
  const excluded = [...new Set([...ALWAYS_EXCLUDED, ...args.exclude.map((a) => a.toLowerCase())])];
  const eligible = new Set(args.entrants.filter((e) => e.enteredAt <= args.cutoff).map((e) => e.address.toLowerCase()));
  const volumes = volumesFor({ fills: args.fills, eligible, window, prices: args.prices });
  const list = volumes.filter((v) => v.usd >= args.qualifierUsd && !excluded.includes(v.address)).map((v) => v.address).sort();
  return {
    promotion: args.promotion,
    day: args.day,
    window,
    cutoff: args.cutoff,
    qualifierUsd: args.qualifierUsd,
    prices: args.prices,
    excluded,
    volumes,
    list,
    listHash: listHashOf(list),
    drawBlock: args.drawBlock.toString(),
  };
}

/** keccak256 of the sorted, lower-case, newline-joined list — what is published before the draw. */
export function listHashOf(list: readonly string[]): Hex {
  return keccak256(toBytes([...list].map((a) => a.toLowerCase()).sort().join("\n")));
}

/** Draw `k` winners from `list` (without replacement) seeded by the block hash. */
export function pickWinners(list: readonly string[], blockHash: Hex, k: number, skip: readonly string[] = []): string[] {
  const listHash = listHashOf(list);
  const pool = [...list].map((a) => a.toLowerCase()).sort().filter((a) => !skip.includes(a));
  const winners: string[] = [];
  for (let j = 0; j < k && pool.length > 0; j++) {
    const seed = BigInt(keccak256(concat([blockHash, listHash, `0x${j.toString(16).padStart(64, "0")}`])));
    winners.push(pool.splice(Number(seed % BigInt(pool.length)), 1)[0]!);
  }
  return winners;
}

/** The announcement line to publish before the draw block. */
export function announcement(s: Snapshot): string {
  return `${s.day} draw · ${s.list.length} qualifying address${s.list.length === 1 ? "" : "es"} · listHash ${s.listHash} · draw block ${s.drawBlock}`;
}

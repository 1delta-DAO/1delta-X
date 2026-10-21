import { concat, keccak256, toBytes, type Hex } from "viem";

import { TOKENS } from "@app/config/markets";
import { nettedUsd, toDashFill, type FillWire } from "@app/lib/dashboard";

/**
 * THE DRAW RULES (2026-10-21), shared by the console (tabs/DrawsTab.tsx) and the CLI
 * (scripts/raffle-draw.ts), so a published result can be re-derived from its record
 * by either.
 *
 *   • Draw PERIODS of `periodDays` UTC days, counted from the UTC midnight of the
 *     promotion's start. Period k = [start + k·p days, start + (k+1)·p days).
 *   • One TICKET per UTC day an address reaches the qualifier in maker volume (valued
 *     the way the Dashboard values fills). At most `periodDays` tickets. EVERY maker is
 *     considered — the Terms (§4.1) promise no registration — except the excluded ones.
 *   • A period with fewer than `minQualifiers` qualifying addresses is NOT drawn: its
 *     prizes are carried forward and added to the first prize of the next period.
 *   • `prizes.length` winners, drawn without replacement, each ticket one chance. With
 *     `onePrizePerAddress`, an address that already won in this promotion is set aside
 *     and only drawn once every other qualifier of the period has won.
 *   • The FINAL draw (optional, after the last period) spends whatever was carried
 *     forward and never paid, among addresses with ≥ 2 qualifying days overall.
 *
 * Everything the selection depends on is in the record (tickets, prior winners, the
 * carry, the prices) and the record's hash is published before the draw block exists.
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
/** Default distance of the draw block from the head when the record is saved (~1 h at 29.3 s). */
export const DRAW_DELAY_BLOCKS = 120n;
export const DAY = 86_400;
/** The final draw: an address needs this many qualifying days over the whole promotion. */
export const FINAL_MIN_DAYS = 2;

export interface Rules {
  qualifierUsd: number;
  periodDays: number;
  minQualifiers: number;
  prizes: number[];
  prizeToken: string;
  onePrizePerAddress: boolean;
  /** The whole pot; 0 = unlimited. The console stops offering draws once it is paid out. */
  pot?: number;
}

/** What the saved records have paid out (winners drawn × their payouts), in prizeToken. */
export function paidOut(records: readonly Snapshot[]): number {
  return records.reduce((a, r) => a + (r.result?.winners.length ? r.payouts.slice(0, r.result.winners.length).reduce((x, y) => x + y, 0) : 0), 0);
}

export interface Volume {
  address: string;
  /** USD over the whole period. */
  usd: number;
  fills: number;
  /** Fills the book could not size (no served order / no price): review before publishing. */
  unsized: number;
  /** UTC days in the period at or above the qualifier = tickets. */
  days: number;
}

/** One draw record — what is published, and later its result. Keyed by its period's start date. */
export interface Snapshot {
  promotion: string;
  /** "YYYY-MM-DD" (UTC): the period's first day — the record's key — or the final draw's date. */
  day: string;
  kind: "period" | "final";
  /** Period index from the start (0-based); absent for the final draw. */
  period?: number;
  /** Unix seconds: [from, to) of the period (the whole promotion for the final draw). */
  window: [number, number];
  /** When the record was computed (fills up to here). */
  cutoff: number;
  rules: Rules;
  prices: Record<string, number>;
  excluded: string[];
  /** Every maker's volume in the window (qualifying or not), for the record. */
  volumes: Volume[];
  /** Tickets per qualifying address, sorted by address. */
  tickets: Array<[string, number]>;
  /** Addresses with a ticket, sorted. */
  list: string[];
  /** Earlier winners of this promotion (set aside under onePrizePerAddress). */
  priorWinners: string[];
  /** Prize amounts carried in from skipped periods (added to the first prize). */
  carriedIn: number;
  /** What this draw pays per winner, in rules.prizeToken. Empty when skipped. */
  payouts: number[];
  /** True when fewer than minQualifiers qualified: no draw, prizes carried forward. */
  skipped: boolean;
  /** What the next period starts with. */
  carriedOut: number;
  /** keccak256 over the tickets, so the published list cannot be changed after the fact. */
  listHash: Hex;
  /** "" for a skipped period. */
  drawBlock: string;
  result?: { blockHash: Hex; winners: string[]; skipped: string[]; drawnAt: number };
}

export const dateOf = (sec: number): string => new Date(sec * 1000).toISOString().slice(0, 10);

/** Unix seconds of the UTC midnight of `sec`'s day. */
export const utcMidnight = (sec: number): number => Math.floor(sec / DAY) * DAY;

/** Period `k`'s window, from the promotion start (floored to its UTC day). */
export function periodWindow(startsAt: number, periodDays: number, k: number): [number, number] {
  const from = utcMidnight(startsAt) + k * periodDays * DAY;
  return [from, from + periodDays * DAY];
}

/** The periods that have ENDED by `now` (k, window), newest first. */
export function completedPeriods(startsAt: number, periodDays: number, now: number, endsAt = Number.MAX_SAFE_INTEGER): Array<{ k: number; window: [number, number] }> {
  if (startsAt <= 0) return [];
  const out: Array<{ k: number; window: [number, number] }> = [];
  for (let k = 0; k < 400; k++) {
    const w = periodWindow(startsAt, periodDays, k);
    if (w[1] > now || w[0] >= endsAt) break;
    out.push({ k, window: w });
  }
  return out.reverse();
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
 * Each maker's volume in `window` (excluded addresses left out), valued the way the Dashboard does
 * (anchor leg × price; opposite fills in one tx netted), and the number of UTC days in
 * the window on which it reached `qualifierUsd`.
 */
export function volumesFor(args: {
  fills: readonly FillWire[];
  excluded: ReadonlySet<string>;
  window: [number, number];
  prices: Record<string, number>;
  qualifierUsd: number;
  chainId?: number;
}): Volume[] {
  const [from, to] = args.window;
  const inWindow = args.fills.filter((f) => typeof f.at === "number" && f.at >= from && f.at < to);
  const dash = inWindow.map((f) => ({ f: toDashFill(args.chainId ?? 30, f, (s) => args.prices[s]), at: f.at as number }));
  const share = nettedUsd(dash.map((d) => d.f));
  const byMaker = new Map<string, { usd: number; fills: number; unsized: number; byDay: Map<number, number> }>();
  for (const { f, at } of dash) {
    if (args.excluded.has(f.maker)) continue;
    const m = byMaker.get(f.maker) ?? { usd: 0, fills: 0, unsized: 0, byDay: new Map() };
    m.fills++;
    if (f.usd === undefined) m.unsized++;
    else {
      const usd = share.get(f.id) ?? 0;
      m.usd += usd;
      const d = utcMidnight(at);
      m.byDay.set(d, (m.byDay.get(d) ?? 0) + usd);
    }
    byMaker.set(f.maker, m);
  }
  return [...byMaker.entries()]
    .map(([address, v]) => ({
      address,
      usd: Math.round(v.usd * 100) / 100,
      fills: v.fills,
      unsized: v.unsized,
      days: [...v.byDay.values()].filter((x) => Math.round(x * 100) / 100 >= args.qualifierUsd).length,
    }))
    .sort((a, b) => b.days - a.days || b.usd - a.usd || a.address.localeCompare(b.address));
}

const round2 = (x: number) => Math.round(x * 100) / 100;

/** The prize list with the carry added to the first prize. */
export function payoutsOf(prizes: readonly number[], carriedIn: number): number[] {
  return prizes.map((p, i) => round2(i === 0 ? p + carriedIn : p));
}

/** Winners (and their payouts) of the saved records so far — what `onePrizePerAddress` sets aside. */
export function priorWinnersOf(records: readonly Snapshot[]): string[] {
  return [...new Set(records.flatMap((r) => r.result?.winners ?? []).map((a) => a.toLowerCase()))].sort();
}

/**
 * What the next draw starts with: the carry the latest decided record passes on.
 * Records without a result (saved, not yet drawn) pass their own carry on unchanged;
 * a skipped record passes carriedIn + its prizes.
 */
export function carriedForward(records: readonly Snapshot[], upToPeriod?: number): number {
  const prior = records.filter((r) => r.kind === "period" && (upToPeriod === undefined || (r.period ?? 0) < upToPeriod)).sort((a, b) => (a.period ?? 0) - (b.period ?? 0));
  const last = prior[prior.length - 1];
  return last ? last.carriedOut : 0;
}

/** Build a period's record (without the draw block, which the caller fixes from the chain head). */
export function buildSnapshot(args: {
  promotion: string;
  startsAt: number;
  period: number;
  fills: readonly FillWire[];
  cutoff: number;
  rules: Rules;
  prices: Record<string, number>;
  exclude: readonly string[];
  /** The promotion's saved records so far (for the carry and the prior winners). */
  records: readonly Snapshot[];
  drawBlock: bigint;
}): Snapshot {
  const window = periodWindow(args.startsAt, args.rules.periodDays, args.period);
  const excluded = [...new Set([...ALWAYS_EXCLUDED, ...args.exclude.map((a) => a.toLowerCase())])];
  const volumes = volumesFor({ fills: args.fills, excluded: new Set(excluded), window, prices: args.prices, qualifierUsd: args.rules.qualifierUsd });
  const tickets = volumes
    .filter((v) => v.days > 0)
    .map((v): [string, number] => [v.address, v.days])
    .sort((a, b) => a[0].localeCompare(b[0]));
  const list = tickets.map(([a]) => a);
  const carriedIn = carriedForward(args.records, args.period);
  const skipped = list.length < args.rules.minQualifiers;
  const payouts = skipped ? [] : payoutsOf(args.rules.prizes, carriedIn);
  const prizeTotal = args.rules.prizes.reduce((a, b) => a + b, 0);
  return {
    promotion: args.promotion,
    day: dateOf(window[0]),
    kind: "period",
    period: args.period,
    window,
    cutoff: args.cutoff,
    rules: args.rules,
    prices: args.prices,
    excluded,
    volumes,
    tickets,
    list,
    priorWinners: args.rules.onePrizePerAddress ? priorWinnersOf(args.records) : [],
    carriedIn,
    payouts,
    skipped,
    carriedOut: skipped ? round2(carriedIn + prizeTotal) : 0,
    listHash: listHashOf(tickets),
    drawBlock: skipped ? "" : args.drawBlock.toString(),
  };
}

/** The final draw: the carry nobody won, one winner, among addresses with ≥ FINAL_MIN_DAYS qualifying days overall. */
export function buildFinalSnapshot(args: {
  promotion: string;
  startsAt: number;
  endsAt: number;
  fills: readonly FillWire[];
  cutoff: number;
  rules: Rules;
  prices: Record<string, number>;
  exclude: readonly string[];
  records: readonly Snapshot[];
  drawBlock: bigint;
}): Snapshot {
  const window: [number, number] = [utcMidnight(args.startsAt), Math.min(args.endsAt, args.cutoff)];
  const excluded = [...new Set([...ALWAYS_EXCLUDED, ...args.exclude.map((a) => a.toLowerCase())])];
  const volumes = volumesFor({ fills: args.fills, excluded: new Set(excluded), window, prices: args.prices, qualifierUsd: args.rules.qualifierUsd });
  const tickets = volumes
    .filter((v) => v.days >= FINAL_MIN_DAYS)
    .map((v): [string, number] => [v.address, v.days])
    .sort((a, b) => a[0].localeCompare(b[0]));
  const list = tickets.map(([a]) => a);
  const carriedIn = carriedForward(args.records);
  const skipped = carriedIn <= 0 || list.length < args.rules.minQualifiers;
  return {
    promotion: args.promotion,
    day: dateOf(args.cutoff),
    kind: "final",
    window,
    cutoff: args.cutoff,
    rules: args.rules,
    prices: args.prices,
    excluded,
    volumes,
    tickets,
    list,
    priorWinners: args.rules.onePrizePerAddress ? priorWinnersOf(args.records) : [],
    carriedIn,
    payouts: skipped ? [] : [round2(carriedIn)],
    skipped,
    carriedOut: skipped ? round2(carriedIn) : 0,
    listHash: listHashOf(tickets),
    drawBlock: skipped ? "" : args.drawBlock.toString(),
  };
}

/** keccak256 of "address:tickets" lines, sorted — what is published before the draw. */
export function listHashOf(tickets: ReadonlyArray<readonly [string, number]>): Hex {
  return keccak256(toBytes([...tickets].map(([a, n]) => `${a.toLowerCase()}:${n}`).sort().join("\n")));
}

/**
 * Draw `k` winners seeded by the block hash: every ticket is one chance, a winner's
 * other tickets leave the pool. `deferred` addresses (earlier winners) are drawn only
 * once nobody else is left; `skip` addresses (excluded after review) never are.
 */
export function pickWinners(tickets: ReadonlyArray<readonly [string, number]>, blockHash: Hex, k: number, skip: readonly string[] = [], deferred: readonly string[] = []): string[] {
  const listHash = listHashOf(tickets);
  const lower = (a: readonly string[]) => a.map((x) => x.toLowerCase());
  const skipSet = new Set(lower(skip));
  const deferSet = new Set(lower(deferred));
  const expand = (rows: ReadonlyArray<readonly [string, number]>) => rows.flatMap(([a, n]) => Array<string>(Math.max(0, Math.floor(n))).fill(a.toLowerCase()));
  const sorted = [...tickets].map(([a, n]): [string, number] => [a.toLowerCase(), n]).sort((x, y) => x[0].localeCompare(y[0]));
  let fresh = expand(sorted.filter(([a]) => !skipSet.has(a) && !deferSet.has(a)));
  let held = expand(sorted.filter(([a]) => !skipSet.has(a) && deferSet.has(a)));
  const winners: string[] = [];
  for (let j = 0; j < k; j++) {
    const pool = fresh.length ? fresh : held;
    if (!pool.length) break;
    const seed = BigInt(keccak256(concat([blockHash, listHash, `0x${j.toString(16).padStart(64, "0")}`])));
    const w = pool[Number(seed % BigInt(pool.length))]!;
    winners.push(w);
    fresh = fresh.filter((a) => a !== w);
    held = held.filter((a) => a !== w);
  }
  return winners;
}

/** The announcement line to publish before the draw block. */
export function announcement(s: Snapshot): string {
  const span = `${dateOf(s.window[0])} → ${dateOf(s.window[1] - 1)}`;
  if (s.skipped) {
    return `${s.kind === "final" ? "Final draw" : `Draw ${span}`}: ${s.list.length} qualifying address${s.list.length === 1 ? "" : "es"}, fewer than ${s.rules.minQualifiers} — carried forward, ${s.carriedOut} ${s.rules.prizeToken} rides on the next draw`;
  }
  const total = s.tickets.reduce((a, [, n]) => a + n, 0);
  return `${s.kind === "final" ? "Final draw" : `Draw ${span}`} · ${s.list.length} qualifying address${s.list.length === 1 ? "" : "es"}, ${total} ticket${total === 1 ? "" : "s"} · prizes ${s.payouts.join(" / ")} ${s.rules.prizeToken} · listHash ${s.listHash} · draw block ${s.drawBlock}`;
}

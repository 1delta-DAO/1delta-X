import { TOKENS } from "@app/config/markets";
import { nettedUsd, toDashFill, type FillWire } from "@app/lib/dashboard";

/**
 * The daily qualifier list — what the operator evaluates by hand each morning.
 *
 * For a UTC day: every maker's volume that day, valued the way the Dashboard values
 * fills (anchor leg × USD price; opposite fills in one transaction netted), and
 * whether it reached the qualifier. Excluded addresses (team, fillers) are left out.
 * Nothing here decides the draw; it is the list the operator draws from.
 */

/**
 * The beta's own addresses (docs/deployment-rootstock-beta.md): never a qualifying
 * "maker". The console's exclusion box starts from this list; team wallets are added
 * there and remembered in the browser.
 */
export const ALWAYS_EXCLUDED = [
  "0x00001d4754680958e7f8fe42d60842ebde4cb30d", // deployer
  "0xcafe35944e3195d59b4a354ea23d60a0445c083a", // filler operator (inventory / spot)
  "0x33ccacb24da5c7f335819da877fc03e4bf62e287", // AggregatorFillSolver v1
  "0x48dbdc43507767bd51ec0af2cb9bfa5e35b332f1", // AggregatorFillSolver v2
  "0x5987a4afe1b680dac657506b69c56b06ffe86cd1", // AggregatorFillSolver v3
  "0xdade4b0f9dea9f2cc371e07f76653971b2c62c04", // RouteSandbox v1
  "0xda2db66b3ae47a1f5f89640666b7802423828c8b", // RouteSandbox v2
  "0xebbbf5719b699a450b2537852e4286a7e69bb1ad", // RouteSandbox v3
  "0xb6107a1dea7ae04129abc27ce607249049f3c735", // NativeUnwrapModule
];
const STABLES = ["USD₮0", "USDT", "USDC.e", "USDRIF"];
export const DAY = 86_400;

export interface DayRow {
  address: string;
  usd: number;
  fills: number;
  /** Fills the book could not size (no served order / no price): look at them before deciding. */
  unsized: number;
  qualifies: boolean;
}

export const dateOf = (sec: number): string => new Date(sec * 1000).toISOString().slice(0, 10);
export const utcMidnight = (sec: number): number => Math.floor(sec / DAY) * DAY;

/** Unix seconds [from, to) of a `YYYY-MM-DD` UTC day. */
export function dayWindow(day: string): [number, number] {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error("day must be YYYY-MM-DD");
  const from = Date.parse(`${day}T00:00:00Z`) / 1000;
  if (!Number.isFinite(from)) throw new Error("not a date");
  return [from, from + DAY];
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

export function dayRows(args: { fills: readonly FillWire[]; day: string; prices: Record<string, number>; qualifierUsd: number; exclude: readonly string[]; chainId?: number }): DayRow[] {
  const [from, to] = dayWindow(args.day);
  const excluded = new Set([...ALWAYS_EXCLUDED, ...args.exclude.map((a) => a.toLowerCase())]);
  const dash = args.fills.filter((f) => typeof f.at === "number" && f.at >= from && f.at < to).map((f) => toDashFill(args.chainId ?? 30, f, (s) => args.prices[s]));
  const share = nettedUsd(dash);
  const byMaker = new Map<string, { usd: number; fills: number; unsized: number }>();
  for (const f of dash) {
    if (excluded.has(f.maker)) continue;
    const m = byMaker.get(f.maker) ?? { usd: 0, fills: 0, unsized: 0 };
    m.fills++;
    if (f.usd === undefined) m.unsized++;
    else m.usd += share.get(f.id) ?? 0;
    byMaker.set(f.maker, m);
  }
  return [...byMaker.entries()]
    .map(([address, v]) => {
      const usd = Math.round(v.usd * 100) / 100;
      return { address, usd, fills: v.fills, unsized: v.unsized, qualifies: usd >= args.qualifierUsd };
    })
    .sort((a, b) => Number(b.qualifies) - Number(a.qualifies) || b.usd - a.usd || a.address.localeCompare(b.address));
}

/** The days of a range: `start` and the following `days - 1` days, oldest first. */
export function daysFrom(start: string, days: number): string[] {
  const [from] = dayWindow(start);
  return Array.from({ length: Math.max(1, Math.min(60, Math.floor(days))) }, (_, i) => dateOf(from + i * DAY));
}

/** Several days at once, oldest first (one `dayRows` per day). */
export function rangeRows(args: { fills: readonly FillWire[]; days: readonly string[]; prices: Record<string, number>; qualifierUsd: number; exclude: readonly string[] }): Array<{ day: string; rows: DayRow[] }> {
  return args.days.map((day) => ({ day, rows: dayRows({ ...args, day }) }));
}

/** Rows as CSV, one line per address and day, qualifiers first within a day. */
export function rangeCsv(groups: ReadonlyArray<{ day: string; rows: readonly DayRow[] }>): string {
  return [`day,address,usd,fills,unsized,qualifies`, ...groups.flatMap((g) => g.rows.map((r) => `${g.day},${r.address},${r.usd},${r.fills},${r.unsized},${r.qualifies}`))].join("\n") + "\n";
}

/** The day's list as CSV, qualifiers first. */
export function dayCsv(day: string, rows: readonly DayRow[]): string {
  return rangeCsv([{ day, rows }]);
}

/**
 * What the order form and the book SHOW for a ticket — pure, so every figure on
 * screen is pinned by a test rather than assembled inline in JSX.
 *
 * Market tickets have ONE price: the filler's indicative quote (lib/quote.ts)
 * whenever there is one. Receive, effective price, "versus mid" and the minimum
 * all derive from it. The local ladder walk is only the fallback when no quote
 * exists (mock book, no filler on the chain, endpoint down) — mixing the two put
 * a quote above mid next to a ladder average 4 % below it (2026-10-11).
 */
import { WRAP_GAS_RESERVE_WEI } from "./funding";
import type { Quote } from "./ladder";
import { toWei } from "./order";
import type { QuoteView } from "./quote";
import type { Side } from "./types";

export interface MarketFigures {
  /** Where the numbers come from: the filler's quote, or the local ladder estimate. */
  basis: "quote" | "ladder";
  /** PAY amount the figures are for. */
  amountIn: number;
  /** ≈ what the maker receives (net of the filler's gas when quoted). */
  receive: number;
  /** Effective price, QUOTE per BASE, of `receive` for `amountIn`. */
  price: number;
  /** Guaranteed minimum receive. */
  minOut: number;
  /** The price at that minimum, QUOTE per BASE. */
  minPrice: number;
  /** `price` against the mid, percent; null without a mid. */
  vsMidPct: number | null;
  /** Network gas charged into the output (incl. the filler's margin), RECEIVE token; null = unknown. */
  networkFee: number | null;
  /** That fee as bps of the gross output. */
  networkFeeBps: number | null;
  /** Quoted tickets: the route's output BEFORE the network fee (receive = gross − fee); null for the ladder estimate. */
  grossReceive: number | null;
  /** Of `networkFee`, the in-fill ERC-2612 permit (gasless tickets); null when there is none. */
  permitFee: number | null;
  /** The route the filler quoted ("sushi", "uniswap"…); null for the ladder estimate. */
  source: string | null;
  /** False while the filler quotes in dry-run mode (it will not fill). */
  live: boolean;
  /** The quoted pool route's hops, for the "how is this filled" hover. */
  path?: import("./quote").FillerQuote["path"];
}

/** QUOTE per BASE for `amountIn` PAY → `out` RECEIVE. */
export function effectivePrice(side: Side, amountIn: number, out: number): number {
  if (!(amountIn > 0) || !(out > 0)) return 0;
  return side === "sell" ? out / amountIn : amountIn / out;
}

export interface FigureArgs {
  side: Side;
  /** The filler's quote, already folded with the maker's slippage. */
  rfq: QuoteView | null;
  /** The ladder walk (fallback only). */
  ladder: Quote | null;
  /** The fallback plan's signed minimum (gas-sized floor); defaults to the walk's flat floor. */
  fallbackMinOut?: number | null;
  /** The fallback's gas estimate in RECEIVE units, when the floor was gas-sized. */
  fallbackGas?: number | null;
  mid: number | null;
}

export function marketFigures(a: FigureArgs): MarketFigures | null {
  const vs = (px: number) => (a.mid && a.mid > 0 && px > 0 ? (px / a.mid - 1) * 100 : null);
  if (a.rfq && a.rfq.amountIn > 0 && a.rfq.receive > 0) {
    const r = a.rfq;
    const price = effectivePrice(a.side, r.amountIn, r.receive);
    return {
      basis: "quote",
      amountIn: r.amountIn,
      receive: r.receive,
      price,
      minOut: r.minOut,
      minPrice: effectivePrice(a.side, r.amountIn, r.minOut),
      vsMidPct: vs(price),
      networkFee: r.gas,
      networkFeeBps: r.gasBps,
      grossReceive: r.gross,
      permitFee: r.permitGas > 0 ? r.permitGas : null,
      source: r.source,
      live: r.live,
      ...(r.path ? { path: r.path } : {}),
    };
  }
  const q = a.ladder;
  if (!q || !(q.filledIn > 0) || !(q.crossedOut > 0)) return null;
  const minOut = a.fallbackMinOut ?? q.minReceived;
  const price = effectivePrice(a.side, q.filledIn, q.crossedOut);
  const gas = a.fallbackGas ?? null;
  return {
    basis: "ladder",
    amountIn: q.filledIn,
    receive: q.crossedOut,
    price,
    minOut,
    minPrice: effectivePrice(a.side, q.filledIn, minOut),
    vsMidPct: vs(price),
    networkFee: gas,
    networkFeeBps: gas !== null && q.crossedOut > 0 ? Math.round((gas / q.crossedOut) * 10_000) : null,
    grossReceive: null,
    permitFee: null,
    source: null,
    live: true,
  };
}

/** "sushi" → "Sushi", "uniswap-v3" → "Uniswap v3". */
export function sourceName(source: string | null): string {
  if (!source || source === "?") return "our filler";
  // A mixed pool route ("oku+sushi-v3"): every venue it swaps on, in hop order.
  if (source.includes("+")) return [...new Set(source.split("+").map((x) => sourceName(x)))].join(" + ");
  const s = source.toLowerCase();
  if (s.startsWith("sushi")) return "Sushi";
  if (s.startsWith("uni")) return "Uniswap";
  // Oku runs a Uniswap v3 deployment (and is our tick indexer, not a quote source): the venue is Uniswap.
  if (s.startsWith("oku")) return "Uniswap";
  if (s.startsWith("inventory")) return "filler inventory";
  // The RIF rail: RIF from the filler's inventory, priced at Money on Chain's redemption rate.
  if (s.startsWith("moc")) return "Money on Chain";
  return source.charAt(0).toUpperCase() + source.slice(1);
}

// ---------------------------------------------------------------- book marker

/**
 * Where a price slots into one side of the displayed ladder: the index of the
 * first row it sits in front of. `descending` for bids (best = highest first),
 * ascending for asks (best = lowest first). `prices.length` = past every row.
 */
export function markerIndex(prices: readonly number[], price: number, descending: boolean): number {
  let i = 0;
  while (i < prices.length && (descending ? prices[i]! > price : prices[i]! < price)) i++;
  return i;
}

export interface QuoteMarkers {
  /** The ladder side a market ticket takes from: a sell hits the bids, a buy lifts the asks. */
  side: "bid" | "ask";
  price: number;
  minPrice: number;
  /** Insertion index in the side's rows (best-first order). */
  index: number;
  minIndex: number;
}

export function quoteMarkers(side: Side, f: Pick<MarketFigures, "price" | "minPrice">, bestFirstPrices: readonly number[]): QuoteMarkers | null {
  if (!(f.price > 0)) return null;
  const descending = side === "sell";
  return {
    side: side === "sell" ? "bid" : "ask",
    price: f.price,
    minPrice: f.minPrice,
    index: markerIndex(bestFirstPrices, f.price, descending),
    minIndex: f.minPrice > 0 ? markerIndex(bestFirstPrices, f.minPrice, descending) : -1,
  };
}

// ---------------------------------------------------------------- balances

/** Truncate (never round UP — a balance must not read as more than you hold). */
function trunc(n: number, dp: number): number {
  const f = 10 ** dp;
  return Math.floor(n * f + 1e-9) / f;
}

/** A wallet balance for display: truncated, separators, at most ~4 significant decimals. */
export function fmtBalance(n: number): string {
  if (!Number.isFinite(n)) return "—";
  if (n <= 0) return "0";
  const dp = n >= 1000 ? 2 : n >= 1 ? 4 : Math.min(8, Math.max(4, -Math.floor(Math.log10(n)) + 3));
  const v = trunc(n, dp);
  if (v === 0) return `<${(10 ** -dp).toFixed(dp)}`;
  return v.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: dp });
}

/** Gas kept back when "Max" spends a NATIVE coin (wei); ERC-20s are spent in full. */
export const NATIVE_GAS_RESERVE_WEI = 10n ** 14n; // 0.0001 RBTC ≈ a few approvals on Rootstock

/** What "Max" fills: the whole balance for an ERC-20, the balance less a gas reserve for a native coin. */
export function maxSpendableWei(balance: bigint, native: boolean, reserve: bigint = NATIVE_GAS_RESERVE_WEI): bigint {
  if (balance <= 0n) return 0n;
  if (!native) return balance;
  return balance > reserve ? balance - reserve : 0n;
}

/**
 * What a ticket that SELLS the wrapped native coin (WRBTC) can spend, wei: the
 * wrapped balance plus whatever native coin (RBTC) is above the gas reserve — the
 * funding plan wraps the shortfall first (lib/funding.ts). Unknown while the
 * wrapped balance is; an unread native balance adds nothing (never assumed).
 */
export function wrapSpendableWei(
  tokenWei: bigint | undefined,
  nativeWei: bigint | undefined,
  reserve: bigint = WRAP_GAS_RESERVE_WEI,
): bigint | undefined {
  if (tokenWei === undefined) return undefined;
  return tokenWei + wrappableWei(nativeWei, reserve);
}

/** The native coin a wrap may use: the balance above the gas reserve, never negative. */
export function wrappableWei(nativeWei: bigint | undefined, reserve: bigint = WRAP_GAS_RESERVE_WEI): bigint {
  return nativeWei !== undefined && nativeWei > reserve ? nativeWei - reserve : 0n;
}

export type BalanceState =
  | { kind: "disconnected"; text: string }
  | { kind: "wrong-network"; text: string }
  | { kind: "loading"; text: string }
  /**
   * `wrap`: part of `value` is native coin the ticket auto-wraps. The line shows the TOTAL
   * (one short figure that fits the field's top row) plus a small `+RBTC` tag whose
   * tooltip spells out the split.
   */
  | { kind: "ok"; text: string; value: number; wrap?: { tag: string; note: string } };

/**
 * One balance line: a number only when it can be one. `wrappable` is native coin
 * the ticket auto-wraps (already net of the gas reserve): it is added to the
 * value and named on the line, "0.01 WRBTC + 0.04995 RBTC (auto-wrapped)".
 */
export function balanceState(a: {
  connected: boolean;
  onChain: boolean;
  value: number | undefined;
  symbol: string;
  wrappable?: { value: number; symbol: string } | null;
}): BalanceState {
  if (!a.connected) return { kind: "disconnected", text: "Connect wallet" };
  if (!a.onChain) return { kind: "wrong-network", text: "Wrong network" };
  if (a.value === undefined) return { kind: "loading", text: "…" };
  const w = a.wrappable;
  if (w && w.value > 0) {
    return {
      kind: "ok",
      text: `${fmtBalance(a.value + w.value)} ${a.symbol}`,
      value: a.value + w.value,
      wrap: {
        tag: `+${w.symbol}`,
        note: `${fmtBalance(a.value)} ${a.symbol} + ${fmtBalance(w.value)} ${w.symbol} — the ${w.symbol} is wrapped to ${a.symbol} when you sign (gas reserve kept)`,
      },
    };
  }
  return { kind: "ok", text: `${fmtBalance(a.value)} ${a.symbol}`, value: a.value };
}

/** The sign button: its label and whether it can be pressed. */
export function signButton(a: {
  signing: boolean;
  amount: number;
  overBalance: boolean;
  payToken: string;
  ready: boolean;
  quoting: boolean;
  priced: boolean;
}): { label: string; disabled: boolean } {
  if (a.signing) return { label: "Waiting for signature…", disabled: true };
  if (!(a.amount > 0)) return { label: "Enter an amount", disabled: true };
  if (a.overBalance) return { label: `Insufficient ${a.payToken} balance`, disabled: true };
  if (!a.ready) return { label: "Waiting for the book…", disabled: true };
  if (!a.priced) return { label: a.quoting ? "Fetching quote…" : "No price for this size", disabled: true };
  return { label: "Sign order", disabled: false };
}

// ---------------------------------------------------------------- details disclosure

export const DETAILS_KEY = "1dx.form.details";

/** Closed by default; any storage failure (private mode, blocked site data) reads as closed. */
export function readDetailsOpen(storage: Pick<Storage, "getItem"> | undefined): boolean {
  try {
    return storage?.getItem(DETAILS_KEY) === "open";
  } catch {
    return false;
  }
}

export function writeDetailsOpen(storage: Pick<Storage, "setItem"> | undefined, open: boolean): void {
  try {
    storage?.setItem(DETAILS_KEY, open ? "open" : "closed");
  } catch {
    // per-viewer convenience only
  }
}

/** A soft exclusivity window, when the deployment opted in; null = nothing to say. */
export function exclusivityLabel(d: { direct: boolean; windowSeconds: number; overrideBps: number }): string | null {
  if (d.direct || d.windowSeconds <= 0) return null;
  const n = Math.max(1, Math.round(d.windowSeconds / 30));
  return `our solver first for ~${n} block${n === 1 ? "" : "s"} (others pay you +${d.overrideBps} bps)`;
}

/** A small fee: two significant figures below 1 ("0.71", "0.0000084"), else the usual amount format. */
export function fmtFee(n: number): string {
  if (!Number.isFinite(n)) return "—";
  if (n <= 0) return "0";
  if (n >= 1) return n >= 1000 ? Math.round(n).toLocaleString("en-US") : n.toFixed(2);
  return String(Number(n.toPrecision(2)));
}

/**
 * Whether the TYPED amount is more than the wallet holds, in wei. The order itself
 * is capped at the balance (G-TS_SIGN-7), so comparing the capped commitment could
 * never say "insufficient" — the ticket would silently trade less than typed.
 * Compared on the exact decimal string, so "Max" (the exact balance) is never over.
 */
export function exceedsBalance(typed: string, decimals: number | undefined, balanceWei: bigint | undefined): boolean {
  if (balanceWei === undefined || decimals === undefined) return false;
  return toWei(typed, decimals) > balanceWei;
}

/** "Uniswap v3" / "SushiSwap v3" for a route venue key (`oku`, `sushi-v3`). */
export function routeVenueName(v: string): string {
  return v === "oku" ? "Uniswap v3" : v.startsWith("sushi") ? "SushiSwap v3" : v;
}

/**
 * The hover on "Swap output": who fills it and over which pools —
 * "Filled by the 1delta solver: USD0 → RIF on Uniswap v3 (0.30 %) → RIFP on SushiSwap v3 (0.30 %)".
 */
export function routeHover(source: string | null, path: { tokens: string[]; fees: number[]; venues: string[] } | undefined, symbolOf: (address: string) => string): string {
  if (source?.toLowerCase().startsWith("moc")) return "Filled from the 1delta filler's RIF inventory, priced at the Money on Chain redemption rate (USD₮0 → USDRIF → RIF)";
  if (!path) return `Filled by the 1delta solver via ${sourceName(source)}`;
  const hops = path.fees.map((f, i) => `${symbolOf(path.tokens[i + 1]!)} on ${routeVenueName(path.venues[i] ?? "")} (${(f / 10_000).toFixed(2)} %)`);
  return `Filled by the 1delta solver: ${symbolOf(path.tokens[0]!)} → ${hops.join(" → ")}`;
}

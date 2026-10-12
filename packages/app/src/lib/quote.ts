/**
 * INDICATIVE FILLER QUOTES for market tickets (2026-10-07) — UniswapX-style.
 *
 * The app asks our filler (`POST /api/quote` → the Pages worker → the filler Worker's
 * `POST /quote`, packages/beta-filler src/quote.ts) what it would deliver for this
 * ticket NOW:
 *
 *     amountOut = route output − one fill's gas × (1 + the filler's gas margin, +20 %)
 *
 * and shows it as "you receive ≈ amountOut". The signed market order is a short DUTCH
 * order that STARTS at the quote and decays to the maker's slippage protection —
 * `amountOut × (1 − slippage)` — over QUOTED_DECAY_SECONDS (210 s, plan.ts);
 * its life stays MARKET_TTL_SECONDS (300 s) so the book / filler gates hold. The filler
 * fills it on its next tick when the price held (the start is its own break-even plus
 * the gas margin), or a little down the decay when it moved; never below the minimum.
 *
 * Slippage is the maker's: "auto" = {@link SLIPPAGE_DEFAULT_BPS} (10 bps when both legs
 * are $1 tokens, 30 bps otherwise), or a custom value in [1, {@link MAX_SLIPPAGE_BPS}].
 *
 * When the quote is unavailable (no filler on the chain, the endpoint down, a 4xx) the
 * market ticket falls back to the ticket-sized gas floor (lib/marketFloor.ts) — the
 * pre-quote Dutch path, unchanged.
 *
 * Pure (no `import.meta.env`, no React): the filler-worker app-shape e2e signs exactly
 * this shape with this code.
 */
import { formatUnits, getAddress, isAddress, zeroAddress, type Address } from "viem";

import { solverForMarket, type DeploymentConfig } from "../config/deploymentConfig";
import { FLOOR_PROFILES } from "./marketFloor";
import type { Side } from "./types";

/** Default slippage protection, bps under the quote: stable pair / anything else. */
export const SLIPPAGE_DEFAULT_BPS = Object.freeze({ stable: 10, volatile: 30 });
/** A custom slippage above this is refused (5 %): a market order is not a limit order. */
export const MAX_SLIPPAGE_BPS = 500;
/** Re-quote this often while a market ticket is on screen, ms (~half a Rootstock block). */
export const QUOTE_REFRESH_MS = 15_000;
/** Wait this long after the last keystroke before quoting a new amount, ms. */
export const QUOTE_DEBOUNCE_MS = 400;

/** The filler serves quotes only where it runs: chains with a FloorProfile (Rootstock). */
export function quotesSupported(chainId: number): boolean {
  return FLOOR_PROFILES[chainId] !== undefined;
}

/** Auto slippage for a market: stable when BOTH legs are the chain's $1 tokens. */
export function defaultSlippageBps(chainId: number, base: string, quote: string): number {
  const usd = FLOOR_PROFILES[chainId]?.usd ?? [];
  return usd.includes(base) && usd.includes(quote) ? SLIPPAGE_DEFAULT_BPS.stable : SLIPPAGE_DEFAULT_BPS.volatile;
}

/**
 * Of the quote's gas charge, the share the AUTO slippage adds as headroom (2026-10-12).
 * The filler's fill gate prices the fill from Rootstock's simulation, the quote from a
 * learned / default estimate; they can differ by tens of thousands of gas (the first v2
 * fill: simulated 424k vs quoted 350k, +10 % of the charge), and the band must absorb
 * that or the order expires. In bps of the ticket that headroom only matters where gas
 * is a big share — a $16 USDRIF ticket pays ~4.3 % gas (→ +109 bps), $1,000 ~0.07 %
 * (→ +2 bps) — so it scales with the gas share instead of one flat band.
 */
export const GAS_SLIPPAGE_SHARE = 0.25;
/** The auto band never goes above this (3 %); a custom one may, up to MAX_SLIPPAGE_BPS. */
export const AUTO_SLIPPAGE_CAP_BPS = 300;

/**
 * Auto slippage for a quoted ticket: the pair's base band + {@link GAS_SLIPPAGE_SHARE}
 * of the quote's gas charge (bps of its gross output). No quote → the base band.
 */
export function autoSlippageBps(baseBps: number, q: Pick<FillerQuote, "gasChargeOut" | "grossOut"> | null | undefined): number {
  if (!q || q.grossOut <= 0n) return baseBps;
  const gasBps = Number((q.gasChargeOut * 10_000n) / q.grossOut);
  return Math.min(AUTO_SLIPPAGE_CAP_BPS, Math.max(baseBps, baseBps + Math.ceil(gasBps * GAS_SLIPPAGE_SHARE)));
}

/** The maker's slippage choice. */
export type SlippageSetting = { mode: "auto" } | { mode: "custom"; bps: number };

/** Effective slippage bps for a setting (a custom value is clamped to [1, MAX_SLIPPAGE_BPS]). */
export function slippageBpsFor(s: SlippageSetting, autoBps: number): number {
  if (s.mode === "auto") return autoBps;
  const v = Math.round(s.bps);
  return Number.isFinite(v) ? Math.min(MAX_SLIPPAGE_BPS, Math.max(1, v)) : autoBps;
}

/** How the app signs a market's orders: direct (delta-verify to a named solver) or pull. */
export function quoteDelivery(deployment: DeploymentConfig | null, marketId: string): "direct" | "pull" {
  const s = solverForMarket(deployment, marketId);
  return s && s !== zeroAddress ? "direct" : "pull";
}

export interface QuoteRequest {
  chainId: number;
  marketId: string;
  side: Side;
  tokenIn: Address;
  tokenOut: Address;
  /** Exact input, wei of the PAY token (a buy pays the quote token). */
  amountIn: bigint;
  maker?: Address;
  delivery: "direct" | "pull";
  /** `permit`: the order will be funded by a gasless ERC-2612 permit the fill executes (more gas). */
  funding?: "permit";
}

/** A validated filler quote. */
export interface FillerQuote {
  quoteId: string;
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  /** What the order starts at, wei of the RECEIVE token. */
  amountOut: bigint;
  grossOut: bigint;
  gasUnits: bigint;
  gasCostOut: bigint;
  /** Gas incl. the filler's margin: grossOut − amountOut (+ any tolerance). */
  gasChargeOut: bigint;
  /** Of `gasChargeOut`, the in-fill ERC-2612 permit's share (`funding: "permit"`); 0 otherwise / from an older filler. */
  permitChargeOut: bigint;
  gasMarginBps: number;
  issuedAt: number;
  /** Unix seconds. */
  validUntil: number;
  strategy: string;
  source: string;
  delivery: "direct" | "pull";
  /** False while the filler runs dry (it quotes but does not fill). */
  live: boolean;
}

export class QuoteError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const big = (v: unknown, what: string): bigint => {
  if (typeof v !== "string" || !/^\d{1,78}$/.test(v)) throw new QuoteError(0, `quote: bad ${what}`);
  return BigInt(v);
};

/**
 * Parse and CHECK a `/quote` answer against the request it answers: same chain, tokens
 * and input; a positive output no larger than the gross; a validity in the future.
 * Anything else throws — a quote the app cannot trust is no quote (Dutch fallback).
 */
export function parseQuote(raw: unknown, req: Pick<QuoteRequest, "chainId" | "tokenIn" | "tokenOut" | "amountIn">, nowS: number = Math.floor(Date.now() / 1000)): FillerQuote {
  if (!raw || typeof raw !== "object") throw new QuoteError(0, "quote: not an object");
  const o = raw as Record<string, unknown>;
  const addr = (v: unknown, what: string): Address => {
    if (typeof v !== "string" || !isAddress(v, { strict: false })) throw new QuoteError(0, `quote: bad ${what}`);
    return getAddress(v);
  };
  const q: FillerQuote = {
    quoteId: typeof o.quoteId === "string" && /^[\w-]{1,64}$/.test(o.quoteId) ? o.quoteId : (() => { throw new QuoteError(0, "quote: bad quoteId"); })(),
    chainId: Number(o.chainId),
    tokenIn: addr(o.tokenIn, "tokenIn"),
    tokenOut: addr(o.tokenOut, "tokenOut"),
    amountIn: big(o.amountIn, "amountIn"),
    amountOut: big(o.amountOut, "amountOut"),
    grossOut: big(o.grossOut, "grossOut"),
    gasUnits: big(o.gasUnits, "gasUnits"),
    gasCostOut: big(o.gasCostOut, "gasCostOut"),
    gasChargeOut: big(o.gasChargeOut, "gasChargeOut"),
    permitChargeOut: o.permitChargeOut === undefined ? 0n : big(o.permitChargeOut, "permitChargeOut"),
    gasMarginBps: Number(big(o.gasMarginBps, "gasMarginBps")),
    issuedAt: Number(o.issuedAt),
    validUntil: Number(o.validUntil),
    strategy: typeof o.strategy === "string" ? o.strategy.slice(0, 20) : "?",
    source: typeof (o.route as { source?: unknown } | undefined)?.source === "string" ? String((o.route as { source: string }).source).slice(0, 20) : "?",
    delivery: o.delivery === "direct" ? "direct" : "pull",
    live: o.live !== false,
  };
  if (q.chainId !== req.chainId) throw new QuoteError(0, "quote: wrong chain");
  if (q.tokenIn !== getAddress(req.tokenIn) || q.tokenOut !== getAddress(req.tokenOut)) throw new QuoteError(0, "quote: wrong tokens");
  if (q.amountIn !== req.amountIn) throw new QuoteError(0, "quote: wrong amountIn");
  if (q.amountOut === 0n || q.amountOut > q.grossOut) throw new QuoteError(0, "quote: bad amountOut");
  if (q.permitChargeOut > q.gasChargeOut) throw new QuoteError(0, "quote: bad permitChargeOut");
  if (!Number.isFinite(q.validUntil) || q.validUntil < nowS) throw new QuoteError(0, "quote: expired");
  return q;
}

type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

/** POST the request; a parsed, checked quote — or a {@link QuoteError} (status 0 = network / bad answer). */
export async function fetchQuote(doFetch: FetchLike, url: string, req: QuoteRequest, signal?: AbortSignal): Promise<FillerQuote> {
  const body = JSON.stringify({
    chainId: req.chainId,
    // Tokens only: the pair is whatever the user picked, and a derived (routed) market
    // has an id the filler never heard of. The filler routes by tokens (ROUTE_TOKENS).
    side: req.side,
    tokenIn: req.tokenIn,
    tokenOut: req.tokenOut,
    amountIn: req.amountIn.toString(),
    delivery: req.delivery,
    ...(req.maker ? { maker: req.maker } : {}),
    ...(req.funding === "permit" ? { funding: "permit" } : {}),
  });
  let res: Response;
  try {
    res = await doFetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json" }, body, ...(signal ? { signal } : {}) });
  } catch (e) {
    throw new QuoteError(0, `quote unavailable: ${e instanceof Error ? e.message : String(e)}`);
  }
  const j = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (!res.ok) throw new QuoteError(res.status, typeof j.error === "string" ? `${j.error}${typeof j.reason === "string" ? `: ${j.reason}` : ""}` : `quote failed (${res.status})`);
  return parseQuote(j, req);
}

/** What a quoted market ticket signs, in human units of each leg. */
export interface QuotedTerms {
  /** PAY amount (the quoted input). */
  amountIn: number;
  /** The Dutch start: the quote. */
  targetOut: number;
  /** The slippage protection: quote × (1 − slippage). */
  minOut: number;
  slippageBps: number;
}

/**
 * The quote → the order's terms. Converted through exact decimal strings (formatUnits),
 * so the signed start is the quoted wei up to the leg's own decimals.
 */
export function quotedTerms(q: FillerQuote, a: { payDecimals: number; recvDecimals: number; slippageBps: number }): QuotedTerms {
  const targetOut = Number(formatUnits(q.amountOut, a.recvDecimals));
  return {
    amountIn: Number(formatUnits(q.amountIn, a.payDecimals)),
    targetOut,
    minOut: Number(formatUnits((q.amountOut * BigInt(10_000 - a.slippageBps)) / 10_000n, a.recvDecimals)),
    slippageBps: a.slippageBps,
  };
}

/** What the form shows for a quoted ticket. */
export interface QuoteView {
  quoteId: string;
  /** PAY amount quoted (the ticket, capped at the balance). */
  amountIn: number;
  /** ≈ what the maker receives: the quote. */
  receive: number;
  /** The route's output before gas. */
  gross: number;
  /** Gas incl. the filler's margin, RECEIVE token. */
  gas: number;
  /** That gas as a share of the ticket, bps of the gross. */
  gasBps: number;
  /** Of `gas`, the part the in-fill ERC-2612 permit costs (gasless tickets); 0 otherwise. */
  permitGas: number;
  gasMarginBps: number;
  minOut: number;
  slippageBps: number;
  source: string;
  validUntil: number;
  live: boolean;
}

export function quoteView(q: FillerQuote, terms: QuotedTerms, recvDecimals: number): QuoteView {
  const gas = Number(formatUnits(q.gasChargeOut, recvDecimals));
  const gross = Number(formatUnits(q.grossOut, recvDecimals));
  return {
    quoteId: q.quoteId,
    amountIn: terms.amountIn,
    receive: terms.targetOut,
    gross,
    gas,
    gasBps: gross > 0 ? Math.round((gas / gross) * 10_000) : 0,
    permitGas: Number(formatUnits(q.permitChargeOut, recvDecimals)),
    gasMarginBps: q.gasMarginBps,
    minOut: terms.minOut,
    slippageBps: terms.slippageBps,
    source: q.source,
    validUntil: q.validUntil,
    live: q.live,
  };
}

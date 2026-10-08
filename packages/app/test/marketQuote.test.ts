/**
 * 2026-10-07: market tickets are priced by the FILLER's indicative quote (lib/quote.ts):
 * a Dutch order that STARTS at the quote (route output − gas × 1.2) and decays to the
 * maker's slippage protection over QUOTED_DECAY_SECONDS; no quote → the gas-floor path.
 */
import { OrderSide } from "@1delta-x/sdk";
import { getAddress, zeroAddress, type Address } from "viem";
import { describe, expect, it } from "vitest";

import { quoteMatches, type IssuedQuote } from "../../beta-filler/src/quote";
import { parseDeployments } from "../src/config/deploymentConfig";
import { pinnedToken } from "../src/config/markets";
import { quoteUrl } from "../src/hooks/useMarketQuote";
import { quote as ladderQuote } from "../src/lib/ladder";
import { floorInputsFor } from "../src/lib/marketFloor";
import { buildOrder } from "../src/lib/order";
import { MARKET_DECAY_SECONDS, QUOTED_DECAY_SECONDS, MARKET_SLIPPAGE_BPS, MARKET_TTL_SECONDS, planTicket } from "../src/lib/plan";
import {
  defaultSlippageBps,
  fetchQuote,
  MAX_SLIPPAGE_BPS,
  parseQuote,
  QuoteError,
  quoteDelivery,
  quotedTerms,
  quotesSupported,
  quoteView,
  slippageBpsFor,
  SLIPPAGE_DEFAULT_BPS,
  type FillerQuote,
  type QuoteRequest,
} from "../src/lib/quote";
import type { Level } from "../src/lib/types";

const WRBTC = getAddress(pinnedToken(30, "WRBTC")!.address);
const USD0 = getAddress(pinnedToken(30, "USD0")!.address);
const USDRIF = getAddress(pinnedToken(30, "USDRIF")!.address);
const MAKER = "0x00000000000000000000000000000000000000bb" as Address;
const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const NOW = 1_800_000_000;
const deployment = parseDeployments(
  JSON.stringify({
    30: { settlement: "0x1111111111111111111111111111111111111111", permit3: "0x2222222222222222222222222222222222222222", lens: "0x3333333333333333333333333333333333333333", solver: SOLVER, marketSolvers: { "rsk-30-usdrif-usd0": "pull" } },
  }),
)[30]!;

/** The filler's `/quote` JSON for 0.01 WRBTC → USD0: gross $1000, gas $0.9175 × 1.2. */
const sellJson = (over: Record<string, unknown> = {}) => ({
  quoteId: "q_0123456789abcdef01234567",
  chainId: 30,
  side: "sell",
  marketId: "rsk-30-wrbtc-usd0",
  delivery: "direct",
  tokenIn: WRBTC,
  tokenOut: USD0,
  amountIn: "10000000000000000",
  amountOut: "998898988",
  grossOut: "1000000000",
  gasUnits: "352000",
  gasPriceWei: "26065600",
  gasCostOut: "917510",
  gasChargeOut: "1101012",
  gasMarginBps: "2000",
  toleranceBps: "0",
  toleranceOut: "0",
  issuedAt: NOW * 1000,
  validUntil: NOW + 30,
  strategy: "route",
  route: { source: "oku", hops: 1 },
  live: true,
  ...over,
});
const sellReq: QuoteRequest = { chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", tokenIn: WRBTC, tokenOut: USD0, amountIn: 10n ** 16n, delivery: "direct", maker: MAKER };
const sellQuote = (): FillerQuote => parseQuote(sellJson(), sellReq, NOW);

/** One rung at mid each side, sized far beyond the ticket (as the e2e builds it). */
function ladder(mid: number, side: "sell" | "buy", amount: number) {
  const rung = (price: number): Level => ({ price, size: 1e12, source: "UNI" });
  return ladderQuote({ bids: [rung(mid)], asks: [rung(mid)], side, amountIn: amount, limit: null, slippageBps: MARKET_SLIPPAGE_BPS });
}

describe("parseQuote: a quote the app cannot trust is no quote", () => {
  it("parses the filler's JSON (bigints from decimal strings)", () => {
    const q = sellQuote();
    expect(q).toMatchObject({ amountOut: 998_898_988n, grossOut: 1_000_000_000n, gasChargeOut: 1_101_012n, gasMarginBps: 2000, source: "oku", delivery: "direct", live: true });
  });
  it.each([
    ["another chain", { chainId: 31 }, /wrong chain/],
    ["other tokens", { tokenOut: USDRIF }, /wrong tokens/],
    ["another input", { amountIn: "1" }, /wrong amountIn/],
    ["a zero output", { amountOut: "0" }, /bad amountOut/],
    ["an output above the gross", { amountOut: "1000000001" }, /bad amountOut/],
    ["an expired quote", { validUntil: NOW - 1 }, /expired/],
    ["a non-numeric amount", { amountOut: "1e9" }, /bad amountOut/],
    ["a bad id", { quoteId: "<script>" }, /quoteId/],
  ])("refuses %s", (_w, over, why) => {
    expect(() => parseQuote(sellJson(over), sellReq, NOW)).toThrow(why);
  });
});

describe("fetchQuote: the request the app sends, the errors it maps", () => {
  it("POSTs JSON (amountIn as a decimal string, maker, delivery) to /api/quote", async () => {
    let seen: { url: string; init: RequestInit } | undefined;
    const q = await fetchQuote(async (url, init) => {
      seen = { url, init: init! };
      return Response.json({ ...sellJson(), validUntil: Math.floor(Date.now() / 1000) + 30 });
    }, "/api/quote", sellReq);
    expect(q.amountOut).toBe(998_898_988n);
    expect(seen!.url).toBe("/api/quote");
    expect(seen!.init.method).toBe("POST");
    expect(JSON.parse(String(seen!.init.body))).toEqual({ chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", tokenIn: WRBTC, tokenOut: USD0, amountIn: "10000000000000000", delivery: "direct", maker: MAKER });
  });
  it("a non-2xx answer is a QuoteError with its status and reason; a network failure is status 0", async () => {
    const e1 = await fetchQuote(async () => Response.json({ error: "no quote", reason: "gas exceeds the output" }, { status: 422 }), "/api/quote", sellReq).catch((e) => e);
    expect(e1).toBeInstanceOf(QuoteError);
    expect([e1.status, e1.message]).toEqual([422, "no quote: gas exceeds the output"]);
    const e2 = await fetchQuote(async () => { throw new TypeError("Failed to fetch"); }, "/api/quote", sellReq).catch((e) => e);
    expect([e2.status, e2.message]).toEqual([0, "quote unavailable: Failed to fetch"]);
  });
  it("quoteUrl: VITE_QUOTE_URL, else /api/quote with a real book, else none (mock book)", () => {
    expect(quoteUrl(" https://q.example/quote/ ", false)).toBe("https://q.example/quote");
    expect(quoteUrl(undefined, true)).toBe("/api/quote");
    expect(quoteUrl("", false)).toBeNull();
  });
});

describe("slippage: auto 10 bps on stable pairs, 30 bps otherwise; custom within [1, 500]", () => {
  it("defaults", () => {
    expect(SLIPPAGE_DEFAULT_BPS).toEqual({ stable: 10, volatile: 30 });
    expect(defaultSlippageBps(30, "USDRIF", "USD0")).toBe(10);
    expect(defaultSlippageBps(30, "WRBTC", "USD0")).toBe(30);
    expect(defaultSlippageBps(30, "WETH", "WRBTC")).toBe(30);
  });
  it("custom values are clamped", () => {
    expect(slippageBpsFor({ mode: "auto" }, 30)).toBe(30);
    expect(slippageBpsFor({ mode: "custom", bps: 75 }, 30)).toBe(75);
    expect(slippageBpsFor({ mode: "custom", bps: 0 }, 30)).toBe(1);
    expect(slippageBpsFor({ mode: "custom", bps: 10_000 }, 30)).toBe(MAX_SLIPPAGE_BPS);
    expect(slippageBpsFor({ mode: "custom", bps: Number.NaN }, 30)).toBe(30);
  });
  it("quotes only where a filler runs; delivery follows the deployment (direct = named solver, else pull)", () => {
    expect(quotesSupported(30)).toBe(true);
    expect(quotesSupported(1)).toBe(false);
    expect(quoteDelivery(deployment, "rsk-30-wrbtc-usd0")).toBe("direct");
    expect(quoteDelivery(deployment, "rsk-30-usdrif-usd0")).toBe("pull");
    expect(quoteDelivery(null, "rsk-30-wrbtc-usd0")).toBe("pull");
  });
});

describe("the quoted market order: a Dutch order that starts AT the quote", () => {
  const mid = 100_000;

  it("SELL: plan start = the quote, min = quote × (1 − 30 bps), 210 s decay, 300 s life; the order signs those exact wei", () => {
    const terms = quotedTerms(sellQuote(), { payDecimals: 18, recvDecimals: 6, slippageBps: 30 });
    const plan = planTicket({ q: ladder(mid, "sell", 0.01), mid, mode: "market", side: "sell", amount: 0.01, limit: null, slices: 1, everyMin: 1, quoted: terms })!;
    expect(plan).toMatchObject({ kind: "market", amountIn: 0.01, targetOut: 998.898988, decaySeconds: QUOTED_DECAY_SECONDS, ttlSeconds: MARKET_TTL_SECONDS });
    expect(plan.minOut).toBe(995.902291); // ⌊998898988 × 0.997⌋ wei
    expect(plan.floor).toBeUndefined();
    const { order } = buildOrder({
      maker: MAKER, side: "sell", pay: { address: WRBTC, decimals: 18 }, recv: { address: USD0, decimals: 6 },
      amountIn: plan.amountIn, targetOut: plan.targetOut, minOut: plan.minOut, ttlSeconds: plan.ttlSeconds, decaySeconds: plan.decaySeconds,
      solver: SOLVER, now: NOW, nonce: 1n,
    });
    expect(order.legsIn[0]).toMatchObject({ start: 10n ** 16n, end: 0n });
    expect(order.legsOut[0]).toMatchObject({ start: 998_898_988n, end: 995_902_291n });
    expect(order.exclusiveFiller).toBe(SOLVER);
    expect(order.expiry).toBe(BigInt(NOW + 300));
    // …and the FILLER recognises it as signed from its quote (beta-filler quoteMatches).
    const issued: IssuedQuote = { id: "q", tokenIn: WRBTC.toLowerCase(), tokenOut: USD0.toLowerCase(), amountIn: "10000000000000000", amountOut: "998898988", maker: MAKER.toLowerCase(), delivery: "direct", issuedAt: NOW * 1000, validUntil: NOW + 30 };
    expect(quoteMatches(issued, order, NOW + 10, 120)).toBe(true);
  });

  it("BUY ($20 USD0 → WRBTC): fixed output = the quote's minimum, the input RISES from the quoted rate to the full $20", () => {
    const json = sellJson({ side: "buy", tokenIn: USD0, tokenOut: WRBTC, amountIn: "20000000", amountOut: "198898988000000", grossOut: "200000000000000", gasChargeOut: "1101012000000" });
    const req = { ...sellReq, side: "buy" as const, tokenIn: USD0, tokenOut: WRBTC, amountIn: 20_000_000n };
    const fq = parseQuote(json, req, NOW);
    const terms = quotedTerms(fq, { payDecimals: 6, recvDecimals: 18, slippageBps: 30 });
    const plan = planTicket({ q: ladder(mid, "buy", 20), mid, mode: "market", side: "buy", amount: 20, limit: null, slices: 1, everyMin: 1, quoted: terms })!;
    const { order } = buildOrder({
      maker: MAKER, side: "buy", pay: { address: USD0, decimals: 6 }, recv: { address: WRBTC, decimals: 18 },
      amountIn: plan.amountIn, targetOut: plan.targetOut, minOut: plan.minOut, ttlSeconds: plan.ttlSeconds, decaySeconds: plan.decaySeconds,
      solver: SOLVER, now: NOW, nonce: 1n,
    });
    expect(order.side).toBe(OrderSide.BUY);
    expect(order.legsIn[0]!.end).toBe(20_000_000n);
    expect(order.legsIn[0]!.start).toBe(19_940_000n); // $20 × (1 − 30 bps): the quote's rate
    expect(order.legsOut[0]!.end).toBe(0n);
    // Start rate within 1 bp of the quote's (float rounding) — the filler matches it.
    const issued: IssuedQuote = { id: "q", tokenIn: USD0.toLowerCase(), tokenOut: WRBTC.toLowerCase(), amountIn: "20000000", amountOut: "198898988000000", maker: MAKER.toLowerCase(), delivery: "direct", issuedAt: NOW * 1000, validUntil: NOW + 30 };
    expect(quoteMatches(issued, order, NOW, 120)).toBe(true);
  });

  it("USDRIF→USD0 (stable, pull): auto slippage 10 bps; pull delivery (exclusiveFiller 0)", () => {
    const json = sellJson({ tokenIn: USDRIF, tokenOut: USD0, amountIn: "20000000000000000000", amountOut: "19858000", grossOut: "19960000", delivery: "pull" });
    const fq = parseQuote(json, { chainId: 30, tokenIn: USDRIF, tokenOut: USD0, amountIn: 20n * 10n ** 18n }, NOW);
    const terms = quotedTerms(fq, { payDecimals: 18, recvDecimals: 6, slippageBps: defaultSlippageBps(30, "USDRIF", "USD0") });
    expect(terms).toEqual({ amountIn: 20, targetOut: 19.858, minOut: 19.838142, slippageBps: 10 });
    const { order } = buildOrder({
      maker: MAKER, side: "sell", pay: { address: USDRIF, decimals: 18 }, recv: { address: USD0, decimals: 6 },
      amountIn: terms.amountIn, targetOut: terms.targetOut, minOut: terms.minOut, ttlSeconds: 300, decaySeconds: 60, now: NOW, nonce: 1n,
    });
    expect(order.exclusiveFiller).toBe(zeroAddress);
    expect(order.legsOut[0]).toMatchObject({ start: 19_858_000n, end: 19_838_142n });
  });

  it("the form's view: ≈ the quote, the gas (incl. margin) and its share of the ticket, the minimum", () => {
    const q = sellQuote();
    const v = quoteView(q, quotedTerms(q, { payDecimals: 18, recvDecimals: 6, slippageBps: 30 }), 6);
    expect(v).toMatchObject({ receive: 998.898988, gas: 1.101012, gasBps: 11, gasMarginBps: 2000, minOut: 995.902291, slippageBps: 30, source: "oku", live: true });
  });
});

describe("fallback: no quote → today's gas-sized Dutch floor", () => {
  it("planTicket without `quoted` signs the floor plan (marketFloor), unchanged", () => {
    const mid = 100_000;
    const floor = floorInputsFor({ chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", deployment, gasPriceWei: 24_406_880n, mid, nativeUsd: mid });
    const plan = planTicket({ q: ladder(mid, "sell", 0.0002), mid, mode: "market", side: "sell", amount: 0.0002, limit: null, slices: 1, everyMin: 1, floor })!;
    expect(plan.quoted).toBeUndefined();
    expect(plan.floor?.gasBound).toBe(true);
    expect(plan.targetOut).toBe(20);
    expect(plan.minOut).toBeCloseTo(20 * (1 - plan.floor!.bps / 10_000), 9);
    expect(plan.decaySeconds).toBe(MARKET_DECAY_SECONDS);
  });

  it("limit and TWAP tickets ignore a quote", () => {
    const terms = quotedTerms(sellQuote(), { payDecimals: 18, recvDecimals: 6, slippageBps: 30 });
    const lim = planTicket({ q: ladderQuote({ bids: [{ price: 100_000, size: 1e12, source: "UNI" }], asks: [{ price: 100_000, size: 1e12, source: "UNI" }], side: "sell", amountIn: 0.01, limit: 125_000, slippageBps: 30 }), mid: 100_000, mode: "limit", side: "sell", amount: 0.01, limit: 125_000, slices: 1, everyMin: 1, quoted: terms })!;
    expect(lim.kind).toBe("limit");
    expect(lim.quoted).toBeUndefined();
  });
});

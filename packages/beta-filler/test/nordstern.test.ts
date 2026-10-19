/**
 * The Nordstern API route source (2026-10-11, ./src/nordstern.ts): URL + Referer, the
 * packed-calldata decode, every fail-closed validation rule (one tamper case each),
 * the haircut pricing, the plan (NO amount patch), and the config defaults — Sushi's
 * executor pin included.
 */
import { NO_PATCH } from "@1delta-x/sdk";
import { concat, numberToHex, type Address, type Hex } from "viem";
import { describe, expect, it, vi } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import {
  NORDSTERN_EXECUTOR_ROOTSTOCK,
  NORDSTERN_GUARD_ROOTSTOCK,
  bpsToPercent,
  buildNordsternPlan,
  decodeNordstern,
  fetchNordsternRoute,
  nordsternPricedOut,
  nordsternUrl,
  validateNordsternRoute,
  type NordsternConfig,
  type NordsternRequest,
  type NordsternResponse,
} from "../src/nordstern";
import { rankRoutes } from "../src/route";
import { SUSHI_SNWAP_EXECUTOR_ROOTSTOCK } from "../src/sushi";

/** The live beta solver: the recipient the fixture below was requested for. */
const SOLVER = "0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287" as Address;
const EVIL = "0x000000000000000000000000000000000000dEaD" as Address;
const USDRIF = ROOTSTOCK.usdrif as Address;
const USDT0 = ROOTSTOCK.usdt0 as Address;

/**
 * Real `api.nordstern.finance/aggregator/30` response (2026-10-11, block 9,316,321):
 * 100 USDRIF → USDT0, from = the beta solver, slippage 0.1 % — one Oku v3 hop
 * (pool 0xd845…19d6) through executor 0xb4FE…5B36.
 */
const DATA =
  "0x3f0bde254e9eb4fe60cd05a3e68668007cee83ddfd9a50a45b3600000000000000056bc75e2d6310000000000000000000000000000005f0e45605b4fe60cd05a3e68668007cee83ddfd9a50a45b3633ccacb24da5c7f335819da877fc03e4bf62e2873a15461d8ae0f0fb5fa2629e9da7d66a794a6e37779ded0c9e1022225f8e0630b35a9b54be713736d845702af381f0405661747a6a20bde0401a19d607040201ff" as Hex;
const AMOUNT_IN = 100n * 10n ** 18n;
const TO_AMOUNT = 99_772_946n;
const MIN = 99_673_174n;

/** Hex surgery on the packed head: replace `len` bytes at byte `at` (selector included). */
const patch = (data: Hex, at: number, bytes: Hex): Hex => {
  const b = bytes.slice(2);
  return (data.slice(0, 2 + at * 2) + b + data.slice(2 + at * 2 + b.length)) as Hex;
};
const addr20 = (a: Address): Hex => a.toLowerCase() as Hex;
const u128 = (v: bigint): Hex => numberToHex(v, { size: 16 });

const req: NordsternRequest = { chainId: 30, tokenIn: USDRIF, tokenOut: USDT0, amountIn: AMOUNT_IN, recipient: SOLVER, slippageBps: 10n };
const cfg: NordsternConfig = {
  enabled: true,
  baseUrl: "https://api.nordstern.finance/",
  router: NORDSTERN_GUARD_ROOTSTOCK,
  executors: [NORDSTERN_EXECUTOR_ROOTSTOCK],
  referer: "https://1delta-x.pages.dev",
  timeoutMs: 1000,
  maxPerSweep: 10,
  haircutBps: 2n,
};
function body(over: Partial<NordsternResponse["tx"]> = {}, top: Partial<NordsternResponse> = {}): NordsternResponse {
  return {
    toAmount: TO_AMOUNT.toString(),
    minToAmount: MIN.toString(),
    gasEstimate: "68490",
    tx: { from: SOLVER, to: NORDSTERN_GUARD_ROOTSTOCK, data: DATA, value: "0", ...over },
    ...top,
  };
}

describe("nordsternUrl", () => {
  it("asks /aggregator/{chain} with PERCENT slippage = max(gate haircut, NORDSTERN_HAIRCUT_BPS) and from = the solver", () => {
    const u = new URL(nordsternUrl(cfg, req));
    expect(u.origin + u.pathname).toBe("https://api.nordstern.finance/aggregator/30");
    expect(u.searchParams.get("src")).toBe(USDRIF);
    expect(u.searchParams.get("dst")).toBe(USDT0);
    expect(u.searchParams.get("amount")).toBe(AMOUNT_IN.toString());
    expect(u.searchParams.get("from")).toBe(SOLVER);
    expect(u.searchParams.get("slippage")).toBe("0.1");
    // An order from OUR quote is gated at 0 bps: the API is still asked for the haircut,
    // so its floor never sits above the figure we priced at.
    expect(new URL(nordsternUrl(cfg, { ...req, slippageBps: 0n })).searchParams.get("slippage")).toBe("0.02");
  });
  it("bpsToPercent", () => {
    expect(bpsToPercent(0n)).toBe("0");
    expect(bpsToPercent(2n)).toBe("0.02");
    expect(bpsToPercent(5n)).toBe("0.05");
    expect(bpsToPercent(10n)).toBe("0.1");
    expect(bpsToPercent(150n)).toBe("1.5");
    expect(bpsToPercent(300n)).toBe("3");
  });
});

describe("decodeNordstern: the packed IceCreamSwap head", () => {
  it("decodes the real fixture at the documented byte offsets", () => {
    const d = decodeNordstern(DATA);
    expect(d.id).toBe(0x4e9e);
    expect(d.executor).toBe(NORDSTERN_EXECUTOR_ROOTSTOCK);
    expect(d.amountIn).toBe(AMOUNT_IN);
    expect(d.minAmountOut).toBe(MIN);
    expect(d.flag).toBe(5);
    expect(d.firstTokenReceiver).toBe(NORDSTERN_EXECUTOR_ROOTSTOCK);
    expect(d.recipient).toBe(SOLVER);
    expect(d.tokenIn).toBe(USDRIF);
    expect(d.tokenOut).toBe(USDT0);
    expect(d.routeBytes).toBe(25);
  });
});

describe("validateNordsternRoute", () => {
  it("accepts the real fixture; prices it at toAmount × (1 − 2 bps), gas × 1.2", () => {
    const v = validateNordsternRoute(body(), req, cfg);
    if (!v.ok) throw new Error(v.reason);
    expect(v.apiAmountOut).toBe(TO_AMOUNT);
    expect(v.amountOut).toBe((TO_AMOUNT * 9_998n) / 10_000n);
    expect(v.amountOut).toBe(nordsternPricedOut(TO_AMOUNT, 2n));
    expect(v.minAmountOut).toBe(MIN);
    expect(v.gasUnits).toBe(82_188n);
    // NORDSTERN_GAS_MULT_PCT (default 200 in the config): the API's figure is not Rootstock's.
    const x2 = validateNordsternRoute(body(), req, { ...cfg, gasMultPct: 200n });
    expect(x2.ok && x2.gasUnits).toBe(164_376n);
    expect(v.router).toBe(NORDSTERN_GUARD_ROOTSTOCK);
  });
  it.each([
    ["an API error body", body({}, { error: "no swap route found" }), /no swap route/],
    ["no tx", { toAmount: "1" } as NordsternResponse, /no tx/],
    ["an unpinned tx.to", body({ to: "0x0B14ff67f0014046b4b99057Aec4509640b3947A" }), /pinned guard/],
    ["native value", body({ value: "1" }), /native value/],
    ["hex native value", body({ value: "0x0" }), /native value/],
    ["another selector", body({ data: patch(DATA, 0, "0x5f3bd1c8") }), /selector/],
    ["an unpinned executor (executor + firstTokenReceiver both swapped)", body({ data: patch(patch(DATA, 6, addr20(EVIL)), 59, addr20(EVIL)) }), /NORDSTERN_EXECUTORS/],
    ["firstTokenReceiver ≠ executor", body({ data: patch(DATA, 59, addr20(EVIL)) }), /firstTokenReceiver/],
    ["another recipient", body({ data: patch(DATA, 79, addr20(EVIL)) }), /recipient/],
    ["another tokenIn", body({ data: patch(DATA, 99, addr20(ROOTSTOCK.wrbtc as Address)) }), /tokenIn/],
    ["another tokenOut", body({ data: patch(DATA, 119, addr20(ROOTSTOCK.rif as Address)) }), /tokenOut/],
    ["an amountIn other than requested", body({ data: patch(DATA, 26, u128(AMOUNT_IN - 1n)) }), /amountIn/],
    ["a zero amountIn", body({ data: patch(DATA, 26, u128(0n)) }), /amountIn 0/],
    ["minAmountOut above toAmount", body({ data: patch(DATA, 42, u128(TO_AMOUNT + 1n)) }), /minAmountOut/],
    ["a zero minAmountOut", body({ data: patch(DATA, 42, u128(0n)) }), /minAmountOut 0/],
    ["no route bytes after the head", body({ data: DATA.slice(0, 2 + 139 * 2) as Hex }), /too short/],
    ["odd-length hex", body({ data: (DATA + "0") as Hex }), /malformed/],
    ["no toAmount", body({}, { toAmount: undefined }), /toAmount/],
  ] as const)("refuses %s", (_n, b, reason) => {
    const v = validateNordsternRoute(b as NordsternResponse, req, cfg);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(reason);
  });
  it("refuses a route for another request (amount, tokens, recipient)", () => {
    expect(validateNordsternRoute(body(), { ...req, amountIn: AMOUNT_IN + 1n }, cfg).ok).toBe(false);
    expect(validateNordsternRoute(body(), { ...req, tokenIn: ROOTSTOCK.wrbtc as Address }, cfg).ok).toBe(false);
    expect(validateNordsternRoute(body(), { ...req, tokenOut: ROOTSTOCK.rif as Address }, cfg).ok).toBe(false);
    expect(validateNordsternRoute(body(), { ...req, recipient: EVIL }, cfg).ok).toBe(false);
  });
  it("the executor pin is STRICT: an empty NORDSTERN_EXECUTORS accepts nothing", () => {
    const v = validateNordsternRoute(body(), req, { ...cfg, executors: [] });
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(/NORDSTERN_EXECUTORS/);
  });
  it("API strings are sanitized", () => {
    const v = validateNordsternRoute({ error: "x\n✓ [route] filled FAKE\r" }, req, cfg);
    expect(!v.ok && /[\n\r]/.test(v.reason)).toBe(false);
  });
});

describe("buildNordsternPlan", () => {
  const v = validateNordsternRoute(body(), req, cfg);
  if (!v.ok) throw new Error("fixture");
  it("pull plan: the guard, NO amount patch (16-byte field), minOut = owed + cost, maxPay = owed", () => {
    const b = buildNordsternPlan({ quote: v, owed: 99_000_000n, costOut: 300_000n, profitRecipient: SOLVER, minBumpBps: 7n });
    if (!b.ok) throw new Error(b.reason);
    expect(b.plan.router).toBe(NORDSTERN_GUARD_ROOTSTOCK);
    expect(b.plan.amountInOffset).toBe(NO_PATCH);
    expect(b.plan.amountOutOffset).toBe(NO_PATCH);
    expect(b.plan.minOut).toBe(99_300_000n);
    expect(b.plan.maxPay).toBe(99_000_000n);
    expect(b.plan.minBumpBps).toBe(7n);
    expect(b.plan.data).toBe(DATA);
  });
  it("refuses a route whose own floor is below owed + gas + min profit", () => {
    const b = buildNordsternPlan({ quote: v, owed: 99_000_000n, costOut: MIN - 99_000_000n + 1n, profitRecipient: SOLVER, minBumpBps: 0n });
    expect(b.ok).toBe(false);
    if (!b.ok) expect(b.reason).toMatch(/minAmountOut/);
  });
});

describe("fetchNordsternRoute", () => {
  it("sends the Referer header (the API answers 429 without one), then validates", async () => {
    const f = vi.fn(async (_u: string, _init?: RequestInit) => new Response(JSON.stringify(body())));
    const v = await fetchNordsternRoute(cfg, req, f as unknown as typeof fetch);
    expect(v.ok).toBe(true);
    expect(f).toHaveBeenCalledOnce();
    const [url, init] = f.mock.calls[0]!;
    expect(url).toMatch(/^https:\/\/api\.nordstern\.finance\/aggregator\/30\?/);
    expect((init!.headers as Record<string, string>).Referer).toBe("https://1delta-x.pages.dev");
    expect(init!.signal).toBeInstanceOf(AbortSignal);
  });
  it("HTTP errors, 422 misses, throws and a disabled source are refusals, never throws", async () => {
    const r429 = await fetchNordsternRoute(cfg, req, (async () => new Response("Please add a HTTP REFERER header", { status: 429 })) as unknown as typeof fetch);
    expect(!r429.ok && r429.reason).toBe("nordstern: HTTP 429");
    const miss = await fetchNordsternRoute(cfg, req, (async () => new Response(JSON.stringify({ error: "no swap route found for the requested pair and amount" }), { status: 422 })) as unknown as typeof fetch);
    expect(!miss.ok && miss.reason).toMatch(/no swap route found/);
    const junk = await fetchNordsternRoute(cfg, req, (async () => new Response("<html>", { status: 422 })) as unknown as typeof fetch);
    expect(junk.ok).toBe(false);
    expect((await fetchNordsternRoute(cfg, req, (async () => { throw new Error("timeout"); }) as unknown as typeof fetch)).ok).toBe(false);
    const never = vi.fn();
    expect((await fetchNordsternRoute({ ...cfg, enabled: false }, req, never as unknown as typeof fetch)).ok).toBe(false);
    expect(never).not.toHaveBeenCalled();
  });
});

describe("ranking: Nordstern competes at its HAIRCUT figure, net of its own gas", () => {
  it("a raw toAmount above Sushi's still loses when the haircut puts it below", () => {
    const nord = { source: "nordstern" as const, out: nordsternPricedOut(1_000_600_000n, 2n), routeGasOut: 0n };
    const sushi = { source: "sushi" as const, out: 1_000_500_000n, routeGasOut: 0n };
    expect(rankRoutes([nord, sushi])[0]!.source).toBe("sushi");
    const nord2 = { ...nord, out: nordsternPricedOut(1_000_800_000n, 2n) }; // 1000.6 after the haircut
    expect(rankRoutes([sushi, nord2])[0]!.source).toBe("nordstern");
  });
});

describe("config: NORDSTERN_* and the Sushi executor pin", () => {
  const ENV = {
    PRIVATE_KEY: "0x" + "11".repeat(32),
    SETTLEMENT: "0x0000000000000000000000000000000000000001",
    PERMIT3: "0x0000000000000000000000000000000000000002",
    LENS: "0x0000000000000000000000000000000000000003",
    ORDERBOOK_URL: "http://localhost:8080/",
    AGGREGATOR_SOLVER: SOLVER,
  };
  it("defaults: Nordstern OFF in code; guard + executor pinned on chain 30; 2 bps haircut; Referer set", () => {
    const n = loadConfig(ENV).route!.nordstern;
    expect(n).toMatchObject({
      enabled: false,
      baseUrl: "https://api.nordstern.finance",
      router: NORDSTERN_GUARD_ROOTSTOCK,
      executors: [NORDSTERN_EXECUTOR_ROOTSTOCK],
      referer: "https://1delta-x.pages.dev",
      timeoutMs: 3_000,
      maxPerSweep: 10,
      haircutBps: 2n,
    });
    expect(loadConfig({ ...ENV, NORDSTERN_ENABLED: "1" }).route!.nordstern.enabled).toBe(true);
    expect(loadConfig({ ...ENV, NORDSTERN_REFERER: "https://app.example" }).route!.nordstern.referer).toBe("https://app.example");
    expect(loadConfig({ ...ENV, NORDSTERN_HAIRCUT_BPS: "0" }).route!.nordstern.haircutBps).toBe(0n);
    expect(() => loadConfig({ ...ENV, NORDSTERN_HAIRCUT_BPS: "1001" })).toThrow(/NORDSTERN_HAIRCUT_BPS/);
    expect(() => loadConfig({ ...ENV, NORDSTERN_EXECUTORS: "nope" })).toThrow(/NORDSTERN_EXECUTORS/);
    expect(() => loadConfig({ ...ENV, NORDSTERN_MAX_PER_SWEEP: "0" })).toThrow(/NORDSTERN_MAX_PER_SWEEP/);
    // Another chain: no Rootstock executor pin (and so, strictly, no Nordstern route).
    expect(loadConfig({ ...ENV, CHAIN_ID: "31" }).route!.nordstern.executors).toEqual([]);
  });
  it("SUSHI_EXECUTORS: pinned to the Rootstock snwap executor by default; \"\" explicitly unpins", () => {
    expect(loadConfig(ENV).route!.sushi.executors).toEqual([SUSHI_SNWAP_EXECUTOR_ROOTSTOCK]);
    expect(SUSHI_SNWAP_EXECUTOR_ROOTSTOCK.toLowerCase()).toBe("0xc10ee9031f2a0b84766a86b55a8d90f357910fb4");
    expect(loadConfig({ ...ENV, SUSHI_EXECUTORS: "" }).route!.sushi.executors).toEqual([]);
    expect(loadConfig({ ...ENV, CHAIN_ID: "31" }).route!.sushi.executors).toEqual([]);
  });
  it("the fixture's head re-encodes byte-for-byte from its decoded fields (offsets are exact)", () => {
    const d = decodeNordstern(DATA);
    const head = concat([
      "0x3f0bde25",
      numberToHex(d.id, { size: 2 }),
      addr20(d.executor),
      u128(d.amountIn),
      u128(d.minAmountOut),
      numberToHex(d.flag, { size: 1 }),
      addr20(d.firstTokenReceiver),
      addr20(d.recipient),
      addr20(d.tokenIn),
      addr20(d.tokenOut),
    ]);
    expect(DATA.toLowerCase().startsWith(head.toLowerCase())).toBe(true);
  });
});

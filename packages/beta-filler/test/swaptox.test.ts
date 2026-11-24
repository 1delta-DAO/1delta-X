/**
 * The SwaptoX API route source (2026-11-24, ./src/swaptox.ts): the URL + API key header,
 * the swapData decode, every fail-closed validation rule (one tamper case each), the
 * router call we encode (amountIn at the patch offset), the plan, ranking and the
 * config defaults (the API key is the switch).
 */
import { NO_PATCH } from "@1delta-x/sdk";
import { decodeFunctionData, encodeAbiParameters, encodeFunctionData, hexToBigInt, parseAbi, sliceHex, zeroAddress, type Address, type Hex } from "viem";
import { describe, expect, it, vi } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import { rankRoutes } from "../src/route";
import {
  awaitBySize,
  SWAPTOX_AMOUNT_IN_OFFSET,
  SWAPTOX_DEADLINE_SECONDS,
  SWAPTOX_EXECUTOR_ROOTSTOCK,
  SWAPTOX_ROUTER_ABI,
  SWAPTOX_ROUTER_ROOTSTOCK,
  buildSwaptoxPlan,
  decodeSwaptoxData,
  fetchSwaptoxRoute,
  swaptoxUrl,
  validateSwaptoxRoute,
  type SwaptoxConfig,
  type SwaptoxRequest,
  type SwaptoxResponse,
} from "../src/swaptox";

const SOLVER = "0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287" as Address;
const EVIL = "0x000000000000000000000000000000000000dEaD" as Address;
const USDRIF = ROOTSTOCK.usdrif as Address;
const USDT0 = ROOTSTOCK.usdt0 as Address;
const WRBTC = "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d" as Address;
const POOL = "0xD845702af381f0405661747a6a20bde0401A19d6" as Address;
const TO_US = "0x0000000000000000000000000000000000000001" as Address;

/**
 * Real `api-v2.swaptox.com/rootstock/routes` best route (2026-11-24, block 9,439,396):
 * 100 USDRIF → USD₮0, one `callSwap` on the Oku v3 pool 0xd845…19d6, paying the router's
 * recipient. Fork-executed through the router: delivered exactly 99,541,128.
 */
const SWAP_DATA =
  "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c4e54bb09c0000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000000000000000002710000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be713736000000000000000000000000d845702af381f0405661747a6a20bde0401a19d60000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000" as Hex;
const AMOUNT_IN = 100n * 10n ** 18n;
const AMOUNT_OUT = 99_541_128n;

const STEP_ABI = parseAbi([
  "function callSwap(address tokenIn, uint256 percentIn, address tokenOut, address pool, uint256 version, address recipient)",
  "function callSafeTransfer(address token, address to, uint256 percentIn)",
]);
type Step = [Address, bigint, Address, Address, bigint, Address];
const step = (...a: Step): Hex => encodeFunctionData({ abi: STEP_ABI, functionName: "callSwap", args: a });
const swapData = (calls: Hex[], version = 1n): Hex =>
  encodeAbiParameters([{ type: "uint256" }, { type: "bytes" }], [version, encodeAbiParameters([{ type: "bytes[]" }], [calls])]);

const req: SwaptoxRequest = { chainId: 30, tokenIn: USDRIF, tokenOut: USDT0, amountIn: AMOUNT_IN };
const cfg: SwaptoxConfig = {
  enabled: true,
  baseUrl: "https://api-v2.swaptox.com/",
  apiKey: "stx_test_key",
  router: SWAPTOX_ROUTER_ROOTSTOCK,
  executor: SWAPTOX_EXECUTOR_ROOTSTOCK,
  version: 1n,
  referral: zeroAddress,
  timeoutMs: 3_000,
  quoteTimeoutMs: 2_500,
  largeUsd: 500,
  largeTimeoutMs: 5_000,
  maxPerSweep: 10,
  gasMultPct: 150n,
};
const body = (over: Record<string, unknown> = {}): SwaptoxResponse => ({
  success: true,
  data: {
    routes: [
      {
        amountIn: AMOUNT_IN.toString(),
        amountOut: AMOUNT_OUT.toString(),
        gas: "112634",
        tokenIn: USDRIF.toLowerCase(),
        tokenOut: USDT0.toLowerCase(),
        swapAddress: SWAPTOX_ROUTER_ROOTSTOCK,
        swapData: SWAP_DATA,
        ...over,
      },
    ],
  },
});
const refused = (over: Record<string, unknown>, r: SwaptoxRequest = req) => {
  const v = validateSwaptoxRoute(body(over), r, cfg);
  return v.ok ? "accepted" : v.reason;
};

describe("swaptoxUrl", () => {
  it("asks /{chain slug}/routes with the raw input amount; an unmapped chain has no URL", () => {
    const u = new URL(swaptoxUrl(cfg, req)!);
    expect(`${u.origin}${u.pathname}`).toBe("https://api-v2.swaptox.com/rootstock/routes");
    expect(Object.fromEntries(u.searchParams)).toEqual({ tokenIn: USDRIF, tokenOut: USDT0, amountIn: AMOUNT_IN.toString() });
    expect(swaptoxUrl(cfg, { ...req, chainId: 1 })).toBeUndefined();
  });
});

describe("decodeSwaptoxData", () => {
  it("decodes the real fixture: version 1, one v3 callSwap paying the router's recipient", () => {
    expect(decodeSwaptoxData(SWAP_DATA)).toEqual({
      version: 1n,
      steps: [{ tokenIn: USDRIF, percentIn: 10_000n, tokenOut: USDT0, pool: POOL, recipient: TO_US }],
    });
  });
  it("refuses any step but a v3 callSwap", () => {
    const transfer = encodeFunctionData({ abi: STEP_ABI, functionName: "callSafeTransfer", args: [USDRIF, EVIL, 10_000n] });
    expect(() => decodeSwaptoxData(swapData([transfer]))).toThrow(/not callSwap/);
    expect(() => decodeSwaptoxData(swapData([step(USDRIF, 10_000n, USDT0, POOL, 15n, TO_US)]))).toThrow(/kind 15/);
    expect(() => decodeSwaptoxData("0x1234" as Hex)).toThrow();
  });
});

describe("validateSwaptoxRoute", () => {
  it("accepts the real fixture; gas × SWAPTOX_GAS_MULT_PCT", () => {
    const v = validateSwaptoxRoute(body(), req, cfg);
    expect(v).toMatchObject({ ok: true, source: "swaptox", router: SWAPTOX_ROUTER_ROOTSTOCK, amountIn: AMOUNT_IN, amountOut: AMOUNT_OUT, gasUnits: 168_951n, pools: [POOL] });
  });
  it("refuses a route for another request or router", () => {
    expect(refused({ swapAddress: EVIL })).toMatch(/not the pinned router/);
    expect(refused({ tokenIn: WRBTC })).toMatch(/tokenIn/);
    expect(refused({ tokenOut: WRBTC })).toMatch(/tokenOut/);
    expect(refused({ amountIn: "1" })).toMatch(/amountIn/);
    expect(refused({}, { ...req, amountIn: AMOUNT_IN + 1n })).toMatch(/amountIn/);
  });
  it("refuses an unpriced route (Sovryn / v2 legs come back with amountOut 0) and API errors", () => {
    expect(refused({ amountOut: "0" })).toMatch(/zero amountOut/);
    expect(refused({ amountOut: undefined })).toMatch(/zero amountOut/);
    expect(validateSwaptoxRoute({ success: false, code: "NOT_FOUND", message: "Unsupported chain" }, req, cfg)).toEqual({ ok: false, reason: "swaptox: Unsupported chain" });
    expect(validateSwaptoxRoute({ success: true, data: { routes: [] } }, req, cfg)).toEqual({ ok: false, reason: "swaptox: no route" });
    expect(validateSwaptoxRoute(null, req, cfg).ok).toBe(false);
  });
  it("refuses another executor slot", () => {
    expect(refused({ swapData: swapData([step(USDRIF, 10_000n, USDT0, POOL, 3n, TO_US)], 2n) })).toMatch(/version 2/);
  });
  it("step rules: sentinel recipients only, held inputs only, the solver paid in tokenOut", () => {
    expect(refused({ swapData: swapData([step(USDRIF, 10_000n, USDT0, POOL, 3n, EVIL)]) })).toMatch(/pays 0x/);
    expect(refused({ swapData: swapData([step(WRBTC, 10_000n, USDT0, POOL, 3n, TO_US)]) })).toMatch(/does not hold/);
    expect(refused({ swapData: swapData([step(USDRIF, 10_000n, WRBTC, POOL, 3n, TO_US)]) })).toMatch(/pays the solver/);
    expect(refused({ swapData: swapData([step(USDRIF, 10_000n, WRBTC, POOL, 3n, zeroAddress)]) })).toMatch(/no step pays the solver/);
    expect(refused({ swapData: swapData([step(USDRIF, 0n, USDT0, POOL, 3n, TO_US)]) })).toMatch(/percent 0/);
    expect(refused({ swapData: swapData([step(USDRIF, 10_001n, USDT0, POOL, 3n, TO_US)]) })).toMatch(/percent/);
    expect(refused({ swapData: swapData([]) })).toMatch(/no steps/);
  });
  it("accepts a split two-hop route (70 % direct, the rest via WRBTC), the shape the API returns", () => {
    const sd = swapData([
      step(USDRIF, 7_000n, USDT0, POOL, 3n, TO_US),
      step(USDRIF, 10_000n, WRBTC, EVIL, 3n, zeroAddress),
      step(WRBTC, 10_000n, USDT0, EVIL, 3n, TO_US),
    ]);
    expect(refused({ swapData: sd })).toBe("accepted");
  });
  it("API strings are sanitized", () => {
    const v = validateSwaptoxRoute({ success: false, message: "bad\n✓ [route] filled" }, req, cfg);
    expect(!v.ok && v.reason).not.toContain("\n");
  });
});

describe("buildSwaptoxPlan", () => {
  const quote = validateSwaptoxRoute(body(), req, cfg);
  if (!quote.ok) throw new Error("fixture");
  const owed = 99_000_000n;
  const costOut = 200_000n;
  const nowSec = 1_795_520_000n;
  it("pull plan: the router, amountIn patched at its offset, our floor as the router's amountMinOut, the solver paid", () => {
    const b = buildSwaptoxPlan({ quote, owed, costOut, solver: SOLVER, profitRecipient: zeroAddress, minBumpBps: 7n, referral: zeroAddress, nowSec });
    if (!b.ok) throw new Error(b.reason);
    expect(b.plan).toMatchObject({ router: SWAPTOX_ROUTER_ROOTSTOCK, minOut: owed + costOut, maxPay: owed, amountInOffset: SWAPTOX_AMOUNT_IN_OFFSET, amountOutOffset: NO_PATCH, minBumpBps: 7n });
    const off = Number(SWAPTOX_AMOUNT_IN_OFFSET);
    expect(hexToBigInt(sliceHex(b.plan.data, off, off + 32))).toBe(AMOUNT_IN);
    const d = decodeFunctionData({ abi: SWAPTOX_ROUTER_ABI, data: b.plan.data });
    expect(d.functionName).toBe("swap");
    const [desc, deadline, referral] = d.args as unknown as [Record<string, unknown>, bigint, Address];
    expect(desc).toEqual({ tokenIn: USDRIF, tokenOut: USDT0, amountIn: AMOUNT_IN, amountMinOut: owed + costOut, recipient: SOLVER, swapData: SWAP_DATA, permitData: "0x" });
    expect(deadline).toBe(nowSec + SWAPTOX_DEADLINE_SECONDS);
    expect(referral).toBe(zeroAddress);
  });
  it("refuses a route whose output is below owed + gas + min profit", () => {
    const b = buildSwaptoxPlan({ quote, owed: AMOUNT_OUT, costOut: 1n, solver: SOLVER, profitRecipient: zeroAddress, minBumpBps: 0n, referral: zeroAddress, nowSec });
    expect(!b.ok && b.reason).toMatch(/amountOut/);
  });
});

describe("fetchSwaptoxRoute", () => {
  it("aborts a slow API at the configured timeout and refuses (never waits it out)", async () => {
    const hang = ((_u: string, init?: RequestInit) =>
      new Promise<Response>((_res, rej) => init!.signal!.addEventListener("abort", () => rej(new Error("The operation was aborted due to timeout"))))) as unknown as typeof fetch;
    const t0 = Date.now();
    const v = await fetchSwaptoxRoute({ ...cfg, timeoutMs: 50 }, req, hang);
    expect(!v.ok && v.reason).toMatch(/swaptox: .*timeout/);
    expect(Date.now() - t0).toBeLessThan(1_000);
  });
  it("sends X-API-Key when configured (and only then), then validates", async () => {
    const f = vi.fn(async (_u: string, _init?: RequestInit) => new Response(JSON.stringify(body())));
    expect((await fetchSwaptoxRoute(cfg, req, f as unknown as typeof fetch)).ok).toBe(true);
    const [url, init] = f.mock.calls[0]!;
    expect(url).toMatch(/^https:\/\/api-v2\.swaptox\.com\/rootstock\/routes\?/);
    expect((init!.headers as Record<string, string>)["X-API-Key"]).toBe("stx_test_key");
    expect(init!.signal).toBeInstanceOf(AbortSignal);
    const { apiKey: _k, ...keyless } = cfg;
    await fetchSwaptoxRoute(keyless, req, f as unknown as typeof fetch);
    expect((f.mock.calls[1]![1]!.headers as Record<string, string>)["X-API-Key"]).toBeUndefined();
  });
  it("HTTP errors, throws, an unmapped chain and a disabled source are refusals, never throws", async () => {
    const r429 = await fetchSwaptoxRoute(cfg, req, (async () => new Response("slow down", { status: 429 })) as unknown as typeof fetch);
    expect(!r429.ok && r429.reason).toBe("swaptox: HTTP 429");
    expect((await fetchSwaptoxRoute(cfg, req, (async () => { throw new Error("timeout"); }) as unknown as typeof fetch)).ok).toBe(false);
    const never = vi.fn();
    expect((await fetchSwaptoxRoute({ ...cfg, enabled: false }, req, never as unknown as typeof fetch)).ok).toBe(false);
    expect((await fetchSwaptoxRoute(cfg, { ...req, chainId: 31 }, never as unknown as typeof fetch)).ok).toBe(false);
    expect(never).not.toHaveBeenCalled();
  });
});

describe("awaitBySize: a small ticket stops waiting at the small deadline, a large one does not", () => {
  const after = <T>(ms: number, v: T) => new Promise<T>((r) => setTimeout(() => r(v), ms));
  const onSmall = () => "gave up";
  it("a fast answer is returned whatever the size, without waiting for the valuation", async () => {
    const never = new Promise<boolean>(() => {});
    expect(await awaitBySize(after(5, "route"), { smallMs: 100, isLarge: never, onSmall })).toBe("route");
  });
  it("a slow answer: given up on for a small ticket at smallMs, awaited for a large one", async () => {
    const t0 = Date.now();
    expect(await awaitBySize(after(300, "route"), { smallMs: 50, isLarge: Promise.resolve(false), onSmall })).toBe("gave up");
    expect(Date.now() - t0).toBeLessThan(250);
    expect(await awaitBySize(after(300, "route"), { smallMs: 50, isLarge: Promise.resolve(true), onSmall })).toBe("route");
  });
  it("a valuation that resolves late still decides (the call keeps running meanwhile)", async () => {
    expect(await awaitBySize(after(200, "route"), { smallMs: 20, isLarge: after(100, true), onSmall })).toBe("route");
  });
});

describe("ranking: SwaptoX is picked only when it nets more", () => {
  it("a tie keeps the earlier source; more output net of its own gas wins", () => {
    const sushi = { source: "sushi" as const, out: 1_000_000n, routeGasOut: 1_000n };
    const sx = { source: "swaptox" as const, out: 1_000_000n, routeGasOut: 1_000n };
    expect(rankRoutes([sushi, sx])[0]!.source).toBe("sushi");
    expect(rankRoutes([sushi, { ...sx, out: 1_000_500n, routeGasOut: 1_600n }])[0]!.source).toBe("sushi");
    expect(rankRoutes([sushi, { ...sx, out: 1_002_000n, routeGasOut: 1_600n }])[0]!.source).toBe("swaptox");
  });
});

describe("config: SWAPTOX_*", () => {
  const ENV = {
    PRIVATE_KEY: "0x" + "11".repeat(32),
    SETTLEMENT: "0x0000000000000000000000000000000000000001",
    PERMIT3: "0x0000000000000000000000000000000000000002",
    LENS: "0x0000000000000000000000000000000000000003",
    ORDERBOOK_URL: "http://localhost:8080/",
    AGGREGATOR_SOLVER: SOLVER,
  };
  it("the API key is the switch on chain 30; router + executor pinned; gas × 150 %", () => {
    const off = loadConfig(ENV).route!.swaptox;
    expect(off).toMatchObject({ enabled: false, baseUrl: "https://api-v2.swaptox.com", router: SWAPTOX_ROUTER_ROOTSTOCK, executor: SWAPTOX_EXECUTOR_ROOTSTOCK, version: 1n, referral: zeroAddress, timeoutMs: 3_000, quoteTimeoutMs: 2_500, largeUsd: 500, largeTimeoutMs: 5_500, maxPerSweep: 10, gasMultPct: 150n });
    expect(off.apiKey).toBeUndefined();
    const on = loadConfig({ ...ENV, SWAPTOX_API_KEY: "k" }).route!.swaptox;
    expect(on).toMatchObject({ enabled: true, apiKey: "k" });
    expect(loadConfig({ ...ENV, SWAPTOX_API_KEY: "k", SWAPTOX_ENABLED: "0" }).route!.swaptox.enabled).toBe(false);
    expect(loadConfig({ ...ENV, SWAPTOX_ENABLED: "1" }).route!.swaptox.enabled).toBe(true);
    expect(loadConfig({ ...ENV, SWAPTOX_API_KEY: "k", CHAIN_ID: "31" }).route!.swaptox.enabled).toBe(false);
    expect(() => loadConfig({ ...ENV, SWAPTOX_GAS_MULT_PCT: "50" })).toThrow(/SWAPTOX_GAS_MULT_PCT/);
    // Timeouts are capped at 3 s.
    expect(loadConfig({ ...ENV, SWAPTOX_TIMEOUT_MS: "1500" }).route!.swaptox.timeoutMs).toBe(1_500);
    expect(() => loadConfig({ ...ENV, SWAPTOX_TIMEOUT_MS: "3001" })).toThrow(/SWAPTOX_TIMEOUT_MS/);
    expect(() => loadConfig({ ...ENV, SWAPTOX_QUOTE_TIMEOUT_MS: "5000" })).toThrow(/SWAPTOX_QUOTE_TIMEOUT_MS/);
    // A large ticket's wait: its own knob, capped at 10 s.
    expect(loadConfig({ ...ENV, SWAPTOX_LARGE_USD: "1000", SWAPTOX_LARGE_TIMEOUT_MS: "8000" }).route!.swaptox).toMatchObject({ largeUsd: 1_000, largeTimeoutMs: 8_000 });
    expect(() => loadConfig({ ...ENV, SWAPTOX_LARGE_TIMEOUT_MS: "10001" })).toThrow(/SWAPTOX_LARGE_TIMEOUT_MS/);
    expect(() => loadConfig({ ...ENV, SWAPTOX_EXECUTOR: "nope" })).toThrow(/SWAPTOX_EXECUTOR/);
  });
});

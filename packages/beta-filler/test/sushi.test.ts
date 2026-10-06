import { NO_PATCH, SNWAP_AMOUNT_IN_OFFSET, decodeSnwap, encodeExactInputSingle } from "@1delta-x/sdk";
import { hexToBigInt, sliceHex, type Address, type Hex } from "viem";
import { describe, expect, it, vi } from "vitest";

import { ROOTSTOCK } from "../src/config";
import {
  SUSHI_RED_SNWAPPER_ROOTSTOCK,
  buildSushiPlan,
  fetchSushiRoute,
  floorAmount,
  sushiUrl,
  validateSushiRoute,
  type SushiRequest,
  type SushiResponse,
} from "../src/sushi";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const PLACEHOLDER = "1111111111111111111111111111111111111111";

/**
 * Real `api.sushi.com/swap/v7/30` response (2026-10-04, block 9,295,925): 100 USDRIF → USDT0
 * with recipient 0x1111…1111 — the same fixture packages/solvers/test/RouteSandboxFork.t.sol
 * replays through the solver on a Rootstock fork. `withRecipient` rewrites the placeholder,
 * which is byte-for-byte what the API returns when asked with that recipient.
 */
const DATA =
  "0x5f3bd1c80000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d631000000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005ea8d5f000000000000000000000000c10ee9031f2a0b84766a86b55a8d90f357910fb400000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001846be92b890000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005f229be0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005101a106b319360001013a15461d8ae0f0fb5fa2629e9da7d66a794a6e3701ffff01d845702af381f0405661747a6a20bde0401a19d601c10ee9031f2a0b84766a86b55a8d90f357910fb400ad7933be450b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
const withRecipient = (who: Address): Hex => DATA.split(PLACEHOLDER).join(who.slice(2).toLowerCase()) as Hex;

const AMOUNT_IN = 100n * 10n ** 18n;
const ASSUMED = 99_756_478n;
const MIN = 99_257_695n;

const req: SushiRequest = {
  chainId: 30,
  tokenIn: ROOTSTOCK.usdrif as Address,
  tokenOut: ROOTSTOCK.usdt0 as Address,
  amountIn: AMOUNT_IN,
  sender: SANDBOX,
  recipient: SOLVER,
  slippageBps: 50n,
};
const cfg = { enabled: true, baseUrl: "https://api.sushi.com/", router: SUSHI_RED_SNWAPPER_ROOTSTOCK, timeoutMs: 1000, executors: [] as Address[], maxPerSweep: 10 };

function body(over: Partial<SushiResponse["tx"]> = {}, top: Partial<SushiResponse> = {}): SushiResponse {
  return {
    status: "Success",
    assumedAmountOut: ASSUMED.toString(),
    gasSpent: 77000,
    tx: { to: "0xac4c6e212a361c968f1725b4d055b47e63f80b75", data: withRecipient(SOLVER), ...over },
    ...top,
  };
}

describe("sushiUrl", () => {
  it("asks swap/v7 with DECIMAL slippage, the sandbox as sender and the solver as recipient", () => {
    const u = new URL(sushiUrl(cfg, req));
    expect(u.pathname).toBe("/swap/v7/30");
    expect(u.searchParams.get("maxSlippage")).toBe("0.005");
    expect(u.searchParams.get("amount")).toBe(AMOUNT_IN.toString());
    expect(u.searchParams.get("sender")).toBe(SANDBOX);
    expect(u.searchParams.get("recipient")).toBe(SOLVER);
  });
});

describe("validateSushiRoute", () => {
  it("accepts the real fixture once it names the solver, and decodes it", () => {
    const v = validateSushiRoute(body(), req, cfg);
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    expect(v.amountOut).toBe(ASSUMED);
    expect(v.amountOutMin).toBe(MIN);
    expect(v.gasUnits).toBe(77_000n);
    expect(hexToBigInt(sliceHex(v.data, Number(SNWAP_AMOUNT_IN_OFFSET), Number(SNWAP_AMOUNT_IN_OFFSET) + 32))).toBe(AMOUNT_IN);
  });
  it.each([
    ["a non-Success status", body({}, { status: "NoWay" }), /status/],
    ["no tx", { status: "Success", assumedAmountOut: "1" } as SushiResponse, /no tx/],
    ["an unpinned router", body({ to: "0x0B14ff67f0014046b4b99057Aec4509640b3947A" }), /pinned router/],
    ["native value", body({ value: "1" }), /native value/],
    ["another selector", body({ data: encodeExactInputSingle({ tokenIn: req.tokenIn, tokenOut: req.tokenOut, fee: 500, recipient: SOLVER, amountIn: AMOUNT_IN, amountOutMinimum: 1n }).data }), /sushi:/],
    ["another recipient (the EOA habit)", body({ data: withRecipient("0x00000000000000000000000000000000000000ee") }), /recipient/],
    ["the sandbox as recipient (not what we asked for)", body({ data: withRecipient(SANDBOX) }), /recipient/],
    ["no assumedAmountOut", body({}, { assumedAmountOut: undefined }), /assumedAmountOut/],
  ] as const)("refuses %s", (_n, b, reason) => {
    const v = validateSushiRoute(b as SushiResponse, req, cfg);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(reason);
  });
  it("refuses a route for another amount, token pair, or a zero amount", () => {
    expect(validateSushiRoute(body(), { ...req, amountIn: AMOUNT_IN - 1n }, cfg).ok).toBe(false);
    expect(validateSushiRoute(body(), { ...req, tokenOut: ROOTSTOCK.rif as Address }, cfg).ok).toBe(false);
    expect(validateSushiRoute(body(), { ...req, tokenIn: ROOTSTOCK.wrbtc as Address }, cfg).ok).toBe(false);
    const zero = (withRecipient(SOLVER).slice(0, 2 + 2 * 36) + "0".repeat(64) + withRecipient(SOLVER).slice(2 + 2 * 68)) as Hex;
    expect(decodeSnwap(zero).amountIn).toBe(0n);
    const v = validateSushiRoute(body({ data: zero }), req, cfg);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(/amountIn 0/);
  });
  it("floors numeric strings and refuses junk", () => {
    expect(floorAmount("12.9")).toBe(12n);
    expect(floorAmount(7)).toBe(7n);
    expect(floorAmount("-1")).toBeNull();
    expect(floorAmount("1e18")).toBeNull();
  });
});

describe("buildSushiPlan", () => {
  const v = validateSushiRoute(body(), req, cfg);
  if (!v.ok) throw new Error("fixture");
  it("pull plan: snwap target, amountIn patch at 36, minOut = owed + cost, maxPay = owed", () => {
    const b = buildSushiPlan({ quote: v, owed: 99_000_000n, costOut: 200_000n, profitRecipient: SOLVER, minBumpBps: 1_234n });
    expect(b.ok).toBe(true);
    if (!b.ok) return;
    expect(b.plan.minBumpBps).toBe(1_234n); // the filler's on-chain floor rides along (task 08)
    expect(b.plan.amountOutOffset).toBe(NO_PATCH);
    expect(b.plan.router.toLowerCase()).toBe(SUSHI_RED_SNWAPPER_ROOTSTOCK.toLowerCase());
    expect(b.plan.amountInOffset).toBe(36n);
    expect(b.plan.minOut).toBe(99_200_000n);
    expect(b.plan.maxPay).toBe(99_000_000n);
  });
  it("refuses a route whose own amountOutMin is below owed + gas + min profit", () => {
    const b = buildSushiPlan({ quote: v, owed: 99_000_000n, costOut: MIN - 99_000_000n + 1n, profitRecipient: SOLVER, minBumpBps: 0n });
    expect(b.ok).toBe(false);
    if (!b.ok) expect(b.reason).toMatch(/amountOutMin/);
  });
});

describe("fetchSushiRoute", () => {
  it("fetches, then validates", async () => {
    const f = vi.fn(async () => new Response(JSON.stringify(body())));
    const v = await fetchSushiRoute(cfg, req, f as unknown as typeof fetch);
    expect(v.ok).toBe(true);
    expect(f).toHaveBeenCalledOnce();
  });
  it("turns HTTP errors, throws and a disabled source into refusals", async () => {
    expect((await fetchSushiRoute(cfg, req, (async () => new Response("x", { status: 502 })) as unknown as typeof fetch)).ok).toBe(false);
    expect((await fetchSushiRoute(cfg, req, (async () => { throw new Error("boom"); }) as unknown as typeof fetch)).ok).toBe(false);
    const never = vi.fn();
    expect((await fetchSushiRoute({ ...cfg, enabled: false }, req, never as unknown as typeof fetch)).ok).toBe(false);
    expect(never).not.toHaveBeenCalled();
  });
});

describe("errorReason", () => {
  it("unwraps CallbackFailed → RouteFailed → MinimalOutputBalanceViolation", async () => {
    const { errorReason } = await import("../src/routeFiller");
    const data =
      "0x30b9b6dd000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a44acca8220000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004463ecb9f6000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000000000fb3dee630000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const r = errorReason(new Error(`Execution reverted with reason: custom error ${data.slice(0, 10)}: ${data.slice(10)}.`));
    expect(r).toBe("CallbackFailed(RouteFailed(MinimalOutputBalanceViolation(0x779Ded0c9e1022225f8E0630b35a9b54bE713736, 4215139939)))");
    expect(errorReason({ cause: { cause: { data } } })).toMatch(/^CallbackFailed\(RouteFailed\(/);
  });
});

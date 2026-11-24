import { NO_PATCH, type RoutePlan } from "@1delta-x/sdk";
import { decodeAbiParameters, decodeFunctionData, encodeFunctionData, getAddress, parseAbi, zeroAddress, type Address, type Hex } from "viem";

import type { Verdict } from "./policy";
import { sanitize } from "./sanitize";
import { floorAmount } from "./sushi";

/**
 * SwaptoX's aggregator API as a fourth route source for PULL fills (2026-11-24),
 * mirroring ./sushi.ts and ./nordstern.ts: what the API returns is DECODED and every
 * field is checked against what WE asked for and the pinned config.
 *
 * `GET {base}/{chain slug}/routes?tokenIn&tokenOut&amountIn` (chain 30 = `rootstock`;
 * header `X-API-Key` when SWAPTOX_API_KEY is set — higher rate limits) returns
 * `{ success, data: { routes: [{ amountOut, gas, swapAddress, swapData, … }] } }`,
 * best route first. Unlike Sushi and Nordstern it returns NO transaction: `swapData`
 * is one argument of the router call, and WE encode the rest:
 *
 *     SwaptoXRouter.swap(
 *       (tokenIn, tokenOut, amountIn, amountMinOut, recipient, swapData, permitData),
 *       deadline, referral)
 *
 * The router (`0xdc39…7F1A` on Rootstock, verified source, immutable, admin EOA) pulls
 * `amountIn` from ITS `msg.sender` — the solver's RouteSandbox — takes its fee (0 bp, and
 * the contract refuses to raise it before `maxFreeTime` ≈ 2028-01; ≤ 20 bp after), sends
 * the rest to `swapAddress[version]` (its executor), runs `executor.entered(…)`, then
 * REQUIRES `recipient`'s `tokenOut` balance to rise by `amountMinOut`. So:
 *
 *   • `recipient` = the SOLVER (pull mode), `amountMinOut` = owed + gas + min profit
 *     (set at plan time: the router's floor is ours, not the API's), no permit, no value.
 *   • `amountIn` is the third word of the tuple — byte {@link SWAPTOX_AMOUNT_IN_OFFSET}
 *     of the calldata we encode — so the plan PATCHES it with what the fill routes: the
 *     executor swaps PERCENTAGES OF ITS OWN BALANCE, never a fixed amount (fork-checked
 *     2026-11-24: 100 USDRIF delivered exactly the API's `amountOut`).
 *   • `swapData` = `abi.encode(version, abi.encode(bytes[] steps))`; each step is a call
 *     the executor makes on itself. Only `callSwap(tokenIn, percentIn, tokenOut, pool,
 *     kind, recipient)` with kind 3 (a v3 pool swap) is accepted — the only step every
 *     Rootstock route named in 2026-11 — and its recipient must be one of the executor's
 *     two sentinels: `address(0)` (the executor itself: an intermediate hop) or
 *     `address(1)` (the router's `recipient`: the solver). An explicit address is refused,
 *     so no step can pay anyone but the executor or us. Every step must spend a token the
 *     route already holds (the input, or an earlier step's output), and every step paying
 *     us must produce `tokenOut`.
 *   • `version` must be {@link SwaptoxConfig.version} and the router's `swapAddress` of it
 *     the PINNED executor. The admin can repoint it, so the route filler re-reads it
 *     (cached ~1 min) before trusting a route; a hostile executor can still only take the
 *     spread above `amountMinOut`, the same bound the solver's `minOut` enforces.
 *
 * LATENCY, BY TICKET SIZE: a ticket under SWAPTOX_LARGE_USD ($500) waits at most
 * SWAPTOX_TIMEOUT_MS (3 s) on a fill, SWAPTOX_QUOTE_TIMEOUT_MS (2.5 s) on a `/quote`
 * (both ≤ {@link SWAPTOX_MAX_TIMEOUT_MS}); a larger one up to SWAPTOX_LARGE_TIMEOUT_MS
 * (5.5 s, ≤ {@link SWAPTOX_MAX_LARGE_TIMEOUT_MS}), on fills and quotes alike. The probe
 * (e2e/swaptox-probe.ts, 2026-11-24) found SwaptoX ahead net of gas only at ≥ $1k, every
 * time after 3–5.4 s: a small ticket gains nothing from waiting, a large one can. The
 * call starts at once with the large deadline; the ticket is valued in parallel, and at
 * the small deadline a small ticket stops waiting. A timeout is a transient miss (no
 * strike), like any API refusal.
 *
 * PRICING: `amountOut` matched the fork execution exactly, but `gas` is the executor's
 * own figure and not Rootstock's: a 1-hop route reported 112,634 and cost 184,988 on a
 * fork receipt (2026-11-24; ~150k of it the route, net of the 21k intrinsic and the
 * calldata), so ranking uses `gas × SWAPTOX_GAS_MULT_PCT` (default 150).
 * The routes reach the same Oku / Sushi v3 pools our pool plans swap on directly, so with
 * the sandbox + router + executor hops on top, a SwaptoX route ranks first only when its
 * split or path is worth more than that gas.
 */
export interface SwaptoxConfig {
  enabled: boolean;
  /** API base, default `https://api-v2.swaptox.com`. */
  baseUrl: string;
  /** Sent as `X-API-Key` when set (a secret: never logged or reported). */
  apiKey?: string;
  /** The PINNED SwaptoXRouter; any other `swapAddress` is refused. */
  router: Address;
  /** The PINNED executor (`router.swapAddress(version)`). */
  executor: Address;
  /** The `swapData` version accepted (the router's executor slot). */
  version: bigint;
  /** The router's `referral` argument; zero = the router binds itself (no inviter). */
  referral: Address;
  /**
   * Per API call on a FILL, ms (≤ {@link SWAPTOX_MAX_TIMEOUT_MS}). The API is slow where
   * it searches splits: WRBTC pairs answered in ~5 s (2026-11-24; USDRIF pairs ~1.4 s,
   * Sushi ~0.3 s), so those time out and the fill goes on without SwaptoX.
   */
  timeoutMs: number;
  /** Per API call on a `/quote` (the app waits on it), ms (≤ {@link SWAPTOX_MAX_TIMEOUT_MS}). */
  quoteTimeoutMs: number;
  /** A ticket whose input is worth at least this many USD (valued on the pools) is LARGE. */
  largeUsd: number;
  /** Per API call on a large ticket, fill or `/quote`, ms (≤ {@link SWAPTOX_MAX_LARGE_TIMEOUT_MS}). */
  largeTimeoutMs: number;
  /** At most this many SwaptoX API calls per sweep over the book. */
  maxPerSweep: number;
  /** Rootstock correction on the API's `gas`, percent (100 = as reported). */
  gasMultPct: bigint;
}

/** SwaptoXRouter on Rootstock (chain 30): every route's `swapAddress`. */
export const SWAPTOX_ROUTER_ROOTSTOCK = "0xdc39E2fda1A4FF4C97C503A86371bAfC4BCc7F1A" as Address;
/** `SwaptoXRouter.swapAddress(1)` on Rootstock (SwaptoXentered, verified), read 2026-11-24. */
export const SWAPTOX_EXECUTOR_ROOTSTOCK = "0x628F59C0f6Dfc4Ba3091C6CA1d83C6bF33a552d1" as Address;
/** The API's chain path segment. */
export const SWAPTOX_CHAINS: Readonly<Record<number, string>> = { 30: "rootstock" };
/** Byte offset (selector included) of the tuple's `amountIn` word: 4 + 3 head words + 2 tuple words. */
export const SWAPTOX_AMOUNT_IN_OFFSET = 164n;
/** The longest a SMALL ticket's SwaptoX call may take, ms: the config refuses a higher timeout. */
export const SWAPTOX_MAX_TIMEOUT_MS = 3_000;
/** The longest a LARGE ticket's SwaptoX call may take, ms. */
export const SWAPTOX_MAX_LARGE_TIMEOUT_MS = 10_000;
/** How long a plan's router `deadline` runs past the moment it is built, seconds. */
export const SWAPTOX_DEADLINE_SECONDS = 600n;
/** `callSwap`'s pool kind for a Uniswap-v3-style pool (the executor's `swapV3`). */
const KIND_V3 = 3n;
/** The executor's recipient sentinels (`_resolveRecipient`). */
const TO_EXECUTOR = zeroAddress;
const TO_RECIPIENT = "0x0000000000000000000000000000000000000001" as Address;

export const SWAPTOX_ROUTER_ABI = parseAbi([
  "function swap((address tokenIn, address tokenOut, uint256 amountIn, uint256 amountMinOut, address recipient, bytes swapData, bytes permitData) desc, uint256 deadline, address referral) payable returns (uint256 amountOut, uint256 gasUsed)",
  "function swapAddress(uint256 version) view returns (address)",
]);
const STEP_ABI = parseAbi(["function callSwap(address tokenIn, uint256 percentIn, address tokenOut, address pool, uint256 version, address recipient)"]);

export interface SwaptoxRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
}

/** The subset of one API route we read. */
export interface SwaptoxApiRoute {
  amountIn?: string;
  amountOut?: string;
  gas?: string | number;
  tokenIn?: string;
  tokenOut?: string;
  swapAddress?: string;
  swapData?: string;
}

export interface SwaptoxResponse {
  success?: boolean;
  code?: string;
  message?: string;
  data?: { routes?: SwaptoxApiRoute[] };
}

/** One decoded executor step. */
export interface SwaptoxStep {
  tokenIn: Address;
  percentIn: bigint;
  tokenOut: Address;
  pool: Address;
  recipient: Address;
}

/** A validated SwaptoX route; the router call is encoded at plan time ({@link buildSwaptoxPlan}). */
export interface SwaptoxQuote {
  source: "swaptox";
  router: Address;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  swapData: Hex;
  /** The API's `amountOut`. */
  amountOut: bigint;
  /** `gas × gasMultPct` (0 if absent). */
  gasUnits: bigint;
  /** The v3 pools the route swaps on, in step order (logs). */
  pools: Address[];
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function swaptoxUrl(cfg: Pick<SwaptoxConfig, "baseUrl">, r: SwaptoxRequest): string | undefined {
  const chain = SWAPTOX_CHAINS[r.chainId];
  if (!chain) return undefined;
  const q = new URLSearchParams({ tokenIn: r.tokenIn, tokenOut: r.tokenOut, amountIn: r.amountIn.toString() });
  return `${cfg.baseUrl.replace(/\/$/, "")}/${chain}/routes?${q.toString()}`;
}

/** Decode `swapData` into its version and executor steps (no step validated here). */
export function decodeSwaptoxData(swapData: Hex): { version: bigint; steps: SwaptoxStep[] } {
  if (!/^0x[0-9a-fA-F]*$/.test(swapData) || swapData.length % 2 !== 0) throw new Error("swaptox: swapData malformed");
  const [version, inner] = decodeAbiParameters([{ type: "uint256" }, { type: "bytes" }], swapData);
  const [calls] = decodeAbiParameters([{ type: "bytes[]" }], inner);
  const steps = calls.map((c, i) => {
    let d;
    try {
      d = decodeFunctionData({ abi: STEP_ABI, data: c });
    } catch {
      throw new Error(`swaptox: step ${i} (${c.slice(0, 10)}) is not callSwap`);
    }
    const [tokenIn, percentIn, tokenOut, pool, kind, recipient] = d.args;
    if (kind !== KIND_V3) throw new Error(`swaptox: step ${i} pool kind ${kind} is not a v3 swap`);
    return { tokenIn, percentIn, tokenOut, pool, recipient };
  });
  return { version, steps };
}

/**
 * The step rules: at least one step; percent 1..10000; a recipient sentinel, never an
 * address; every step spends the input or an earlier step's output; every step paying
 * us produces `tokenOut`, and at least one does.
 */
export function checkSwaptoxSteps(steps: readonly SwaptoxStep[], req: Pick<SwaptoxRequest, "tokenIn" | "tokenOut">): string | undefined {
  if (steps.length === 0) return "swaptox: route has no steps";
  const held = new Set([req.tokenIn.toLowerCase()]);
  let paysUs = false;
  for (const [i, s] of steps.entries()) {
    if (s.percentIn === 0n || s.percentIn > 10_000n) return `swaptox: step ${i} percent ${s.percentIn}`;
    if (!held.has(s.tokenIn.toLowerCase())) return `swaptox: step ${i} spends ${s.tokenIn}, which the route does not hold`;
    if (eq(s.recipient, TO_RECIPIENT)) {
      if (!eq(s.tokenOut, req.tokenOut)) return `swaptox: step ${i} pays the solver ${s.tokenOut}, not ${req.tokenOut}`;
      paysUs = true;
    } else if (eq(s.recipient, TO_EXECUTOR)) {
      held.add(s.tokenOut.toLowerCase());
    } else {
      return `swaptox: step ${i} pays ${s.recipient}, not the executor or the solver`;
    }
  }
  return paysUs ? undefined : `swaptox: no step pays the solver`;
}

/** Validate the API's best route against what WE asked for and the pinned config. Fail closed. */
export function validateSwaptoxRoute(
  body: SwaptoxResponse | null,
  req: SwaptoxRequest,
  cfg: Pick<SwaptoxConfig, "router" | "version" | "gasMultPct">,
): Verdict<SwaptoxQuote> {
  if (!body) return { ok: false, reason: "swaptox: no response" };
  if (body.success !== true) return { ok: false, reason: `swaptox: ${sanitize(body.message ?? body.code ?? "not successful", 120)}` };
  const r = body.data?.routes?.[0];
  if (!r) return { ok: false, reason: "swaptox: no route" };
  if (typeof r.swapAddress !== "string" || !eq(r.swapAddress, cfg.router)) {
    return { ok: false, reason: `swaptox: swapAddress ${sanitize(r.swapAddress ?? "(none)", 64)} is not the pinned router ${cfg.router}` };
  }
  if (typeof r.tokenIn !== "string" || !eq(r.tokenIn, req.tokenIn)) return { ok: false, reason: `swaptox: tokenIn ${sanitize(r.tokenIn, 64)} != ${req.tokenIn}` };
  if (typeof r.tokenOut !== "string" || !eq(r.tokenOut, req.tokenOut)) return { ok: false, reason: `swaptox: tokenOut ${sanitize(r.tokenOut, 64)} != ${req.tokenOut}` };
  const amountIn = floorAmount(r.amountIn);
  if (amountIn !== req.amountIn) return { ok: false, reason: `swaptox: amountIn ${sanitize(r.amountIn, 80)} != ${req.amountIn}` };
  // Routes through venues the API cannot price (Sovryn, v2) come back with 0.
  const amountOut = floorAmount(r.amountOut);
  if (amountOut === null || amountOut === 0n) return { ok: false, reason: "swaptox: zero amountOut" };
  if (typeof r.swapData !== "string") return { ok: false, reason: "swaptox: no swapData" };
  let d;
  try {
    d = decodeSwaptoxData(r.swapData as Hex);
  } catch (e) {
    return { ok: false, reason: sanitize((e as Error).message.split("\n")[0]) };
  }
  if (d.version !== cfg.version) return { ok: false, reason: `swaptox: swapData version ${d.version} is not ${cfg.version}` };
  const bad = checkSwaptoxSteps(d.steps, req);
  if (bad) return { ok: false, reason: bad };
  const gas = floorAmount(r.gas ?? 0) ?? 0n;
  return {
    ok: true,
    source: "swaptox",
    router: getAddress(r.swapAddress),
    tokenIn: req.tokenIn,
    tokenOut: req.tokenOut,
    amountIn,
    swapData: r.swapData as Hex,
    amountOut,
    gasUnits: (gas * cfg.gasMultPct + 99n) / 100n,
    pools: d.steps.map((s) => s.pool),
  };
}

/** Fetch and validate one SwaptoX route; any network or shape problem is a refusal, never a throw. */
export async function fetchSwaptoxRoute(
  cfg: SwaptoxConfig,
  req: SwaptoxRequest,
  fetchImpl: typeof fetch = fetch,
): Promise<Verdict<SwaptoxQuote>> {
  if (!cfg.enabled) return { ok: false, reason: "swaptox: disabled" };
  const url = swaptoxUrl(cfg, req);
  if (!url) return { ok: false, reason: `swaptox: chain ${req.chainId} unsupported` };
  let body: SwaptoxResponse | null = null;
  try {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (cfg.apiKey) headers["X-API-Key"] = cfg.apiKey;
    const res = await fetchImpl(url, { headers, signal: AbortSignal.timeout(cfg.timeoutMs) });
    if (!res.ok) return { ok: false, reason: `swaptox: HTTP ${res.status}` };
    body = (await res.json()) as SwaptoxResponse;
  } catch (e) {
    return { ok: false, reason: `swaptox: ${sanitize((e as Error).message.split("\n")[0])}` };
  }
  return validateSwaptoxRoute(body, req, cfg);
}

/**
 * Wait for `call` by ticket size: up to `smallMs`, then — only when `isLarge` resolves
 * true — until `call` settles (its own, longer deadline bounds that). A small ticket
 * gets `onSmall()` at `smallMs`; `call` is left to finish on its own (it never throws).
 */
export async function awaitBySize<T>(call: Promise<T>, a: { smallMs: number; isLarge: Promise<boolean>; onSmall: () => T }): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = Symbol("late");
  const first = await Promise.race([call, new Promise<typeof late>((r) => (timer = setTimeout(() => r(late), a.smallMs)))]);
  clearTimeout(timer);
  if (first !== late) return first;
  return (await a.isLarge) ? call : a.onSmall();
}

/** The router call for a validated route: recipient = the solver, our floor, no permit. */
export function encodeSwaptoxSwap(a: { quote: SwaptoxQuote; recipient: Address; amountMinOut: bigint; deadline: bigint; referral: Address }): Hex {
  return encodeFunctionData({
    abi: SWAPTOX_ROUTER_ABI,
    functionName: "swap",
    args: [
      {
        tokenIn: a.quote.tokenIn,
        tokenOut: a.quote.tokenOut,
        amountIn: a.quote.amountIn,
        amountMinOut: a.amountMinOut,
        recipient: a.recipient,
        swapData: a.quote.swapData,
        permitData: "0x",
      },
      a.deadline,
      a.referral,
    ],
  });
}

/**
 * The RoutePlan for a validated SwaptoX route on a PULL fill: target = the router,
 * `minOut` = owed + cost (also the router's own `amountMinOut`), `maxPay` = owed,
 * `amountIn` patched with what the fill routes.
 */
export function buildSwaptoxPlan(a: {
  quote: SwaptoxQuote;
  owed: bigint;
  costOut: bigint;
  /** The solver: the router's `recipient`. */
  solver: Address;
  profitRecipient: Address;
  minBumpBps: bigint;
  referral: Address;
  /** Unix seconds; the deadline is this + {@link SWAPTOX_DEADLINE_SECONDS}. */
  nowSec: bigint;
}): Verdict<{ plan: RoutePlan }> {
  const minOut = a.owed + a.costOut;
  if (a.quote.amountOut < minOut) return { ok: false, reason: `swaptox: amountOut ${a.quote.amountOut} < owed ${a.owed} + cost ${a.costOut}` };
  return {
    ok: true,
    plan: {
      router: a.quote.router,
      minOut,
      maxPay: a.owed,
      amountInOffset: SWAPTOX_AMOUNT_IN_OFFSET,
      // Exact-input only, like Sushi: no output word to patch.
      amountOutOffset: NO_PATCH,
      minBumpBps: a.minBumpBps,
      profitRecipient: a.profitRecipient,
      originator: zeroAddress,
      originatorPpm: 0,
      data: encodeSwaptoxSwap({ quote: a.quote, recipient: a.solver, amountMinOut: minOut, deadline: a.nowSec + SWAPTOX_DEADLINE_SECONDS, referral: a.referral }),
    },
  };
}

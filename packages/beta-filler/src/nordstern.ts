import { NO_PATCH, type RoutePlan } from "@1delta-x/sdk";
import { getAddress, hexToBigInt, sliceHex, size, zeroAddress, type Address, type Hex } from "viem";

import type { Verdict } from "./policy";
import { sanitize } from "./sanitize";
import { floorAmount } from "./sushi";

/**
 * Nordstern's aggregator API as a third route source for PULL fills (2026-10-11),
 * mirroring ./sushi.ts: the returned calldata is fully DECODED and every field is
 * checked against what WE asked for, never against the response itself.
 *
 * `GET {base}/aggregator/{chainId}?src&dst&amount&from&slippage` (slippage in PERCENT)
 * returns `{ toAmount, minToAmount, gasEstimate, tx: { from, to, data, value } }`.
 * The API answers HTTP 429 without a `Referer` header naming the integrating
 * project's domain, so every request sends `NORDSTERN_REFERER`.
 *
 * `tx.to` is Nordstern's **AggregatorGuard** (Rootstock: `0x63d3…527c`, verified
 * source, immutable). Its calldata is NOT ABI-encoded: selector `IceCreamSwap()`
 * `0x3f0bde25` followed by PACKED fields at fixed byte offsets (selector included):
 *
 *     4   id                  uint16
 *     6   executor            address   (20 B)
 *     26  amountIn            uint128   (16 B)
 *     42  minAmountOut        uint128   (16 B)
 *     58  executor flag       1 B       (opaque)
 *     59  firstTokenReceiver  address
 *     79  recipient           address   (= the request's `from`)
 *     99  tokenIn             address
 *     119 tokenOut            address
 *     139 …                   opaque route bytes for the executor
 *
 * The guard pulls `amountIn` of `tokenIn` from ITS `msg.sender` — the solver's
 * RouteSandbox — to `firstTokenReceiver`, calls `executor.executeSwap(msg.data[26:])`,
 * then REQUIRES `recipient`'s `tokenOut` balance to have risen by `minAmountOut`.
 * Exact-input only (no exact-output form), so: PULL orders only.
 *
 *   • `recipient` must be the SOLVER (we pass it as `from`); the sandbox, which calls
 *     the guard, appears nowhere in the calldata.
 *   • `executor` must be in `NORDSTERN_EXECUTORS` — STRICT: an empty list accepts
 *     nothing (the executor's source is unverified; Rootstock default
 *     `0xb4FE…5B36`, same deployer as the guard). `firstTokenReceiver` must be that
 *     executor.
 *   • `amountIn` must equal exactly what the fill routes. It is a 16-byte field, so
 *     the plan's 32-byte `amountInOffset` patch would clobber the executor's address
 *     bytes: the plan is built with {@link NO_PATCH} and the quote is requested for
 *     the exact previewed input. A fill that delivers more leaves the excess as input
 *     residue (swept back to the solver); one that delivers less makes the guard's
 *     `transferFrom` revert — never a silent mis-size.
 *   • `minAmountOut` is the guard's FIXED floor: > 0 and ≤ `toAmount`, and at plan
 *     time ≥ owed + gas + min profit (the solver's `minOut` repeats it on-chain).
 *   • no native value; the calldata must carry route bytes after the fixed head.
 *
 * PRICING: `toAmount` is not trusted. A Rootstock fork execution delivered exactly
 * the Oku QuoterV2 figure while the API reported ~1 bp more. The candidate's output
 * is therefore `toAmount × (1 − NORDSTERN_HAIRCUT_BPS)` (default 2 bps) — for ranking,
 * for the profit gate and for `/quote` alike — and the API is asked for at least that
 * much slippage, so the guard's own floor never sits above the figure we price at.
 * The simulation of `executeFill` then runs with the plan's `minOut` = owed + gas +
 * min profit: a route that delivers less than the gate assumed reverts there.
 */
export interface NordsternConfig {
  enabled: boolean;
  /** API base, default `https://api.nordstern.finance`. */
  baseUrl: string;
  /** The PINNED AggregatorGuard; any other `tx.to` is refused. */
  router: Address;
  /** The executors accepted in the calldata. STRICT: empty = every route refused. */
  executors: Address[];
  /** Sent as the `Referer` header (the API refuses requests without one). */
  referer: string;
  timeoutMs: number;
  /** At most this many Nordstern API calls per sweep over the book. */
  maxPerSweep: number;
  /** Haircut on the API's `toAmount` before it is ranked, gated or quoted, bps. */
  haircutBps: bigint;
}

/** Nordstern's AggregatorGuard on Rootstock (chain 30): `/chains` → `RouterAddress`. */
export const NORDSTERN_GUARD_ROOTSTOCK = "0x63d3C7Ab37ca36A2A0A338076C163fF60c72527c" as Address;
/** The executor every Rootstock route named in 2026-10 (source unverified; same deployer as the guard). */
export const NORDSTERN_EXECUTOR_ROOTSTOCK = "0xb4FE60CD05A3e68668007Cee83DDFD9A50A45B36" as Address;
/** `IceCreamSwap()`. */
export const NORDSTERN_SELECTOR = "0x3f0bde25" as Hex;
/** The packed head ends here; route bytes follow. */
export const NORDSTERN_HEAD_BYTES = 139;
/** The docs advise +20 % on `gasEstimate`; applied to the ranking figure. */
const GAS_MARKUP_PCT = 120n;

export interface NordsternRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  /** Who the guard pays: the solver (pull mode). The API's `from`. */
  recipient: Address;
  /** The route haircut the fill is gated at; the API is asked for max(this, the Nordstern haircut). */
  slippageBps: bigint;
}

/** The subset of the aggregator response we read. */
export interface NordsternResponse {
  toAmount?: string;
  minToAmount?: string;
  gasEstimate?: string | number;
  error?: string;
  tx?: { from?: string; to?: string; data?: string; value?: string | number };
}

/** The decoded packed head of a guard call. */
export interface NordsternCall {
  id: number;
  executor: Address;
  amountIn: bigint;
  minAmountOut: bigint;
  flag: number;
  firstTokenReceiver: Address;
  recipient: Address;
  tokenIn: Address;
  tokenOut: Address;
  /** Length of the opaque route bytes after the head. */
  routeBytes: number;
}

/** A validated, executable Nordstern route. */
export interface NordsternQuote {
  source: "nordstern";
  router: Address;
  data: Hex;
  /** The figure we price at: `toAmount × (1 − haircut)`. */
  amountOut: bigint;
  /** The API's own `toAmount` (logged, never priced). */
  apiAmountOut: bigint;
  /** The guard's floor, decoded from the calldata. */
  minAmountOut: bigint;
  /** The route's own gas: `gasEstimate × 1.2` (0 if absent). */
  gasUnits: bigint;
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** The slippage the API is asked for, bps: never below the haircut we price at. */
export function nordsternSlippageBps(req: Pick<NordsternRequest, "slippageBps">, cfg: Pick<NordsternConfig, "haircutBps">): bigint {
  return req.slippageBps > cfg.haircutBps ? req.slippageBps : cfg.haircutBps;
}

/** bps → the API's PERCENT string (10 bps ⇒ "0.1", 2 bps ⇒ "0.02"). */
export function bpsToPercent(bps: bigint): string {
  const whole = bps / 100n;
  const frac = (bps % 100n).toString().padStart(2, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole.toString();
}

export function nordsternUrl(cfg: Pick<NordsternConfig, "baseUrl" | "haircutBps">, r: NordsternRequest): string {
  const q = new URLSearchParams({
    src: r.tokenIn,
    dst: r.tokenOut,
    amount: r.amountIn.toString(),
    from: r.recipient,
    // PERCENT (0.1% ⇒ "0.1") — unlike Sushi's decimal maxSlippage.
    slippage: bpsToPercent(nordsternSlippageBps(r, cfg)),
  });
  return `${cfg.baseUrl.replace(/\/$/, "")}/aggregator/${r.chainId}?${q.toString()}`;
}

/** Decode the packed guard calldata (selector checked; no field validated here). */
export function decodeNordstern(data: Hex): NordsternCall {
  if (!/^0x[0-9a-fA-F]*$/.test(data) || data.length % 2 !== 0) throw new Error("nordstern: calldata malformed");
  const n = size(data);
  if (n <= NORDSTERN_HEAD_BYTES) throw new Error(`nordstern: calldata too short (${n} bytes)`);
  if (sliceHex(data, 0, 4).toLowerCase() !== NORDSTERN_SELECTOR) throw new Error(`nordstern: selector ${sliceHex(data, 0, 4)} is not IceCreamSwap`);
  const a = (from: number) => getAddress(sliceHex(data, from, from + 20));
  const u = (from: number, to: number) => hexToBigInt(sliceHex(data, from, to));
  return {
    id: Number(u(4, 6)),
    executor: a(6),
    amountIn: u(26, 42),
    minAmountOut: u(42, 58),
    flag: Number(u(58, 59)),
    firstTokenReceiver: a(59),
    recipient: a(79),
    tokenIn: a(99),
    tokenOut: a(119),
    routeBytes: n - NORDSTERN_HEAD_BYTES,
  };
}

/** `toAmount × (1 − haircut)`, rounded down. */
export function nordsternPricedOut(toAmount: bigint, haircutBps: bigint): bigint {
  return (toAmount * (10_000n - haircutBps)) / 10_000n;
}

/**
 * Decode and validate an aggregator response against what WE asked for and the
 * pinned config. Fail closed on anything unexpected.
 */
export function validateNordsternRoute(
  body: NordsternResponse | null,
  req: NordsternRequest,
  cfg: Pick<NordsternConfig, "router" | "executors" | "haircutBps">,
): Verdict<NordsternQuote> {
  if (!body) return { ok: false, reason: "nordstern: no response" };
  if (typeof body.error === "string") return { ok: false, reason: `nordstern: ${sanitize(body.error, 120)}` };
  const tx = body.tx;
  if (!tx || typeof tx.to !== "string" || typeof tx.data !== "string") return { ok: false, reason: "nordstern: no tx" };
  if (!eq(tx.to, cfg.router)) return { ok: false, reason: `nordstern: tx.to ${sanitize(tx.to, 64)} is not the pinned guard ${cfg.router}` };
  if (tx.value !== undefined && floorAmount(tx.value) !== 0n) return { ok: false, reason: "nordstern: native value on an ERC-20 route" };
  let d: NordsternCall;
  try {
    d = decodeNordstern(tx.data as Hex);
  } catch (e) {
    return { ok: false, reason: sanitize((e as Error).message.split("\n")[0]) };
  }
  if (!cfg.executors.some((x) => eq(x, d.executor))) return { ok: false, reason: `nordstern: executor ${d.executor} is not in NORDSTERN_EXECUTORS` };
  if (!eq(d.firstTokenReceiver, d.executor)) return { ok: false, reason: `nordstern: firstTokenReceiver ${d.firstTokenReceiver} is not the executor` };
  if (!eq(d.recipient, req.recipient)) return { ok: false, reason: `nordstern: recipient ${d.recipient} is not the solver ${req.recipient}` };
  if (!eq(d.tokenIn, req.tokenIn)) return { ok: false, reason: `nordstern: tokenIn ${d.tokenIn} != ${req.tokenIn}` };
  if (!eq(d.tokenOut, req.tokenOut)) return { ok: false, reason: `nordstern: tokenOut ${d.tokenOut} != ${req.tokenOut}` };
  if (d.amountIn === 0n || d.amountIn !== req.amountIn) return { ok: false, reason: `nordstern: amountIn ${d.amountIn} != ${req.amountIn}` };
  const apiOut = floorAmount(body.toAmount);
  if (apiOut === null || apiOut === 0n) return { ok: false, reason: "nordstern: no toAmount" };
  if (d.minAmountOut === 0n || d.minAmountOut > apiOut) return { ok: false, reason: `nordstern: minAmountOut ${d.minAmountOut} vs toAmount ${apiOut}` };
  const amountOut = nordsternPricedOut(apiOut, cfg.haircutBps);
  if (amountOut === 0n) return { ok: false, reason: "nordstern: zero output after the haircut" };
  const gas = floorAmount(body.gasEstimate ?? 0) ?? 0n;
  return {
    ok: true,
    source: "nordstern",
    router: getAddress(tx.to),
    data: tx.data as Hex,
    amountOut,
    apiAmountOut: apiOut,
    minAmountOut: d.minAmountOut,
    gasUnits: (gas * GAS_MARKUP_PCT + 99n) / 100n,
  };
}

/** Fetch and validate one Nordstern route; any network or shape problem is a refusal, never a throw. */
export async function fetchNordsternRoute(
  cfg: NordsternConfig,
  req: NordsternRequest,
  fetchImpl: typeof fetch = fetch,
): Promise<Verdict<NordsternQuote>> {
  if (!cfg.enabled) return { ok: false, reason: "nordstern: disabled" };
  let body: NordsternResponse | null = null;
  try {
    const res = await fetchImpl(nordsternUrl(cfg, req), {
      headers: { Referer: cfg.referer, Accept: "application/json" },
      signal: AbortSignal.timeout(cfg.timeoutMs),
    });
    // 422 = "no swap route found": a plain miss, carried as the API's own message.
    if (!res.ok && res.status !== 422) return { ok: false, reason: `nordstern: HTTP ${res.status}` };
    body = (await res.json()) as NordsternResponse;
    if (!res.ok && typeof body?.error !== "string") return { ok: false, reason: `nordstern: HTTP ${res.status}` };
  } catch (e) {
    return { ok: false, reason: `nordstern: ${sanitize((e as Error).message.split("\n")[0])}` };
  }
  return validateNordsternRoute(body, req, cfg);
}

/**
 * The RoutePlan for a validated Nordstern route on a PULL fill: target = the guard,
 * `minOut` = owed + cost, `maxPay` = owed, NO amount patch (the 16-byte `amountIn`
 * cannot take the plan's 32-byte patch — the quote is for the exact input). Refuses a
 * route whose own floor is below owed + cost, so the guard reverts before the fill
 * could lose money; the solver's `minOut` carries the same bound on-chain.
 */
export function buildNordsternPlan(a: {
  quote: NordsternQuote;
  owed: bigint;
  costOut: bigint;
  profitRecipient: Address;
  minBumpBps: bigint;
}): Verdict<{ plan: RoutePlan }> {
  const minOut = a.owed + a.costOut;
  if (a.quote.minAmountOut < minOut) {
    return { ok: false, reason: `nordstern: minAmountOut ${a.quote.minAmountOut} < owed ${a.owed} + cost ${a.costOut}` };
  }
  return {
    ok: true,
    plan: {
      router: a.quote.router,
      minOut,
      maxPay: a.owed,
      amountInOffset: NO_PATCH,
      amountOutOffset: NO_PATCH,
      minBumpBps: a.minBumpBps,
      profitRecipient: a.profitRecipient,
      originator: zeroAddress,
      originatorPpm: 0,
      data: a.quote.data,
    },
  };
}

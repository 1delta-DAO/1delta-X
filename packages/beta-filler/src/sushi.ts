import { decodeSnwap, isSnwapExecutorAllowed, NO_PATCH, SNWAP_AMOUNT_IN_OFFSET, type RoutePlan } from "@1delta-x/sdk";
import { zeroAddress, type Address, type Hex } from "viem";

import type { Verdict } from "./policy";
import { sanitize } from "./sanitize";

/**
 * SushiSwap's routing API as a second route source for PULL fills (adapted from
 * packages/auction/src/sources/sushi.ts + guard.ts, but stricter: the returned
 * calldata is fully DECODED and every field checked, not presence-tested).
 *
 * `GET {base}/swap/v7/{chainId}?tokenIn&tokenOut&amount&maxSlippage&sender&recipient`
 * returns `tx = { to, data, value }`, a call to Sushi's **RedSnwapper**
 * (`snwap(tokenIn, amountIn, recipient, tokenOut, amountOutMin, executor,
 * executorData)`), NOT a RouteProcessor: snwap pulls `amountIn` from ITS
 * `msg.sender` — the solver's RouteSandbox — into `executor` and then REQUIRES
 * `recipient`'s `tokenOut` balance to rise by `amountOutMin`. So:
 *
 *   • `recipient` must be the SOLVER (pull mode: Settlement pulls the owed amount
 *     from the solver; the surplus is our spread). We request it that way and
 *     refuse anything else.
 *   • `sender` is the sandbox (who calls snwap). It does not appear in the calldata.
 *   • `amountIn` must equal what the fill delivers (`received`); 0 means "snwap's
 *     own balance" and is refused. Its word is at byte offset 36, which is the
 *     plan's `amountInOffset` (the executor swaps what it actually received).
 *   • `amountOutMin` is snwap's own floor, a FIXED figure — it must be ≥ owed +
 *     gas + min profit, so the route reverts rather than fill at a loss (the
 *     solver's `minOut` repeats the same bound on-chain).
 *   • the calldata must be CANONICAL (re-encoding the decoded arguments gives the
 *     same bytes — no trailing data, no relocated `executorData`), and when
 *     `SUSHI_EXECUTORS` is set, `executor` must be one of those addresses.
 *
 * Pull mode only: exact-INPUT pays the surplus to the solver. Direct
 * (delta-verify) orders keep the local Oku exact-output path.
 */
export interface SushiConfig {
  enabled: boolean;
  /** API base, default `https://api.sushi.com`. */
  baseUrl: string;
  /** The PINNED RedSnwapper address; any other `tx.to` is refused. */
  router: Address;
  timeoutMs: number;
  /**
   * Pinned snwap executors (Sushi's RouteProcessor). Empty = not pinned (warned at
   * start-up); when set, any other executor is refused.
   */
  executors: Address[];
  /** At most this many Sushi API calls per sweep over the book. */
  maxPerSweep: number;
}

/** Sushi's RedSnwapper on Rootstock (chain 30) — `tx.to` of every swap/v7 response. */
export const SUSHI_RED_SNWAPPER_ROOTSTOCK = "0xAC4c6e212A361c968F1725b4d055b47E63F80b75" as Address;

export interface SushiRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  /** Who calls snwap: the solver's RouteSandbox. */
  sender: Address;
  /** Who snwap pays: the solver (pull mode). */
  recipient: Address;
  slippageBps: bigint;
}

/** The subset of the swap/v7 response we read. */
export interface SushiResponse {
  status?: string;
  assumedAmountOut?: string;
  gasSpent?: number | string;
  tx?: { to?: string; data?: string; value?: string | number; gas?: string | number };
}

/** A validated, executable Sushi route. */
export interface SushiQuote {
  source: "sushi";
  router: Address;
  data: Hex;
  /** The API's expected output (`assumedAmountOut`). */
  amountOut: bigint;
  /** snwap's own floor, decoded from the calldata. */
  amountOutMin: bigint;
  /** The route's own gas, as the API reports it (0 if absent). */
  gasUnits: bigint;
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function sushiUrl(cfg: Pick<SushiConfig, "baseUrl">, r: SushiRequest): string {
  const q = new URLSearchParams({
    tokenIn: r.tokenIn,
    tokenOut: r.tokenOut,
    amount: r.amountIn.toString(),
    // DECIMAL slippage (0.3% ⇒ "0.003") — the one API-shape difference that
    // misprices silently if copied from a percent-based source.
    maxSlippage: (Number(r.slippageBps) / 10_000).toString(),
    sender: r.sender,
    recipient: r.recipient,
    simulate: "false",
  });
  return `${cfg.baseUrl.replace(/\/$/, "")}/swap/v7/${r.chainId}?${q.toString()}`;
}

/** A non-negative integer string (the API sometimes sends floats) floored to bigint, or null. */
export function floorAmount(v: unknown): bigint | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const s = String(v).trim();
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  return BigInt(s.split(".")[0]!);
}

/**
 * Decode and validate a swap/v7 response against what WE asked for. Every check
 * is against the request or the pinned config, never against the response itself.
 */
export function validateSushiRoute(
  body: SushiResponse | null,
  req: SushiRequest,
  cfg: Pick<SushiConfig, "router"> & Partial<Pick<SushiConfig, "executors">>,
): Verdict<SushiQuote> {
  if (!body) return { ok: false, reason: "sushi: no response" };
  if (body.status !== "Success") return { ok: false, reason: `sushi: status ${sanitize(body.status ?? "(none)", 80)}` };
  const tx = body.tx;
  if (!tx || typeof tx.to !== "string" || typeof tx.data !== "string") return { ok: false, reason: "sushi: no tx" };
  if (!eq(tx.to, cfg.router)) return { ok: false, reason: `sushi: tx.to ${sanitize(tx.to, 64)} is not the pinned router ${cfg.router}` };
  if (tx.value !== undefined && floorAmount(tx.value) !== 0n) return { ok: false, reason: "sushi: native value on an ERC-20 route" };
  if (!/^0x[0-9a-fA-F]*$/.test(tx.data)) return { ok: false, reason: "sushi: calldata malformed" };
  let d;
  try {
    d = decodeSnwap(tx.data as Hex);
  } catch (e) {
    return { ok: false, reason: `sushi: ${sanitize((e as Error).message.split("\n")[0])}` };
  }
  if (!isSnwapExecutorAllowed(d.executor, cfg.executors ?? [])) {
    return { ok: false, reason: `sushi: executor ${d.executor} is not in SUSHI_EXECUTORS` };
  }
  if (!eq(d.tokenIn, req.tokenIn)) return { ok: false, reason: `sushi: tokenIn ${d.tokenIn} != ${req.tokenIn}` };
  if (!eq(d.tokenOut, req.tokenOut)) return { ok: false, reason: `sushi: tokenOut ${d.tokenOut} != ${req.tokenOut}` };
  if (d.amountIn === 0n || d.amountIn !== req.amountIn) return { ok: false, reason: `sushi: amountIn ${d.amountIn} != ${req.amountIn}` };
  if (!eq(d.recipient, req.recipient)) return { ok: false, reason: `sushi: recipient ${d.recipient} is not the solver ${req.recipient}` };
  const amountOut = floorAmount(body.assumedAmountOut);
  if (amountOut === null || amountOut === 0n) return { ok: false, reason: "sushi: no assumedAmountOut" };
  if (d.amountOutMin === 0n || d.amountOutMin > amountOut) return { ok: false, reason: `sushi: amountOutMin ${d.amountOutMin} vs assumed ${amountOut}` };
  const gasUnits = floorAmount(body.gasSpent ?? body.tx?.gas ?? 0) ?? 0n;
  return { ok: true, source: "sushi", router: tx.to as Address, data: tx.data as Hex, amountOut, amountOutMin: d.amountOutMin, gasUnits };
}

/** Fetch and validate one Sushi route; any network or shape problem is a refusal, never a throw. */
export async function fetchSushiRoute(
  cfg: SushiConfig,
  req: SushiRequest,
  fetchImpl: typeof fetch = fetch,
): Promise<Verdict<SushiQuote>> {
  if (!cfg.enabled) return { ok: false, reason: "sushi: disabled" };
  let body: SushiResponse | null = null;
  try {
    const res = await fetchImpl(sushiUrl(cfg, req), { signal: AbortSignal.timeout(cfg.timeoutMs) });
    if (!res.ok) return { ok: false, reason: `sushi: HTTP ${res.status}` };
    body = (await res.json()) as SushiResponse;
  } catch (e) {
    return { ok: false, reason: `sushi: ${sanitize((e as Error).message.split("\n")[0])}` };
  }
  return validateSushiRoute(body, req, cfg);
}

/**
 * The RoutePlan for a validated Sushi route on a PULL fill. Refuses a route whose
 * own floor (`amountOutMin`) is below what the fill must produce — owed + gas + min
 * profit — so snwap reverts before the fill could lose money; the solver's `minOut`
 * carries the same bound on-chain.
 */
export function buildSushiPlan(a: {
  quote: SushiQuote;
  owed: bigint;
  costOut: bigint;
  profitRecipient: Address;
  /** The filler's on-chain price floor — see `buildRoutePlan`. */
  minBumpBps: bigint;
}): Verdict<{ plan: RoutePlan }> {
  const minOut = a.owed + a.costOut;
  if (a.quote.amountOutMin < minOut) {
    return { ok: false, reason: `sushi: amountOutMin ${a.quote.amountOutMin} < owed ${a.owed} + cost ${a.costOut}` };
  }
  return {
    ok: true,
    plan: {
      router: a.quote.router,
      minOut,
      maxPay: a.owed,
      amountInOffset: SNWAP_AMOUNT_IN_OFFSET,
      // Never patched (task 05): Sushi routes only PULL fills, where Settlement pulls
      // `owed` and the decay is already our surplus; and snwap is exact-INPUT — its only
      // output word, `amountOutMin`, is a floor on the solver's own balance rise, not
      // the amount paid, so there is no word a live `outputAt` could safely replace.
      amountOutOffset: NO_PATCH,
      minBumpBps: a.minBumpBps,
      profitRecipient: a.profitRecipient,
      originator: zeroAddress,
      originatorPpm: 0,
      data: a.quote.data,
    },
  };
}

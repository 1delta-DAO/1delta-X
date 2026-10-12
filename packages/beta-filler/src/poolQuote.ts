import { QUOTER_V2_ABI, encodeV3Path, encodeV3PathReversed } from "@1delta-x/sdk";
import type { Address } from "viem";

import type { RoutePath } from "./config";
import { aggregate, pathVenues, type BatchCall, type BatchClient, type BatchResult } from "./poolGraph";

/**
 * Quoting pool paths on each venue's Uniswap-v3 QuoterV2.
 *
 *  • A SINGLE-VENUE path is one call on that venue's quoter: `quoteExactInput(path,
 *    amountIn)` forward, or `quoteExactOutput(reversed path, amountOut)` backward.
 *  • A MIXED-VENUE path cannot be (a quoter only knows its own factory's pools): it
 *    is quoted HOP BY HOP — `quoteExactInputSingle` forward from the first hop, each
 *    hop's output the next hop's input; `quoteExactOutputSingle` BACKWARD from the
 *    last hop for an exact-output route, each hop's required input the previous hop's
 *    output — on each hop's own venue quoter, summing the hops' `gasEstimate`s.
 *
 * Every path is quoted in ROUNDS: round r carries every single-venue path (round 0)
 * and hop r of every mixed path, batched through Multicall3 when one is configured —
 * so K candidates of ≤ 3 hops cost ≤ 3 `eth_call`s, not ~K × hops.
 */

/**
 * Quoter calls per Multicall3 `eth_call`. A quote usually costs 75–250k gas, but one
 * through a THIN pool can cross ticks for 0.5–2M gas or run out of gas outright
 * (measured on Rootstock 2026-10-12: USD₮0/DOC 0.01 %, RIF/WRBTC 0.05 %) — and a
 * sub-call that runs out of gas takes 63/64 of what is left with it, starving the
 * calls after it. Small chunks bound that blast radius; failed calls are re-run alone
 * ({@link runCalls}).
 */
export const QUOTES_PER_CALL = 4;

/** What a quote needs from the chain: single calls (viem `simulateContract`) and, for batches, `readContract` (Multicall3). */
export interface QuoteClient extends BatchClient {
  simulateContract(a: { address: Address; abi: typeof QUOTER_V2_ABI; functionName: string; args: readonly unknown[] }): Promise<{ result: unknown }>;
}

export type PathQuote =
  /** `amount` = the output (exact-in) or the required input (exact-out); `gasUnits` = the quoters' summed estimate. */
  | { ok: true; amount: bigint; gasUnits: bigint }
  /** `transient` = an RPC failure (says nothing about the path); else the quote reverted or came back zero. */
  | { ok: false; transient: boolean; reason: string };

/**
 * Whether an error is an execution failure (deterministic for the state it ran on),
 * not an RPC failure: a revert, or an `eth_call` that returned NO data — what the
 * Rootstock node answers for a call that ran out of gas or reverted without a reason.
 */
export function isRevert(e: unknown): boolean {
  let cur = e as { name?: unknown; message?: unknown; cause?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (cur.name === "ContractFunctionRevertedError" || cur.name === "ContractFunctionZeroDataError") return true;
    if (typeof cur.message === "string" && /execution reverted|returned no data/i.test(cur.message)) return true;
    cur = cur.cause as typeof cur;
  }
  return false;
}

/** Whether every hop of the path is on one venue (one `quoteExactInput` / `quoteExactOutput` call). */
export function singleVenue(path: RoutePath): boolean {
  const v = pathVenues(path);
  return v.every((x) => x === v[0]);
}

type CallResult = BatchResult & { transient?: boolean };

/** Plain `eth_call`s, one after another (the public node rate-limits). */
async function single(client: QuoteClient, calls: readonly BatchCall[]): Promise<CallResult[]> {
  const out: CallResult[] = [];
  for (const c of calls) {
    try {
      const { result } = await client.simulateContract({ address: c.address, abi: QUOTER_V2_ABI, functionName: c.functionName, args: c.args ?? [] });
      out.push({ ok: true, result });
    } catch (e) {
      out.push({ ok: false, reason: (e as Error).message?.split("\n")[0] ?? String(e), transient: !isRevert(e) });
    }
  }
  return out;
}

/**
 * Run quoter calls: one call alone (or with no Multicall3) as plain `eth_call`s;
 * more than one through Multicall3 in chunks of {@link QUOTES_PER_CALL}. A call that
 * FAILS inside a chunk is re-run alone (it may only have been starved by an
 * out-of-gas neighbour), and so is every call of a chunk whose `eth_call` itself
 * failed deterministically (no data: the chunk ran out of gas). A chunk whose RPC
 * failed (network, rate limit) marks its calls transient without a retry.
 */
async function runCalls(client: QuoteClient, multicall: Address | undefined, calls: readonly BatchCall[]): Promise<CallResult[]> {
  if (calls.length === 0) return [];
  if (calls.length === 1 || !multicall) return single(client, calls);
  const out: CallResult[] = [];
  for (let i = 0; i < calls.length; i += QUOTES_PER_CALL) {
    const chunk = calls.slice(i, i + QUOTES_PER_CALL);
    let res: CallResult[];
    try {
      res = await aggregate(client, multicall, chunk, chunk.length);
    } catch (e) {
      if (!isRevert(e)) {
        const reason = `multicall: ${(e as Error).message?.split("\n")[0] ?? e}`;
        out.push(...chunk.map(() => ({ ok: false as const, reason, transient: true })));
        continue;
      }
      res = chunk.map(() => ({ ok: false as const, reason: "multicall ran out of gas" }));
    }
    if (chunk.length > 1) {
      const failed = res.flatMap((r, k) => (r.ok ? [] : [k]));
      if (failed.length) {
        const again = await single(client, failed.map((k) => chunk[k]!));
        failed.forEach((k, j) => void (res[k] = again[j]!));
      }
    }
    out.push(...res);
  }
  return out;
}

/**
 * Quote every path for `amount`: `kind = "in"` → exact-input of `amount` (forward),
 * `"out"` → the input an exact-OUTPUT of `amount` needs (backward). `quoters` maps a
 * venue index to its QuoterV2; a path with a venue missing from it is refused (not
 * transient). Results are index-aligned with `paths`.
 */
export async function quotePaths(
  client: QuoteClient,
  quoters: ReadonlyMap<number, Address>,
  multicall: Address | undefined,
  paths: readonly RoutePath[],
  amount: bigint,
  kind: "in" | "out",
): Promise<PathQuote[]> {
  const res: Array<PathQuote | undefined> = paths.map(() => undefined);
  const live = paths.map((p, i) => ({ i, p, venues: pathVenues(p), single: singleVenue(p), cur: amount, gas: 0n, step: 0 }));
  for (const s of live) {
    const missing = s.venues.find((v) => !quoters.has(v));
    if (missing !== undefined) res[s.i] = { ok: false, transient: false, reason: `venue ${missing} is not routable` };
  }
  let active = live.filter((s) => res[s.i] === undefined);
  while (active.length) {
    const calls: BatchCall[] = active.map((s) => {
      if (s.single) {
        return {
          address: quoters.get(s.venues[0]!)!,
          abi: QUOTER_V2_ABI,
          functionName: kind === "in" ? "quoteExactInput" : "quoteExactOutput",
          args: [kind === "in" ? encodeV3Path(s.p.tokens, s.p.fees) : encodeV3PathReversed(s.p.tokens, s.p.fees), s.cur],
        };
      }
      const hops = s.p.fees.length;
      const h = kind === "in" ? s.step : hops - 1 - s.step;
      return {
        address: quoters.get(s.venues[h]!)!,
        abi: QUOTER_V2_ABI,
        functionName: kind === "in" ? "quoteExactInputSingle" : "quoteExactOutputSingle",
        args: [{ tokenIn: s.p.tokens[h]!, tokenOut: s.p.tokens[h + 1]!, [kind === "in" ? "amountIn" : "amount"]: s.cur, fee: s.p.fees[h]!, sqrtPriceLimitX96: 0n }],
      };
    });
    const out = await runCalls(client, multicall, calls);
    const next: typeof active = [];
    active.forEach((s, k) => {
      const r = out[k]!;
      if (!r.ok) return void (res[s.i] = { ok: false, transient: !!(r as { transient?: boolean }).transient, reason: r.reason });
      const t = r.result as readonly [bigint, unknown, unknown, bigint];
      const amt = BigInt(t[0]);
      s.gas += BigInt(t[3]);
      if (amt === 0n) return void (res[s.i] = { ok: false, transient: false, reason: "zero quote" });
      s.cur = amt;
      s.step++;
      if (s.single || s.step === s.p.fees.length) res[s.i] = { ok: true, amount: s.cur, gasUnits: s.gas };
      else next.push(s);
    });
    active = next;
  }
  return res.map((r) => r!);
}

import { decodeAbiParameters, type Hex } from "viem";

/**
 * TURNOVER (2026-10-20): every conversion a fill ran, read from its transaction's
 * receipt — each Uniswap-v3-style pool `Swap` (Oku, Sushi v3, the pool hops of an API
 * route) is one hop, counted at the USD of what the pool RECEIVED. A transaction with
 * no swap (an inventory fill, two orders matched against each other) converts only
 * through its fills, so its fills are its turnover. A two-hop route is therefore ~2×
 * its fill; volume (lib/dashboard.ts) never is.
 */

/** keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)") — Uniswap v3 and its forks. */
export const SWAP_V3_TOPIC =
  "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67";

export interface ReceiptLog {
  address: string;
  topics: readonly string[];
  data: string;
}

/** One pool hop: the pool and the raw amounts it moved (token0, token1; positive = the pool received it). */
export interface Hop {
  pool: string;
  amount0: string;
  amount1: string;
}

/** The v3 swaps in a receipt's logs, in order. */
export function hopsOf(logs: readonly ReceiptLog[]): Hop[] {
  const out: Hop[] = [];
  for (const l of logs) {
    if (l.topics[0]?.toLowerCase() !== SWAP_V3_TOPIC) continue;
    try {
      const [a0, a1] = decodeAbiParameters(
        [{ type: "int256" }, { type: "int256" }],
        l.data as Hex,
      );
      out.push({
        pool: l.address.toLowerCase(),
        amount0: a0.toString(),
        amount1: a1.toString(),
      });
    } catch {
      // not a v3 Swap after all
    }
  }
  return out;
}

/** A pool's two tokens (lowercase). */
export interface PoolTokens {
  token0: string;
  token1: string;
}

/**
 * One hop's USD: what the pool received, at its token's price; else what it paid out
 * (a token we have no price for on the input side). `undefined` when neither side prices.
 */
export function hopUsd(
  hop: Hop,
  pool: PoolTokens | undefined,
  value: (token: string, wei: bigint) => number | undefined,
): number | undefined {
  if (!pool) return undefined;
  const a0 = BigInt(hop.amount0);
  const a1 = BigInt(hop.amount1);
  const [inTok, inAmt, outTok, outAmt] =
    a0 > 0n
      ? [pool.token0, a0, pool.token1, -a1]
      : [pool.token1, a1, pool.token0, -a0];
  return value(inTok, inAmt) ?? value(outTok, outAmt);
}

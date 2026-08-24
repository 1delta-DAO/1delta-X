import type { Address } from "viem";

import type { RouteQuote, RouteRequest, RouteSource } from "../solver";
import {
  floorNumericAmount,
  getJson,
  isAddress,
  isRealRecipient,
  nativeAs,
  searchParams,
  type HttpSourceOptions,
} from "./http";

/**
 * SushiSwap as a {@link RouteSource}.
 *
 * Two endpoints, and which one is used depends on whether a recipient is known:
 *   • `/swap/v7/{chainId}`  — returns a `tx` the winner can execute
 *   • `/quote/v6/{chainId}` — price only, no recipient required
 *
 * A solver about to bid wants the first: it needs the number to price with AND
 * the calldata to execute if it wins, and asking twice doubles both latency and
 * the chance the two disagree.
 *
 * Slippage is a DECIMAL here (0.3% ⇒ 0.003) — the one API-shape difference from
 * Nordstern that silently misprices if copied across.
 */
export interface SushiOptions extends HttpSourceOptions {
  baseUrl?: string;
}

interface SushiResponse {
  status?: string;
  amountIn?: string;
  assumedAmountOut?: string;
  tx?: { to?: string; data?: string; value?: string; gas?: string | number };
}

export function sushiSource(opts: SushiOptions = {}): RouteSource {
  const base = opts.baseUrl ?? "https://api.sushi.com";
  const slippage = (opts.slippagePercent ?? 0.5) / 100;

  return {
    name: "sushiswap",
    async quote(req: RouteRequest): Promise<RouteQuote | null> {
      const tokenIn = nativeAs(req.tokenIn, "placeholder");
      const tokenOut = nativeAs(req.tokenOut, "placeholder");
      // The tokens come from an ORDER LEG, i.e. off the wire — see {isAddress}.
      // Refusing to quote is the right answer: a malformed token is not a route
      // this solver can bid on anyway.
      if (!isAddress(tokenIn) || !isAddress(tokenOut)) return null;
      const executable = isRealRecipient(req.recipient);
      // No real recipient ⇒ this is a PRICE check, and `quote/v6` is the endpoint
      // that takes none. Asking `swap/v7` for calldata nobody can execute wastes
      // the call and invites a tx built for the wrong destination.
      const url = executable
        ? `${base}/swap/v7/${req.chainId}?` +
          searchParams({
            tokenIn,
            tokenOut,
            sender: req.recipient,
            recipient: req.recipient,
            amount: String(req.amountIn),
            maxSlippage: slippage,
            simulate: "false",
            validate: "false",
          })
        : `${base}/quote/v6/${req.chainId}?` +
          searchParams({ tokenIn, tokenOut, amount: String(req.amountIn), maxSlippage: slippage });

      const body = (await getJson(url, opts)) as SushiResponse | null;
      if (!body) return null;
      // `status` is the API's own verdict; anything but Success may still carry
      // a stale number, and bidding on one is how a solver wins and cannot fill.
      if (body.status && body.status !== "Success") return null;

      const amountOut = floorNumericAmount(body.assumedAmountOut);
      if (amountOut === null) return null;

      return {
        amountOut,
        source: "sushiswap",
        // Sushi reports the route's own gas; the solver adds settlement overhead.
        ...(body.tx?.gas ? { gasUnits: BigInt(String(body.tx.gas).split(".")[0] || "0") } : {}),
        // `route` only when the quote was fetched FOR this recipient.
        ...(executable && body.tx?.to && body.tx.data
          ? {
              route: {
                to: body.tx.to as Address,
                data: body.tx.data as `0x${string}`,
                value: BigInt(body.tx.value ?? "0"),
              },
            }
          : {}),
      };
    },
  };
}

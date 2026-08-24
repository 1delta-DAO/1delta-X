import type { Address } from "viem";

import type { RouteQuote, RouteRequest, RouteSource } from "../solver";
import {
  DUMMY_CALLER,
  floorNumericAmount,
  getJson,
  isAddress,
  isRealRecipient,
  nativeAs,
  searchParams,
  type HttpSourceOptions,
} from "./http";

/**
 * Nordstern as a {@link RouteSource}.
 *
 * One endpoint, `/aggregator/{chainId}`, returning both the price and a `tx`.
 * Native is the ZERO address here, not the `0xEeee…` placeholder, and slippage
 * is a PERCENT (0.3 ⇒ 0.3) rather than a decimal — both differ from Sushi and
 * both misprice silently if crossed.
 *
 * ⚠ `toAmount` arrives as a JSON NUMBER and can carry a fractional part, so it
 * is floored rather than parsed directly — `BigInt(1234.5)` throws, and a naive
 * round could overstate what the solver will actually receive. Above 2^53 the
 * value has already lost precision upstream; see {@link floorNumericAmount}.
 */
export interface NordsternOptions extends HttpSourceOptions {
  baseUrl?: string;
}

interface NordsternResponse {
  toAmount?: number | string;
  tx?: { to?: string; data?: string; value?: number | string };
}

export function nordsternSource(opts: NordsternOptions = {}): RouteSource {
  const base = opts.baseUrl ?? "https://api.nordstern.finance";
  const slippage = opts.slippagePercent ?? 0.5;

  return {
    name: "nordstern",
    async quote(req: RouteRequest): Promise<RouteQuote | null> {
      const src = nativeAs(req.tokenIn, "zero");
      const dst = nativeAs(req.tokenOut, "zero");
      // Order-leg tokens are untrusted strings at runtime — see {isAddress}.
      if (!isAddress(src) || !isAddress(dst)) return null;
      // One endpoint here, so a price-only request still needs a `from`. The
      // dummy stands in — and the tx built against it is discarded below.
      const executable = isRealRecipient(req.recipient);
      const from = executable ? req.recipient : DUMMY_CALLER;
      const url =
        `${base}/aggregator/${req.chainId}?` +
        searchParams({ src, dst, amount: String(req.amountIn), slippage, from });

      const body = (await getJson(url, opts)) as NordsternResponse | null;
      if (!body) return null;

      const amountOut = floorNumericAmount(body.toAmount);
      if (amountOut === null) return null;

      return {
        amountOut,
        source: "nordstern",
        // `route` only when the quote was fetched FOR this recipient — calldata
        // built for DUMMY_CALLER would deliver the output to the placeholder.
        ...(executable && body.tx?.to && body.tx.data
          ? {
              route: {
                to: body.tx.to as Address,
                data: body.tx.data as `0x${string}`,
                value: BigInt(String(body.tx.value ?? "0").split(".")[0] || "0"),
              },
            }
          : {}),
      };
    },
  };
}

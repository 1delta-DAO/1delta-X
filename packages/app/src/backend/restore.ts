import { OrderSide, type Deployment, type Order } from "@1delta-x/sdk";

import { MARKETS, pinnedToken } from "../config/markets";
import type { Side } from "../lib/types";

/** Where a signed order from the book belongs in this app's UI. */
export interface RestoredRow {
  marketId: string;
  side: Side;
  /** BASE amount the order works. */
  size: number;
  /** The SIGNED limit price, quote per base — the floor (sell) or ceiling (buy). */
  price: number;
  /** The domain the order's signature is bound to. */
  deployment: Deployment;
}

export type RowResolver = (order: Order) => RestoredRow | null;

function human(wei: bigint, decimals: number): number {
  return Number(wei) / 10 ** decimals;
}

/**
 * Map a book order back to a market row — the inverse of `buildOrder` for the
 * shapes this app signs: one input leg, one output leg, both pinned tokens of
 * one configured market on a chain with a deployment. Anything else (an order
 * this app did not build) is `null` and not shown.
 *
 * SELL pays BASE: size = input; price = output floor (`end`, or `start` when
 * fixed) per base. BUY receives BASE: size = output; price = input ceiling
 * (`end` when rising, else `start`) per base.
 */
export function rowResolver(deploymentFor: (chainId: number) => Deployment | null): RowResolver {
  return (order) => {
    if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return null;
    const tin = order.legsIn[0]!;
    const tout = order.legsOut[0]!;
    for (const m of MARKETS) {
      const base = pinnedToken(m.chainId, m.base);
      const quote = pinnedToken(m.chainId, m.quote);
      if (!base || !quote) continue;
      const i = tin.token.toLowerCase();
      const o = tout.token.toLowerCase();
      let side: Side;
      if (i === base.address && o === quote.address && order.side === OrderSide.SELL) side = "sell";
      else if (i === quote.address && o === base.address && order.side === OrderSide.BUY) side = "buy";
      else continue;
      const deployment = deploymentFor(m.chainId);
      if (!deployment) continue;
      if (side === "sell") {
        const size = human(tin.start, base.decimals);
        const floor = tout.end !== 0n ? tout.end : tout.start;
        if (size <= 0) return null;
        return { marketId: m.id, side, size, price: human(floor, quote.decimals) / size, deployment };
      }
      const size = human(tout.start, base.decimals);
      const ceiling = tin.end !== 0n ? tin.end : tin.start;
      if (size <= 0) return null;
      return { marketId: m.id, side, size, price: human(ceiling, quote.decimals) / size, deployment };
    }
    return null;
  };
}

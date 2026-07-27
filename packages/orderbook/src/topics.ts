import type { Address } from "viem";

import type { OrderbookConfig } from "./config";

/**
 * Waku-style content topic `/{app}/{version}/{name}/{encoding}`. The name binds
 * the wire namespace to the EIP-712 domain (`chainId` + `settlement`), so a
 * message can never be confused across chains or deployments — a cross-chain
 * replay is rejected by both the topic AND the signature (`docs/waku-orderbook.md`).
 *
 * One order topic per `chain + settlement` is the sweet spot; fillers filter by
 * token pair locally rather than sharding the mesh.
 */
export function orderTopic(chainId: number, settlement: Address): string {
  return `/1delta/1/orders-${chainId}-${settlement.toLowerCase()}/proto`;
}

/** Soft-cancel topic, paired 1:1 with {@link orderTopic}. */
export function cancelTopic(chainId: number, settlement: Address): string {
  return `/1delta/1/cancels-${chainId}-${settlement.toLowerCase()}/proto`;
}

/** RFQ / exclusive-quote topic (encrypted-to-filler flow lives here). */
export function rfqTopic(chainId: number, settlement: Address): string {
  return `/1delta/1/rfq-${chainId}-${settlement.toLowerCase()}/proto`;
}

/** The two topics a `Book` subscribes to for a given deployment. */
export function topicsFor(cfg: Pick<OrderbookConfig, "chainId" | "settlement">): { orders: string; cancels: string } {
  return { orders: orderTopic(cfg.chainId, cfg.settlement), cancels: cancelTopic(cfg.chainId, cfg.settlement) };
}

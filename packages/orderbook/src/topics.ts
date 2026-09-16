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

/**
 * Cancel-and-replace topic. Its own topic, not a second frame kind on the order
 * topic: a `Book` subscribes the order topic to the ANNOUNCE decoder only, so a
 * replace published there was decoded as a garbage announce and dropped by every
 * transport-fed node — only the REST `/replaces` route ever reached
 * `ingestReplace` (F29 P6).
 */
export function replaceTopic(chainId: number, settlement: Address): string {
  return `/1delta/1/replaces-${chainId}-${settlement.toLowerCase()}/proto`;
}

/** RFQ / exclusive-quote topic (encrypted-to-filler flow lives here). */
export function rfqTopic(chainId: number, settlement: Address): string {
  return `/1delta/1/rfq-${chainId}-${settlement.toLowerCase()}/proto`;
}

/** The three topics a `Book` subscribes to for a given deployment. */
export function topicsFor(cfg: Pick<OrderbookConfig, "chainId" | "settlement">): {
  orders: string;
  cancels: string;
  replaces: string;
} {
  return {
    orders: orderTopic(cfg.chainId, cfg.settlement),
    cancels: cancelTopic(cfg.chainId, cfg.settlement),
    replaces: replaceTopic(cfg.chainId, cfg.settlement),
  };
}

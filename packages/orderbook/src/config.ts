import type { Deployment } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

/**
 * Everything the orderbook needs to verify and serve a deployment. A superset of
 * the SDK's {@link Deployment} (which locates the two EIP-712 verifying
 * contracts) plus the read-only {@link SettlementLens} address — the single view
 * contract whose `getOrderRelevantStates` powers the entire Layer-2 pipeline — an
 * RPC to read it, and the filler previewed in that call.
 */
export interface OrderbookConfig {
  chainId: number;
  settlement: Address;
  permit3: Address;
  /** Read-only preflight companion; `getOrderRelevantStates` is Layer 2. */
  lens: Address;
  /** JSON-RPC endpoint for the Layer-2 lens reads. */
  rpcUrl: string;
  /**
   * Filler address the lens previews validators for (filler-conditional orders
   * — e.g. per-order solver whitelists — verify against this). Defaults to the
   * zero address (an open/permissionless filler).
   */
  defaultFiller?: Address;
}

/** Narrow an {@link OrderbookConfig} to the SDK {@link Deployment} for signing/verifying. */
export function toDeployment(cfg: OrderbookConfig): Deployment {
  return { chainId: cfg.chainId, settlement: cfg.settlement, permit3: cfg.permit3 };
}

/** The filler the lens previews for — `defaultFiller` or the open zero address. */
export function fillerOf(cfg: OrderbookConfig): Address {
  return cfg.defaultFiller ?? zeroAddress;
}

export const ROOTSTOCK_TESTNET_CHAIN_ID = 31;
export const ROOTSTOCK_TESTNET_RPC = "https://public-node.testnet.rsk.co";

/**
 * Rootstock-testnet (chainId 31) preset — the first target in the design note.
 * Supply the three deployed addresses; RPC and filler take sensible defaults.
 */
export function rootstockTestnetConfig(addrs: {
  settlement: Address;
  permit3: Address;
  lens: Address;
  rpcUrl?: string;
  defaultFiller?: Address;
}): OrderbookConfig {
  return {
    chainId: ROOTSTOCK_TESTNET_CHAIN_ID,
    settlement: addrs.settlement,
    permit3: addrs.permit3,
    lens: addrs.lens,
    rpcUrl: addrs.rpcUrl ?? ROOTSTOCK_TESTNET_RPC,
    ...(addrs.defaultFiller ? { defaultFiller: addrs.defaultFiller } : {}),
  };
}

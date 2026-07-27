import type { OrderbookConfig } from "@1delta-x/orderbook";
export interface ServerEnv {
    config: OrderbookConfig;
    host: string;
    port: number;
}
/**
 * Config-driven deployment: the demo backend points at whichever Settlement /
 * Permit3 / SettlementLens you deployed to a testnet (contracts are deployed
 * separately — `Deploy.s.sol` is a stub). Rootstock testnet is chainId 31.
 *
 *   CHAIN_ID   e.g. 31
 *   SETTLEMENT 0x…
 *   PERMIT3    0x…
 *   LENS       0x…  (SettlementLens)
 *   RPC_URL    https://public-node.testnet.rsk.co
 *   PORT       8080          (optional)
 *   HOST       0.0.0.0       (optional)
 *   DEFAULT_FILLER 0x…       (optional — filler previewed by the lens)
 */
export declare function loadEnv(): ServerEnv;

import type { OrderbookConfig } from "@1delta-x/orderbook";
import { getAddress, isAddress, type Address } from "viem";

export interface ServerEnv {
  config: OrderbookConfig;
  host: string;
  port: number;
}

function reqStr(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`env ${name} is required`);
  return v;
}

function reqAddr(name: string): Address {
  const v = reqStr(name);
  if (!isAddress(v)) throw new Error(`env ${name} must be a valid address (got ${v})`);
  return getAddress(v);
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
export function loadEnv(): ServerEnv {
  const chainId = Number(reqStr("CHAIN_ID"));
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error(`CHAIN_ID must be a positive integer (got ${process.env.CHAIN_ID})`);

  const filler = process.env.DEFAULT_FILLER;
  if (filler && !isAddress(filler)) throw new Error(`DEFAULT_FILLER must be a valid address (got ${filler})`);

  const config: OrderbookConfig = {
    chainId,
    settlement: reqAddr("SETTLEMENT"),
    permit3: reqAddr("PERMIT3"),
    lens: reqAddr("LENS"),
    rpcUrl: reqStr("RPC_URL"),
    ...(filler ? { defaultFiller: getAddress(filler) } : {}),
  };

  return {
    config,
    host: process.env.HOST ?? "0.0.0.0",
    port: Number(process.env.PORT ?? 8080),
  };
}

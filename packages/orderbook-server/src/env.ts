import { DEFAULT_ADMISSION, type AdmissionPolicy, type OrderbookConfig } from "@1delta-x/orderbook";
import { getAddress, isAddress, type Address } from "viem";

import { DEFAULT_RATE_LIMIT, type RateLimitOptions } from "./ratelimit";

export interface ServerEnv {
  config: OrderbookConfig;
  host: string;
  port: number;
  admission: AdmissionPolicy;
  rateLimit: RateLimitOptions;
  watchChain: boolean;
  indexFills: boolean;
  fillsFromBlock?: bigint;
  ocoModules?: Address[];
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

function num(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined || v === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`env ${name} must be a non-negative number (got ${v})`);
  return n;
}

/** Booleans are explicit: an unset flag takes the default, never `false` by accident. */
function bool(name: string, fallback: boolean): boolean {
  const v = process.env[name];
  if (v === undefined || v === "") return fallback;
  return v === "1" || v.toLowerCase() === "true";
}

function addrList(name: string): Address[] | undefined {
  const v = process.env[name];
  if (!v) return undefined;
  return v.split(",").map((raw) => {
    const trimmed = raw.trim();
    if (!isAddress(trimmed)) throw new Error(`env ${name} contains an invalid address (${trimmed})`);
    return getAddress(trimmed);
  });
}

/**
 * Config-driven deployment. Everything the node needs to run against a real
 * chain, with defaults chosen for a public mainnet endpoint rather than a local
 * test: the chain watcher and the fill index are ON, because on mainnet a book
 * that only learns about cancellations from its own polling sweep serves dead
 * orders to solvers who pay gas to discover it.
 *
 * Required
 *   CHAIN_ID              e.g. 1
 *   SETTLEMENT            0x…
 *   PERMIT3               0x…
 *   LENS                  0x…  (SettlementLens)
 *   RPC_URL               https://…
 *
 * Serving
 *   PORT                  8080
 *   HOST                  0.0.0.0
 *   DEFAULT_FILLER        0x…   filler the lens previews validators for
 *   OCO_MODULES           0x…,0x…  OcoGroupModule deployments to watch
 *
 * Chain following
 *   WATCH_CHAIN           true  — evict on Settlement logs, not on a timer
 *   INDEX_FILLS           true  — index OrderFilled so /fills can answer
 *   FILLS_FROM_BLOCK      block to backfill fills from (default: a lookback window)
 *
 * Admission (what the book will hold at all)
 *   MAX_ORDERS            25000
 *   MAX_ORDERS_PER_MAKER  500
 *   MIN_TTL_SECONDS       15
 *   MAX_TTL_SECONDS       7776000 (90d)
 *
 * Rate limiting (token buckets; writes cost 10, reads 1–2)
 *   RATE_LIMIT_IP_CAPACITY      120
 *   RATE_LIMIT_IP_REFILL        1     tokens per second
 *   RATE_LIMIT_MAKER_CAPACITY   120
 *   RATE_LIMIT_MAKER_REFILL     1
 *   MAX_BODY_BYTES              65536
 *   TRUST_PROXY                 false — set only behind a proxy that sets
 *                                       x-forwarded-for, or the header becomes
 *                                       a free way to reset your own bucket
 */
export function loadEnv(): ServerEnv {
  const chainId = Number(reqStr("CHAIN_ID"));
  if (!Number.isInteger(chainId) || chainId <= 0) {
    throw new Error(`CHAIN_ID must be a positive integer (got ${process.env.CHAIN_ID})`);
  }

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

  const admission: AdmissionPolicy = {
    maxOrders: num("MAX_ORDERS", DEFAULT_ADMISSION.maxOrders),
    maxOrdersPerMaker: num("MAX_ORDERS_PER_MAKER", DEFAULT_ADMISSION.maxOrdersPerMaker),
    maxLegsIn: num("MAX_LEGS_IN", DEFAULT_ADMISSION.maxLegsIn),
    maxLegsOut: num("MAX_LEGS_OUT", DEFAULT_ADMISSION.maxLegsOut),
    maxItems: num("MAX_ITEMS", DEFAULT_ADMISSION.maxItems),
    maxValidators: num("MAX_VALIDATORS", DEFAULT_ADMISSION.maxValidators),
    minTtlSeconds: num("MIN_TTL_SECONDS", DEFAULT_ADMISSION.minTtlSeconds),
    maxTtlSeconds: num("MAX_TTL_SECONDS", DEFAULT_ADMISSION.maxTtlSeconds),
  };

  const rateLimit: RateLimitOptions = {
    ip: {
      capacity: num("RATE_LIMIT_IP_CAPACITY", DEFAULT_RATE_LIMIT.ip.capacity),
      refillPerSecond: num("RATE_LIMIT_IP_REFILL", DEFAULT_RATE_LIMIT.ip.refillPerSecond),
    },
    maker: {
      capacity: num("RATE_LIMIT_MAKER_CAPACITY", DEFAULT_RATE_LIMIT.maker.capacity),
      refillPerSecond: num("RATE_LIMIT_MAKER_REFILL", DEFAULT_RATE_LIMIT.maker.refillPerSecond),
    },
    maxBodyBytes: num("MAX_BODY_BYTES", DEFAULT_RATE_LIMIT.maxBodyBytes),
    idleEvictionMs: num("RATE_LIMIT_IDLE_MS", DEFAULT_RATE_LIMIT.idleEvictionMs),
    trustProxy: bool("TRUST_PROXY", DEFAULT_RATE_LIMIT.trustProxy),
  };

  const fillsFrom = process.env.FILLS_FROM_BLOCK;
  const oco = addrList("OCO_MODULES");

  return {
    config,
    host: process.env.HOST ?? "0.0.0.0",
    port: num("PORT", 8080),
    admission,
    rateLimit,
    watchChain: bool("WATCH_CHAIN", true),
    indexFills: bool("INDEX_FILLS", true),
    ...(fillsFrom ? { fillsFromBlock: BigInt(fillsFrom) } : {}),
    ...(oco ? { ocoModules: oco } : {}),
  };
}

import { DEFAULT_ADMISSION, type AdmissionPolicy, type OrderbookConfig } from "@1delta-x/orderbook";
import { getAddress, isAddress, type Address } from "viem";

import { DEFAULT_RATE_LIMIT, type RateLimitOptions } from "./ratelimit";
import { DEFAULT_STREAM_LIMITS, type StreamLimits } from "./server";

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
  stream: Partial<StreamLimits>;
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
  return v.split(",").filter((raw) => raw.trim() !== "").map((raw) => {
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
 *   MAX_ORDERS_PER_MAKER  100
 *   MIN_TTL_SECONDS       15
 *   MAX_TTL_SECONDS       7776000 (90d)
 *   MAX_CURVE_POINTS      32
 *   MAX_ORDER_BYTES       16384
 *   ALLOWED_TOKENS        0x…,0x…  only these leg tokens (unset: any) — set it
 *                                  whenever the book serves a known market set
 *
 * Stream (WebSocket /stream)
 *   WS_MAX_CONNECTIONS    1000
 *   WS_MAX_PER_IP         16
 *   WS_ALLOWED_ORIGINS    https://app.example,…  browser Origins allowed (unset: any)
 *   WS_SNAPSHOT_LIMIT     1000  orders in the connect snapshot
 *
 * Rate limiting (token buckets; writes cost 10, reads 1–2)
 *   RATE_LIMIT_IP_CAPACITY      120
 *   RATE_LIMIT_IP_REFILL        1     tokens per second
 *   RATE_LIMIT_MAKER_CAPACITY   120
 *   RATE_LIMIT_MAKER_REFILL     1
 *   MAX_BODY_BYTES              65536
 *   RATE_LIMIT_MAX_KEYS         100000 buckets per map (LRU past it)
 *   TRUST_PROXY                 false — set only behind a proxy that sets
 *                                       x-forwarded-for, or the header becomes
 *                                       a free way to reset your own bucket
 *   TRUSTED_PROXY_HOPS          1     — your proxies in front of the node; the
 *                                       client is read that far from the RIGHT
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

  const allowedTokens = addrList("ALLOWED_TOKENS");
  const admission: AdmissionPolicy = {
    maxOrders: num("MAX_ORDERS", DEFAULT_ADMISSION.maxOrders),
    maxOrdersPerMaker: num("MAX_ORDERS_PER_MAKER", DEFAULT_ADMISSION.maxOrdersPerMaker),
    maxLegsIn: num("MAX_LEGS_IN", DEFAULT_ADMISSION.maxLegsIn),
    maxLegsOut: num("MAX_LEGS_OUT", DEFAULT_ADMISSION.maxLegsOut),
    maxItems: num("MAX_ITEMS", DEFAULT_ADMISSION.maxItems),
    maxValidators: num("MAX_VALIDATORS", DEFAULT_ADMISSION.maxValidators),
    minTtlSeconds: num("MIN_TTL_SECONDS", DEFAULT_ADMISSION.minTtlSeconds),
    maxTtlSeconds: num("MAX_TTL_SECONDS", DEFAULT_ADMISSION.maxTtlSeconds),
    maxCurvePoints: num("MAX_CURVE_POINTS", DEFAULT_ADMISSION.maxCurvePoints),
    maxOrderBytes: num("MAX_ORDER_BYTES", DEFAULT_ADMISSION.maxOrderBytes),
    ...(allowedTokens ? { allowedTokens } : {}),
    requireDeltaVerifyOutputs: bool("REQUIRE_DELTA_VERIFY", DEFAULT_ADMISSION.requireDeltaVerifyOutputs),
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
    maxKeys: num("RATE_LIMIT_MAX_KEYS", DEFAULT_RATE_LIMIT.maxKeys),
    trustProxy: bool("TRUST_PROXY", DEFAULT_RATE_LIMIT.trustProxy),
    trustedHops: num("TRUSTED_PROXY_HOPS", DEFAULT_RATE_LIMIT.trustedHops),
  };

  const fillsFrom = process.env.FILLS_FROM_BLOCK;
  const oco = addrList("OCO_MODULES");

  return {
    config,
    host: process.env.HOST ?? "0.0.0.0",
    port: num("PORT", 8080),
    admission,
    rateLimit,
    stream: {
      maxConnections: num("WS_MAX_CONNECTIONS", DEFAULT_STREAM_LIMITS.maxConnections),
      maxPerIp: num("WS_MAX_PER_IP", DEFAULT_STREAM_LIMITS.maxPerIp),
      snapshotLimit: num("WS_SNAPSHOT_LIMIT", DEFAULT_STREAM_LIMITS.snapshotLimit),
      ...(process.env.WS_ALLOWED_ORIGINS
        ? { allowedOrigins: process.env.WS_ALLOWED_ORIGINS.split(",").map((o) => o.trim()).filter(Boolean) }
        : {}),
    },
    watchChain: bool("WATCH_CHAIN", true),
    indexFills: bool("INDEX_FILLS", true),
    ...(fillsFrom ? { fillsFromBlock: BigInt(fillsFrom) } : {}),
    ...(oco ? { ocoModules: oco } : {}),
  };
}

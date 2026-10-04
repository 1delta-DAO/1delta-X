import { DEFAULT_ADMISSION, type AdmissionPolicy, type OrderbookConfig } from "@1delta-x/orderbook/pure";
import { isAddress, zeroAddress, type Address } from "viem";

/**
 * The worker's bindings. Every knob is a `[vars]` string (see `wrangler.toml`);
 * `BINDING_KEY` is a secret (`wrangler secret put BINDING_KEY`).
 */
export interface Env {
  BOOK: DurableObjectNamespace;
  CHAIN_ID: string;
  SETTLEMENT: string;
  PERMIT3: string;
  LENS: string;
  RPC_URL: string;
  DEFAULT_FILLER?: string;
  OCO_MODULES?: string;
  ALLOWED_TOKENS?: string;
  MAX_ORDERS?: string;
  MAX_ORDERS_PER_MAKER?: string;
  MAX_CURVE_POINTS?: string;
  MAX_ORDER_JSON_BYTES?: string;
  MIN_TTL_SECONDS?: string;
  MAX_TTL_SECONDS?: string;
  REQUIRE_DELTA_VERIFY?: string;
  MAX_BODY_BYTES?: string;
  RATE_LIMIT_IP_CAPACITY?: string;
  RATE_LIMIT_IP_REFILL?: string;
  RATE_LIMIT_MAKER_CAPACITY?: string;
  RATE_LIMIT_MAKER_REFILL?: string;
  RATE_LIMIT_MAX_KEYS?: string;
  ALARM_INTERVAL_SECONDS?: string;
  MAX_LOG_RANGE?: string;
  CONFIRMATIONS?: string;
  START_BLOCK?: string;
  INITIAL_LOOKBACK_BLOCKS?: string;
  REVALIDATE_SECONDS?: string;
  MAX_RECHECK_PER_ALARM?: string;
  TOMBSTONE_TTL_SECONDS?: string;
  MAX_TOMBSTONES?: string;
  MAX_FILLS?: string;
  /** Shared secret proving a request came through the app's service binding. */
  BINDING_KEY?: string;
}

export interface WorkerConfig {
  chain: OrderbookConfig;
  /** False while SETTLEMENT / PERMIT3 / LENS are still placeholders: writes 503, the alarm skips chain work. */
  configured: boolean;
  ocoModules: Address[];
  admission: AdmissionPolicy;
  /** Raw JSON body cap for POST /orders and /cancels. */
  maxBodyBytes: number;
  rate: {
    ip: { capacity: number; refillPerSecond: number };
    maker: { capacity: number; refillPerSecond: number };
    maxKeys: number;
    idleSeconds: number;
  };
  alarmIntervalMs: number;
  /** Blocks scanned per alarm, at most. */
  maxLogRange: bigint;
  /** Blocks behind head the log cursor stays, so a scanned range is not reorged out from under it. */
  confirmations: bigint;
  startBlock?: bigint;
  initialLookback: bigint;
  /** A live order is re-checked on the lens at least this often. */
  revalidateSeconds: number;
  /** Lens re-checks per alarm (dirty orders first, then the stalest). */
  maxRecheckPerAlarm: number;
  tombstoneTtlSeconds: number;
  maxTombstones: number;
  maxFills: number;
  /** Soft-cancel tombstones: total cap and pending-per-maker cap (same defaults as the Book). */
  maxSoftCancels: number;
  maxPendingSoftCancelsPerMaker: number;
  /** Bills remembered (an order/cancel is billed to its maker once). */
  maxBilled: number;
}

function num(v: string | undefined, fallback: number, name: string): number {
  if (v === undefined || v.trim() === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative number`);
  return n;
}

function big(v: string | undefined, fallback: bigint, name: string): bigint {
  if (v === undefined || v.trim() === "") return fallback;
  if (!/^\d+$/.test(v.trim())) throw new Error(`${name} must be a non-negative integer`);
  return BigInt(v.trim());
}

function addr(v: string | undefined, name: string): Address {
  const s = (v ?? "").trim();
  if (!s) return zeroAddress;
  if (!isAddress(s, { strict: false })) throw new Error(`${name} is not an address`);
  return s.toLowerCase() as Address;
}

function addrList(v: string | undefined, name: string): Address[] {
  return (v ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => addr(s, name));
}

export function loadConfig(env: Env): WorkerConfig {
  const chainId = num(env.CHAIN_ID, NaN, "CHAIN_ID");
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error("CHAIN_ID must be a positive integer");
  const settlement = addr(env.SETTLEMENT, "SETTLEMENT");
  const permit3 = addr(env.PERMIT3, "PERMIT3");
  const lens = addr(env.LENS, "LENS");
  const defaultFiller = env.DEFAULT_FILLER ? addr(env.DEFAULT_FILLER, "DEFAULT_FILLER") : undefined;
  const allowed = addrList(env.ALLOWED_TOKENS, "ALLOWED_TOKENS");
  const configured = settlement !== zeroAddress && permit3 !== zeroAddress && lens !== zeroAddress && !!env.RPC_URL;

  const admission: AdmissionPolicy = {
    ...DEFAULT_ADMISSION,
    maxOrders: num(env.MAX_ORDERS, 5_000, "MAX_ORDERS"),
    maxOrdersPerMaker: num(env.MAX_ORDERS_PER_MAKER, DEFAULT_ADMISSION.maxOrdersPerMaker, "MAX_ORDERS_PER_MAKER"),
    maxCurvePoints: num(env.MAX_CURVE_POINTS, DEFAULT_ADMISSION.maxCurvePoints, "MAX_CURVE_POINTS"),
    // Measured on the canonical JSON announce, not protobuf (the worker has no
    // protobuf). JSON spells bytes as hex plus field names, so the default is 2×.
    maxOrderBytes: num(env.MAX_ORDER_JSON_BYTES, 2 * DEFAULT_ADMISSION.maxOrderBytes, "MAX_ORDER_JSON_BYTES"),
    minTtlSeconds: num(env.MIN_TTL_SECONDS, DEFAULT_ADMISSION.minTtlSeconds, "MIN_TTL_SECONDS"),
    maxTtlSeconds: num(env.MAX_TTL_SECONDS, DEFAULT_ADMISSION.maxTtlSeconds, "MAX_TTL_SECONDS"),
    requireDeltaVerifyOutputs: (env.REQUIRE_DELTA_VERIFY ?? "").trim().toLowerCase() === "true",
    ...(allowed.length ? { allowedTokens: allowed } : {}),
  };

  return {
    chain: { chainId, settlement, permit3, lens, rpcUrl: env.RPC_URL ?? "", ...(defaultFiller ? { defaultFiller } : {}) },
    configured,
    ocoModules: addrList(env.OCO_MODULES, "OCO_MODULES"),
    admission,
    maxBodyBytes: num(env.MAX_BODY_BYTES, 256 * 1024, "MAX_BODY_BYTES"),
    rate: {
      ip: {
        capacity: num(env.RATE_LIMIT_IP_CAPACITY, 120, "RATE_LIMIT_IP_CAPACITY"),
        refillPerSecond: num(env.RATE_LIMIT_IP_REFILL, 1, "RATE_LIMIT_IP_REFILL"),
      },
      maker: {
        capacity: num(env.RATE_LIMIT_MAKER_CAPACITY, 120, "RATE_LIMIT_MAKER_CAPACITY"),
        refillPerSecond: num(env.RATE_LIMIT_MAKER_REFILL, 1, "RATE_LIMIT_MAKER_REFILL"),
      },
      maxKeys: num(env.RATE_LIMIT_MAX_KEYS, 100_000, "RATE_LIMIT_MAX_KEYS"),
      idleSeconds: 600,
    },
    alarmIntervalMs: 1000 * num(env.ALARM_INTERVAL_SECONDS, 20, "ALARM_INTERVAL_SECONDS"),
    maxLogRange: big(env.MAX_LOG_RANGE, 2_000n, "MAX_LOG_RANGE"),
    confirmations: big(env.CONFIRMATIONS, 2n, "CONFIRMATIONS"),
    ...(env.START_BLOCK && env.START_BLOCK.trim() ? { startBlock: big(env.START_BLOCK, 0n, "START_BLOCK") } : {}),
    initialLookback: big(env.INITIAL_LOOKBACK_BLOCKS, 2_880n, "INITIAL_LOOKBACK_BLOCKS"),
    revalidateSeconds: num(env.REVALIDATE_SECONDS, 60, "REVALIDATE_SECONDS"),
    maxRecheckPerAlarm: num(env.MAX_RECHECK_PER_ALARM, 500, "MAX_RECHECK_PER_ALARM"),
    tombstoneTtlSeconds: num(env.TOMBSTONE_TTL_SECONDS, 14 * 24 * 3600, "TOMBSTONE_TTL_SECONDS"),
    maxTombstones: num(env.MAX_TOMBSTONES, 20_000, "MAX_TOMBSTONES"),
    maxFills: num(env.MAX_FILLS, 50_000, "MAX_FILLS"),
    maxSoftCancels: 100_000,
    maxPendingSoftCancelsPerMaker: 1_024,
    maxBilled: 100_000,
  };
}

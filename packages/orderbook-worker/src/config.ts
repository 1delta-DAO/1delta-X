import { DEFAULT_ADMISSION, type AdmissionPolicy, type OrderbookConfig } from "@1delta-x/orderbook/pure";
import { isAddress, zeroAddress, type Address } from "viem";

/**
 * The worker's bindings. Every knob is a `[vars]` string (see `wrangler.toml`);
 * `BINDING_KEY` and `RPC_URL_SECRET` are secrets (`wrangler secret put …`).
 */
export interface Env {
  BOOK: DurableObjectNamespace;
  CHAIN_ID: string;
  SETTLEMENT: string;
  PERMIT3: string;
  LENS: string;
  RPC_URL: string;
  /**
   * A keyed RPC endpoint (secret), read IN PREFERENCE to the `RPC_URL` var — a var
   * and a secret cannot share a name, so the secret has its own and the var line can
   * stay. It must serve `eth_getLogs`: Rootstock's public node does not.
   */
  RPC_URL_SECRET?: string;
  /**
   * Further RPC endpoints tried in order when the primary errors, times out or rate-limits
   * (comma-separated). 2026-10-13: the 1delta gateway answered 429 under the filler's load
   * and every POST /orders failed "verification unavailable".
   */
  RPC_FALLBACK_URLS?: string;
  /** Keyed fallback endpoint(s), a secret: tried before RPC_FALLBACK_URLS. */
  RPC_FALLBACK_URLS_SECRET?: string;
  RPC_MULTICALL?: string;
  /** Optional Durable Object location hint (`wnam`, `enam`, `weur`, …); only affects object CREATION. */
  DO_LOCATION_HINT?: string;
  DEFAULT_FILLER?: string;
  OCO_MODULES?: string;
  ALLOWED_TOKENS?: string;
  /**
   * The `NativeBalance` view (task 30), or unset/"" = none: an order receiving the RAW
   * native coin names it as its DIRECT output token. Added to ALLOWED_TOKENS (when that
   * list is set) and policed at admission: never an input leg, never a pull output.
   */
  NATIVE_BALANCE?: string;
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
  ALARM_BUDGET_SECONDS?: string;
  /** Shared secret proving a request came through the app's service binding. */
  BINDING_KEY?: string;
  /**
   * The prize draw (src/raffle.ts). `RAFFLE_ID` unset/"" = no draw: every `/raffle`
   * route answers `live: false` / 404. `RAFFLE_TERMS_HASH` is keccak256 of the TC.md
   * the app ships (`pnpm --filter @1delta-x/app terms-hash`); entries naming another
   * version are refused. `RAFFLE_STARTS_AT` / `RAFFLE_ENDS_AT` are unix seconds: a
   * fill counts from the start, entries close at the end.
   */
  RAFFLE_ID?: string;
  RAFFLE_TERMS_HASH?: string;
  RAFFLE_STARTS_AT?: string;
  RAFFLE_ENDS_AT?: string;
  /** Secret: `authorization: Bearer …` for `GET /raffle/export` and `POST /raffle/purge-contacts`. */
  RAFFLE_ADMIN_TOKEN?: string;
}

/**
 * The running prize draw. From `RAFFLE_*` (the deploy-time default), or — when an
 * admin saved one — from the Durable Object (`PUT /raffle/admin/config`), which wins.
 */
export interface RaffleConfig {
  id: string;
  terms: `0x${string}`;
  /** Unix seconds; 0 = open since forever. */
  startsAt: number;
  /** Unix seconds; entries close here. */
  endsAt: number;
  /** The daily qualifier the draw tool uses, USD (display / tooling only; the desk does not price). */
  qualifierUsd: number;
  /** Addresses the draw tool never lists (team, ambassadors, fillers) — lower-case. */
  exclude: string[];
  /**
   * THE DRAW RULES (2026-10-21), published on `GET /raffle` so the app notice and the
   * draw tool read one source. Draw periods of `periodDays` UTC days, counted from the
   * UTC midnight of `startsAt`; each UTC day an address reaches `qualifierUsd` is one
   * ticket in that period's draw. A period with fewer than `minQualifiers` qualifying
   * addresses is not drawn: its prizes are carried forward to the next one. `prizes` is
   * one amount per winner, in `prizeToken`. With `onePrizePerAddress`, an earlier
   * winner's tickets count only once every other qualifier of the period has won.
   */
  periodDays: number;
  minQualifiers: number;
  prizes: number[];
  prizeToken: string;
  onePrizePerAddress: boolean;
  /**
   * TEST MODE when non-empty: the desk is live ONLY for these addresses (lower-case);
   * everyone else sees `live: false` and no notice, so a draw can be rehearsed on the
   * production book before it is announced.
   */
  testers: string[];
}

const ADDR_RE = /^0x[0-9a-f]{40}$/;

function addrArray(v: unknown, name: string): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new Error(`${name} must be a list of addresses`);
  const out = v.map((a) => (typeof a === "string" ? a.trim().toLowerCase() : ""));
  for (const a of out) if (!ADDR_RE.test(a)) throw new Error(`${name}: "${a}" is not an address`);
  if (out.length > 1000) throw new Error(`${name}: at most 1000 addresses`);
  return [...new Set(out)];
}

/** Validate a raffle config from JSON (the operator console). Throws a readable message. */
export function parseRaffleConfig(raw: unknown): RaffleConfig {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new Error("config must be an object");
  const r = raw as Record<string, unknown>;
  const known = ["id", "terms", "startsAt", "endsAt", "qualifierUsd", "exclude", "testers", "periodDays", "minQualifiers", "prizes", "prizeToken", "onePrizePerAddress"];
  for (const k of Object.keys(r)) if (!known.includes(k)) throw new Error(`unknown field "${k}"`);
  const id = typeof r.id === "string" ? r.id.trim() : "";
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(id)) throw new Error("id must be lower-case letters, digits and dashes (≤ 64)");
  const terms = typeof r.terms === "string" ? r.terms.trim().toLowerCase() : "";
  if (!/^0x[0-9a-f]{64}$/.test(terms)) throw new Error("terms must be a 32-byte hex hash (keccak256 of TC.md)");
  const int = (v: unknown, fallback: number, name: string) => {
    if (v === undefined || v === null || v === "") return fallback;
    const n = Number(v);
    if (!Number.isSafeInteger(n) || n < 0) throw new Error(`${name} must be unix seconds`);
    return n;
  };
  const startsAt = int(r.startsAt, 0, "startsAt");
  const endsAt = int(r.endsAt, Number.MAX_SAFE_INTEGER, "endsAt");
  if (endsAt <= startsAt) throw new Error("endsAt must be after startsAt");
  const q = r.qualifierUsd === undefined ? 20 : Number(r.qualifierUsd);
  if (!Number.isFinite(q) || q < 0) throw new Error("qualifierUsd must be a non-negative number");
  const periodDays = r.periodDays === undefined ? DEFAULT_RULES.periodDays : Number(r.periodDays);
  if (!Number.isInteger(periodDays) || periodDays < 1 || periodDays > 31) throw new Error("periodDays must be a whole number of days, 1 to 31");
  const minQualifiers = r.minQualifiers === undefined ? DEFAULT_RULES.minQualifiers : Number(r.minQualifiers);
  if (!Number.isInteger(minQualifiers) || minQualifiers < 1 || minQualifiers > 1000) throw new Error("minQualifiers must be a whole number, 1 to 1000");
  let prizes = [...DEFAULT_RULES.prizes];
  if (r.prizes !== undefined) {
    if (!Array.isArray(r.prizes) || r.prizes.length === 0 || r.prizes.length > 20) throw new Error("prizes must be a list of 1 to 20 amounts");
    prizes = r.prizes.map((x) => Number(x));
    if (prizes.some((x) => !Number.isFinite(x) || x <= 0)) throw new Error("every prize must be a positive amount");
  }
  const prizeToken = r.prizeToken === undefined ? DEFAULT_RULES.prizeToken : typeof r.prizeToken === "string" ? r.prizeToken.trim() : "";
  if (!/^[A-Za-z0-9₮$.-]{1,16}$/.test(prizeToken)) throw new Error("prizeToken must be a short token symbol");
  const onePrizePerAddress = r.onePrizePerAddress === undefined ? DEFAULT_RULES.onePrizePerAddress : r.onePrizePerAddress === true;
  return {
    id,
    terms: terms as `0x${string}`,
    startsAt,
    endsAt,
    qualifierUsd: q,
    exclude: addrArray(r.exclude, "exclude"),
    testers: addrArray(r.testers, "testers"),
    periodDays,
    minQualifiers,
    prizes,
    prizeToken,
    onePrizePerAddress,
  };
}

/** The rules a draw starts from (2026-10-21: 3-day periods, 25 USDRIF to one winner, at least 3 qualifiers). */
export const DEFAULT_RULES: Pick<RaffleConfig, "periodDays" | "minQualifiers" | "prizes" | "prizeToken" | "onePrizePerAddress"> = {
  periodDays: 3,
  minQualifiers: 3,
  prizes: [25],
  prizeToken: "USDRIF",
  onePrizePerAddress: true,
};

export interface WorkerConfig {
  chain: OrderbookConfig;
  /** Backup RPC endpoints, in order (RPC_FALLBACK_URLS). */
  rpcFallbackUrls: string[];
  /** Merge concurrent eth_call reads into Multicall3 (RPC_MULTICALL=1). */
  rpcMulticall: boolean;
  /** Which binding `chain.rpcUrl` came from (status only; the URL itself is never echoed). */
  rpcSource: "RPC_URL_SECRET" | "RPC_URL" | "none";
  /** False while SETTLEMENT / PERMIT3 / LENS are still placeholders: writes 503, the alarm skips chain work. */
  configured: boolean;
  ocoModules: Address[];
  /** NATIVE_BALANCE (lower-case), when configured — see {@link Env.NATIVE_BALANCE}. */
  nativeBalance?: Address;
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
  /**
   * The re-check cadence while the RPC does not serve `eth_getLogs`: fills and
   * cancels then reach the book ONLY through the lens re-check, so it falls back to
   * this (≤ `revalidateSeconds`) automatically.
   */
  revalidateNoLogsSeconds: number;
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
  /**
   * Wall-clock budget of one maintenance pass, ms. Past it the pass stops sizing
   * fills (the log cursor stops at the first log it did not apply) and starts no
   * lens re-check; the next alarm continues 1 s later. With the 8 s RPC timeout it
   * keeps an alarm far inside Cloudflare's 15-minute alarm wall-clock limit.
   */
  alarmBudgetMs: number;
  /** Bounds of one lens re-check sweep (the library Verifier's bisection). */
  verifier: { maxRecheckCalls: number; maxSweepMs: number };
  /** The prize draw, or absent when none is configured. */
  raffle?: RaffleConfig;
}

/** Re-check cadence when the RPC serves no `eth_getLogs` (see {@link WorkerConfig.revalidateNoLogsSeconds}). */
export const REVALIDATE_NO_LOGS_SECONDS = 60;
/** viem HTTP transport timeout for every orderbook RPC call, ms. */
export const RPC_TIMEOUT_MS = 8_000;

/** The RPC endpoint: the `RPC_URL_SECRET` secret if set, else the `RPC_URL` var. */
export function rpcUrlOf(env: Pick<Env, "RPC_URL" | "RPC_URL_SECRET">): { url: string; source: WorkerConfig["rpcSource"] } {
  const secret = (env.RPC_URL_SECRET ?? "").trim();
  if (secret) return { url: secret, source: "RPC_URL_SECRET" };
  const plain = (env.RPC_URL ?? "").trim();
  return plain ? { url: plain, source: "RPC_URL" } : { url: "", source: "none" };
}

/** Durable Object location hints Cloudflare accepts (https://developers.cloudflare.com/durable-objects/reference/data-location/). */
const LOCATION_HINTS = new Set(["wnam", "enam", "sam", "weur", "eeur", "apac", "apac-ne", "apac-se", "oc", "afr", "me"]);

/**
 * `DO_LOCATION_HINT`, validated: a hint only matters when the object is first
 * CREATED (an existing object never moves), and an unknown one would make `get()`
 * throw on every request — so anything not on Cloudflare's list is ignored.
 */
export function locationHint(env: { DO_LOCATION_HINT?: string }): DurableObjectLocationHint | undefined {
  const h = (env.DO_LOCATION_HINT ?? "").trim().toLowerCase();
  return LOCATION_HINTS.has(h) ? (h as DurableObjectLocationHint) : undefined;
}

/** `MAX_BODY_BYTES` for the entry worker's body buffering (same parse as {@link loadConfig}). */
export function maxBodyBytesOf(env: Pick<Env, "MAX_BODY_BYTES">): number {
  return num(env.MAX_BODY_BYTES, 256 * 1024, "MAX_BODY_BYTES");
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

/** `RAFFLE_*`, validated; undefined when no draw is configured. */
export function raffleConfigOf(env: Pick<Env, "RAFFLE_ID" | "RAFFLE_TERMS_HASH" | "RAFFLE_STARTS_AT" | "RAFFLE_ENDS_AT">): RaffleConfig | undefined {
  const id = (env.RAFFLE_ID ?? "").trim();
  if (!id) return undefined;
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(id)) throw new Error("RAFFLE_ID must be lower-case letters, digits and dashes (≤ 64)");
  const terms = (env.RAFFLE_TERMS_HASH ?? "").trim().toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(terms)) throw new Error("RAFFLE_TERMS_HASH must be a 32-byte hex hash (keccak256 of TC.md)");
  const startsAt = num(env.RAFFLE_STARTS_AT, 0, "RAFFLE_STARTS_AT");
  const endsAt = num(env.RAFFLE_ENDS_AT, Number.MAX_SAFE_INTEGER, "RAFFLE_ENDS_AT");
  if (endsAt <= startsAt) throw new Error("RAFFLE_ENDS_AT must be after RAFFLE_STARTS_AT");
  return { id, terms: terms as `0x${string}`, startsAt, endsAt, qualifierUsd: 20, exclude: [], testers: [], ...DEFAULT_RULES, prizes: [...DEFAULT_RULES.prizes] };
}

export function loadConfig(env: Env): WorkerConfig {
  const chainId = num(env.CHAIN_ID, NaN, "CHAIN_ID");
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error("CHAIN_ID must be a positive integer");
  const settlement = addr(env.SETTLEMENT, "SETTLEMENT");
  const permit3 = addr(env.PERMIT3, "PERMIT3");
  const lens = addr(env.LENS, "LENS");
  const defaultFiller = env.DEFAULT_FILLER ? addr(env.DEFAULT_FILLER, "DEFAULT_FILLER") : undefined;
  const nativeBalance = addr(env.NATIVE_BALANCE, "NATIVE_BALANCE");
  // The view is a listed token wherever the book names its tokens: it is how a native
  // receipt is signed. (Unlisted, an allowlisted book would refuse every such order.)
  const allowed = [...addrList(env.ALLOWED_TOKENS, "ALLOWED_TOKENS")];
  if (allowed.length && nativeBalance !== zeroAddress && !allowed.includes(nativeBalance)) allowed.push(nativeBalance);
  const rpc = rpcUrlOf(env);
  const raffle = raffleConfigOf(env);
  const configured = settlement !== zeroAddress && permit3 !== zeroAddress && lens !== zeroAddress && !!rpc.url;

  const admission: AdmissionPolicy = {
    ...DEFAULT_ADMISSION,
    // 1000 = the beta filler's intake window (INTAKE_MAX_PAGES 2 × INTAKE_PAGE_SIZE 500):
    // every order this book holds is one the filler can see.
    maxOrders: num(env.MAX_ORDERS, 1_000, "MAX_ORDERS"),
    maxOrdersPerMaker: num(env.MAX_ORDERS_PER_MAKER, DEFAULT_ADMISSION.maxOrdersPerMaker, "MAX_ORDERS_PER_MAKER"),
    maxCurvePoints: num(env.MAX_CURVE_POINTS, DEFAULT_ADMISSION.maxCurvePoints, "MAX_CURVE_POINTS"),
    // Measured on the canonical JSON announce, not protobuf (the worker has no
    // protobuf). JSON spells bytes as hex plus field names, so the default is 2×.
    maxOrderBytes: num(env.MAX_ORDER_JSON_BYTES, 2 * DEFAULT_ADMISSION.maxOrderBytes, "MAX_ORDER_JSON_BYTES"),
    minTtlSeconds: num(env.MIN_TTL_SECONDS, 120, "MIN_TTL_SECONDS"),
    maxTtlSeconds: num(env.MAX_TTL_SECONDS, DEFAULT_ADMISSION.maxTtlSeconds, "MAX_TTL_SECONDS"),
    requireDeltaVerifyOutputs: (env.REQUIRE_DELTA_VERIFY ?? "").trim().toLowerCase() === "true",
    ...(allowed.length ? { allowedTokens: allowed } : {}),
  };

  return {
    chain: { chainId, settlement, permit3, lens, rpcUrl: rpc.url, ...(defaultFiller ? { defaultFiller } : {}) },
    // RPC_FALLBACK_URLS_SECRET (a keyed endpoint, never in a committed file) goes first.
    rpcFallbackUrls: [env.RPC_FALLBACK_URLS_SECRET ?? "", env.RPC_FALLBACK_URLS ?? ""]
      .join(",")
      .split(",")
      .map((u) => u.trim())
      .filter((u) => /^https?:\/\//.test(u) && u !== rpc.url),
    rpcMulticall: (env.RPC_MULTICALL ?? "") === "1",
    rpcSource: rpc.source,
    configured,
    ocoModules: addrList(env.OCO_MODULES, "OCO_MODULES"),
    ...(nativeBalance !== zeroAddress ? { nativeBalance } : {}),
    admission,
    maxBodyBytes: num(env.MAX_BODY_BYTES, 256 * 1024, "MAX_BODY_BYTES"),
    rate: {
      ip: {
        capacity: num(env.RATE_LIMIT_IP_CAPACITY, 120, "RATE_LIMIT_IP_CAPACITY"),
        refillPerSecond: num(env.RATE_LIMIT_IP_REFILL, 3, "RATE_LIMIT_IP_REFILL"),
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
    revalidateSeconds: num(env.REVALIDATE_SECONDS, 300, "REVALIDATE_SECONDS"),
    revalidateNoLogsSeconds: Math.min(REVALIDATE_NO_LOGS_SECONDS, num(env.REVALIDATE_SECONDS, 300, "REVALIDATE_SECONDS")),
    maxRecheckPerAlarm: num(env.MAX_RECHECK_PER_ALARM, 500, "MAX_RECHECK_PER_ALARM"),
    tombstoneTtlSeconds: num(env.TOMBSTONE_TTL_SECONDS, 14 * 24 * 3600, "TOMBSTONE_TTL_SECONDS"),
    maxTombstones: num(env.MAX_TOMBSTONES, 20_000, "MAX_TOMBSTONES"),
    maxFills: num(env.MAX_FILLS, 50_000, "MAX_FILLS"),
    maxSoftCancels: 100_000,
    maxPendingSoftCancelsPerMaker: 1_024,
    maxBilled: 100_000,
    alarmBudgetMs: 1000 * num(env.ALARM_BUDGET_SECONDS, 240, "ALARM_BUDGET_SECONDS"),
    // 16 bisection calls and 60 s per sweep: with the 8 s transport timeout (and one
    // retry) a dead RPC costs one sweep about a minute, not (chunks + 64) × 16 s.
    verifier: { maxRecheckCalls: 16, maxSweepMs: 60_000 },
    ...(raffle ? { raffle } : {}),
  };
}

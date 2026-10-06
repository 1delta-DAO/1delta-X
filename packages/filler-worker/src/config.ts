import { loadConfig, type Config } from "@1delta-x/beta-filler/core";
import { zeroAddress } from "viem";

/**
 * The worker's bindings. Every non-secret knob is a `[vars]` string (see
 * `wrangler.toml`); the filler core reads the same names as the Node CLI's env.
 * Secrets: PRIVATE_KEY, ADMIN_TOKEN, ALERT_WEBHOOK_URL, optionally RPC_URL_SECRET
 * (a keyed RPC, read in preference to the RPC_URL var) and ORDERBOOK_BINDING_KEY.
 */
export interface Env {
  FILLER: DurableObjectNamespace;
  /** Service binding to the orderbook worker (`orderbook-1delta-rsk`). */
  ORDERBOOK?: Fetcher;
  PRIVATE_KEY?: string;
  ADMIN_TOKEN?: string;
  ALERT_WEBHOOK_URL?: string;
  ORDERBOOK_BINDING_KEY?: string;
  RPC_URL?: string;
  RPC_URL_SECRET?: string;
  DO_LOCATION_HINT?: string;
  [key: string]: unknown;
}

/** Worker-only knobs (the filler core's own config comes from `loadConfig`). */
export interface WorkerConfig {
  tickMs: number;
  pendingTickMs: number;
  maxOrdersPerTick: number;
  maxSubrequestsPerTick: number;
  subrequestsPerOrder: number;
  tickBudgetMs: number;
  intakeMaxPages: number;
  intakePageSize: number;
  balanceCheckMs: number;
  /** The rebalancer step runs at most this often (it reads balances / the MoC queue). */
  rebalanceMs: number;
  maxFillRows: number;
  startPaused: boolean;
  adminAllowWorkersDev: boolean;
  orderbookUrl: string;
  orderbookClientIp: string;
  /** How often the monitor reads the orderbook's /health (its alarm loop and log scan), ms. */
  bookHealthMs: number;
  alerts: AlertConfig;
}

export interface AlertConfig {
  webhookUrl?: string;
  format: "slack" | "telegram";
  telegramChatId?: string;
  name: string;
  minRbtcWei: bigint;
  minUsdt0: bigint;
  minUsdrif: bigint;
  revertsPerHour: number;
  pendingTxMs: number;
  mocPendingMs: number;
  rpcErrorStreak: number;
  cooldownMs: number;
  maxPerHour: number;
}

/** Every string binding, with empty strings treated as unset (an empty var means "default"). */
export function stringVars(env: Env): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (typeof v === "string" && v.trim() !== "") out[k] = v;
  return out;
}

function num(v: string | undefined, fallback: number, name: string, min = 0): number {
  if (v === undefined || v.trim() === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n) || n < min) throw new Error(`${name} must be a number ≥ ${min}`);
  return n;
}

function decimal(v: string | undefined, fallback: string, decimals: number, name: string): bigint {
  const s = (v ?? fallback).trim();
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m || (m[2] ?? "").length > decimals) throw new Error(`${name} must be a non-negative decimal`);
  return BigInt(m[1]!) * 10n ** BigInt(decimals) + BigInt((m[2] ?? "").padEnd(decimals, "0") || "0");
}

const flag = (v: string | undefined, fallback: boolean) => (v === undefined || v.trim() === "" ? fallback : v.trim() === "1" || v.trim().toLowerCase() === "true");

/** The worker knobs. Throws on a malformed value (the status endpoint reports it). */
export function loadWorkerConfig(env: Env): WorkerConfig {
  const v = stringVars(env);
  const format = (v.ALERT_FORMAT ?? "slack").trim().toLowerCase();
  if (format !== "slack" && format !== "telegram") throw new Error("ALERT_FORMAT must be slack or telegram");
  return {
    tickMs: 1000 * num(v.TICK_SECONDS, 5, "TICK_SECONDS", 1),
    pendingTickMs: 1000 * num(v.PENDING_TICK_SECONDS, 3, "PENDING_TICK_SECONDS", 1),
    maxOrdersPerTick: num(v.MAX_ORDERS_PER_TICK, 10, "MAX_ORDERS_PER_TICK", 1),
    maxSubrequestsPerTick: num(v.MAX_SUBREQUESTS_PER_TICK, 500, "MAX_SUBREQUESTS_PER_TICK", 10),
    subrequestsPerOrder: num(v.SUBREQUESTS_PER_ORDER, 40, "SUBREQUESTS_PER_ORDER", 1),
    tickBudgetMs: num(v.TICK_BUDGET_MS, 20_000, "TICK_BUDGET_MS", 1_000),
    intakeMaxPages: num(v.INTAKE_MAX_PAGES, 2, "INTAKE_MAX_PAGES", 1),
    intakePageSize: num(v.INTAKE_PAGE_SIZE, 500, "INTAKE_PAGE_SIZE", 1),
    balanceCheckMs: 1000 * num(v.BALANCE_CHECK_SECONDS, 300, "BALANCE_CHECK_SECONDS", 1),
    rebalanceMs: 1000 * num(v.REBALANCE_SECONDS, 30, "REBALANCE_SECONDS", 0),
    maxFillRows: num(v.MAX_FILL_ROWS, 20_000, "MAX_FILL_ROWS", 100),
    startPaused: flag(v.START_PAUSED, false),
    adminAllowWorkersDev: flag(v.ADMIN_ALLOW_WORKERS_DEV, false),
    orderbookUrl: (v.ORDERBOOK_URL ?? "").replace(/\/+$/, ""),
    orderbookClientIp: v.ORDERBOOK_CLIENT_IP ?? "127.0.0.2",
    bookHealthMs: 1000 * num(v.BOOK_HEALTH_SECONDS, 300, "BOOK_HEALTH_SECONDS", 10),
    alerts: {
      ...(v.ALERT_WEBHOOK_URL ? { webhookUrl: v.ALERT_WEBHOOK_URL } : {}),
      format,
      ...(v.ALERT_TELEGRAM_CHAT_ID ? { telegramChatId: v.ALERT_TELEGRAM_CHAT_ID } : {}),
      name: v.ALERT_NAME ?? "filler-1delta-rsk",
      minRbtcWei: decimal(v.ALERT_MIN_RBTC, "0.001", 18, "ALERT_MIN_RBTC"),
      minUsdt0: decimal(v.ALERT_MIN_USDT0, "50", 6, "ALERT_MIN_USDT0"),
      minUsdrif: decimal(v.ALERT_MIN_USDRIF, "0", 18, "ALERT_MIN_USDRIF"),
      revertsPerHour: num(v.ALERT_REVERTS_PER_HOUR, 3, "ALERT_REVERTS_PER_HOUR", 1),
      pendingTxMs: 1000 * num(v.ALERT_PENDING_TX_SECONDS, 600, "ALERT_PENDING_TX_SECONDS", 1),
      mocPendingMs: 1000 * num(v.ALERT_MOC_PENDING_SECONDS, 900, "ALERT_MOC_PENDING_SECONDS", 1),
      rpcErrorStreak: num(v.ALERT_RPC_ERROR_STREAK, 5, "ALERT_RPC_ERROR_STREAK", 1),
      cooldownMs: 1000 * num(v.ALERT_COOLDOWN_SECONDS, 3600, "ALERT_COOLDOWN_SECONDS", 0),
      maxPerHour: num(v.ALERT_MAX_PER_HOUR, 12, "ALERT_MAX_PER_HOUR", 1),
    },
  };
}

/**
 * The filler core's config from the bindings, with the admin API's dry-run
 * override applied. A service binding stands in for ORDERBOOK_URL when unset.
 */
export function loadFillerConfig(env: Env, dryRunOverride?: boolean): Config {
  const v = stringVars(env);
  if (!v.ORDERBOOK_URL) v.ORDERBOOK_URL = "https://book";
  if (dryRunOverride !== undefined) v.DRY_RUN = dryRunOverride ? "1" : "0";
  return loadConfig(v);
}

/** Durable Object location hints Cloudflare accepts (https://developers.cloudflare.com/durable-objects/reference/data-location/). */
const LOCATION_HINTS = new Set(["wnam", "enam", "sam", "weur", "eeur", "apac", "apac-ne", "apac-se", "oc", "afr", "me"]);

/**
 * `DO_LOCATION_HINT`, validated (an unknown hint would make every `get()` throw).
 * Cloudflare honours it only when the object is first CREATED; an existing object
 * never moves.
 */
export function locationHint(env: Pick<Env, "DO_LOCATION_HINT">): DurableObjectLocationHint | undefined {
  const h = typeof env.DO_LOCATION_HINT === "string" ? env.DO_LOCATION_HINT.trim().toLowerCase() : "";
  return LOCATION_HINTS.has(h) ? (h as DurableObjectLocationHint) : undefined;
}

/** Every RPC URL binding that may be secret (API-key-bearing): redacted from anything that leaves the worker. */
export function rpcUrls(env: Pick<Env, "RPC_URL" | "RPC_URL_SECRET">): string[] {
  return [env.RPC_URL_SECRET, env.RPC_URL].filter((u): u is string => typeof u === "string" && u.trim() !== "").map((u) => u.trim());
}

/** False while SETTLEMENT / LENS are still the zero-address placeholders. */
export function isConfigured(cfg: Config): boolean {
  return cfg.settlement !== zeroAddress && cfg.lens !== zeroAddress && cfg.permit3 !== zeroAddress;
}

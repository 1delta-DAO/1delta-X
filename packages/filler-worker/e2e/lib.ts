/**
 * Shared helpers of the staging harness (LOCAL ONLY, not part of CI): the run's
 * environment, anvil clients, storage-slot `deal`, order signing, timed HTTP
 * clients for the book / filler admin / wrangler's local explorer, and stats.
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { ROOTSTOCK } from "@1delta-x/beta-filler/core";
import {
  OrderSide,
  QUOTER_V2_ABI,
  encodeV3Path,
  hashOrderStruct,
  orderToJson,
  packTiming,
  randomOrderNonce,
  signOrder,
  softCancelOrders,
  softCancelToJson,
  withDeltaVerifyOutputs,
  type Order,
} from "@1delta-x/sdk";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  erc20Abi,
  getAddress,
  http,
  keccak256,
  numberToHex,
  pad,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

export { ROOTSTOCK };
export const WRBTC = getAddress(ROOTSTOCK.wrbtc);
export const USDT0 = getAddress(ROOTSTOCK.usdt0);
export const USDRIF = getAddress(ROOTSTOCK.usdrif);
export const WETH = getAddress(ROOTSTOCK.weth);
export const RIF = getAddress(ROOTSTOCK.rif);
export const QUOTER = getAddress(ROOTSTOCK.quoterV2);

/** Written by `staging.sh up` (setup.ts) to $RUN_DIR/env.json. */
export interface StagingEnv {
  label: string;
  runDir: string;
  anvilUrl: string;
  proxyUrl: string;
  gatewayUrl: string;
  explorerUrl: string;
  forkUrl: string;
  forkBlock: number;
  startBlock: number;
  blockTimeS: number;
  chainId: number;
  permit3: Address;
  settlement: Address;
  lens: Address;
  solver: Address;
  sandbox: Address;
  operator: Address;
  operatorKey: Hex;
  deployerKey: Hex;
  treasury: Address;
  adminToken: string;
  bindingKey: string;
  rbtcUsd: number;
  gasPriceWei: string;
  latencyMs: number;
  jitterMs: number;
  workerVars: { orderbook: Record<string, string>; filler: Record<string, string> };
}

export function runDir(): string {
  const d = process.env.RUN_DIR;
  if (!d) throw new Error("RUN_DIR is not set (staging.sh exports it)");
  return d;
}

export function loadEnv(dir = runDir()): StagingEnv {
  return JSON.parse(readFileSync(join(dir, "env.json"), "utf8")) as StagingEnv;
}

export const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
export const nowS = () => Math.floor(Date.now() / 1000);
export const json = (v: unknown) => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x), 1);

export function chainOf(url: string) {
  return defineChain({ id: 30, name: "rootstock-fork", nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 }, rpcUrls: { default: { http: [url] } } });
}

/** A public client straight to anvil — the harness never goes through the counting proxy. */
export function publicClient(env: Pick<StagingEnv, "anvilUrl">): PublicClient {
  return createPublicClient({ chain: chainOf(env.anvilUrl), transport: http(env.anvilUrl, { batch: false, retryCount: 2 }) }) as PublicClient;
}

export function walletClient(env: Pick<StagingEnv, "anvilUrl">, account: PrivateKeyAccount) {
  return createWalletClient({ chain: chainOf(env.anvilUrl), transport: http(env.anvilUrl, { retryCount: 2 }), account });
}

/** A deterministic test key, never a real one: keccak256("1delta-staging:<label>:<i>"). */
export function testKey(label: string, i: number): Hex {
  return keccak256(toHex(`1delta-staging:${label}:${i}`));
}

export async function rpc<T = unknown>(pub: PublicClient, method: string, params: unknown[]): Promise<T> {
  return (await pub.request({ method: method as never, params: params as never })) as T;
}

export async function setBalance(pub: PublicClient, who: Address, wei: bigint): Promise<void> {
  await rpc(pub, "anvil_setBalance", [who, numberToHex(wei)]);
}

export async function balanceOf(pub: PublicClient, token: Address, who: Address, blockNumber?: bigint): Promise<bigint> {
  return pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who], ...(blockNumber !== undefined ? { blockNumber } : {}) });
}

const EIP1967 = new Set([
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
  "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103",
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50",
]);

/**
 * Set `who`'s ERC20 balance by writing storage — anvil's `anvil_dealERC20` finds
 * no slot on these Rootstock proxies, so: take the storage keys `balanceOf(who)`
 * reads (eth_createAccessList), write each candidate and keep the one that makes
 * `balanceOf` answer `amount` (forge-std `deal` style; totalSupply is not touched).
 */
export async function deal(pub: PublicClient, token: Address, who: Address, amount: bigint): Promise<void> {
  const data = encodeFunctionData({ abi: erc20Abi, functionName: "balanceOf", args: [who] });
  const al = await rpc<{ accessList: Array<{ address: Address; storageKeys: Hex[] }> }>(pub, "eth_createAccessList", [{ to: token, data }, "latest"]);
  const value = pad(numberToHex(amount), { size: 32 });
  for (const entry of al.accessList) {
    for (const slot of entry.storageKeys) {
      if (EIP1967.has(slot.toLowerCase())) continue;
      const prev = (await pub.getStorageAt({ address: entry.address, slot })) ?? pad("0x0", { size: 32 });
      await rpc(pub, "anvil_setStorageAt", [entry.address, slot, value]);
      if ((await balanceOf(pub, token, who)) === amount) return;
      await rpc(pub, "anvil_setStorageAt", [entry.address, slot, prev]);
    }
  }
  throw new Error(`deal: no balance slot found for ${token}`);
}

/** QuoterV2 exact-input quote along `tokens`/`fees`. */
export async function quote(pub: PublicClient, tokens: Address[], fees: number[], amountIn: bigint): Promise<bigint> {
  const { result } = await pub.simulateContract({ address: QUOTER, abi: QUOTER_V2_ABI, functionName: "quoteExactInput", args: [encodeV3Path(tokens, fees), amountIn] });
  return result[0];
}

export interface OrderSpec {
  maker: PrivateKeyAccount;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  owed: bigint;
  expiry: bigint;
  direct?: boolean;
  solver?: Address;
}

/** Build + sign an order exactly as the app's buildOrder does for a fixed sell (make-order.ts). */
export async function buildOrder(env: Pick<StagingEnv, "settlement" | "permit3">, s: OrderSpec): Promise<{ order: Order; sig: Hex; hash: Hex; body: string }> {
  const order: Order = {
    maker: s.maker.address,
    side: OrderSide.SELL,
    nonce: randomOrderNonce(0n),
    expiry: s.expiry,
    legsIn: [{ token: s.tokenIn, start: s.amountIn, end: 0n }],
    legsOut: [{ token: s.tokenOut, start: s.owed, end: 0n, recipient: zeroAddress }],
    timing: s.direct ? withDeltaVerifyOutputs(packTiming(0, 0, 0)) : packTiming(0, 0, 0),
    exclusiveFiller: s.direct ? s.solver! : zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };
  const sig = await signOrder(s.maker, order, { chainId: 30, settlement: env.settlement, permit3: env.permit3 });
  return { order, sig, hash: hashOrderStruct(order).toLowerCase() as Hex, body: JSON.stringify({ order: orderToJson(order), sig }) };
}

export async function signedSoftCancel(env: Pick<StagingEnv, "settlement" | "permit3">, maker: PrivateKeyAccount, hashes: Hex[]): Promise<string> {
  const { cancel, sig } = await softCancelOrders(maker, maker.address, hashes, { chainId: 30, settlement: env.settlement, permit3: env.permit3 }, { ttlSeconds: 3600n });
  return JSON.stringify({ cancel: softCancelToJson(cancel), sig });
}

// ──────────────────── timed HTTP ────────────────────

export interface Timed<T = unknown> {
  status: number;
  ms: number;
  body: T;
  headers: Headers;
  at: number;
}

export async function timed<T = unknown>(url: string, init: RequestInit = {}, timeoutMs = 60_000): Promise<Timed<T>> {
  const at = Date.now();
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { ...init, signal: ctl.signal });
    const text = await r.text();
    let body: unknown = text;
    try {
      body = JSON.parse(text);
    } catch {
      // keep text
    }
    return { status: r.status, ms: Date.now() - at, body: body as T, headers: r.headers, at };
  } catch (e) {
    return { status: 0, ms: Date.now() - at, body: { error: (e as Error).message } as T, headers: new Headers(), at };
  } finally {
    clearTimeout(timer);
  }
}

/** The book through the app's Pages worker (`/api/book/*`), as visitor `ip`. */
export function book(env: Pick<StagingEnv, "gatewayUrl">, ip: string) {
  const base = `${env.gatewayUrl}/api/book`;
  return {
    post: (path: string, body: string, contentType = "application/json") =>
      timed(`${base}${path}`, { method: "POST", headers: { "content-type": contentType, "x-sim-ip": ip }, body }),
    get: <T = unknown>(path: string) => timed<T>(`${base}${path}`, { headers: { accept: "application/json", "x-sim-ip": ip } }),
  };
}

/** The orderbook worker directly (its public route): /health, /orders/:hash. */
export function obDirect(env: Pick<StagingEnv, "gatewayUrl">, ip = "10.255.0.1") {
  return { get: <T = unknown>(path: string) => timed<T>(`${env.gatewayUrl}/ob${path}`, { headers: { accept: "application/json", "x-sim-ip": ip } }) };
}

/** The filler's admin API (bearer token). */
export function admin(env: Pick<StagingEnv, "gatewayUrl" | "adminToken">) {
  const h = { authorization: `Bearer ${env.adminToken}`, "content-type": "application/json" };
  return {
    get: <T = unknown>(path: string) => timed<T>(`${env.gatewayUrl}/filler${path}`, { headers: h }),
    post: <T = unknown>(path: string, body = "{}") => timed<T>(`${env.gatewayUrl}/filler${path}`, { method: "POST", headers: h, body }),
  };
}

/** wrangler's Local Explorer API (DO SQLite, scheduled dispatch, the trace store). */
export function explorer(env: Pick<StagingEnv, "explorerUrl">) {
  const base = env.explorerUrl;
  const post = async <T>(path: string, body: unknown): Promise<T> => {
    const r = await timed<{ success: boolean; result: T; errors?: unknown }>(`${base}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    if (r.status !== 200 || !r.body || !(r.body as { success?: boolean }).success) throw new Error(`explorer ${path}: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
    return r.body.result;
  };
  return {
    /** Rows of each query against one Durable Object's SQLite, by `idFromName` name. */
    async doQuery(namespace: string, name: string, queries: Array<{ sql: string; params?: unknown[] }>): Promise<Array<Array<Record<string, unknown>>>> {
      const res = await post<Array<{ columns: string[]; rows: unknown[][] }>>(`/workers/durable_objects/namespaces/${namespace}/query`, { durable_object_name: name, queries });
      return res.map((r) => r.rows.map((row) => Object.fromEntries(r.columns.map((c, i) => [c, row[i]]))));
    },
    async obs(sql: string, params: unknown[] = []): Promise<Array<Record<string, unknown>>> {
      const r = await post<{ columns: string[]; rows: unknown[][] }>(`/local/observability/query`, { sql, params });
      return r.rows.map((row) => Object.fromEntries(r.columns.map((c, i) => [c, row[i]])));
    },
    scheduled: (worker: string) => post<{ outcome: string; noRetry: boolean }>(`/local/scheduled?worker=${worker}`, { cron: "* * * * *" }),
  };
}

/** The RPC proxy's control API. */
export function proxy(env: Pick<StagingEnv, "proxyUrl">) {
  return {
    stats: async () => (await timed<ProxyStats>(`${env.proxyUrl}/__stats`)).body,
    txs: async () => (await timed<ProxyTx[]>(`${env.proxyUrl}/__txs`)).body,
    webhooks: async () => (await timed<Array<{ at: number; body: unknown }>>(`${env.proxyUrl}/__webhooks`)).body,
    reset: async () => (await timed(`${env.proxyUrl}/__reset`, { method: "POST" })).body,
    config: async (patch: Record<string, unknown>) => (await timed(`${env.proxyUrl}/__config`, { method: "POST", body: JSON.stringify(patch) })).body,
  };
}

export interface ProxyStats {
  since: number;
  now: number;
  config: Record<string, unknown>;
  tags: Record<string, { calls: number; httpRequests: number; rateLimited: number; byMethod: Record<string, number>; errors: Record<string, number>; upstreamMs: { p50: number; p95: number; max: number } }>;
}

export interface ProxyTx {
  at: number;
  tag: string;
  hash: Hex;
  /** The signed bytes (the lost-broadcast test re-sends them by hand). */
  raw: Hex;
  from?: string;
  nonce?: number;
  to?: string | null;
  gas?: string;
  gasPrice?: string;
  mode: string;
  forwardedAt?: number;
  result?: string;
  error?: string;
}

// ──────────────────── stats ────────────────────

export function pct(xs: readonly number[], p: number): number {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const i = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1));
  return s[i]!;
}

export function dist(xs: readonly number[]): { n: number; p50: number; p95: number; p99: number; max: number; mean: number } {
  const n = xs.length;
  return {
    n,
    p50: pct(xs, 50),
    p95: pct(xs, 95),
    p99: pct(xs, 99),
    max: n ? Math.max(...xs) : NaN,
    mean: n ? xs.reduce((a, b) => a + b, 0) / n : NaN,
  };
}

export function resultsDir(dir = runDir()): string {
  const d = join(dir, "results");
  if (!existsSync(d)) mkdirSync(d, { recursive: true });
  return d;
}

export function writeResult(name: string, v: unknown): string {
  const p = join(resultsDir(), `${name}.json`);
  writeFileSync(p, json(v));
  return p;
}

export function logLine(file: string, line: string): void {
  appendFileSync(join(runDir(), file), `${new Date().toISOString()} ${line}\n`);
}

export const PERMIT3_ABI = [
  {
    type: "function",
    name: "approveToken",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
] as const;

// ──────────────────── the proxy's RPC timeline ────────────────────

export interface RpcCall {
  t: number;
  tag: string;
  m: string;
  ms?: number;
  lat?: number;
  err?: string;
  rl?: number;
  local?: number;
}

/** Every call the proxy saw in [from, to] (optionally one tag). */
export function readTimeline(dir: string, from: number, to: number, tag?: string): RpcCall[] {
  const p = join(dir, "rpc-timeline.jsonl");
  if (!existsSync(p)) return [];
  const out: RpcCall[] = [];
  for (const line of readFileSync(p, "utf8").split("\n")) {
    if (!line) continue;
    const r = JSON.parse(line) as RpcCall;
    if (r.t >= from && r.t <= to && (!tag || r.tag === tag)) out.push(r);
  }
  return out;
}

/**
 * The filler's ticks, reconstructed from its RPC calls: ticks are serialised and the
 * alarm re-arms ≥ 1 s after a tick ends, while calls inside a tick follow each other
 * back to back — so a quiet gap > `gapMs` separates two ticks. `exclude` windows
 * (the harness's own /status requests, which read 6 balances) are dropped first.
 * Lossless, unlike the runtime trace store (which drops spans under heavy load).
 */
export function segmentTicks(calls: readonly RpcCall[], exclude: ReadonlyArray<[number, number]> = [], gapMs = 600): Array<{ start: number; end: number; calls: number; methods: Record<string, number> }> {
  const keep = calls.filter((c) => !((c.m === "eth_getBalance" || c.m === "eth_call") && exclude.some(([a, b]) => c.t >= a - 5 && c.t <= b + 5)));
  const ticks: Array<{ start: number; end: number; calls: number; methods: Record<string, number> }> = [];
  let cur: RpcCall[] = [];
  const endOf = (c: RpcCall) => c.t + (c.lat ?? 0) + (c.ms ?? 0);
  const flush = () => {
    if (!cur.length) return;
    const methods: Record<string, number> = {};
    for (const c of cur) methods[c.m] = (methods[c.m] ?? 0) + 1;
    ticks.push({ start: cur[0]!.t, end: Math.max(...cur.map(endOf)), calls: cur.length, methods });
    cur = [];
  };
  for (const c of keep) {
    if (cur.length && c.t - Math.max(...cur.map(endOf)) > gapMs) flush();
    cur.push(c);
  }
  flush();
  return ticks;
}

/**
 * Root invocation spans (alarm / scheduled) of wrangler's local trace store, with the
 * number of `fetch` subrequests under each. Polled continuously because the store
 * DROPS new spans when its write batch is full (heavy request load) — so this is a
 * best-effort sample; the RPC timeline and the DO's own /status are the exact sources.
 */
export class TraceCollector {
  readonly rows = new Map<string, Record<string, unknown>>();
  private cursor: number;
  constructor(private readonly ex: ReturnType<typeof explorer>, from: number) {
    this.cursor = from;
  }
  async poll(): Promise<void> {
    try {
      const rows = await this.ex.obs(
        `SELECT r.trace_id AS id, r.service AS service, r.name AS name, r.start_ms AS start, r.duration_ms AS ms, r.outcome AS outcome,
                (SELECT count(*) FROM spans c WHERE c.trace_id = r.trace_id AND c.name = 'fetch') AS fetches
           FROM spans r WHERE r.parent_id IS NULL AND r.name IN ('alarm', 'scheduled') AND r.start_ms >= ? AND r.duration_ms IS NOT NULL`,
        [this.cursor - 120_000],
      );
      for (const r of rows) this.rows.set(String(r.id), r);
      for (const r of rows) this.cursor = Math.max(this.cursor, Number(r.start));
    } catch {
      // best effort
    }
  }
  of(service: string, name = "alarm", from = 0, to = Number.MAX_SAFE_INTEGER): Array<Record<string, unknown>> {
    return [...this.rows.values()].filter((r) => r.service === service && r.name === name && Number(r.start) >= from && Number(r.start) <= to).sort((a, b) => Number(a.start) - Number(b.start));
  }
}

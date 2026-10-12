import { MAX_POOL_HOPS, v3PoolAddress, type PoolVenue } from "@1delta-x/sdk";
import { decodeFunctionResult, encodeFunctionData, getAddress, multicall3Abi, zeroAddress, type Address, type Hex } from "viem";

import type { RoutePath, RoutePool } from "./config";

/**
 * POOL GRAPH (2026-10-12): which Uniswap-v3-style pools exist between the route
 * tokens on every venue the solver can swap on, and how deep each is right now — so
 * the route strategy can find multi-hop, mixed-venue paths on its own instead of
 * only the ones written into ROUTE_POOLS / ROUTE_PATHS.
 *
 *  • DISCOVERY ({@link discoverPools}): for every token pair × fee tier × venue,
 *    `factory.getPool(a, b, fee)`; every pool that exists is checked against the
 *    address the SOLVER derives for it (CREATE2 over its venue allowlist — SDK
 *    `v3PoolAddress`, mirroring `poolFor`) and SKIPPED with a warning on a mismatch
 *    (the plan would swap on a different address than the one quoted). Then each
 *    pool's `liquidity()` and `slot0()`. Every read goes through Multicall3
 *    `aggregate3` in a handful of `eth_call`s; INCREMENTAL: a pool once found is
 *    never looked up again (a v3 pool cannot be destroyed), only its state is re-read.
 *  • ENUMERATION ({@link enumeratePaths}): every simple path tokenIn → tokenOut of
 *    1..maxHops whose INTERMEDIATE tokens are hubs, each hop on any (fee, venue) pool
 *    of that pair; hard-capped.
 *  • PRUNING ({@link selectPaths}): a zero-RPC estimate of each path's output from
 *    the pools' in-range virtual reserves (`x = L / √P`, `y = L·√P`: exact while the
 *    swap stays inside the current tick range), less a per-extra-hop gas penalty;
 *    the best K are quoted for real (plus the best single hop, always).
 */

/** One pool of the graph. `liquidity` / `sqrtPriceX96` are unset for a configured pool discovery has not read. */
export interface GraphPool {
  tokenA: Address;
  tokenB: Address;
  fee: number;
  venue: number;
  pool: Address;
  liquidity?: bigint;
  sqrtPriceX96?: bigint;
}

/** The discovered graph: every pool that exists (any liquidity) and when it was read. */
export interface PoolGraph {
  /** ms timestamp of the last successful refresh. */
  at: number;
  /** Discovery inputs the graph was built for (tokens, fees, venue factories): a change rebuilds it. */
  key: string;
  pools: GraphPool[];
}

/** {@link PoolGraph} as JSON (bigints as decimal strings) — persisted in the filler state. */
export interface PoolGraphState {
  at: number;
  key: string;
  pools: Array<{ a: string; b: string; fee: number; venue: number; pool: string; liq?: string; sqrtP?: string }>;
}

export function graphToState(g: PoolGraph): PoolGraphState {
  return {
    at: g.at,
    key: g.key,
    pools: g.pools.map((p) => ({
      a: p.tokenA,
      b: p.tokenB,
      fee: p.fee,
      venue: p.venue,
      pool: p.pool,
      ...(p.liquidity !== undefined ? { liq: p.liquidity.toString() } : {}),
      ...(p.sqrtPriceX96 !== undefined ? { sqrtP: p.sqrtPriceX96.toString() } : {}),
    })),
  };
}

/** The inverse of {@link graphToState}; `undefined` for anything malformed (the graph is then simply rediscovered). */
export function graphFromState(s: PoolGraphState | undefined): PoolGraph | undefined {
  if (!s || typeof s.at !== "number" || typeof s.key !== "string" || !Array.isArray(s.pools)) return undefined;
  try {
    return {
      at: s.at,
      key: s.key,
      pools: s.pools.map((p) => ({
        tokenA: getAddress(p.a),
        tokenB: getAddress(p.b),
        fee: p.fee,
        venue: p.venue,
        pool: getAddress(p.pool),
        ...(p.liq !== undefined ? { liquidity: BigInt(p.liq) } : {}),
        ...(p.sqrtP !== undefined ? { sqrtPriceX96: BigInt(p.sqrtP) } : {}),
      })),
    };
  } catch {
    return undefined;
  }
}

const lc = (a: string) => a.toLowerCase();
const eq = (a: string, b: string) => lc(a) === lc(b);

/** Order-independent identity of a (pair, fee, venue) pool slot. */
export function poolKey(a: string, b: string, fee: number, venue: number): string {
  const [x, y] = lc(a) < lc(b) ? [lc(a), lc(b)] : [lc(b), lc(a)];
  return `${x}-${y}-${fee}-${venue}`;
}

/** The discovery inputs as a string: a graph built for other inputs is rebuilt from scratch. */
export function discoveryKey(tokens: readonly Address[], fees: readonly number[], venues: ReadonlyMap<number, PoolVenue>): string {
  const t = [...new Set(tokens.map(lc))].sort().join(",");
  const v = [...venues.entries()].sort((x, y) => x[0] - y[0]).map(([i, x]) => `${i}:${lc(x.factory)}:${lc(x.initCodeHash)}`).join(",");
  return `${t}|${[...fees].sort((x, y) => x - y).join(",")}|${v}`;
}

// ──────────────────── batched reads (Multicall3) ────────────────────

/** One contract call to batch. */
export interface BatchCall {
  address: Address;
  abi: readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
}

/** A batched call's outcome: decoded result, or a REVERT (deterministic) — an RPC failure throws instead. */
export type BatchResult = { ok: true; result: unknown } | { ok: false; reason: string };

/** What batching needs from a viem public client. */
export interface BatchClient {
  readContract(a: { address: Address; abi: typeof multicall3Abi; functionName: "aggregate3"; args: readonly [readonly { target: Address; allowFailure: boolean; callData: Hex }[]] }): Promise<unknown>;
}

/**
 * Run `calls` through Multicall3 `aggregate3` (allowFailure on every call), at most
 * `perCall` per `eth_call` — chunks run one after another, never in parallel (the
 * public node rate-limits). A chunk's RPC failure THROWS (transient: it says nothing
 * about the calls); a call that reverts inside it is `{ ok: false }`.
 */
export async function aggregate(client: BatchClient, multicall: Address, calls: readonly BatchCall[], perCall: number): Promise<BatchResult[]> {
  const out: BatchResult[] = [];
  for (let i = 0; i < calls.length; i += perCall) {
    const chunk = calls.slice(i, i + perCall);
    const encoded = chunk.map((c) => ({
      target: c.address,
      allowFailure: true,
      callData: encodeFunctionData({ abi: c.abi, functionName: c.functionName, args: c.args ?? [] } as never),
    }));
    const res = (await client.readContract({ address: multicall, abi: multicall3Abi, functionName: "aggregate3", args: [encoded] })) as readonly { success: boolean; returnData: Hex }[];
    if (!Array.isArray(res) || res.length !== chunk.length) throw new Error(`multicall returned ${Array.isArray(res) ? res.length : "no"} results for ${chunk.length} calls`);
    res.forEach((r, k) => {
      const c = chunk[k]!;
      if (!r.success) return void out.push({ ok: false, reason: `${c.functionName} reverted` });
      try {
        out.push({ ok: true, result: decodeFunctionResult({ abi: c.abi, functionName: c.functionName, data: r.returnData } as never) });
      } catch (e) {
        out.push({ ok: false, reason: `${c.functionName}: ${(e as Error).message.split("\n")[0]}` });
      }
    });
  }
  return out;
}

// ──────────────────── discovery ────────────────────

export const FACTORY_GET_POOL_ABI = [
  {
    type: "function",
    name: "getPool",
    stateMutability: "view",
    inputs: [
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
      { name: "fee", type: "uint24" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

/** `liquidity()` and the first two words of `slot0()` (identical on Uniswap v3 and SushiSwap v3; the rest is not decoded). */
export const POOL_STATE_ABI = [
  { type: "function", name: "liquidity", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint128" }] },
  {
    type: "function",
    name: "slot0",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
    ],
  },
] as const;

/** getPool calls per `eth_call` (a mapping read, ≈5k gas each with the Multicall3 overhead): the default 6 tokens × 4 fees × 2 venues = 120 fit one call. */
export const GETPOOL_PER_CALL = 200;
/** liquidity/slot0 calls per `eth_call`. */
export const STATE_PER_CALL = 100;

export interface DiscoverOptions {
  /** Every token of the graph (route tokens ∪ hubs). */
  tokens: readonly Address[];
  feeTiers: readonly number[];
  /** venue index → the solver's (factory, init code hash) — only venues we can quote. */
  venues: ReadonlyMap<number, PoolVenue>;
  multicall: Address;
  /** The previous graph: its pools are not looked up again, only re-read (incremental). */
  previous?: PoolGraph;
  now: number;
}

export interface Discovery {
  graph: PoolGraph;
  /** CREATE2 mismatches and unreadable pools — logged by the caller. */
  warnings: string[];
  /** `eth_call`s spent. */
  rpcCalls: number;
}

/**
 * Discover (or refresh) the pool graph: `getPool` for every (pair, fee, venue) the
 * previous graph does not already hold, the CREATE2 check, then `liquidity()` +
 * `slot0()` of every pool. A pool whose state cannot be read this round keeps its
 * previous state (or none). Throws on an RPC failure (keep the old graph, retry later).
 */
export async function discoverPools(client: BatchClient, o: DiscoverOptions): Promise<Discovery> {
  const key = discoveryKey(o.tokens, o.feeTiers, o.venues);
  const prev = o.previous && o.previous.key === key ? o.previous : undefined;
  const known = new Map<string, GraphPool>();
  for (const p of prev?.pools ?? []) known.set(poolKey(p.tokenA, p.tokenB, p.fee, p.venue), p);
  const warnings: string[] = [];
  let rpcCalls = 0;

  const tokens = [...new Map(o.tokens.map((t) => [lc(t), getAddress(t)])).values()];
  const lookups: Array<{ a: Address; b: Address; fee: number; venue: number; v: PoolVenue }> = [];
  for (let i = 0; i < tokens.length; i++) {
    for (let j = i + 1; j < tokens.length; j++) {
      for (const fee of o.feeTiers) {
        for (const [venue, v] of o.venues) {
          if (!known.has(poolKey(tokens[i]!, tokens[j]!, fee, venue))) lookups.push({ a: tokens[i]!, b: tokens[j]!, fee, venue, v });
        }
      }
    }
  }
  const found: GraphPool[] = [...known.values()];
  if (lookups.length) {
    const res = await aggregate(
      client,
      o.multicall,
      lookups.map((l) => ({ address: l.v.factory, abi: FACTORY_GET_POOL_ABI, functionName: "getPool", args: [l.a, l.b, l.fee] })),
      GETPOOL_PER_CALL,
    );
    rpcCalls += Math.ceil(lookups.length / GETPOOL_PER_CALL);
    res.forEach((r, k) => {
      const l = lookups[k]!;
      if (!r.ok || typeof r.result !== "string" || eq(r.result, zeroAddress)) return;
      const pool = getAddress(r.result);
      const derived = v3PoolAddress(l.v, l.a, l.b, l.fee);
      if (!eq(derived, pool)) {
        warnings.push(`venue ${l.venue} ${l.a}/${l.b} fee ${l.fee}: factory.getPool = ${pool} but the solver derives ${derived} (CREATE2) — skipped`);
        return;
      }
      found.push({ tokenA: l.a, tokenB: l.b, fee: l.fee, venue: l.venue, pool });
    });
  }
  const pools: GraphPool[] = [];
  if (found.length) {
    const calls: BatchCall[] = [];
    for (const p of found) {
      calls.push({ address: p.pool, abi: POOL_STATE_ABI, functionName: "liquidity" });
      calls.push({ address: p.pool, abi: POOL_STATE_ABI, functionName: "slot0" });
    }
    const res = await aggregate(client, o.multicall, calls, STATE_PER_CALL);
    rpcCalls += Math.ceil(calls.length / STATE_PER_CALL);
    found.forEach((p, k) => {
      const l = res[2 * k]!;
      const s = res[2 * k + 1]!;
      if (l.ok && s.ok) {
        pools.push({ ...p, liquidity: BigInt(l.result as bigint), sqrtPriceX96: BigInt((s.result as readonly [bigint, number])[0]) });
      } else {
        warnings.push(`pool ${p.pool} (venue ${p.venue} fee ${p.fee}): state unreadable this round`);
        pools.push(p);
      }
    });
  }
  return { graph: { at: o.now, key, pools }, warnings, rpcCalls };
}

/** The pools a path may use: state read and liquidity ≥ `minLiquidity` (> 0 always). */
export function activePools(g: PoolGraph | undefined, minLiquidity: bigint): GraphPool[] {
  const floor = minLiquidity > 0n ? minLiquidity : 1n;
  return (g?.pools ?? []).filter((p) => p.liquidity !== undefined && p.sqrtPriceX96 !== undefined && p.sqrtPriceX96 > 0n && p.liquidity >= floor);
}

/**
 * The graph's edges: every active discovered pool, plus each CONFIGURED pool
 * (ROUTE_POOLS) discovery did not see (state unknown — quoted, never estimated) unless
 * discovery saw it below the liquidity floor.
 */
export function graphEdges(g: PoolGraph | undefined, minLiquidity: bigint, configured: readonly RoutePool[]): GraphPool[] {
  const edges = activePools(g, minLiquidity);
  const seen = new Set((g?.pools ?? []).map((p) => poolKey(p.tokenA, p.tokenB, p.fee, p.venue)));
  for (const p of configured) {
    const venue = p.venue ?? 0;
    const k = poolKey(p.tokenA, p.tokenB, p.fee, venue);
    if (seen.has(k)) continue;
    seen.add(k);
    edges.push({ tokenA: getAddress(p.tokenA), tokenB: getAddress(p.tokenB), fee: p.fee, venue, pool: p.pool ? getAddress(p.pool) : zeroAddress });
  }
  return edges;
}

// ──────────────────── enumeration ────────────────────

/** Hard cap on enumerated paths per pair (before pruning). */
export const MAX_ENUMERATED_PATHS = 512;

/** A path's venue per hop (`venues`, else `venue` on every hop, else 0). */
export function pathVenues(p: Pick<RoutePath, "fees" | "venue" | "venues">): number[] {
  return p.venues && p.venues.length === p.fees.length ? [...p.venues] : p.fees.map(() => p.venue ?? 0);
}

/** Identity of a path (tokens, fees, venues per hop). */
export function pathKey(p: RoutePath): string {
  const v = pathVenues(p);
  return p.tokens.map((t, i) => (i < p.fees.length ? `${lc(t)}>${p.fees[i]}:${v[i]}` : lc(t))).join(">");
}

/** A path in canonical form: `venues` per hop, and `venue` too when every hop shares one (older readers). */
export function normalizePath(tokens: readonly Address[], fees: readonly number[], venues: readonly number[]): RoutePath {
  const single = venues.every((v) => v === venues[0]);
  return { tokens: [...tokens], fees: [...fees], venues: [...venues], ...(single ? { venue: venues[0] } : {}) };
}

/**
 * Every simple path tokenIn → tokenOut of 1..`maxHops` hops over `edges` whose
 * intermediate tokens are all in `hubs` — each hop on any pool (fee, venue) of its
 * pair. Shorter paths first; at most `cap`.
 */
export function enumeratePaths(
  edges: readonly GraphPool[],
  tokenIn: Address,
  tokenOut: Address,
  o: { maxHops: number; hubs: readonly Address[]; cap?: number },
): RoutePath[] {
  const cap = o.cap ?? MAX_ENUMERATED_PATHS;
  const maxHops = Math.max(1, Math.min(o.maxHops, MAX_POOL_HOPS));
  if (eq(tokenIn, tokenOut)) return [];
  const adj = new Map<string, Map<string, GraphPool[]>>();
  const add = (x: string, y: string, p: GraphPool) => {
    let m = adj.get(x);
    if (!m) adj.set(x, (m = new Map()));
    let l = m.get(y);
    if (!l) m.set(y, (l = []));
    l.push(p);
  };
  for (const p of edges) {
    add(lc(p.tokenA), lc(p.tokenB), p);
    add(lc(p.tokenB), lc(p.tokenA), p);
  }
  const hubs = new Set(o.hubs.map(lc));
  const addr = new Map<string, Address>();
  for (const p of edges) {
    addr.set(lc(p.tokenA), p.tokenA);
    addr.set(lc(p.tokenB), p.tokenB);
  }
  // Token sequences by length (BFS order), then every pool choice per hop.
  const seqs: string[][] = [];
  const walk = (seq: string[]) => {
    const last = seq[seq.length - 1]!;
    for (const next of adj.get(last)?.keys() ?? []) {
      if (seq.includes(next)) continue;
      if (next === lc(tokenOut)) seqs.push([...seq, next]);
      else if (seq.length < maxHops && hubs.has(next)) walk([...seq, next]);
    }
  };
  walk([lc(tokenIn)]);
  seqs.sort((x, y) => x.length - y.length);
  const out: RoutePath[] = [];
  for (const seq of seqs) {
    const hopPools = seq.slice(1).map((t, i) => adj.get(seq[i]!)!.get(t)!);
    const pick = (i: number, fees: number[], venues: number[]): boolean => {
      if (out.length >= cap) return false;
      if (i === hopPools.length) {
        out.push(normalizePath([tokenIn, ...seq.slice(1, -1).map((t) => addr.get(t)!), tokenOut], fees, venues));
        return true;
      }
      for (const p of hopPools[i]!) if (!pick(i + 1, [...fees, p.fee], [...venues, p.venue])) return false;
      return true;
    };
    if (!pick(0, [], [])) break;
  }
  return out;
}

// ──────────────────── zero-RPC estimate ────────────────────

const Q96 = 1n << 96n;
const FEE_DENOM = 1_000_000n;

/**
 * A hop is THIN when its input exceeds 1/THIN_DIVISOR of the pool's in-range virtual
 * input reserve: the swap then almost surely leaves the current tick range, where the
 * estimate knows nothing — and the real liquidity is often a sliver. Measured on
 * Rootstock 2026-10-12: 0.01 WRBTC into the RIF/WRBTC 0.05 % pool (virtual 0.001
 * WRBTC) estimated 141 USD₮0 out, quoted 0.27 — at 2.1M quoter gas.
 */
export const THIN_DIVISOR = 10n;

/**
 * One hop's output from the pool's in-range VIRTUAL reserves (`x = L·2^96/√P`,
 * `y = L·√P/2^96`, x·y = L²): exact while the swap stays inside the current tick
 * range, an approximation beyond it — ranking only, never a price we act on.
 * `undefined` when the pool's state is unknown; `thin` per {@link THIN_DIVISOR}.
 */
export function estimateHopDetail(p: GraphPool, tokenIn: Address, amountIn: bigint): { out: bigint; thin: boolean } | undefined {
  if (p.liquidity === undefined || p.sqrtPriceX96 === undefined) return undefined;
  if (p.liquidity === 0n || p.sqrtPriceX96 === 0n || amountIn <= 0n) return { out: 0n, thin: true };
  const zeroForOne = lc(tokenIn) === (lc(p.tokenA) < lc(p.tokenB) ? lc(p.tokenA) : lc(p.tokenB));
  const x = (p.liquidity * Q96) / p.sqrtPriceX96; // token0
  const y = (p.liquidity * p.sqrtPriceX96) / Q96; // token1
  const dx = (amountIn * (FEE_DENOM - BigInt(p.fee))) / FEE_DENOM;
  const [rin, rout] = zeroForOne ? [x, y] : [y, x];
  return { out: (rout * dx) / (rin + dx), thin: amountIn * THIN_DIVISOR > rin };
}

/** {@link estimateHopDetail}'s output. */
export function estimateHop(p: GraphPool, tokenIn: Address, amountIn: bigint): bigint | undefined {
  return estimateHopDetail(p, tokenIn, amountIn)?.out;
}

/** A path's estimate hop by hop: the output and whether any hop is thin; `undefined` when a hop's pool state is unknown. */
export function estimatePathDetail(path: RoutePath, edges: readonly GraphPool[], amountIn: bigint): { out: bigint; thin: boolean } | undefined {
  const venues = pathVenues(path);
  let amt = amountIn;
  let thin = false;
  for (let i = 0; i < path.fees.length; i++) {
    const k = poolKey(path.tokens[i]!, path.tokens[i + 1]!, path.fees[i]!, venues[i]!);
    const p = edges.find((e) => poolKey(e.tokenA, e.tokenB, e.fee, e.venue) === k);
    if (!p) return undefined;
    const o = estimateHopDetail(p, path.tokens[i]!, amt);
    if (o === undefined) return undefined;
    amt = o.out;
    thin ||= o.thin;
  }
  return { out: amt, thin };
}

/** A path's estimated output ({@link estimatePathDetail}). */
export function estimatePath(path: RoutePath, edges: readonly GraphPool[], amountIn: bigint): bigint | undefined {
  return estimatePathDetail(path, edges, amountIn)?.out;
}

/** The best estimated output tokenIn → tokenOut over the graph (e.g. RBTC in a token, for the hop penalty); thin paths only when nothing else exists. */
export function estimateBest(edges: readonly GraphPool[], tokenIn: Address, tokenOut: Address, amountIn: bigint, o: { maxHops: number; hubs: readonly Address[] }): bigint | undefined {
  if (eq(tokenIn, tokenOut)) return amountIn;
  let best: bigint | undefined;
  let thinBest: bigint | undefined;
  for (const p of enumeratePaths(edges, tokenIn, tokenOut, { ...o, cap: 64 })) {
    const e = estimatePathDetail(p, edges, amountIn);
    if (e === undefined) continue;
    if (!e.thin && (best === undefined || e.out > best)) best = e.out;
    if (e.thin && (thinBest === undefined || e.out > thinBest)) thinBest = e.out;
  }
  return best ?? thinBest;
}

/**
 * The paths worth a real quote: ranked by estimated output (for `amountIn`) less
 * `hopPenalty` per hop beyond the first (the measured gas of an extra hop, in output
 * units), the best `k` — always including the best-estimated single hop, every path
 * whose state is unknown and is a single hop (a configured pool: the legacy behaviour)
 * and every `forced` path (ROUTE_PATHS). A THIN path ({@link THIN_DIVISOR}) is taken
 * only when no other path has an estimate: its estimate is not to be trusted and its
 * quote can cost millions of gas. Deduplicated; the estimate order is kept.
 */
export function selectPaths(
  paths: readonly RoutePath[],
  edges: readonly GraphPool[],
  amountIn: bigint,
  o: { k: number; hopPenalty?: bigint; forced?: readonly RoutePath[] },
): RoutePath[] {
  const penalty = o.hopPenalty ?? 0n;
  const scored = paths.map((p, i) => {
    const e = estimatePathDetail(p, edges, amountIn);
    return { p, i, est: e?.out, thin: e?.thin ?? false, net: e === undefined ? undefined : e.out - BigInt(p.fees.length - 1) * penalty };
  });
  const byNet = (a: (typeof scored)[number], b: (typeof scored)[number]) => (a.net === b.net ? a.i - b.i : a.net! > b.net! ? -1 : 1);
  const usable = scored.filter((s) => s.net !== undefined && (s.est ?? 0n) > 0n);
  const sound = usable.filter((s) => !s.thin).sort(byNet);
  const ranked = sound.length ? sound : usable.filter((s) => s.thin).sort(byNet);
  const picked = new Map<string, RoutePath>();
  const take = (p: RoutePath) => void (picked.has(pathKey(p)) ? undefined : picked.set(pathKey(p), p));
  const bestSingle = ranked.find((s) => s.p.fees.length === 1);
  if (bestSingle) take(bestSingle.p);
  for (const s of ranked) {
    if (picked.size >= Math.max(o.k, 1)) break;
    take(s.p);
  }
  for (const s of scored) if (s.est === undefined && s.p.fees.length === 1) take(s.p);
  for (const p of o.forced ?? []) take(p);
  return [...picked.values()];
}

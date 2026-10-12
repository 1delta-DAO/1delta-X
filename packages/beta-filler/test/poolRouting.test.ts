import {
  AGGREGATOR_FILL_SOLVER_ABI,
  NO_PATCH,
  OrderSide,
  POOL_ROUTE,
  ROOTSTOCK_POOL_VENUES,
  decodePoolRoute,
  encodePoolRoute,
  v3PoolAddress,
  withDeltaVerifyOutputs,
  type Order,
} from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, getAddress, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { loadConfig, parsePaths, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { Budget } from "../src/policy";
import {
  activePools,
  discoverPools,
  enumeratePaths,
  estimateHop,
  estimatePathDetail,
  graphEdges,
  graphFromState,
  graphToState,
  pathKey,
  pathVenues,
  selectPaths,
  THIN_DIVISOR,
  type GraphPool,
} from "../src/poolGraph";
import { isRevert, quotePaths, QUOTES_PER_CALL } from "../src/poolQuote";
import { buildPoolPlan, extraHopGas, pathLabel, POOL_HOP_GAS, poolRouteGasUnits, rankRoutes, routePaths, validatePoolPlan } from "../src/route";
import { ROUTE_FILLS, RouteFiller } from "../src/routeFiller";
import { MemoryStateStore } from "../src/state";
import { aggregate3 } from "./multicallShim";

const WRBTC = getAddress(ROOTSTOCK.wrbtc);
const USDT0 = getAddress(ROOTSTOCK.usdt0);
const WETH = getAddress(ROOTSTOCK.weth);
const USDRIF = getAddress(ROOTSTOCK.usdrif);
const RIF = getAddress(ROOTSTOCK.rif);
const DOC = getAddress(ROOTSTOCK.doc);
const MC = getAddress(ROOTSTOCK.multicall3);
const OKU = ROOTSTOCK_POOL_VENUES[0]!;
const SUSHI = ROOTSTOCK_POOL_VENUES[1]!;
const VENUES = new Map([
  [0, OKU],
  [1, SUSHI],
]);
const QUOTER_OKU = getAddress(ROOTSTOCK.quoterV2);
const QUOTER_SUSHI = getAddress(ROOTSTOCK.sushiV3Quoter);
const QUOTERS = new Map<number, Address>([
  [0, QUOTER_OKU],
  [1, QUOTER_SUSHI],
]);

// ─────────────────────────── a synthetic market ───────────────────────────
//
// Every pool prices at the tokens' USD values less its own haircut (ppm). Quoting is
// exact-in forward / exact-out backward per hop, each hop on its venue, 80k gas a hop.

const DEC: Record<string, number> = { [WRBTC]: 18, [USDT0]: 6, [WETH]: 18, [USDRIF]: 18, [RIF]: 18, [DOC]: 18 };
/** USD per whole token, 1e6-scaled. */
const USD: Record<string, bigint> = { [WRBTC]: 100_000_000_000n, [USDT0]: 1_000_000n, [WETH]: 3_000_000_000n, [USDRIF]: 1_000_000n, [RIF]: 40_000n, [DOC]: 1_000_000n };
const HOP_GAS = 80_000n;

interface MPool {
  a: Address;
  b: Address;
  fee: number;
  venue: number;
  haircutPpm: bigint;
  liquidity?: bigint;
}

const isqrt = (n: bigint): bigint => {
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
};
/** sqrt(token1 raw per token0 raw) × 2^96 at the USD prices. */
function sqrtPriceX96(a: Address, b: Address): bigint {
  const [t0, t1] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  // price = USD0 × 10^d1 / (USD1 × 10^d0); sqrt(price) × 2^96 = sqrt(price × 2^192)
  return isqrt((USD[t0]! * 10n ** BigInt(DEC[t1]!) * (1n << 192n)) / (USD[t1]! * 10n ** BigInt(DEC[t0]!)));
}

function market(pools: MPool[]) {
  const find = (x: string, y: string, fee: number, venue: number) =>
    pools.find((p) => p.fee === fee && p.venue === venue && ((p.a.toLowerCase() === x.toLowerCase() && p.b.toLowerCase() === y.toLowerCase()) || (p.a.toLowerCase() === y.toLowerCase() && p.b.toLowerCase() === x.toLowerCase())));
  const fwd = (tin: string, tout: string, amt: bigint, p: MPool) =>
    (amt * USD[getAddress(tin)]! * 10n ** BigInt(DEC[getAddress(tout)]!) * (1_000_000n - p.haircutPpm)) / (USD[getAddress(tout)]! * 10n ** BigInt(DEC[getAddress(tin)]!) * 1_000_000n);
  const bwd = (tin: string, tout: string, amtOut: bigint, p: MPool) => {
    const num = amtOut * USD[getAddress(tout)]! * 10n ** BigInt(DEC[getAddress(tin)]!) * 1_000_000n;
    const den = USD[getAddress(tin)]! * 10n ** BigInt(DEC[getAddress(tout)]!) * (1_000_000n - p.haircutPpm);
    return (num + den - 1n) / den;
  };
  const venueOf = (q: Address) => (q.toLowerCase() === QUOTER_OKU.toLowerCase() ? 0 : 1);
  const decodePath = (path: Hex) => {
    const hex = path.slice(2);
    const tokens: string[] = [];
    const fees: number[] = [];
    for (let at = 0; ; ) {
      tokens.push(`0x${hex.slice(at, at + 40)}`);
      at += 40;
      if (at >= hex.length) break;
      fees.push(parseInt(hex.slice(at, at + 6), 16));
      at += 6;
    }
    return { tokens, fees };
  };
  const calls: Array<{ quoter: Address; fn: string; amount: bigint; tokenIn?: string; tokenOut?: string }> = [];
  const quote = (address: Address, functionName: string, args: readonly unknown[]): unknown => {
    const venue = venueOf(address);
    if (functionName === "quoteExactInputSingle" || functionName === "quoteExactOutputSingle") {
      const p = args[0] as { tokenIn: string; tokenOut: string; amountIn?: bigint; amount?: bigint; fee: number };
      const pool = find(p.tokenIn, p.tokenOut, p.fee, venue);
      const amount = (p.amountIn ?? p.amount)!;
      calls.push({ quoter: address, fn: functionName, amount, tokenIn: p.tokenIn, tokenOut: p.tokenOut });
      if (!pool) throw new Error("execution reverted: no pool");
      const out = functionName === "quoteExactInputSingle" ? fwd(p.tokenIn, p.tokenOut, amount, pool) : bwd(p.tokenIn, p.tokenOut, amount, pool);
      return [out, 0n, 0, HOP_GAS];
    }
    const { tokens, fees } = decodePath(args[0] as Hex);
    let amt = args[1] as bigint;
    calls.push({ quoter: address, fn: functionName, amount: amt, tokenIn: tokens[0], tokenOut: tokens[tokens.length - 1] });
    // quoteExactInput: tokens in swap order; quoteExactOutput: REVERSED (tokenOut first).
    for (let i = 0; i < fees.length; i++) {
      const pool = find(tokens[i]!, tokens[i + 1]!, fees[i]!, venue);
      if (!pool) throw new Error("execution reverted: no pool");
      amt = functionName === "quoteExactInput" ? fwd(tokens[i]!, tokens[i + 1]!, amt, pool) : bwd(tokens[i + 1]!, tokens[i]!, amt, pool);
    }
    return [amt, [], [], HOP_GAS * BigInt(fees.length)];
  };
  /** factory.getPool / liquidity / slot0 for the shim; `bad` = getPool answers a non-CREATE2 address there. */
  const view = (o: { bad?: string; reads: Record<string, number> }) => (address: Address, functionName: string, args: readonly unknown[]) => {
    o.reads[functionName] = (o.reads[functionName] ?? 0) + 1;
    if (functionName === "getPool") {
      const [x, y, fee] = args as [Address, Address, number];
      const venue = address.toLowerCase() === OKU.factory.toLowerCase() ? 0 : 1;
      const p = find(x, y, fee, venue);
      if (!p) return zeroAddress;
      const k = `${venue}-${fee}-${[x, y].map((t) => t.toLowerCase()).sort().join("-")}`;
      if (o.bad === k) return "0x000000000000000000000000000000000000bad1";
      return v3PoolAddress(VENUES.get(venue)!, x, y, fee);
    }
    const p = pools.find((q) => v3PoolAddress(VENUES.get(q.venue)!, q.a, q.b, q.fee).toLowerCase() === address.toLowerCase());
    if (!p) throw new Error("no pool");
    if (functionName === "liquidity") return p.liquidity ?? 10n ** 24n;
    if (functionName === "slot0") return [sqrtPriceX96(p.a, p.b), 0];
    throw new Error(`unexpected ${functionName}`);
  };
  return { quote, view, calls, fwd };
}

const badKey = (venue: number, fee: number, x: Address, y: Address) => `${venue}-${fee}-${[x, y].map((t) => t.toLowerCase()).sort().join("-")}`;

/** A BatchClient + QuoteClient over a market: aggregate3 through the shim, quotes by simulateContract. */
function client(m: ReturnType<typeof market>, o: { bad?: string; failMulticall?: "network" | "nodata" } = {}) {
  const reads: Record<string, number> = {};
  let aggregates = 0;
  let singles = 0;
  const v = m.view({ ...(o.bad ? { bad: o.bad } : {}), reads });
  const c = {
    readContract: async ({ functionName, args }: { functionName: string; args: readonly unknown[] }) => {
      if (functionName !== "aggregate3") throw new Error(`unexpected ${functionName}`);
      aggregates++;
      if (o.failMulticall === "network") throw new Error("HTTP request failed. Status: 429");
      if (o.failMulticall === "nodata") throw Object.assign(new Error('The contract function "aggregate3" returned no data ("0x").'), { name: "ContractFunctionZeroDataError" });
      return aggregate3(args[0] as never, async (call) => (call.functionName.startsWith("quote") ? m.quote(call.address, call.functionName, call.args) : v(call.address, call.functionName, call.args)));
    },
    simulateContract: async ({ address, functionName, args }: { address: Address; functionName: string; args: readonly unknown[] }) => {
      singles++;
      return { result: m.quote(address, functionName, args) };
    },
  };
  return { c, reads, counts: () => ({ aggregates, singles }) };
}

const P = (a: Address, b: Address, fee: number, venue: number, haircutPpm = 3_000n, liquidity?: bigint): MPool => ({ a, b, fee, venue, haircutPpm, ...(liquidity !== undefined ? { liquidity } : {}) });

/** The live Rootstock graph's shape (2026-10-12): WRBTC/USDT0 on both venues, the RIF hub, USDRIF only against USD₮0. */
const LIVE_SHAPE = (): MPool[] => [
  P(WRBTC, USDT0, 3000, 0),
  P(WRBTC, USDT0, 3000, 1, 3_200n),
  P(WRBTC, USDT0, 500, 0, 500n, 0n), // exists, no in-range liquidity
  P(WETH, WRBTC, 3000, 0),
  P(WETH, WRBTC, 3000, 1),
  P(WRBTC, RIF, 3000, 0),
  P(WRBTC, RIF, 3000, 1, 2_000n),
  P(RIF, USDT0, 3000, 0),
  P(USDRIF, USDT0, 500, 0, 500n),
  P(USDRIF, USDT0, 100, 0, 200n),
  P(USDT0, DOC, 3000, 0),
];

const discover = (c: ReturnType<typeof client>["c"], prev?: Parameters<typeof discoverPools>[1]["previous"], tokens = [WRBTC, USDT0, WETH, USDRIF, RIF, DOC]) =>
  discoverPools(c, { tokens, feeTiers: [100, 500, 3000, 10000], venues: VENUES, multicall: MC, now: 1_000, ...(prev ? { previous: prev } : {}) });

describe("pool discovery", () => {
  it("finds every pool via factory.getPool, reads liquidity + slot0, and keeps only nonzero (≥ min) liquidity as active", async () => {
    const m = market(LIVE_SHAPE());
    const { c, reads, counts } = client(m);
    const d = await discover(c);
    expect(d.warnings).toEqual([]);
    expect(d.graph.pools).toHaveLength(11);
    // 15 pairs × 4 fees × 2 venues = 120 getPool reads in ONE eth_call; then 11 × 2 state reads in one more.
    expect(reads.getPool).toBe(120);
    expect(reads.liquidity).toBe(11);
    expect(reads.slot0).toBe(11);
    expect(counts().aggregates).toBe(2);
    expect(d.rpcCalls).toBe(2);
    for (const p of d.graph.pools) expect(p.pool).toBe(v3PoolAddress(VENUES.get(p.venue)!, p.tokenA, p.tokenB, p.fee));
    const active = activePools(d.graph, 1n);
    expect(active).toHaveLength(10); // the zero-liquidity WRBTC/USDT0 0.05 % pool is out
    expect(active.some((p) => p.fee === 500 && p.tokenA === WRBTC)).toBe(false);
    expect(activePools(d.graph, 10n ** 25n)).toHaveLength(0); // ROUTE_MIN_LIQUIDITY above every pool
  });

  it("skips (and warns about) a pool whose getPool address is not the solver's CREATE2 derivation", async () => {
    const m = market(LIVE_SHAPE());
    const { c } = client(m, { bad: badKey(1, 3000, WRBTC, USDT0) });
    const d = await discover(c);
    expect(d.graph.pools).toHaveLength(10);
    expect(d.graph.pools.some((p) => p.venue === 1 && p.fee === 3000 && [p.tokenA, p.tokenB].includes(USDT0) && [p.tokenA, p.tokenB].includes(WRBTC))).toBe(false);
    expect(d.warnings.join("\n")).toMatch(/venue 1 .* fee 3000: factory.getPool = 0x000000000000000000000000000000000000[bB][aA][dD]1 but the solver derives 0x[0-9a-fA-F]{40} \(CREATE2\) — skipped/);
  });

  it("is incremental: a refresh looks up only the slots not found before and re-reads every known pool's state", async () => {
    const m = market(LIVE_SHAPE());
    const first = client(m);
    const d1 = await discover(first.c);
    const again = client(m);
    const d2 = await discover(again.c, d1.graph);
    expect(again.reads.getPool).toBe(120 - 11);
    expect(again.reads.liquidity).toBe(11);
    expect(d2.graph.pools.map((p) => p.pool).sort()).toEqual(d1.graph.pools.map((p) => p.pool).sort());
    // Other inputs (another token set) → the previous graph is not reused: full lookup.
    const other = client(m);
    await discover(other.c, d1.graph, [WRBTC, USDT0]);
    expect(other.reads.getPool).toBe(8);
  });

  it("an RPC failure throws (the caller keeps its old graph); the graph survives a JSON round trip", async () => {
    const m = market(LIVE_SHAPE());
    await expect(discover(client(m, { failMulticall: "network" }).c)).rejects.toThrow(/429/);
    const d = await discover(client(m).c);
    const back = graphFromState(JSON.parse(JSON.stringify(graphToState(d.graph))));
    expect(back).toEqual(d.graph);
    expect(graphFromState({ at: 1, key: "k", pools: [{ a: "nope", b: "x", fee: 1, venue: 0, pool: "y" }] })).toBeUndefined();
  });
});

/** A fully-connected test graph over `tokens` on both venues and two fee tiers, deep liquidity. */
function denseGraph(tokens: Address[]): GraphPool[] {
  const out: GraphPool[] = [];
  for (let i = 0; i < tokens.length; i++)
    for (let j = i + 1; j < tokens.length; j++)
      for (const fee of [500, 3000])
        for (const venue of [0, 1]) out.push({ tokenA: tokens[i]!, tokenB: tokens[j]!, fee, venue, pool: v3PoolAddress(VENUES.get(venue)!, tokens[i]!, tokens[j]!, fee), liquidity: 10n ** 24n, sqrtPriceX96: sqrtPriceX96(tokens[i]!, tokens[j]!) });
  return out;
}

describe("path enumeration", () => {
  const tokens = [WRBTC, USDT0, WETH, USDRIF, RIF, DOC];
  const g = denseGraph(tokens);

  it("simple paths of 1..maxHops through hub tokens only, each hop on any (fee, venue); shorter first", () => {
    const hubs = [USDT0, RIF];
    for (const maxHops of [1, 2, 3]) {
      const ps = enumeratePaths(g, WRBTC, USDRIF, { maxHops, hubs, cap: 10_000 });
      // 4 pools per pair; sequences: direct (1), via 1 hub (2), via 2 hubs in either order (2).
      const expected = [4, 4 + 2 * 16, 4 + 2 * 16 + 2 * 64][maxHops - 1];
      expect(ps).toHaveLength(expected);
      for (const p of ps) {
        expect(p.fees.length).toBeLessThanOrEqual(maxHops);
        expect(p.tokens[0]).toBe(WRBTC);
        expect(p.tokens.at(-1)).toBe(USDRIF);
        expect(new Set(p.tokens.map((t) => t.toLowerCase())).size).toBe(p.tokens.length); // simple
        for (const mid of p.tokens.slice(1, -1)) expect(hubs).toContain(mid);
        expect(pathVenues(p)).toHaveLength(p.fees.length);
      }
      for (let i = 1; i < ps.length; i++) expect(ps[i]!.fees.length).toBeGreaterThanOrEqual(ps[i - 1]!.fees.length);
    }
    // Mixed venues are enumerated, and carry `venues` (no single `venue`).
    const mixed = enumeratePaths(g, WRBTC, USDRIF, { maxHops: 2, hubs: [USDT0] }).find((p) => new Set(pathVenues(p)).size > 1)!;
    expect(mixed.venue).toBeUndefined();
    expect(mixed.venues).toHaveLength(2);
  });

  it("is hard-capped, never exceeds the solver's MAX_POOL_HOPS, and a non-hub never sits in the middle", () => {
    expect(enumeratePaths(g, WRBTC, USDRIF, { maxHops: 3, hubs: tokens, cap: 50 })).toHaveLength(50);
    expect(enumeratePaths(g, WRBTC, USDRIF, { maxHops: 9, hubs: tokens, cap: 100_000 }).every((p) => p.fees.length <= 4)).toBe(true);
    expect(enumeratePaths(g, WRBTC, USDRIF, { maxHops: 3, hubs: [] }).every((p) => p.fees.length === 1)).toBe(true);
    expect(enumeratePaths(g, WRBTC, WRBTC, { maxHops: 3, hubs: tokens })).toEqual([]);
  });

  it("routePaths: configured paths first (reversed when needed, per-hop venues kept), then the graph's, deduplicated", () => {
    const cfgPath = parsePaths(`${USDRIF}>500:0>${USDT0}>3000:1>${WRBTC}`)[0]!;
    expect(cfgPath.venues).toEqual([0, 1]);
    const rc = { pools: [], paths: [cfgPath], maxHops: 2, discovery: { hubTokens: [USDT0] } };
    const ps = routePaths(WRBTC, USDRIF, rc, g);
    expect(pathVenues(ps[0]!)).toEqual([1, 0]); // reversed
    expect(ps[0]!.fees).toEqual([3000, 500]);
    expect(new Set(ps.map(pathKey)).size).toBe(ps.length);
    expect(routePaths(WRBTC, USDRIF, rc)).toHaveLength(1); // no graph: configured only (legacy)
  });

  it("selectPaths: best K by estimate net of the hop penalty, the best single hop always, configured unknowns and forced paths kept", () => {
    const ps = enumeratePaths(g, WRBTC, USDT0, { maxHops: 3, hubs: [RIF, DOC, USDRIF], cap: 10_000 });
    const sel = selectPaths(ps, g, 10n ** 16n, { k: 4 });
    expect(sel).toHaveLength(4);
    expect(sel[0]!.fees).toHaveLength(1); // a direct pool: fewest fees paid
    expect(selectPaths(ps, g, 10n ** 16n, { k: 1 })).toHaveLength(1);
    // An unknown-state configured pool and a forced (ROUTE_PATHS) path ride along.
    const unknown: GraphPool = { tokenA: WRBTC, tokenB: USDT0, fee: 10000, venue: 0, pool: zeroAddress };
    const forced = { tokens: [WRBTC, RIF, DOC, USDT0], fees: [3000, 3000, 3000], venue: 1 };
    const sel2 = selectPaths([...ps, { tokens: [WRBTC, USDT0], fees: [10000], venue: 0 }], [...g, unknown], 10n ** 16n, { k: 2, forced: [forced] });
    expect(sel2.map(pathKey)).toContain(pathKey({ tokens: [WRBTC, USDT0], fees: [10000], venue: 0 }));
    expect(sel2.map(pathKey)).toContain(pathKey(forced));
    expect(sel2).toHaveLength(4);
  });

  it("a hop penalty (one extra hop's gas in output units) pushes multi-hop paths down the order", () => {
    // Two routes of equal estimated output: 1 hop at 1 % haircut-equivalent fee vs 2 hops at 0.05 % each.
    const g2: GraphPool[] = [
      { tokenA: WRBTC, tokenB: USDT0, fee: 10000, venue: 0, pool: zeroAddress, liquidity: 10n ** 24n, sqrtPriceX96: sqrtPriceX96(WRBTC, USDT0) },
      { tokenA: WRBTC, tokenB: RIF, fee: 500, venue: 1, pool: zeroAddress, liquidity: 10n ** 30n, sqrtPriceX96: sqrtPriceX96(WRBTC, RIF) },
      { tokenA: RIF, tokenB: USDT0, fee: 500, venue: 0, pool: zeroAddress, liquidity: 10n ** 30n, sqrtPriceX96: sqrtPriceX96(RIF, USDT0) },
    ];
    const ps = enumeratePaths(g2, WRBTC, USDT0, { maxHops: 2, hubs: [RIF] });
    expect(ps).toHaveLength(2);
    const two = estimatePathDetail(ps[1]!, g2, 10n ** 16n)!.out;
    const one = estimatePathDetail(ps[0]!, g2, 10n ** 16n)!.out;
    expect(two).toBeGreaterThan(one);
    expect(selectPaths(ps, g2, 10n ** 16n, { k: 2 })[1]!.fees).toHaveLength(2);
    // k = 1 keeps the best single hop; with a penalty bigger than the 2-hop's edge it ranks below the 1-hop.
    expect(selectPaths(ps, g2, 10n ** 16n, { k: 3, hopPenalty: two - one + 1n }).map((p) => p.fees.length)).toEqual([1, 2]);
  });

  it("estimateHop is the in-range constant-product on virtual reserves; a hop above 1/THIN_DIVISOR of them is THIN and only quoted when nothing else exists", () => {
    const deep: GraphPool = { tokenA: WRBTC, tokenB: USDT0, fee: 3000, venue: 0, pool: zeroAddress, liquidity: 4_042_750_141_251_367n, sqrtPriceX96: sqrtPriceX96(WRBTC, USDT0) };
    // 0.01 WRBTC at $100k ≈ 1000 USD₮0 less 0.3 % and a little impact.
    const out = estimateHop(deep, WRBTC, 10n ** 16n)!;
    expect(out).toBeGreaterThan(996_000_000n);
    expect(out).toBeLessThan(997_000_000n);
    expect(estimateHop({ ...deep, liquidity: undefined }, WRBTC, 1n)).toBeUndefined();
    const thin: GraphPool = { tokenA: WRBTC, tokenB: RIF, fee: 500, venue: 0, pool: zeroAddress, liquidity: 10n ** 15n, sqrtPriceX96: sqrtPriceX96(WRBTC, RIF) };
    const rifUsdt0: GraphPool = { tokenA: RIF, tokenB: USDT0, fee: 3000, venue: 0, pool: zeroAddress, liquidity: 10n ** 24n, sqrtPriceX96: sqrtPriceX96(RIF, USDT0) };
    const viaThin = { tokens: [WRBTC, RIF, USDT0], fees: [500, 3000], venue: 0 };
    expect(estimatePathDetail(viaThin, [thin, rifUsdt0], 10n ** 16n)!.thin).toBe(true);
    expect(THIN_DIVISOR).toBe(10n);
    const direct = { tokens: [WRBTC, USDT0], fees: [3000], venue: 0 };
    expect(selectPaths([viaThin, direct], [thin, rifUsdt0, deep], 10n ** 16n, { k: 5 }).map(pathKey)).toEqual([pathKey(direct)]);
    expect(selectPaths([viaThin], [thin, rifUsdt0], 10n ** 16n, { k: 5 }).map(pathKey)).toEqual([pathKey(viaThin)]); // the only way
  });
});

describe("mixed-venue quoting (QuoterV2 per hop)", () => {
  const m = () => market([P(USDRIF, USDT0, 500, 0, 500n), P(USDT0, RIF, 3000, 0), P(RIF, WRBTC, 3000, 1, 2_000n), P(USDT0, WRBTC, 3000, 0), P(USDT0, WRBTC, 3000, 1, 3_200n)]);
  const mixed = { tokens: [USDRIF, USDT0, RIF, WRBTC], fees: [500, 3000, 3000], venues: [0, 0, 1] };
  const single = { tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venue: 0 };

  it("forward: quoteExactInputSingle hop by hop on each hop's venue, each hop's output the next one's input, gas summed", async () => {
    const mk = m();
    const { c } = client(mk);
    const [q] = await quotePaths(c, QUOTERS, undefined, [mixed], 100n * 10n ** 18n, "in");
    expect(mk.calls.map((x) => [x.fn, x.quoter, x.tokenIn, x.tokenOut])).toEqual([
      ["quoteExactInputSingle", QUOTER_OKU, USDRIF, USDT0],
      ["quoteExactInputSingle", QUOTER_OKU, USDT0, RIF],
      ["quoteExactInputSingle", QUOTER_SUSHI, RIF, WRBTC],
    ]);
    expect(mk.calls[1]!.amount).toBe(mk.fwd(USDRIF, USDT0, 100n * 10n ** 18n, P(USDRIF, USDT0, 500, 0, 500n)));
    expect(q).toEqual({ ok: true, amount: expect.any(BigInt), gasUnits: 3n * HOP_GAS });
    // The chained figure equals the product of the three hops.
    let x = 100n * 10n ** 18n;
    x = mk.fwd(USDRIF, USDT0, x, P(USDRIF, USDT0, 500, 0, 500n));
    x = mk.fwd(USDT0, RIF, x, P(USDT0, RIF, 3000, 0));
    x = mk.fwd(RIF, WRBTC, x, P(RIF, WRBTC, 3000, 1, 2_000n));
    expect((q as { amount: bigint }).amount).toBe(x);
  });

  it("backward (exact-output, direct fills): quoteExactOutputSingle from the LAST hop, each hop's required input the previous hop's output", async () => {
    const mk = m();
    const { c } = client(mk);
    const owed = 10n ** 15n;
    const [q] = await quotePaths(c, QUOTERS, undefined, [mixed], owed, "out");
    expect(mk.calls.map((x) => [x.fn, x.quoter, x.tokenIn, x.tokenOut])).toEqual([
      ["quoteExactOutputSingle", QUOTER_SUSHI, RIF, WRBTC],
      ["quoteExactOutputSingle", QUOTER_OKU, USDT0, RIF],
      ["quoteExactOutputSingle", QUOTER_OKU, USDRIF, USDT0],
    ]);
    expect(mk.calls[0]!.amount).toBe(owed);
    expect(q!.ok && q!.gasUnits).toBe(3n * HOP_GAS);
    // What the backward chain asks for buys at least `owed` going forward.
    const [fw] = await quotePaths(c, QUOTERS, undefined, [mixed], (q as { amount: bigint }).amount, "in");
    expect((fw as { amount: bigint }).amount).toBeGreaterThanOrEqual(owed);
  });

  it("a single-venue path is ONE call: quoteExactInput forward, quoteExactOutput on the reversed path backward", async () => {
    const mk = m();
    const { c } = client(mk);
    await quotePaths(c, QUOTERS, undefined, [single], 10n ** 18n, "in");
    await quotePaths(c, QUOTERS, undefined, [single], 10n ** 15n, "out");
    expect(mk.calls.map((x) => [x.fn, getAddress(x.tokenIn!), getAddress(x.tokenOut!)])).toEqual([
      ["quoteExactInput", USDRIF, WRBTC],
      ["quoteExactOutput", WRBTC, USDRIF],
    ]);
  });

  it("many paths are batched through Multicall3 by ROUND: K paths of ≤ 3 hops cost ≤ 3 rounds, chunks of QUOTES_PER_CALL", async () => {
    const mk = m();
    const cl = client(mk);
    const paths = [mixed, single, { ...single, venues: [0, 1] }, { tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venue: 1 }];
    const qs = await quotePaths(cl.c, QUOTERS, MC, paths, 10n ** 18n, "in");
    expect(qs.map((q) => q.ok)).toEqual([true, true, true, false]); // no USDRIF pool on venue 1
    expect((qs[3] as { transient: boolean }).transient).toBe(false); // a revert says something about the path
    // Round 0: 4 calls in 1 Multicall3 chunk (the failed venue-1 call is re-run alone once:
    // an out-of-gas neighbour might have starved it); round 1: the two mixed paths' second
    // hops (1 chunk); round 2: the 3-hop's last — a lone call goes out as a plain eth_call.
    expect(cl.counts()).toEqual({ aggregates: 2, singles: 2 });
    expect(QUOTES_PER_CALL).toBe(4);
  });

  it("a Multicall3 call that runs out of gas (no data) re-runs its quotes one by one; a network failure is transient", async () => {
    const mk = m();
    const oog = client(mk, { failMulticall: "nodata" });
    const qs = await quotePaths(oog.c, QUOTERS, MC, [single, single], 10n ** 18n, "in");
    expect(qs.every((q) => q.ok)).toBe(true);
    expect(oog.counts().singles).toBe(2);
    const net = client(mk, { failMulticall: "network" });
    const qn = await quotePaths(net.c, QUOTERS, MC, [single, single], 10n ** 18n, "in");
    expect(qn.every((q) => !q.ok && q.transient)).toBe(true);
    expect(net.counts().singles).toBe(0);
    // A venue with no quoter is refused up front (not transient, no call).
    const [nv] = await quotePaths(client(mk).c, new Map([[0, QUOTER_OKU]]), MC, [mixed], 1n, "in");
    expect(nv).toEqual({ ok: false, transient: false, reason: "venue 1 is not routable" });
    expect(isRevert(Object.assign(new Error('The contract function "x" returned no data ("0x").'), { name: "ContractFunctionZeroDataError" }))).toBe(true);
  });
});

describe("ranking: an extra hop must earn its gas", () => {
  it("poolRouteGasUnits floors a pool path at POOL_HOP_GAS per hop; extraHopGas prices each hop beyond the first", () => {
    expect(POOL_HOP_GAS).toBe(65_000n);
    expect(poolRouteGasUnits(1, 78_452n)).toBe(78_452n);
    expect(poolRouteGasUnits(2, 100_000n)).toBe(130_000n);
    expect(extraHopGas(1)).toBe(0n);
    expect(extraHopGas(3)).toBe(130_000n);
  });

  it("rankRoutes prefers the 2-hop route only when its output beats the 1-hop's by more than the extra hop's gas", () => {
    const gasPerUnit = 5n; // output units per gas unit
    const cand = (out: bigint, hops: number, quoterGas: bigint) => ({ source: "pool" as const, hops, out, routeGasOut: poolRouteGasUnits(hops, quoterGas) * gasPerUnit });
    const one = cand(1_000_000_000n, 1, 80_000n);
    const extra = (160_000n - 80_000n) * gasPerUnit; // the 2-hop's extra gas in output units
    expect(rankRoutes([one, cand(one.out + extra - 1n, 2, 160_000n)])[0]!.hops).toBe(1);
    expect(rankRoutes([one, cand(one.out + extra + 1n, 2, 160_000n)])[0]!.hops).toBe(2);
  });
});

describe("pool plans with per-hop venues", () => {
  const order = (over: Partial<Order> = {}): Order => ({
    maker: "0x00000000000000000000000000000000000000bb",
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: 2_000_000_000n,
    legsIn: [{ token: USDRIF, start: 100n * 10n ** 18n, end: 0n }],
    legsOut: [{ token: WRBTC, start: 10n ** 15n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
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
    ...over,
  });
  const path = { tokens: [USDRIF, USDT0, RIF, WRBTC], fees: [500, 3000, 3000], venues: [0, 0, 1] };
  const received = 100n * 10n ** 18n;
  const owed = 10n ** 15n;
  const base = { path, received, owed, quotedOut: 1_200_000_000_000_000n, costOut: 10n ** 12n, profitRecipient: zeroAddress, minBumpBps: 0n };

  it("encodes each hop's venue; decodePoolRoute round-trips it, pull and direct; validatePoolPlan accepts it", () => {
    for (const direct of [false, true]) {
      const { plan } = buildPoolPlan({ ...base, direct });
      const d = decodePoolRoute(plan.data);
      expect(d.tokens.map((t) => getAddress(t))).toEqual(path.tokens);
      expect(d.fees).toEqual(path.fees);
      expect(d.venues).toEqual([0, 0, 1]);
      expect(plan.router).toBe(POOL_ROUTE);
      expect(validatePoolPlan(plan, order(), { direct, path, received, owed })).toEqual({ ok: true, plan });
    }
    // The legacy single-venue shape still encodes the venue on every hop.
    const legacy = buildPoolPlan({ ...base, direct: false, path: { tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venue: 1 } });
    expect(decodePoolRoute(legacy.plan.data).venues).toEqual([1, 1]);
    expect(pathLabel(path)).toBe("oku+sushi-v3");
  });

  it("validatePoolPlan rejects a tampered venue, fee, token or hop count", () => {
    const { plan } = buildPoolPlan({ ...base, direct: false });
    const tamper = (p: Partial<{ tokens: Address[]; fees: number[]; venues: number[] }>) => ({
      ...plan,
      data: encodePoolRoute({ tokens: path.tokens, fees: path.fees, venues: path.venues, amountIn: received, amountOut: 0n, ...p }).data,
    });
    const v = (p: typeof plan) => validatePoolPlan(p, order(), { direct: false, path, received, owed });
    expect(v(tamper({ venues: [0, 0, 0] }))).toMatchObject({ ok: false, reason: expect.stringMatching(/venues 0,0,0 differ from the quoted path's 0,0,1/) });
    expect(v(tamper({ venues: [1, 0, 1] }))).toMatchObject({ ok: false });
    expect(v(tamper({ fees: [500, 3000, 500] }))).toMatchObject({ ok: false, reason: expect.stringMatching(/fees differ/) });
    expect(v(tamper({ tokens: [USDRIF, USDT0, DOC, WRBTC] }))).toMatchObject({ ok: false, reason: expect.stringMatching(/tokens differ/) });
    expect(v(tamper({ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venues: [0, 1] }))).toMatchObject({ ok: false, reason: expect.stringMatching(/tokens differ/) });
    // ...and the quoted path itself must say the same: a path whose venues were swapped after quoting is refused.
    expect(validatePoolPlan(plan, order(), { direct: false, path: { ...path, venues: [0, 1, 1] }, received, owed })).toMatchObject({ ok: false });
  });
});

describe("config: discovery knobs and per-hop ROUTE_PATHS", () => {
  const ENV = {
    PRIVATE_KEY: "0x" + "11".repeat(32),
    SETTLEMENT: "0x0000000000000000000000000000000000000001",
    PERMIT3: "0x0000000000000000000000000000000000000002",
    LENS: "0x0000000000000000000000000000000000000003",
    ORDERBOOK_URL: "http://localhost:8080/",
    AGGREGATOR_SOLVER: "0x00000000000000000000000000000000000050a1",
  };
  it("defaults: discovery on, fees 100/500/3000/10000, hourly, hubs WRBTC/USD₮0/RIF/DOC, Multicall3, ≤3 hops, 5 candidates", () => {
    const rc = loadConfig(ENV).route!;
    expect(rc.discovery).toEqual({ enabled: true, feeTiers: [100, 500, 3000, 10000], minLiquidity: 1n, refreshMs: 3_600_000, hubTokens: [WRBTC, USDT0, RIF, DOC], multicall: MC });
    expect(rc.maxHops).toBe(3);
    expect(rc.maxCandidates).toBe(5);
    expect(loadConfig({ ...ENV, CHAIN_ID: "31" }).route!.discovery).toMatchObject({ hubTokens: [], multicall: undefined });
  });
  it("overrides and fail-closed validation", () => {
    const rc = loadConfig({ ...ENV, ROUTE_DISCOVERY: "0", ROUTE_FEE_TIERS: "500, 3000", ROUTE_MIN_LIQUIDITY: "1000", ROUTE_DISCOVERY_SECONDS: "600", ROUTE_HUB_TOKENS: USDT0, MULTICALL3: "", ROUTE_MAX_HOPS: "4", ROUTE_MAX_CANDIDATES: "8" }).route!;
    expect(rc.discovery).toEqual({ enabled: false, feeTiers: [500, 3000], minLiquidity: 1000n, refreshMs: 600_000, hubTokens: [USDT0], multicall: undefined });
    expect(rc.maxHops).toBe(4);
    expect(rc.maxCandidates).toBe(8);
    expect(() => loadConfig({ ...ENV, ROUTE_MAX_HOPS: "5" })).toThrow(/ROUTE_MAX_HOPS/);
    expect(() => loadConfig({ ...ENV, ROUTE_MAX_HOPS: "0" })).toThrow(/ROUTE_MAX_HOPS/);
    expect(() => loadConfig({ ...ENV, ROUTE_MAX_CANDIDATES: "0" })).toThrow(/ROUTE_MAX_CANDIDATES/);
    expect(() => loadConfig({ ...ENV, ROUTE_FEE_TIERS: "3000,abc" })).toThrow(/ROUTE_FEE_TIERS/);
    expect(() => loadConfig({ ...ENV, ROUTE_HUB_TOKENS: "nope" })).toThrow(/ROUTE_HUB_TOKENS/);
  });
  it("ROUTE_PATHS takes a per-hop `fee:venue`; mixing it with an @venue suffix is refused", () => {
    expect(parsePaths(`${USDRIF}>500:0>${USDT0}>3000:1>${WRBTC}`)).toEqual([{ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venues: [0, 1] }]);
    expect(parsePaths(`${USDRIF}>500:1>${USDT0}>3000:1>${WRBTC}`)).toEqual([{ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venue: 1 }]);
    expect(parsePaths(`${USDRIF}>500>${USDT0}@1`)).toEqual([{ tokens: [USDRIF, USDT0], fees: [500], venue: 1 }]);
    expect(() => parsePaths(`${USDRIF}>500:0>${USDT0}@1`)).toThrow(/mixes a per-hop venue/);
    expect(() => parsePaths(`${USDRIF}>500:x>${USDT0}`)).toThrow(/bad venue/);
  });
});

// ─────────────────────────── RouteFiller end to end ───────────────────────────

describe("RouteFiller: discovered multi-hop, mixed-venue routes", () => {
  const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
  const ACCOUNT = privateKeyToAccount(("0x" + "11".repeat(32)) as Hex);
  const ENV = {
    PRIVATE_KEY: "0x" + "11".repeat(32),
    SETTLEMENT: "0x0000000000000000000000000000000000000001",
    PERMIT3: "0x0000000000000000000000000000000000000002",
    LENS: "0x0000000000000000000000000000000000000003",
    ORDERBOOK_URL: "http://localhost:8080/",
    AGGREGATOR_SOLVER: SOLVER,
    SUSHI_ENABLED: "0",
    DRY_RUN: "0",
    ROUTE_POOLS: "",
    ROUTE_PATHS: "",
  };
  const GAS_PRICE = 60_000_000n;

  function chain(pools: MPool[], w: { received: bigint; owed: bigint }) {
    const mk = market(pools);
    const reads: Record<string, number> = {};
    const v = mk.view({ reads });
    const sent: Hex[] = [];
    let aggregates = 0;
    const pub = {
      getCode: async () => "0x60",
      getGasPrice: async () => GAS_PRICE,
      getTransactionCount: async () => 0,
      sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
        sent.push(parseTransaction(serializedTransaction).data!);
        return keccak256(serializedTransaction);
      },
      getTransactionReceipt: async () => {
        throw new Error("Transaction receipt could not be found");
      },
      getTransaction: async () => ({}),
      readContract: async ({ functionName, address, args }: { functionName: string; address: Address; args?: readonly unknown[] }) => {
        switch (functionName) {
          case "SETTLEMENT": return ENV.SETTLEMENT;
          case "GATED": return true;
          case "isOperator": return true;
          case "SANDBOX": return "0x0000000000000000000000000000000000005a4d";
          case "OWNER": return SOLVER;
          case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
          case "POOL_VENUES": return 2n;
          case "poolVenue": return [args![0] === 0n ? OKU.factory : SUSHI.factory, OKU.initCodeHash];
          case "factory": return address.toLowerCase() === QUOTER_OKU.toLowerCase() ? OKU.factory : SUSHI.factory;
          case "previewFill": return [0n, [w.received], [w.owed]];
          case "previewBump": return 0n;
          case "decimals": return 6;
          case "aggregate3":
            aggregates++;
            return aggregate3(args![0] as never, async (c) => (c.functionName.startsWith("quote") ? mk.quote(c.address, c.functionName, c.args) : v(c.address, c.functionName, c.args)));
        }
        throw new Error(`unexpected read ${functionName}`);
      },
      simulateContract: async ({ address, functionName, args }: { address: Address; functionName: string; args: readonly unknown[] }) => ({ result: mk.quote(address, functionName, args) }),
      call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [w.owed] }) }),
      estimateGas: async () => 300_000n,
    };
    return { mk, reads, sent, aggregates: () => aggregates, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
  }
  const make = (c: unknown, env: Record<string, string> = {}) => {
    const logs: string[] = [];
    const rf = new RouteFiller(loadConfig({ ...ENV, ...env }), c as never, new Budget({ [ROUTE_FILLS]: 60n }), (m) => logs.push(m));
    return { rf, logs };
  };
  const quote = (rf: RouteFiller, tokenIn: Address, tokenOut: Address, amountIn: bigint, direct = false) => rf.quoteRoute({ tokenIn, tokenOut, amountIn, direct, gasPrice: GAS_PRICE });

  it("discovers the graph at start-up (Multicall3) and routes a pair no pool joins directly: USDRIF → WRBTC over two hops", async () => {
    const c = chain(LIVE_SHAPE(), { received: 0n, owed: 0n });
    const { rf, logs } = make(c.chain);
    await rf.init();
    expect(logs.join("\n")).toMatch(/pool graph: 10 active \/ 11 pool\(s\) over 9 tokens × 4 fees × venues oku\+sushi-v3 \(3 eth_call\)/);
    const q = await quote(rf, USDRIF, WRBTC, 100n * 10n ** 18n);
    expect(q).toMatchObject({ ok: true, candidate: { hops: 2, source: "oku" } });
    // Fresh graph: no rediscovery on the next quote.
    const before = c.reads.getPool;
    await quote(rf, USDRIF, WRBTC, 100n * 10n ** 18n);
    expect(c.reads.getPool).toBe(before);
  });

  it("the 1-hop pool wins while a 2-hop route's extra output is below its extra gas; the 2-hop wins once it beats it", async () => {
    // Extra hop in the ranking: (160k − 80k quoter gas) × 60 Mwei × $100k ≈ 0.48 USD₮0 on a 1000 USD₮0 ticket.
    const near = [P(WRBTC, USDT0, 3000, 0, 3_000n), P(WRBTC, RIF, 3000, 1, 1_000n), P(RIF, USDT0, 500, 0, 1_700n)]; // 2-hop +0.3 USD₮0 gross
    const far = [P(WRBTC, USDT0, 3000, 0, 3_000n), P(WRBTC, RIF, 3000, 1, 1_000n), P(RIF, USDT0, 500, 0, 1_000n)]; // 2-hop +1.0 USD₮0 gross
    const a = make(chain(near, { received: 0n, owed: 0n }).chain);
    const qa = await quote(a.rf, WRBTC, USDT0, 10n ** 16n);
    expect(qa).toMatchObject({ ok: true, candidate: { hops: 1, source: "oku" } });
    const b = make(chain(far, { received: 0n, owed: 0n }).chain);
    const qb = await quote(b.rf, WRBTC, USDT0, 10n ** 16n);
    expect(qb).toMatchObject({ ok: true, candidate: { hops: 2, source: "sushi-v3+oku" } });
    // ...and the quote's gas carries the extra hop.
    if (qa.ok && qb.ok) expect(qb.candidate.gasUnits).toBeGreaterThan(qa.candidate.gasUnits);
  });

  it("a PULL fill sends the winning mixed-venue path as a pool plan whose venues match per hop — on a COLD start (no init, no graph yet)", async () => {
    // 3 hops (0.2 % in fees) vs 2 hops (1.05 %): +0.85 % ≈ 8.3e-6 WRBTC, above the extra hop's
    // 80k gas × 60 Mwei = 4.8e-6 WRBTC. (At 6.5 k ppm on the 2-hop the edge is 4.4e-6 — the 2-hop wins.)
    const pools = [P(USDRIF, USDT0, 500, 0, 500n), P(USDT0, RIF, 3000, 0, 1_000n), P(RIF, WRBTC, 3000, 1, 500n), P(USDT0, WRBTC, 3000, 0, 10_000n)];
    const received = 100n * 10n ** 18n;
    const c = chain(pools, { received, owed: 900_000_000_000_000n }); // owed 0.0009 WRBTC (quote ≈ 0.00098)
    const { rf } = make(c.chain);
    const o = {
      maker: "0x00000000000000000000000000000000000000bb" as Address, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
      legsIn: [{ token: USDRIF, start: received, end: 0n }], legsOut: [{ token: WRBTC, start: 900_000_000_000_000n, end: 0n, recipient: zeroAddress }],
      timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [], gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n,
      items: [], validators: [], invariants: [], fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
    } as Order;
    const e = { orderHash: ("0x" + "0c".repeat(32)) as Hex, announce: { order: o, sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: received, validatorsPass: true } };
    // No configured pool joins USDRIF/WRBTC: before the graph is loaded the pair is not
    // refused (accepts), and consider loads the solver + graph before classifying.
    expect(rf.accepts(e)).toBe(true);
    expect((await rf.consider(e)).status).toBe("pending");
    expect(rf.accepts(e)).toBe(true);
    const noRoute = { ...e, announce: { ...e.announce, order: { ...o, legsOut: [{ ...o.legsOut[0]!, token: WETH }] } } };
    expect(rf.accepts(noRoute)).toBe(false); // graph loaded: USDRIF → WETH has no path in this market
    const plan = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: c.sent[0]! }).args[3] as { router: Address; data: Hex };
    const d = decodePoolRoute(plan.data);
    expect(d.tokens.map((t) => getAddress(t))).toEqual([USDRIF, USDT0, RIF, WRBTC]);
    expect(d.venues).toEqual([0, 0, 1]);
    expect(d.amountOut).toBe(0n);
    expect(d.amountIn).toBe(received);
  });

  it("a DIRECT fill quotes the backward exact-output chain of what it owes, and its input ceiling covers that need", async () => {
    const pools = [P(USDRIF, USDT0, 500, 0, 500n), P(USDT0, RIF, 3000, 0, 1_000n), P(RIF, WRBTC, 3000, 1, 500n)];
    const received = 100n * 10n ** 18n;
    const owed = 900_000_000_000_000n;
    const c = chain(pools, { received, owed });
    const { rf } = make(c.chain);
    const o = {
      maker: "0x00000000000000000000000000000000000000bb" as Address, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
      legsIn: [{ token: USDRIF, start: received, end: 0n }], legsOut: [{ token: WRBTC, start: owed, end: 0n, recipient: zeroAddress }],
      timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [], gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n,
      items: [], validators: [], invariants: [], fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
    } as Order;
    const e = { orderHash: ("0x" + "0d".repeat(32)) as Hex, announce: { order: o, sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: received, validatorsPass: true } };
    expect((await rf.consider(e)).status).toBe("pending");
    // The fill's pool quote was the BACKWARD chain from `owed` on the last hop's venue (Sushi).
    const back = c.mk.calls.filter((x) => x.fn === "quoteExactOutputSingle");
    expect(back[0]).toMatchObject({ quoter: QUOTER_SUSHI, amount: owed, tokenIn: RIF, tokenOut: WRBTC });
    expect(back.map((x) => x.quoter)).toEqual([QUOTER_SUSHI, QUOTER_OKU, QUOTER_OKU]);
    const need = (await rf.quoteExactOut({ tokens: [USDRIF, USDT0, RIF, WRBTC], fees: [500, 3000, 3000], venues: [0, 0, 1] }, owed)).need;
    const plan = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: c.sent[0]! }).args[3] as { data: Hex; amountInOffset: bigint };
    const d = decodePoolRoute(plan.data);
    expect(d.venues).toEqual([0, 0, 1]);
    expect(d.amountOut).toBe(owed);
    expect(plan.amountInOffset).toBe(NO_PATCH);
    expect(d.amountIn).toBeGreaterThanOrEqual(need);
    expect(d.amountIn).toBeLessThan(received);
  });

  it("a failed discovery is not fatal (configured pools still route) and is retried later; the Engine persists the graph", async () => {
    const c = chain(LIVE_SHAPE(), { received: 0n, owed: 0n });
    const { rf, logs } = make(c.chain, { MULTICALL3: "", ROUTE_POOLS: `${WRBTC}/${USDT0}/3000/0` });
    await rf.init();
    expect(logs.join("\n")).toMatch(/pool discovery failed .*ROUTE_POOLS \/ ROUTE_PATHS only.*MULTICALL3 is unset/);
    expect(await quote(rf, WRBTC, USDT0, 10n ** 16n)).toMatchObject({ ok: true, candidate: { hops: 1 } });

    const store = new MemoryStateStore();
    const cfg = loadConfig(ENV);
    const e1 = await Engine.create({ cfg, chain: c.chain, store, log: () => {} });
    await e1.route!.init();
    await e1.save();
    const saved = (await store.get<{ poolGraph?: unknown }>("state"))!.poolGraph;
    expect(saved).toBeDefined();
    const getPools = c.reads.getPool;
    const e2 = await Engine.create({ cfg, chain: c.chain, store, log: () => {} });
    await e2.route!.init(); // fresh persisted graph: no rediscovery
    expect(c.reads.getPool).toBe(getPools);
    expect(activePools(e2.route!.poolGraph, 1n)).toHaveLength(10);
  });
});

// Keep the edges helper honest: configured pools discovery never saw ride along unestimated.
describe("graphEdges", () => {
  it("adds ROUTE_POOLS discovery did not see, drops ones it saw below the floor", () => {
    const g = { at: 0, key: "", pools: [{ tokenA: WRBTC, tokenB: USDT0, fee: 500, venue: 0, pool: zeroAddress, liquidity: 0n, sqrtPriceX96: 1n }] };
    const edges = graphEdges(g, 1n, [
      { tokenA: WRBTC, tokenB: USDT0, fee: 500, venue: 0 },
      { tokenA: WRBTC, tokenB: USDT0, fee: 3000, venue: 1 },
    ]);
    expect(edges).toHaveLength(1);
    expect(edges[0]).toMatchObject({ fee: 3000, venue: 1 });
    expect(edges[0]!.liquidity).toBeUndefined();
  });
});

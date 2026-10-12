import {
  AGGREGATOR_FILL_SOLVER_ABI,
  NO_PATCH,
  OrderSide,
  POOL_ROUTE,
  ROOTSTOCK_POOL_VENUES,
  decodePoolRoute,
  encodeAggregatorExecuteFill,
  encodePoolRoute,
  packTiming,
  v3PoolAddress,
  withBlockClock,
  withDeltaVerifyOutputs,
  withPriorityAuction,
  type Order,
} from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, getAddress, hexToBigInt, keccak256, parseTransaction, sliceHex, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it, vi } from "vitest";

import { loadConfig, parsePaths, parsePools, ROOTSTOCK, ROOTSTOCK_POOLS, VENUE_OKU, VENUE_SUSHI_V3 } from "../src/config";
import { aggregate3 } from "./multicallShim";
import { dispatch, type Strategy } from "../src/dispatch";
import type { FillOutcome } from "../src/filler";
import type { BookEntry } from "../src/intake";
import { Budget } from "../src/policy";
import { ROUTE_FILLS, RouteFiller } from "../src/routeFiller";
import {
  buildPoolPlan,
  candidatePaths,
  classifyRoute,
  mulDivUp,
  nativeToTokenAtQuote,
  nativeToUsdToken,
  grossUp,
  haircutBps,
  liveDecayPerBlock,
  patchesLiveOutput,
  PERMIT_IN_FILL_GAS,
  planGasEstimate,
  planKind,
  rankingGasUnits,
  SANDBOX_ROUTE_OVERHEAD_GAS,
  TYPED_CALLBACK_GAS,
  rankRoutes,
  routeProfitable,
  validatePoolPlan,
  venueName,
} from "../src/route";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const MAKER = "0x00000000000000000000000000000000000000bb" as Address;
const OTHER = "0x00000000000000000000000000000000000000cc" as Address;
const ENV = {
  PRIVATE_KEY: "0x" + "11".repeat(32),
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://localhost:8080/",
  AGGREGATOR_SOLVER: SOLVER,
};
const cfg = loadConfig(ENV);
const rc = cfg.route!;

/** Maker sells 0.01 WRBTC for ≥ 900 USDT0 — the rsk-30-wrbtc-usd0 market. */
function wrbtcOrder(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER,
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.wrbtc, start: 10n ** 16n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: 900_000_000n, end: 0n, recipient: zeroAddress }],
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
  };
}

const word = (data: Hex, off: bigint) => hexToBigInt(sliceHex(data, Number(off), Number(off) + 32));

describe("route config", () => {
  it("is on by default once AGGREGATOR_SOLVER is set, off without it", () => {
    expect(cfg.strategies).toEqual({ inventory: true, route: true });
    const { AGGREGATOR_SOLVER: _, ...noRoute } = ENV;
    expect(loadConfig(noRoute).strategies).toEqual({ inventory: true, route: false });
    expect(() => loadConfig({ ...noRoute, ROUTE_ENABLED: "1" })).toThrow(/AGGREGATOR_SOLVER/);
    expect(loadConfig({ ...ENV, INVENTORY_ENABLED: "0" }).strategies).toEqual({ inventory: false, route: true });
    expect(() => loadConfig({ ...ENV, INVENTORY_ENABLED: "0", ROUTE_ENABLED: "0" })).toThrow(/both/);
  });
  it("enables the Sushi source by default, pinned to Rootstock's RedSnwapper and snwap executor", () => {
    expect(rc.sushi).toEqual({
      enabled: true,
      baseUrl: "https://api.sushi.com",
      router: "0xAC4c6e212A361c968F1725b4d055b47E63F80b75",
      timeoutMs: 4000,
      executors: ["0xC10eE9031F2a0B84766A86B55a8D90F357910fb4"],
      maxPerSweep: 10,
    });
    expect(loadConfig({ ...ENV, SUSHI_ENABLED: "0" }).route!.sushi.enabled).toBe(false);
    expect(rc.okuPull).toBe(true);
    expect(loadConfig({ ...ENV, ROUTE_OKU_PULL: "0" }).route!.okuPull).toBe(false);
    expect(() => loadConfig({ ...ENV, SUSHI_ROUTER: "nope" })).toThrow(/SUSHI_ROUTER/);
  });
  it("defaults to the app's Rootstock Oku pools + SushiSwap v3 WRBTC/USDT0 and RIF/WRBTC (venue 1) and the USDRIF→WRBTC path", () => {
    expect(rc.pools).toEqual(ROOTSTOCK_POOLS);
    expect(rc.pools.map((p) => p.market)).toEqual(["rsk-30-wrbtc-usd0", "rsk-30-weth-wrbtc", "rsk-30-usdrif-usd0", undefined, "rsk-30-rif-usd0", "rsk-30-rif-wrbtc", undefined]);
    expect(rc.pools.map((p) => p.venue)).toEqual([VENUE_OKU, VENUE_OKU, VENUE_OKU, VENUE_SUSHI_V3, VENUE_OKU, VENUE_OKU, VENUE_SUSHI_V3]);
    expect(rc.paths).toHaveLength(1);
    expect(rc.paths[0]!.fees).toEqual([500, 3000]);
    expect(rc.paths[0]!.venue).toBe(0);
    expect(rc.slippageBps).toBe(10n);
    expect(rc.stableSlippageBps).toBe(5n);
    expect(rc.minProfitWei).toBe(0n);
    expect(loadConfig({ ...ENV, ROUTE_STABLE_SLIPPAGE_BPS: "12" }).route!.stableSlippageBps).toBe(12n);
    expect(() => loadConfig({ ...ENV, ROUTE_STABLE_SLIPPAGE_BPS: "10001" })).toThrow(/ROUTE_STABLE_SLIPPAGE_BPS/);
  });
  it("parses ROUTE_PATHS and ROUTE_POOLS, with an optional venue (default 0)", () => {
    const p = parsePaths(`${ROOTSTOCK.weth}>3000>${ROOTSTOCK.wrbtc}>3000>${ROOTSTOCK.usdt0}; `);
    expect(p).toEqual([{ tokens: [ROOTSTOCK.weth, ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000, 3000], venue: 0 }]);
    expect(parsePaths(`${ROOTSTOCK.wrbtc}>3000>${ROOTSTOCK.usdt0}@1`)).toEqual([{ tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000], venue: 1 }]);
    expect(parsePaths("")).toEqual([]);
    expect(() => parsePaths(`${ROOTSTOCK.weth}>3000`)).toThrow();
    expect(() => parsePaths(`${ROOTSTOCK.weth}>x>${ROOTSTOCK.wrbtc}`)).toThrow(/fee/);
    expect(() => parsePaths(`${ROOTSTOCK.wrbtc}>3000>${ROOTSTOCK.usdt0}@x`)).toThrow(/venue/);
    expect(() => parsePaths(`${ROOTSTOCK.wrbtc}>3000>${ROOTSTOCK.usdt0}@256`)).toThrow(/venue/);
    const five = [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif, ROOTSTOCK.usdt0, ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0].join(">3000>");
    expect(() => parsePaths(five)).toThrow(/hops/); // 5 hops > MAX_POOL_HOPS
    expect(parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/500`)).toEqual([
      { tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 500, venue: 0 },
    ]);
    expect(parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/3000/1`)).toEqual([
      { tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 3000, venue: 1 },
    ]);
    expect(() => parsePools("a/b")).toThrow();
    expect(() => parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/3000/-1`)).toThrow(/venue/);
    expect(() => parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/3000/1/2`)).toThrow(/bad pool/);
  });
  it("venue quoters: QUOTER_V2 for venue 0, Rootstock's verified Sushi v3 QuoterV2 for venue 1 (SUSHI_V3_QUOTER, \"\" = none)", () => {
    expect(rc.venueQuoters).toEqual([getAddress(ROOTSTOCK.quoterV2), getAddress(ROOTSTOCK.sushiV3Quoter)]);
    expect(loadConfig({ ...ENV, SUSHI_V3_QUOTER: "" }).route!.venueQuoters).toEqual([getAddress(ROOTSTOCK.quoterV2), undefined]);
    expect(loadConfig({ ...ENV, SUSHI_V3_QUOTER: OTHER }).route!.venueQuoters[1]).toBe(getAddress(OTHER));
    expect(loadConfig({ ...ENV, CHAIN_ID: "31" }).route!.venueQuoters[1]).toBeUndefined(); // no default off Rootstock
    expect(() => loadConfig({ ...ENV, SUSHI_V3_QUOTER: "nope" })).toThrow(/SUSHI_V3_QUOTER/);
  });
  it("every default pool address is the one the solver derives for its venue (CREATE2, SDK v3PoolAddress)", () => {
    for (const p of ROOTSTOCK_POOLS) {
      const derived = v3PoolAddress(ROOTSTOCK_POOL_VENUES[p.venue ?? 0]!, p.tokenA as Address, p.tokenB as Address, p.fee);
      expect(derived.toLowerCase()).toBe(p.pool!.toLowerCase());
    }
  });
});

describe("candidatePaths", () => {
  it("finds a pool in either direction, on every venue that has it", () => {
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, rc)).toEqual([
      { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000], venue: 0 },
      { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000], venue: 1 },
    ]);
    expect(candidatePaths(ROOTSTOCK.usdt0, ROOTSTOCK.weth, rc)).toEqual([]);
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.weth, rc)).toEqual([{ tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.weth], fees: [3000], venue: 0 }]);
  });
  it("uses a configured multi-hop path, reversed when needed (venue kept)", () => {
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.usdrif, rc)).toEqual([
      { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif], fees: [3000, 500], venue: 0 },
    ]);
    const sushiPath = { pools: [], paths: parsePaths(`${ROOTSTOCK.usdrif}>500>${ROOTSTOCK.usdt0}>3000>${ROOTSTOCK.wrbtc}@1`) };
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.usdrif, sushiPath)[0]!.venue).toBe(1);
  });
  it("finds nothing for an unconfigured pair", () => {
    expect(candidatePaths(ROOTSTOCK.weth, ROOTSTOCK.usdrif, rc)).toEqual([]);
  });
});

describe("classifyRoute", () => {
  it("takes an open pull order on a configured pool", () => {
    const v = classifyRoute(wrbtcOrder(), rc);
    expect(v.ok && v.direct).toBe(false);
    expect(v.ok).toBe(true);
  });
  it("takes a delta-verify order naming OUR solver (direct)", () => {
    const v = classifyRoute(wrbtcOrder({ timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }), rc);
    expect(v.ok && v.direct).toBe(true);
  });
  it("takes a pull order naming our solver as exclusive filler", () => {
    expect(classifyRoute(wrbtcOrder({ exclusiveFiller: SOLVER }), rc).ok).toBe(true);
  });
  it("B13: the app's pull-market shape — our solver's soft ~2-block window — is ours, premium-free", () => {
    const now = 1_800_000_000;
    const app = wrbtcOrder({ exclusiveFiller: SOLVER, timing: packTiming(now, 60, now + 60), exclusivityOverrideBps: 5n });
    const v = classifyRoute(app, rc, { nowS: BigInt(now + 1) });
    expect(v.ok && !v.direct).toBe(true);
  });
  it("another filler's window: refused only while it is HARD; a soft one or an ended one is fillable", () => {
    const now = 1_800_000_000;
    const soft = wrbtcOrder({ exclusiveFiller: OTHER, timing: packTiming(0, 0, now + 60), exclusivityOverrideBps: 5n });
    const hard = wrbtcOrder({ exclusiveFiller: OTHER, timing: packTiming(0, 0, now + 60) });
    expect(classifyRoute(soft, rc, { nowS: BigInt(now) }).ok).toBe(true);
    expect(classifyRoute(hard, rc, { nowS: BigInt(now) }).ok).toBe(false);
    expect(classifyRoute(hard, rc, { nowS: BigInt(now + 60) }).ok).toBe(true);
  });
  it.each([
    ["delta-verify for another filler", { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: OTHER }, /another filler/],
    ["delta-verify open (core refuses it anyway)", { timing: withDeltaVerifyOutputs(0n) }, /another filler/],
    ["pull order in another filler's HARD window", { exclusiveFiller: OTHER, timing: packTiming(0, 0, 4_000_000_000) }, /another exclusive/],
    ["same token", { legsOut: [{ token: ROOTSTOCK.wrbtc, start: 1n, end: 0n, recipient: zeroAddress }] }, /same-token/],
    ["third-party recipient", { legsOut: [{ token: ROOTSTOCK.usdt0, start: 1n, end: 0n, recipient: OTHER }] }, /third party/],
    ["fee leg", { legsOut: [wrbtcOrder().legsOut[0]!, { ...wrbtcOrder().legsOut[0]!, recipient: OTHER }] }, /one-in/],
    ["item", { items: [{ op: 0, module: OTHER, amount: 0n, recipient: zeroAddress, data: "0x" as const }] }, /items/],
    ["pricing module", { pricingModule: OTHER }, /modules/],
    ["proportional leg", { legsIn: [{ token: ROOTSTOCK.wrbtc, start: 2n ** 256n - 1n, end: 0n }] }, /proportional/],
  ] as const)("refuses %s", (_n, over, reason) => {
    const v = classifyRoute(wrbtcOrder(over as Partial<Order>), rc);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(reason);
  });
  // Task 08 (2026-10): the tick of these can move maker-ward after the preview, but the
  // plan now carries `minBumpBps` and the solver forwards it to `fillWithCallback`, so
  // such a move reverts `BumpTooLow` on-chain. They were refused until then.
  it.each([
    ["priority auction (bit 103)", { timing: withPriorityAuction(0n) }],
    ["priority auction (scale)", { priorityScale: 1_000_000_000n }],
    ["gas bump", { gasBumpBps: 50n, gasPriceRef: 10n ** 9n }],
    ["custom curve", { curve: [{ timeDelta: 1, bumpBps: 1 }] }],
  ] as const)("admits %s (the plan's minBumpBps floors it on-chain)", (_n, over) => {
    expect(classifyRoute(wrbtcOrder(over as Partial<Order>), rc).ok).toBe(true);
  });
  it("an unrouted pair: refused without Sushi; with Sushi only a PULL order is admitted", () => {
    const doc = { legsOut: [{ token: ROOTSTOCK.doc, start: 1n, end: 0n, recipient: zeroAddress }] };
    const withDoc = { ...rc, routeTokens: [...rc.routeTokens, ROOTSTOCK.doc as Address] };
    const noSushi = { ...withDoc, sushi: { ...rc.sushi, enabled: false } };
    const off = classifyRoute(wrbtcOrder(doc), noSushi);
    expect(off.ok).toBe(false);
    if (!off.ok) expect(off.reason).toMatch(/no configured/);
    const pull = classifyRoute(wrbtcOrder(doc), withDoc);
    expect(pull.ok && pull.paths.length).toBe(0); // admitted, Sushi-only
    const direct = classifyRoute(wrbtcOrder({ ...doc, timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }), withDoc);
    expect(direct.ok).toBe(false); // direct orders use the local Oku path only
  });
  it("ROUTE_TOKENS: with Sushi on, a pair outside the allowlist is refused before any quote (L-6)", () => {
    const doc = { legsOut: [{ token: ROOTSTOCK.doc, start: 1n, end: 0n, recipient: zeroAddress }] };
    expect(rc.routeTokens).toEqual([ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.weth, ROOTSTOCK.usdrif, ROOTSTOCK.rif]);
    expect(rc.sushi.enabled).toBe(true);
    const v = classifyRoute(wrbtcOrder(doc), rc);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(/ROUTE_TOKENS/);
    // An arbitrary unknown token on either side, too.
    const junk = "0x00000000000000000000000000000000000Ba5Ed" as Address;
    expect(classifyRoute(wrbtcOrder({ legsIn: [{ token: junk, start: 1n, end: 0n }] }), rc).ok).toBe(false);
    // Configurable.
    const only = loadConfig({ ...ENV, ROUTE_TOKENS: `${ROOTSTOCK.wrbtc},${ROOTSTOCK.usdt0}` }).route!;
    expect(classifyRoute(wrbtcOrder(), only).ok).toBe(true);
    expect(() => loadConfig({ ...ENV, ROUTE_TOKENS: "nope" })).toThrow(/ROUTE_TOKENS/);
  });
  it("refuses permit-batch and sigless announces", () => {
    expect(classifyRoute(wrbtcOrder(), rc, { hasPermitBatch: true }).ok).toBe(false);
    expect(classifyRoute(wrbtcOrder(), rc, { sigless: true }).ok).toBe(false);
  });
});

describe("liveDecayPerBlock (task 05 threshold)", () => {
  const mk = (start: bigint, end: bigint, decayStart: number, dur: number, blockClock = false) =>
    ({
      legsOut: [{ token: ROOTSTOCK.usdt0, start, end, recipient: zeroAddress }],
      timing: packTiming(decayStart, dur, 0) | (blockClock ? 1n << 102n : 0n),
    }) as never;
  it("one 30 s block of decay, pro rata to owed, rounded down", () => {
    // 1,000 → 900 over 60 s: 30 s is half the span = 50 of 1,000 ⇒ 5 % of owed.
    expect(liveDecayPerBlock(mk(1_000n, 900n, 1_000, 60), 2_000n, 1_010n)).toBe(100n);
  });
  it("capped at what is left of the decay; 0 once it is over or the leg is fixed/rising", () => {
    expect(liveDecayPerBlock(mk(1_000n, 900n, 1_000, 60), 2_000n, 1_050n)).toBe(33n); // 10 s left
    expect(liveDecayPerBlock(mk(1_000n, 900n, 1_000, 60), 2_000n, 1_060n)).toBe(0n);
    expect(liveDecayPerBlock(mk(1_000n, 0n, 1_000, 60), 2_000n, 1_010n)).toBe(0n);
    expect(liveDecayPerBlock(mk(1_000n, 1_100n, 1_000, 60), 2_000n, 1_010n)).toBe(0n);
  });
  it("a block-clock order counts one block of its decay", () => {
    expect(liveDecayPerBlock(mk(1_000n, 900n, 100, 4, true), 2_000n, 0n)).toBe(50n);
  });
});

describe("profitability", () => {
  it("requires quote × (1 − slippage) ≥ owed + gas + min profit", () => {
    // 1,000 USDT0 quoted, 30 bps haircut → 997.
    const base = { quotedOut: 1_000_000_000n, slippageBps: 30n, gasOut: 1_000_000n, minProfitOut: 500_000n };
    const ok = routeProfitable({ ...base, owed: 995_500_000n });
    expect(ok).toEqual({ ok: true, haircutOut: 997_000_000n, requiredOut: 997_000_000n, costOut: 1_500_000n, marginOut: 0n });
    const short = routeProfitable({ ...base, owed: 995_500_001n });
    expect(short.ok).toBe(false);
    if (!short.ok) expect(short.reason).toMatch(/unprofitable/);
    expect(routeProfitable({ ...base, owed: 0n }).ok).toBe(false);
  });
  it("haircuts a $1/$1 pair by the stable bps and every other pair by the default", () => {
    const rc = { slippageBps: 30n, stableSlippageBps: 5n, usdTokens: [ROOTSTOCK.usdt0, ROOTSTOCK.usdrif] as Address[] };
    expect(haircutBps(rc, ROOTSTOCK.usdrif as Address, ROOTSTOCK.usdt0 as Address)).toBe(5n);
    expect(haircutBps(rc, ROOTSTOCK.usdt0.toLowerCase() as Address, ROOTSTOCK.usdrif as Address)).toBe(5n);
    expect(haircutBps(rc, ROOTSTOCK.wrbtc as Address, ROOTSTOCK.usdt0 as Address)).toBe(30n);
    expect(haircutBps(rc, ROOTSTOCK.usdt0 as Address, ROOTSTOCK.wrbtc as Address)).toBe(30n);
  });
  it("fills the app's 300 USDRIF market at its 50 bps floor with the stable haircut (task 15)", () => {
    // The e2e's numbers at the floor: 30 bps missed by 198,764; 5 bps and no min profit clear it.
    const atFloor = { quotedOut: 299_228_774n, owed: 297_732_746n, gasOut: 711_771n };
    expect(routeProfitable({ ...atFloor, slippageBps: 30n, minProfitOut: 85_334n }).ok).toBe(false);
    const ok = routeProfitable({ ...atFloor, slippageBps: 5n, minProfitOut: 0n });
    expect(ok.ok && ok.marginOut).toBe(634_642n);
  });
  it("grosses the cost up for the solver's maker/protocol surplus split (L-4)", () => {
    expect(grossUp(1_500_000n)).toBe(1_500_000n);
    // We keep 80% of the surplus ⇒ the surplus must be cost / 0.8.
    expect(grossUp(1_500_000n, 800_000n)).toBe(1_875_000n);
    expect(grossUp(1n, 3n)).toBe(333_334n); // rounds up
    expect(() => grossUp(1n, 0n)).toThrow();
    const base = { quotedOut: 1_000_000_000n, slippageBps: 30n, gasOut: 1_000_000n, minProfitOut: 500_000n };
    // Passes with no split, fails once 20% of the surplus goes to maker + protocol.
    expect(routeProfitable({ ...base, owed: 995_500_000n }).ok).toBe(true);
    const split = routeProfitable({ ...base, owed: 995_500_000n, keepPpm: 800_000n });
    expect(split.ok).toBe(false);
    const ok = routeProfitable({ ...base, owed: 995_125_000n, keepPpm: 800_000n });
    expect(ok.ok && ok.costOut).toBe(1_875_000n);
  });
  it("converts RBTC gas into the output token, rounding against us", () => {
    // 0.001 RBTC quoted at 100 USDT0 ⇒ 320k gas × 0.06 gwei = 1.92e13 wei = 1.92 USDT0.
    expect(nativeToTokenAtQuote(320_000n * 60_000_000n, 10n ** 15n, 100_000_000n)).toBe(1_920_000n);
    expect(nativeToTokenAtQuote(1n, 10n ** 15n, 100_000_000n)).toBe(1n); // never rounds to free
    // RBTC at $100,000 into a 6-dec $1 token / an 18-dec one.
    expect(nativeToUsdToken(10n ** 13n, 100_000n * 10n ** 18n, 6)).toBe(1_000_000n);
    expect(nativeToUsdToken(10n ** 13n, 100_000n * 10n ** 18n, 18)).toBe(10n ** 18n);
    expect(mulDivUp(7n, 3n, 2n)).toBe(11n);
  });
});

describe("buildPoolPlan (direct pool routes, router = POOL_ROUTE)", () => {
  const received = 10n ** 16n;
  const owed = 900_000_000n;
  const quotedOut = 1_000_000_000n;
  const costOut = 2_000_000n;
  const single = { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0] as Address[], fees: [3000], venue: 0 };
  const multi = { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif] as Address[], fees: [3000, 500], venue: 0 };
  const base = { received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n };
  const directOrder = wrbtcOrder({ timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER });

  it("pull: exact-INPUT of received (amountOut word 0), amountInOffset = the amountIn word, minOut = owed + cost, maxPay = owed", () => {
    const { plan, call } = buildPoolPlan({ ...base, direct: false, path: single });
    expect(plan.router).toBe(POOL_ROUTE);
    expect(plan.minOut).toBe(owed + costOut);
    expect(plan.maxPay).toBe(owed);
    expect(plan.amountInOffset).toBe(0n);
    expect(plan.amountOutOffset).toBe(NO_PATCH);
    expect(call.amountOutOffset).toBe(NO_PATCH);
    const d = decodePoolRoute(plan.data);
    expect(d).toEqual({ amountIn: received, amountOut: 0n, tokens: single.tokens.map((t) => t.toLowerCase()), fees: [3000], venues: [0] });
    expect(word(plan.data, plan.amountInOffset)).toBe(received);
    // The same bytes the SDK encoder produces; the solver accepts the offsets.
    expect(plan.data).toBe(encodePoolRoute({ tokens: single.tokens, fees: [3000], venues: [0], amountIn: received, amountOut: 0n }).data);
    expect(() => encodeAggregatorExecuteFill({ order: wrbtcOrder(), sig: "0x", fillAmount: received, plan })).not.toThrow();
  });

  it("pull, multi-hop on venue 1: every hop carries the path's venue", () => {
    const { plan } = buildPoolPlan({ ...base, direct: false, path: { ...multi, venue: 1 }, profitRecipient: OTHER });
    const d = decodePoolRoute(plan.data);
    expect(d.venues).toEqual([1, 1]);
    expect(d.fees).toEqual([3000, 500]);
    expect(d.tokens[2]).toBe(ROOTSTOCK.usdrif.toLowerCase());
    expect(plan.profitRecipient).toBe(OTHER);
  });

  it("direct: exact-OUTPUT of owed, amountIn word = the input CEILING (received − margin), NO_PATCH on the input; no recipient field", () => {
    const { plan } = buildPoolPlan({ ...base, direct: true, path: single });
    expect(plan.router).toBe(POOL_ROUTE);
    expect(plan.minOut).toBe(0n);
    expect(plan.maxPay).toBe(0n);
    expect(plan.amountInOffset).toBe(NO_PATCH);
    expect(plan.amountOutOffset).toBe(NO_PATCH);
    const d = decodePoolRoute(plan.data);
    expect(d.amountOut).toBe(owed);
    // keep = ceil(2 USDT0 × 0.01 WRBTC / 1,000 USDT0) = 2e-5 WRBTC = 2e13 wei.
    expect(d.amountIn).toBe(received - 2n * 10n ** 13n);
    // Swap order (input first), unlike SwapRouter02's reversed exact-output path.
    expect(d.tokens[0]).toBe(ROOTSTOCK.wrbtc.toLowerCase());
    expect(() => encodeAggregatorExecuteFill({ order: directOrder, sig: "0x", fillAmount: received, plan })).not.toThrow();
  });

  it("carries minBumpBps (the filler's floor) on both paths; no output patch unless asked", () => {
    for (const direct of [false, true]) {
      const { plan } = buildPoolPlan({ ...base, direct, path: single, minBumpBps: 4_321n });
      expect(plan.minBumpBps).toBe(4_321n);
      expect(plan.amountOutOffset).toBe(NO_PATCH);
    }
  });

  it("task 05: a live-output direct plan points amountOutOffset at the amountOut word (32), single + multi hop", () => {
    for (const path of [single, multi]) {
      const { plan } = buildPoolPlan({ ...base, direct: true, path, liveOut: true });
      expect(plan.amountOutOffset).toBe(32n);
      // The word there IS the previewed owed the solver overwrites with pricedOut[0].
      expect(word(plan.data, plan.amountOutOffset)).toBe(owed);
      // The ceiling is unchanged: still sized on the PREVIEWED owed.
      expect(plan.amountInOffset).toBe(NO_PATCH);
      expect(word(plan.data, 0n)).toBe(received - 2n * 10n ** 13n);
      expect(() => encodeAggregatorExecuteFill({ order: directOrder, sig: "0x", fillAmount: received, plan })).not.toThrow();
    }
  });

  it("task 05: liveOut is ignored on the pull path (exact-input: setting it would turn the route exact-output)", () => {
    expect(buildPoolPlan({ ...base, direct: false, path: single, liveOut: true }).plan.amountOutOffset).toBe(NO_PATCH);
  });

  it("a pool plan offset other than 0 / 32 / NO_PATCH is refused before signing (the solver reverts BadPoolRoute)", () => {
    const { plan } = buildPoolPlan({ ...base, direct: true, path: single });
    expect(() => encodeAggregatorExecuteFill({ order: directOrder, sig: "0x", fillAmount: received, plan: { ...plan, amountOutOffset: 64n } })).toThrow(/amountOutOffset/);
    expect(() => encodeAggregatorExecuteFill({ order: directOrder, sig: "0x", fillAmount: received, plan: { ...plan, amountInOffset: 32n } })).toThrow(/amountInOffset/);
  });

  it("refuses a margin larger than the input, and a zero quote", () => {
    expect(() => buildPoolPlan({ ...base, direct: true, path: single, quotedOut: 1n })).toThrow(/margin/);
    expect(() => buildPoolPlan({ ...base, direct: true, path: single, quotedOut: 0n })).toThrow(/zero quote/);
  });
});

describe("validatePoolPlan (pre-send check against the order)", () => {
  const received = 10n ** 16n;
  const owed = 900_000_000n;
  const single = { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0] as Address[], fees: [3000], venue: 0 };
  const base = { received, owed, quotedOut: 1_000_000_000n, costOut: 2_000_000n, profitRecipient: zeroAddress, minBumpBps: 0n };
  const ok = (direct: boolean, path = single) => buildPoolPlan({ ...base, direct, path }).plan;

  it("accepts what buildPoolPlan builds, pull and direct", () => {
    expect(validatePoolPlan(ok(false), wrbtcOrder(), { direct: false, path: single, received, owed }).ok).toBe(true);
    expect(validatePoolPlan(ok(true), wrbtcOrder(), { direct: true, path: single, received, owed }).ok).toBe(true);
  });
  it.each([
    ["a path that does not start at the order's input", () => ok(false, { ...single, tokens: [ROOTSTOCK.usdt0, ROOTSTOCK.wrbtc] as Address[] }), false, /first token/],
    ["a path that does not end at the order's output", () => ok(false, { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif] as Address[], fees: [3000, 500], venue: 0 }), false, /last token/],
    ["another venue than the quoted path's", () => ok(false, { ...single, venue: 1 }), false, /venues/],
    ["a pull plan swapping another amount", () => ({ ...ok(false), data: encodePoolRoute({ tokens: single.tokens, fees: [3000], venues: [0], amountIn: received - 1n, amountOut: 0n }).data }), false, /exact-input/],
    ["a pull plan made exact-output", () => ({ ...ok(false), data: encodePoolRoute({ tokens: single.tokens, fees: [3000], venues: [0], amountIn: received, amountOut: 1n }).data }), false, /exact-input/],
    ["a pull plan with an uncapped payout", () => ({ ...ok(false), maxPay: 0n }), false, /floor\/cap/],
    ["a direct plan paying another amount", () => ({ ...ok(true), data: encodePoolRoute({ tokens: single.tokens, fees: [3000], venues: [0], amountIn: received - 1n, amountOut: owed + 1n }).data }), true, /exactly owed/],
    ["a direct plan whose ceiling is the whole input (no margin)", () => ({ ...ok(true), data: encodePoolRoute({ tokens: single.tokens, fees: [3000], venues: [0], amountIn: received, amountOut: owed }).data }), true, /ceiling/],
    ["a direct plan that patches its ceiling", () => ({ ...ok(true), amountInOffset: 0n }), true, /ceiling/],
    ["another router", () => ({ ...ok(false), router: OTHER }), false, /POOL_ROUTE/],
    ["malformed data", () => ({ ...ok(false), data: "0x1234" as Hex }), false, /malformed/],
  ] as const)("refuses %s", (_n, mk, direct, reason) => {
    const v = validatePoolPlan(mk(), wrbtcOrder(), { direct, path: single, received, owed });
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(reason);
  });
});

describe("plan-kind gas (SANDBOX_ROUTE_OVERHEAD_GAS, PERMIT_IN_FILL_GAS)", () => {
  it("the measured constants (PoolRouteFork.t.sol)", () => {
    expect(SANDBOX_ROUTE_OVERHEAD_GAS).toBe(30_000n);
    expect(PERMIT_IN_FILL_GAS).toBe(60_000n);
  });
  it("ROUTE_GAS_ESTIMATE is a sandbox plan's estimate; a pool plan's is that less the overhead", () => {
    expect(planGasEstimate(320_000n, "sandbox")).toBe(320_000n);
    expect(planGasEstimate(320_000n, "pool")).toBe(320_000n - SANDBOX_ROUTE_OVERHEAD_GAS);
    expect(planGasEstimate(SANDBOX_ROUTE_OVERHEAD_GAS, "pool")).toBe(SANDBOX_ROUTE_OVERHEAD_GAS); // never ≤ 0
  });
  it("pool paths build pool plans, API routes sandbox plans; ranking charges the sandbox overhead to API routes only", () => {
    expect(planKind({ source: "pool" })).toBe("pool");
    expect(planKind({ source: "sushi" })).toBe("sandbox");
    expect(planKind({ source: "nordstern" })).toBe("sandbox");
    expect(rankingGasUnits("pool", 100_000n)).toBe(100_000n);
    expect(rankingGasUnits("sandbox", 100_000n)).toBe(100_000n + SANDBOX_ROUTE_OVERHEAD_GAS);
  });
  it("venue names for logs and the quote API (the app shows Oku / Sushi)", () => {
    expect([venueName(0), venueName(1), venueName(7)]).toEqual(["oku", "sushi-v3", "venue-7"]);
  });
});

describe("rankRoutes", () => {
  it("orders by output net of each route's own gas; ties keep input order", () => {
    const r = rankRoutes([
      { source: "pool", out: 1_000n, routeGasOut: 10n },
      { source: "sushi", out: 1_005n, routeGasOut: 20n },
      { source: "sushi", out: 995n, routeGasOut: 0n },
    ] as const);
    // nets: pool 990, sushi 985, sushi 995
    expect(r.map((c) => [c.source, c.out])).toEqual([
      ["sushi", 995n],
      ["pool", 1_000n],
      ["sushi", 1_005n],
    ]);
    expect(rankRoutes([{ source: "pool", out: 10n, routeGasOut: 0n }, { source: "sushi", out: 10n, routeGasOut: 0n }])[0]!.source).toBe("pool");
    expect(rankRoutes([{ source: "sushi", out: 1_010n, routeGasOut: 9n }, { source: "pool", out: 1_000n, routeGasOut: 0n }])[0]!.source).toBe("sushi");
  });
  it("the sandbox overhead decides a near tie: an API route must beat a pool plan by more than SANDBOX_ROUTE_OVERHEAD_GAS", () => {
    // 1 output unit per gas unit; the API quotes 20k more, its own gas is equal.
    const gas = 100_000n;
    const pool = { source: "pool" as const, out: 1_000_000n, routeGasOut: rankingGasUnits("pool", gas) };
    const api = { source: "sushi" as const, out: 1_020_000n, routeGasOut: rankingGasUnits("sandbox", gas) };
    expect(rankRoutes([api, pool])[0]!.source).toBe("pool"); // 20k better < 30k overhead
    const better = { ...api, out: 1_031_000n };
    expect(rankRoutes([better, pool])[0]!.source).toBe("sushi"); // 31k better > 30k overhead
  });
});

describe("dispatch (strategy order)", () => {
  const entry = { orderHash: "0x01" as Hex, announce: { order: wrbtcOrder(), sig: "0x" as Hex } } as BookEntry;
  const strat = (name: "inventory" | "route", status: FillOutcome["status"]) => {
    const consider = vi.fn(async (): Promise<FillOutcome> => ({ orderHash: "0x01", status, strategy: name }));
    return { s: { name, consider } as Strategy, consider };
  };
  it("stops at inventory when it takes the order", async () => {
    const inv = strat("inventory", "filled");
    const route = strat("route", "filled");
    expect((await dispatch(entry, [inv.s, route.s]))?.strategy).toBe("inventory");
    expect(route.consider).not.toHaveBeenCalled();
  });
  it("falls through to route when inventory skips or fails", async () => {
    for (const status of ["skipped", "failed"] as const) {
      const inv = strat("inventory", status);
      const route = strat("route", "dry-run");
      expect((await dispatch(entry, [inv.s, route.s]))?.strategy).toBe("route");
      expect(inv.consider).toHaveBeenCalledOnce();
    }
  });
});

describe("patchesLiveOutput (task 05)", () => {
  const T0 = 1_800_000_000;
  const decaying = (over: Partial<Order> = {}) =>
    wrbtcOrder({
      timing: withDeltaVerifyOutputs(packTiming(T0, 60, 0)),
      exclusiveFiller: SOLVER,
      legsOut: [{ token: ROOTSTOCK.usdt0, start: 900_000_000n, end: 895_500_000n, recipient: zeroAddress }],
      ...over,
    });
  const at = (s: number) => BigInt(T0 + s);

  it("patches a direct SELL whose output is still decaying", () => {
    expect(patchesLiveOutput(decaying(), true, at(-10))).toBe(true); // before the decay starts
    expect(patchesLiveOutput(decaying(), true, at(30))).toBe(true);
    expect(patchesLiveOutput(decaying(), true, at(59))).toBe(true);
  });

  it("does not patch once the decay window is over (the output rests at end)", () => {
    expect(patchesLiveOutput(decaying(), true, at(60))).toBe(false);
    expect(patchesLiveOutput(decaying(), true, at(500))).toBe(false);
  });

  it("does not patch a pull order, a fixed output, or a BUY", () => {
    expect(patchesLiveOutput(decaying(), false, at(30))).toBe(false);
    const fixed = decaying({ legsOut: [{ token: ROOTSTOCK.usdt0, start: 900_000_000n, end: 0n, recipient: zeroAddress }] });
    expect(patchesLiveOutput(fixed, true, at(30))).toBe(false);
    const buy = decaying({
      side: OrderSide.BUY,
      legsIn: [{ token: ROOTSTOCK.usdt0, start: 795_000_000n, end: 800_000_000n }],
      legsOut: [{ token: ROOTSTOCK.wrbtc, start: 10n ** 16n, end: 0n, recipient: zeroAddress }],
    });
    expect(patchesLiveOutput(buy, true, at(30))).toBe(false);
  });

  it("a block-clock order is assumed to still decay (only the typed gas is at stake)", () => {
    const o = decaying({ timing: withBlockClock(withDeltaVerifyOutputs(packTiming(1, 30, 0))) });
    expect(patchesLiveOutput(o, true, at(10_000))).toBe(true);
  });

  it("the typed path's extra gas is the measured +5.9k, rounded up", () => {
    expect(TYPED_CALLBACK_GAS).toBe(6_000n);
  });
});

describe("RouteFiller: pool venues against the deployed solver", () => {
  const OKU = ROOTSTOCK_POOL_VENUES[0]!.factory;
  const SUSHI = ROOTSTOCK_POOL_VENUES[1]!.factory;
  const QUOTER_OKU = getAddress(ROOTSTOCK.quoterV2);
  const QUOTER_SUSHI = getAddress(ROOTSTOCK.sushiV3Quoter);
  const ACCOUNT = privateKeyToAccount(ENV.PRIVATE_KEY as Hex);
  const RECEIVED = 10n ** 16n;
  const OWED = 900_000_000n;

  /** A solver with `venues` pool venues; each quoter reports `factories[addr]`; quotes per quoter address. */
  function chain(o: { venues?: bigint | "missing"; factories?: Record<string, Address>; quotes?: Record<string, bigint> } = {}) {
    const quoted: Address[] = [];
    const sent: Hex[] = [];
    const factories = o.factories ?? { [QUOTER_OKU.toLowerCase()]: OKU, [QUOTER_SUSHI.toLowerCase()]: SUSHI };
    const quotes = o.quotes ?? { [QUOTER_OKU.toLowerCase()]: 1_000_000_000n, [QUOTER_SUSHI.toLowerCase()]: 1_001_000_000n };
    const pub = {
      getCode: async () => "0x60",
      getGasPrice: async () => 60_000_000n,
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
          case "POOL_VENUES":
            if (o.venues === "missing") throw new Error("execution reverted");
            return o.venues ?? 2n;
          case "poolVenue": return [args![0] === 0n ? OKU : SUSHI, ROOTSTOCK_POOL_VENUES[0]!.initCodeHash];
          case "factory": return factories[address.toLowerCase()];
          case "previewFill": return [0n, [RECEIVED], [OWED]];
          case "previewBump": return 0n;
          case "decimals": return 6;
          case "aggregate3":
            // Batched quotes (Multicall3): served by the per-call quote mock below;
            // discovery's getPool reads revert here (no graph: configured pools only).
            return aggregate3(args![0] as never, async (c) => {
              if (!c.functionName.startsWith("quote")) throw new Error("no pool");
              return (await pub.simulateContract({ address: c.address, args: c.args as [Hex, bigint] })).result;
            });
        }
        throw new Error(`unexpected read ${functionName}`);
      },
      simulateContract: async ({ address, args }: { address: Address; args: [Hex, bigint] }) => {
        quoted.push(address);
        // 1 WRBTC = 100k USDT0 at the venue's rate (scaled from 0.01 WRBTC → quotes[addr]).
        const usdt0In = args[0].slice(2, 42).toLowerCase() === ROOTSTOCK.usdt0.slice(2).toLowerCase();
        const rate = quotes[address.toLowerCase()]!;
        return { result: [usdt0In ? (args[1] * 10n ** 16n) / rate : (args[1] * rate) / 10n ** 16n, [], [], 100_000n] };
      },
      call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [OWED] }) }),
      estimateGas: async () => 250_000n,
    };
    return { quoted, sent, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
  }
  const make = (c: unknown, env: Record<string, string> = {}) => {
    const cfg = loadConfig({ ...ENV, SUSHI_ENABLED: "0", DRY_RUN: "0", ...env });
    const logs: string[] = [];
    return { rf: new RouteFiller(cfg, c as never, new Budget({ [ROUTE_FILLS]: 60n }), (m) => logs.push(m)), logs };
  };
  const wrbtcPath = (venue: number) => ({ tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0] as Address[], fees: [3000], venue });

  it("each venue is quoted on ITS quoter; the better one (SushiSwap v3) is sent as a venue-1 pool plan", async () => {
    const c = chain();
    const { rf, logs } = make(c.chain);
    await rf.init();
    expect(logs.join("\n")).toMatch(/venues oku\+sushi-v3/);
    await rf.quote(wrbtcPath(1), RECEIVED);
    expect(c.quoted.at(-1)).toBe(QUOTER_SUSHI);
    await rf.quote(wrbtcPath(0), RECEIVED);
    expect(c.quoted.at(-1)).toBe(QUOTER_OKU);
    const e = { orderHash: ("0x" + "0a".repeat(32)) as Hex, announce: { order: wrbtcOrder(), sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: RECEIVED, validatorsPass: true } };
    const out = await rf.consider(e);
    expect(out.status).toBe("pending");
    const args = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: c.sent[0]! }).args;
    const plan = args[3] as { router: Address; data: Hex; amountInOffset: bigint; minOut: bigint };
    expect(plan.router).toBe(POOL_ROUTE);
    expect(plan.amountInOffset).toBe(0n);
    const d = decodePoolRoute(plan.data);
    expect(d.venues).toEqual([1]);
    expect(d.amountOut).toBe(0n); // pull: exact-input
    expect(args[5]).toEqual([]); // no permit
  });

  it("a direct order is sent as an exact-output pool plan to the order's payee (no recipient in the plan)", async () => {
    const c = chain();
    const { rf } = make(c.chain);
    const o = wrbtcOrder({ timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER });
    const e = { orderHash: ("0x" + "0b".repeat(32)) as Hex, announce: { order: o, sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: RECEIVED, validatorsPass: true } };
    expect((await rf.consider(e)).status).toBe("pending");
    const plan = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: c.sent[0]! }).args[3] as { router: Address; data: Hex; amountInOffset: bigint; amountOutOffset: bigint };
    expect(plan.router).toBe(POOL_ROUTE);
    expect(plan.amountInOffset).toBe(NO_PATCH);
    expect(plan.amountOutOffset).toBe(NO_PATCH);
    const d = decodePoolRoute(plan.data);
    expect(d.amountOut).toBe(OWED);
    expect(d.amountIn).toBeLessThan(RECEIVED);
  });

  it("a quoter that prices another factory than the solver's venue disables that venue (a quote must price the pool the plan swaps on)", async () => {
    const c = chain({ factories: { [QUOTER_OKU.toLowerCase()]: OKU, [QUOTER_SUSHI.toLowerCase()]: OKU } });
    const { rf, logs } = make(c.chain);
    await rf.init();
    expect(logs.join("\n")).toMatch(/venue 1 \(sushi-v3\): quoter .* prices factory .* venue disabled/);
    await expect(rf.quote(wrbtcPath(1), RECEIVED)).rejects.toThrow(/not routable/);
    expect(await rf.quote(wrbtcPath(0), RECEIVED)).toBeGreaterThan(0n);
  });

  it("a venue the solver does not have, or one without a quoter, is ignored with a warning", async () => {
    const one = make(chain({ venues: 1n }).chain);
    await one.rf.init();
    expect(one.logs.join("\n")).toMatch(/venue 1 \(sushi-v3\) is not on the solver \(POOL_VENUES = 1\)/);
    await expect(one.rf.quote(wrbtcPath(1), RECEIVED)).rejects.toThrow(/not routable/);
    const noQuoter = make(chain().chain, { SUSHI_V3_QUOTER: "" });
    await noQuoter.rf.init();
    expect(noQuoter.logs.join("\n")).toMatch(/venue 1 \(sushi-v3\) is without a quoter/);
  });

  it("a solver without POOL_VENUES predates pool plans and the permits argument: refused at start-up", async () => {
    const { rf } = make(chain({ venues: "missing" }).chain);
    await expect(rf.init()).rejects.toThrow(/POOL_VENUES/);
  });
});

import {
  NO_PATCH,
  OrderSide,
  encodeAggregatorExecuteFill,
  packTiming,
  withBlockClock,
  SWAP_ROUTER02_ABI,
  withDeltaVerifyOutputs,
  withPriorityAuction,
  type Order,
} from "@1delta-x/sdk";
import { decodeFunctionData, hexToBigInt, sliceHex, zeroAddress, type Address, type Hex } from "viem";
import { describe, expect, it, vi } from "vitest";

import { loadConfig, parsePaths, parsePools, ROOTSTOCK, ROOTSTOCK_POOLS } from "../src/config";
import { dispatch, type Strategy } from "../src/dispatch";
import type { FillOutcome } from "../src/filler";
import type { BookEntry } from "../src/intake";
import {
  buildRoutePlan,
  candidatePaths,
  classifyRoute,
  mulDivUp,
  nativeToTokenAtQuote,
  nativeToUsdToken,
  grossUp,
  haircutBps,
  patchesLiveOutput,
  TYPED_CALLBACK_GAS,
  rankRoutes,
  routeProfitable,
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
  it("enables the Sushi source by default, pinned to Rootstock's RedSnwapper", () => {
    expect(rc.sushi).toEqual({
      enabled: true,
      baseUrl: "https://api.sushi.com",
      router: "0xAC4c6e212A361c968F1725b4d055b47E63F80b75",
      timeoutMs: 4000,
      executors: [],
      maxPerSweep: 10,
    });
    expect(loadConfig({ ...ENV, SUSHI_ENABLED: "0" }).route!.sushi.enabled).toBe(false);
    expect(rc.okuPull).toBe(true);
    expect(loadConfig({ ...ENV, ROUTE_OKU_PULL: "0" }).route!.okuPull).toBe(false);
    expect(() => loadConfig({ ...ENV, SUSHI_ROUTER: "nope" })).toThrow(/SUSHI_ROUTER/);
  });
  it("defaults to the app's three Rootstock Uniswap v3 pools and the USDRIF→WRBTC path", () => {
    expect(rc.pools).toEqual(ROOTSTOCK_POOLS);
    expect(rc.pools.map((p) => p.market)).toEqual(["rsk-30-wrbtc-usd0", "rsk-30-weth-wrbtc", "rsk-30-usdrif-usd0"]);
    expect(rc.paths).toHaveLength(1);
    expect(rc.paths[0]!.fees).toEqual([500, 3000]);
    expect(rc.slippageBps).toBe(30n);
    expect(rc.stableSlippageBps).toBe(5n);
    expect(rc.minProfitWei).toBe(0n);
    expect(loadConfig({ ...ENV, ROUTE_STABLE_SLIPPAGE_BPS: "12" }).route!.stableSlippageBps).toBe(12n);
    expect(() => loadConfig({ ...ENV, ROUTE_STABLE_SLIPPAGE_BPS: "10001" })).toThrow(/ROUTE_STABLE_SLIPPAGE_BPS/);
  });
  it("parses ROUTE_PATHS and ROUTE_POOLS", () => {
    const p = parsePaths(`${ROOTSTOCK.weth}>3000>${ROOTSTOCK.wrbtc}>3000>${ROOTSTOCK.usdt0}; `);
    expect(p).toEqual([{ tokens: [ROOTSTOCK.weth, ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000, 3000] }]);
    expect(parsePaths("")).toEqual([]);
    expect(() => parsePaths(`${ROOTSTOCK.weth}>3000`)).toThrow();
    expect(() => parsePaths(`${ROOTSTOCK.weth}>x>${ROOTSTOCK.wrbtc}`)).toThrow(/fee/);
    expect(parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/500`)).toEqual([
      { tokenA: ROOTSTOCK.wrbtc, tokenB: ROOTSTOCK.usdt0, fee: 500 },
    ]);
    expect(() => parsePools("a/b")).toThrow();
  });
});

describe("candidatePaths", () => {
  it("finds a pool in either direction", () => {
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, rc)).toEqual([{ tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0], fees: [3000] }]);
    expect(candidatePaths(ROOTSTOCK.usdt0, ROOTSTOCK.wrbtc, rc)).toEqual([{ tokens: [ROOTSTOCK.usdt0, ROOTSTOCK.wrbtc], fees: [3000] }]);
  });
  it("uses a configured multi-hop path, reversed when needed", () => {
    expect(candidatePaths(ROOTSTOCK.wrbtc, ROOTSTOCK.usdrif, rc)).toEqual([
      { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif], fees: [3000, 500] },
    ]);
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
  it.each([
    ["delta-verify for another filler", { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: OTHER }, /another filler/],
    ["delta-verify open (core refuses it anyway)", { timing: withDeltaVerifyOutputs(0n) }, /another filler/],
    ["pull order for another filler", { exclusiveFiller: OTHER }, /another exclusive/],
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
    const rif = { legsOut: [{ token: ROOTSTOCK.rif, start: 1n, end: 0n, recipient: zeroAddress }] };
    const withRif = { ...rc, routeTokens: [...rc.routeTokens, ROOTSTOCK.rif as Address] };
    const noSushi = { ...withRif, sushi: { ...rc.sushi, enabled: false } };
    const off = classifyRoute(wrbtcOrder(rif), noSushi);
    expect(off.ok).toBe(false);
    if (!off.ok) expect(off.reason).toMatch(/no configured/);
    const pull = classifyRoute(wrbtcOrder(rif), withRif);
    expect(pull.ok && pull.paths.length).toBe(0); // admitted, Sushi-only
    const direct = classifyRoute(wrbtcOrder({ ...rif, timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }), withRif);
    expect(direct.ok).toBe(false); // direct orders use the local Oku path only
  });
  it("ROUTE_TOKENS: with Sushi on, a pair outside the allowlist is refused before any quote (L-6)", () => {
    const rif = { legsOut: [{ token: ROOTSTOCK.rif, start: 1n, end: 0n, recipient: zeroAddress }] };
    expect(rc.routeTokens).toEqual([ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.weth, ROOTSTOCK.usdrif]);
    expect(rc.sushi.enabled).toBe(true);
    const v = classifyRoute(wrbtcOrder(rif), rc);
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

describe("buildRoutePlan", () => {
  const ROUTER = ROOTSTOCK.swapRouter as Address;
  const received = 10n ** 16n;
  const owed = 900_000_000n;
  const quotedOut = 1_000_000_000n;
  const costOut = 2_000_000n;
  const single = { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0] as Address[], fees: [3000] };
  const multi = { tokens: [ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0, ROOTSTOCK.usdrif] as Address[], fees: [3000, 500] };

  it("pull, single hop: exactInputSingle to the SOLVER, patched amountIn, minOut = owed + cost, maxPay = owed", () => {
    const { plan, call } = buildRoutePlan({
      direct: false, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n,
    });
    expect(plan.router).toBe(ROUTER);
    expect(plan.minOut).toBe(owed + costOut);
    expect(plan.maxPay).toBe(owed);
    expect(plan.amountInOffset).toBe(132n);
    expect(word(plan.data, plan.amountInOffset)).toBe(received);
    const d = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: call.data });
    expect(d.functionName).toBe("exactInputSingle");
    const p = d.args[0] as { recipient: Address; amountOutMinimum: bigint; fee: number };
    expect(p.recipient.toLowerCase()).toBe(SOLVER.toLowerCase());
    expect(p.amountOutMinimum).toBe(owed + costOut);
    expect(p.fee).toBe(3000);
  });

  it("pull, multi-hop: exactInput, offset at amountIn", () => {
    const { plan } = buildRoutePlan({
      direct: false, path: multi, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: OTHER, minBumpBps: 0n,
    });
    expect(plan.amountInOffset).toBe(100n);
    expect(word(plan.data, plan.amountInOffset)).toBe(received);
    expect(plan.profitRecipient).toBe(OTHER);
    expect(decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: plan.data }).functionName).toBe("exactInput");
  });

  it("direct, single hop: exactOutputSingle paying the MAKER exactly owed, bounded amountInMaximum, NO_PATCH", () => {
    const { plan } = buildRoutePlan({
      direct: true, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n,
    });
    expect(plan.amountInOffset).toBe(NO_PATCH);
    const d = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: plan.data });
    expect(d.functionName).toBe("exactOutputSingle");
    const p = d.args[0] as { recipient: Address; amountOut: bigint; amountInMaximum: bigint };
    expect(p.recipient.toLowerCase()).toBe(MAKER.toLowerCase());
    expect(p.amountOut).toBe(owed);
    // keep = ceil(2 USDT0 × 0.01 WRBTC / 1,000 USDT0) = 2e-5 WRBTC = 2e13 wei.
    expect(p.amountInMaximum).toBe(received - 2n * 10n ** 13n);
  });

  it("direct, multi-hop: exactOutput over the REVERSED path", () => {
    const { plan } = buildRoutePlan({
      direct: true, path: multi, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n,
    });
    const d = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: plan.data });
    expect(d.functionName).toBe("exactOutput");
    const p = d.args[0] as { path: Hex };
    expect(sliceHex(p.path, 0, 20)).toBe(ROOTSTOCK.usdrif.toLowerCase()); // tokenOut first
  });

  it("carries minBumpBps (the filler's floor) on both paths; no output patch unless asked", () => {
    for (const direct of [false, true]) {
      const { plan } = buildRoutePlan({
        direct, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
        received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 4_321n,
      });
      expect(plan.minBumpBps).toBe(4_321n);
      expect(plan.amountOutOffset).toBe(NO_PATCH);
    }
  });

  it("task 05: a live-output direct plan points amountOutOffset at the router's amountOut word (single + multi hop)", () => {
    for (const [path, off] of [[single, 132n], [multi, 100n]] as const) {
      const { plan, call } = buildRoutePlan({
        direct: true, path, router: ROUTER, solver: SOLVER, maker: MAKER,
        received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n, liveOut: true,
      });
      expect(plan.amountOutOffset).toBe(off);
      expect(plan.amountOutOffset).toBe(call.amountOutOffset);
      // In bounds, and the word there IS the previewed owed the solver overwrites.
      expect(plan.amountOutOffset + 32n <= BigInt((plan.data.length - 2) / 2)).toBe(true);
      expect(word(plan.data, plan.amountOutOffset)).toBe(owed);
      // The floor is unchanged: amountInMaximum still sized on the PREVIEWED owed.
      expect(plan.amountInOffset).toBe(NO_PATCH);
      expect(word(plan.data, call.amountInOffset)).toBe(received - 2n * 10n ** 13n);
      // The SDK encoder's bounds check accepts it.
      expect(() => encodeAggregatorExecuteFill({ order: wrbtcOrder(), sig: "0x", fillAmount: received, plan })).not.toThrow();
    }
  });

  it("task 05: liveOut is ignored on the pull path (exact-input has no amountOut word)", () => {
    const { plan } = buildRoutePlan({
      direct: false, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n, liveOut: true,
    });
    expect(plan.amountOutOffset).toBe(NO_PATCH);
  });

  it("task 05: an out-of-bounds output offset is refused before signing", () => {
    const { plan } = buildRoutePlan({
      direct: true, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
      received, owed, quotedOut, costOut, profitRecipient: zeroAddress, minBumpBps: 0n, liveOut: true,
    });
    const size = BigInt((plan.data.length - 2) / 2);
    expect(() => encodeAggregatorExecuteFill({ order: wrbtcOrder(), sig: "0x", fillAmount: received, plan: { ...plan, amountOutOffset: size - 31n } })).toThrow(/amountOutOffset/);
    expect(() => encodeAggregatorExecuteFill({ order: wrbtcOrder(), sig: "0x", fillAmount: received, plan: { ...plan, amountOutOffset: size - 32n } })).not.toThrow();
  });

  it("refuses a margin larger than the input", () => {
    expect(() =>
      buildRoutePlan({
        direct: true, path: single, router: ROUTER, solver: SOLVER, maker: MAKER,
        received, owed, quotedOut: 1n, costOut, profitRecipient: zeroAddress, minBumpBps: 0n,
      }),
    ).toThrow(/margin/);
  });
});

describe("rankRoutes", () => {
  it("orders by output net of each route's own gas; ties keep input order", () => {
    const r = rankRoutes([
      { source: "oku", out: 1_000n, routeGasOut: 10n },
      { source: "sushi", out: 1_005n, routeGasOut: 20n },
      { source: "sushi", out: 995n, routeGasOut: 0n },
    ] as const);
    // nets: oku 990, sushi 985, sushi 995
    expect(r.map((c) => [c.source, c.out])).toEqual([
      ["sushi", 995n],
      ["oku", 1_000n],
      ["sushi", 1_005n],
    ]);
    expect(rankRoutes([{ source: "oku", out: 10n, routeGasOut: 0n }, { source: "sushi", out: 10n, routeGasOut: 0n }])[0]!.source).toBe("oku");
    expect(rankRoutes([{ source: "sushi", out: 1_010n, routeGasOut: 9n }, { source: "oku", out: 1_000n, routeGasOut: 0n }])[0]!.source).toBe("sushi");
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

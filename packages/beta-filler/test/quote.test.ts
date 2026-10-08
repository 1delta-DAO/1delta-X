/**
 * Indicative quotes (2026-10-07, ./src/quote.ts): amountOut = grossOut − gas × (1 + margin),
 * the request validation, the registry that recognises an order signed from one of our
 * quotes, and the fill gate for such an order (no route haircut).
 */
import { AGGREGATOR_FILL_SOLVER_ABI, OrderSide, packTiming, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { gasShape } from "../src/gasRatio";
import { MAX_QUOTES, netQuote, parseQuoteRequest, QuoteBook, quoteMatches, quoteToJson, type IssuedQuote, type QuoteRequest } from "../src/quote";
import { MemoryStateStore, STATE_KEY, type FillerState } from "../src/state";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const MAKER = "0x00000000000000000000000000000000000000bb" as Address;
const OTHER = "0x00000000000000000000000000000000000000cc" as Address;
const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
  AGGREGATOR_SOLVER: SOLVER,
  INVENTORY_ENABLED: "0",
  SUSHI_ENABLED: "0",
  DRY_RUN: "0",
};
const WRBTC = ROOTSTOCK.wrbtc as Address;
const USDT0 = ROOTSTOCK.usdt0 as Address;
const USDRIF = ROOTSTOCK.usdrif as Address;
const RIF = ROOTSTOCK.rif as Address;
/** eth_gasPrice of the fake (no getBlock → the send price falls back to it). */
const GAS_PRICE = 26_065_600n;
const eqa = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** The fake pools: WRBTC = $100k, USDRIF→USDT0 at 0.998, RIF at $0.0399. */
function rate(tin: string, tout: string, amt: bigint): bigint {
  if (eqa(tin, WRBTC) && eqa(tout, USDT0)) return amt / 10n ** 7n;
  if (eqa(tin, USDT0) && eqa(tout, WRBTC)) return amt * 10n ** 7n;
  if (eqa(tin, USDRIF) && eqa(tout, USDT0)) return (amt * 998n) / 10n ** 15n;
  if (eqa(tin, RIF) && eqa(tout, USDT0)) return (amt * 399n) / 10n ** 16n;
  return 0n;
}
/** WRBTC wei → USDT0 units at $100k, rounded up (the route's nativeToToken). */
const rbtcToUsdt0 = (wei: bigint) => (wei * 10n ** 8n + 10n ** 15n - 1n) / 10n ** 15n;

function fake(o: { estimate?: bigint; usdt0Balance?: bigint } = {}) {
  const w = { owed: 0n, received: 0n, sent: [] as Array<{ data: Hex; gas?: bigint }>, quoterCalls: 0 };
  const pub: Record<string, unknown> = {
    getCode: async () => "0x60",
    getGasPrice: async () => GAS_PRICE,
    getTransactionCount: async () => 0,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      w.sent.push({ data: t.data!, gas: t.gas });
      return keccak256(serializedTransaction);
    },
    getTransactionReceipt: async () => {
      throw new Error("Transaction receipt could not be found");
    },
    getTransaction: async () => ({}),
    readContract: async ({ functionName }: { functionName: string }) => {
      switch (functionName) {
        case "SETTLEMENT": return ENV.SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return SANDBOX;
        case "OWNER": return SOLVER;
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "previewFill": return [0n, [w.received], [w.owed]];
        case "previewBump": return 0n;
        case "decimals": return 6;
        case "getPACtp": return 4n * 10n ** 16n; // $0.04 per RIF
        case "getExecFee": return 0n;
        case "balanceOf": return o.usdt0Balance ?? 10n ** 12n;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ functionName, args }: { functionName: string; args: unknown[] }) => {
      w.quoterCalls++;
      if (functionName === "quoteExactInputSingle") {
        const p = args[0] as { tokenIn: string; tokenOut: string; amountIn: bigint };
        return { result: [rate(p.tokenIn, p.tokenOut, p.amountIn), 0n, 0, 90_000n] };
      }
      const path = args[0] as Hex;
      const tin = `0x${path.slice(2, 42)}`;
      const tout = `0x${path.slice(-40)}`;
      return { result: [rate(tin, tout, args[1] as bigint), [], [], 100_000n] };
    },
    call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [w.owed] }) }),
    estimateGas: async () => o.estimate ?? 400_000n,
  };
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const sellReq = (over: Partial<QuoteRequest> = {}): QuoteRequest => ({
  chainId: 30, tokenIn: WRBTC, tokenOut: USDT0, amountIn: 10n ** 16n, side: "sell", delivery: "pull", maker: MAKER, ...over,
});

function order(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: BigInt(Math.floor(Date.now() / 1000) + 300),
    legsIn: [{ token: WRBTC, start: 10n ** 16n, end: 0n }],
    legsOut: [{ token: USDT0, start: 0n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}
/** The app's market shape: a 60 s Dutch decay from the quote to `minOut`. */
const dutch = (start: bigint, min: bigint, over: Partial<Order> = {}) =>
  order({ legsOut: [{ token: USDT0, start, end: min, recipient: zeroAddress }], timing: packTiming(Math.floor(Date.now() / 1000), 60, 0), ...over });
const entry = (h: string, o: Order) => ({
  orderHash: ("0x" + h.repeat(32)) as Hex,
  announce: { order: o, sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: o.legsIn[0]!.start, validatorsPass: true },
});

describe("netQuote: amountOut = grossOut − ⌈gas × (1 + margin)⌉ − tolerance", () => {
  it("the default +20 % on the gas", () => {
    expect(netQuote({ grossOut: 1_000_000n, costOut: 10_000n, gasMarginBps: 2_000n, toleranceBps: 0n })).toEqual({ amountOut: 988_000n, chargeOut: 12_000n, toleranceOut: 0n });
  });
  it("rounds the charge UP (never under-charges the gas)", () => {
    expect(netQuote({ grossOut: 1_000n, costOut: 7n, gasMarginBps: 2_000n, toleranceBps: 0n }).chargeOut).toBe(9n); // 8.4 → 9
  });
  it("the operator tolerance comes off the gross; a cap bounds the result", () => {
    expect(netQuote({ grossOut: 1_000_000n, costOut: 10_000n, gasMarginBps: 0n, toleranceBps: 10n })).toEqual({ amountOut: 989_000n, chargeOut: 10_000n, toleranceOut: 1_000n });
    expect(netQuote({ grossOut: 1_000_000n, costOut: 10_000n, gasMarginBps: 2_000n, toleranceBps: 0n, capOut: 900_000n }).amountOut).toBe(900_000n);
  });
  it("gas above the output: 0 (unquotable), never negative", () => {
    expect(netQuote({ grossOut: 1_000n, costOut: 2_000n, gasMarginBps: 2_000n, toleranceBps: 0n }).amountOut).toBe(0n);
  });
});

describe("parseQuoteRequest: strict validation", () => {
  const cfg = loadConfig(ENV);
  const base = { chainId: 30, side: "sell", delivery: "direct", amountIn: "10000000000000000" };
  it("marketId + side → tokens (sell pays the base, buy pays the quote)", () => {
    const s = parseQuoteRequest({ ...base, marketId: "rsk-30-wrbtc-usd0" }, cfg);
    expect(s.ok && [s.req.tokenIn, s.req.tokenOut]).toEqual([WRBTC, USDT0]);
    const b = parseQuoteRequest({ ...base, side: "buy", marketId: "rsk-30-wrbtc-usd0", amountIn: "20000000" }, cfg);
    expect(b.ok && [b.req.tokenIn, b.req.tokenOut, b.req.amountIn]).toEqual([USDT0, WRBTC, 20_000_000n]);
  });
  it("explicit tokens; consistent with the market when both are given", () => {
    expect(parseQuoteRequest({ ...base, tokenIn: USDRIF, tokenOut: USDT0 }, cfg).ok).toBe(true);
    expect(parseQuoteRequest({ ...base, tokenIn: WRBTC, tokenOut: USDT0, marketId: "rsk-30-wrbtc-usd0" }, cfg).ok).toBe(true);
    const bad = parseQuoteRequest({ ...base, tokenIn: USDT0, tokenOut: WRBTC, marketId: "rsk-30-wrbtc-usd0" }, cfg);
    expect(!bad.ok && bad.reason).toMatch(/do not match/);
  });
  it.each([
    [null, /JSON object/],
    [[1], /JSON object/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", extra: 1 }, /unknown field/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", chainId: 31 }, /chainId/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", side: "long" }, /side/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", delivery: "x" }, /delivery/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", amountIn: 1 }, /amountIn/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", amountIn: "0" }, /out of range/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", amountIn: "1e18" }, /amountIn/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", amountIn: (2n ** 128n).toString() }, /out of range/],
    [{ ...base, marketId: "nope" }, /unknown marketId/],
    [{ ...base, marketId: "rsk-30-wrbtc-usd0", maker: "0x12" }, /maker/],
    [{ ...base, tokenIn: WRBTC }, /both be addresses/],
    [{ ...base, tokenIn: WRBTC, tokenOut: WRBTC }, /equals/],
    [base, /tokenIn\/tokenOut or a marketId/],
  ])("refuses %j", (raw, why) => {
    const v = parseQuoteRequest(raw, cfg);
    expect(v.ok).toBe(false);
    expect(!v.ok && v.reason).toMatch(why);
  });
});

describe("Quoter: the filler's real pricing for the order shape", () => {
  const pullShape = gasShape("route", "pull", WRBTC, USDT0);

  it("SELL: grossOut = the best route output; gas = QUOTE_GAS_ESTIMATE_PULL × r × the send price; amountOut = gross − gas × 1.1", async () => {
    const { chain } = fake();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const v = await e.quote(sellReq());
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    const q = v.quote;
    expect(q.grossOut).toBe(1_000_000_000n); // 0.01 WRBTC × $100k
    expect(q.gasUnits).toBe(334_400n); // 380k × 0.88
    const gasOut = rbtcToUsdt0(334_400n * GAS_PRICE);
    expect(q.gasCostOut).toBe(gasOut);
    expect(q.gasChargeOut).toBe((gasOut * 11_000n + 9_999n) / 10_000n);
    expect(q.amountOut).toBe(q.grossOut - q.gasChargeOut);
    expect(q.gasMarginBps).toBe(1_000n);
    expect(q.strategy).toBe("route");
    expect(q.route).toEqual({ source: "oku", hops: 1 });
    expect(q.validUntil - Math.floor(q.issuedAt / 1000)).toBe(30);
    expect(q.quoteId).toMatch(/^q_[0-9a-f]{24}$/);
    expect(e.quotes.size).toBe(1);
    // JSON: bigints as decimal strings, nothing secret.
    const j = quoteToJson(q);
    expect(j.amountOut).toBe(q.amountOut.toString());
    expect(JSON.stringify(j)).not.toMatch(/11111111/);
  });

  it("direct delivery prices QUOTE_GAS_ESTIMATE_DIRECT; a LEARNED estimate for the shape replaces the default", async () => {
    const { chain } = fake();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const d = await e.quote(sellReq({ delivery: "direct" }));
    expect(d.ok && d.quote.gasUnits).toBe(316_800n); // 360k × 0.88
    e.gasRatios.record(pullShape, 380_000n, 330_000n, 1);
    const p = await e.quote(sellReq({ amountIn: 2n * 10n ** 16n }));
    expect(p.ok && p.quote.gasUnits).toBe(e.gasRatios.priced(pullShape, 380_000n));
    // …never below ROUTE_GAS_ESTIMATE (320k): a tiny learned estimate is floored.
    e.gasRatios.record(gasShape("route", "pull", USDT0, WRBTC), 100_000n, 90_000n, 2);
    const b = await e.quote(sellReq({ tokenIn: USDT0, tokenOut: WRBTC, amountIn: 20_000_000n, side: "buy" }));
    expect(b.ok && b.quote.gasUnits).toBe(e.gasRatios.priced(gasShape("route", "pull", USDT0, WRBTC), 320_000n));
  });

  it("BUY (pay USDT0, receive WRBTC): exact-input of the pay amount, gas charged in the RECEIVE token", async () => {
    const { chain } = fake();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const v = await e.quote(sellReq({ tokenIn: USDT0, tokenOut: WRBTC, amountIn: 20_000_000n, side: "buy", delivery: "direct" }));
    expect(v.ok).toBe(true);
    if (!v.ok) return;
    expect(v.quote.grossOut).toBe(2n * 10n ** 14n); // $20 of WRBTC at $100k
    const gasWei = 316_800n * GAS_PRICE; // WRBTC output: gas is 1:1 in wei
    expect(v.quote.gasCostOut).toBe(gasWei);
    expect(v.quote.amountOut).toBe(2n * 10n ** 14n - (gasWei * 11_000n + 9_999n) / 10_000n);
    // A $20 ticket: several % of it is the gas (+ margin) — shown to the user by the app.
    expect(Number(v.quote.gasChargeOut) / Number(v.quote.grossOut)).toBeGreaterThan(0.04);
  });

  it("QUOTE_GAS_MARGIN_BPS / QUOTE_TOLERANCE_BPS / QUOTE_TTL_SECONDS are config", async () => {
    const { chain } = fake();
    const cfg = loadConfig({ ...ENV, QUOTE_GAS_MARGIN_BPS: "5000", QUOTE_TOLERANCE_BPS: "10", QUOTE_TTL_SECONDS: "60" });
    const e = await Engine.create({ cfg, chain, store: new MemoryStateStore(), log: () => {} });
    const v = await e.quote(sellReq());
    if (!v.ok) throw new Error(v.reason);
    expect(v.quote.gasChargeOut).toBe((v.quote.gasCostOut * 15_000n + 9_999n) / 10_000n);
    expect(v.quote.toleranceOut).toBe(1_000_000n); // 10 bps of 1000 USDT0
    expect(v.quote.amountOut).toBe(v.quote.grossOut - v.quote.gasChargeOut - 1_000_000n);
    expect(v.quote.validUntil - Math.floor(v.quote.issuedAt / 1000)).toBe(60);
    expect(() => loadConfig({ ...ENV, QUOTE_GAS_MARGIN_BPS: "100001" })).toThrow(/QUOTE_GAS_MARGIN_BPS/);
    expect(() => loadConfig({ ...ENV, QUOTE_TTL_SECONDS: "0" })).toThrow(/QUOTE_TTL_SECONDS/);
  });

  it("refusals: QUOTE_ENABLED=0, a pair outside ROUTE_TOKENS, gas above the output, gas price above the ceiling", async () => {
    const { chain } = fake();
    const off = await Engine.create({ cfg: loadConfig({ ...ENV, QUOTE_ENABLED: "0" }), chain, store: new MemoryStateStore(), log: () => {} });
    expect(await off.quote(sellReq())).toEqual({ ok: false, reason: "quotes disabled" });
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const odd = await e.quote(sellReq({ tokenIn: RIF }));
    expect(!odd.ok && odd.reason).toMatch(/ROUTE_TOKENS/);
    const dust = await e.quote(sellReq({ amountIn: 10n ** 11n })); // $0.01 of WRBTC
    expect(!dust.ok && dust.reason).toMatch(/gas .* exceeds the output/);
    const pricey = await Engine.create({ cfg: loadConfig({ ...ENV, MAX_GAS_PRICE_GWEI: "0.01" }), chain, store: new MemoryStateStore(), log: () => {} });
    const p = await pricey.quote(sellReq());
    expect(!p.ok && p.reason).toMatch(/MAX_GAS_PRICE_GWEI/);
  });

  it("identical requests within QUOTE_CACHE_MS reuse the priced result (fresh quote id, no new RPC)", async () => {
    const { chain, w } = fake();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const a = await e.quote(sellReq());
    const calls = w.quoterCalls;
    const b = await e.quote(sellReq());
    expect(w.quoterCalls).toBe(calls);
    expect(a.ok && b.ok && a.quote.quoteId !== b.quote.quoteId && a.quote.amountOut === b.quote.amountOut).toBe(true);
    expect(e.quotes.size).toBe(2);
  });

  it("USDRIF→USDT0 pull: the INVENTORY price is quoted when it beats the route", async () => {
    const { chain } = fake();
    // The pre-2026-10-07 quote gas (420k pull, +20 %) so the route clearly loses on this
    // fixture: the test is about the selection, not the defaults.
    const QENV = { ...ENV, QUOTE_GAS_ESTIMATE_PULL: "420000", QUOTE_GAS_MARGIN_BPS: "2000" };
    const cfg = loadConfig({ ...QENV, INVENTORY_ENABLED: "1" });
    const e = await Engine.create({ cfg, chain, store: new MemoryStateStore(), log: () => {} });
    const amountIn = 100n * 10n ** 18n;
    const v = await e.quote(sellReq({ tokenIn: USDRIF, tokenOut: USDT0, amountIn }));
    if (!v.ok) throw new Error(v.reason);
    expect(v.quote.strategy).toBe("inventory");
    // exit: 100 USDRIF → 2500 RIF − 0.2 % MoC fee → × $0.0399 = 99.55 USDT0.
    const exit = ((2_500n * 10n ** 18n * 9_980n) / 10_000n * 399n) / 10n ** 16n;
    expect(v.quote.grossOut).toBe(exit - cfg.policy.minProfitUsdt0);
    const cap = (exit * 10_000n) / (10_000n + cfg.policy.minExitEdgeBps);
    const net = v.quote.grossOut - v.quote.gasChargeOut;
    expect(v.quote.amountOut).toBe(net < cap ? net : cap);
    expect(v.quote.gasUnits).toBe(228_800n); // INVENTORY_GAS_ESTIMATE 260k × 0.88
    // The route alone would quote less: 99.8 − its (higher) pull gas × 1.2.
    const routeOnly = await (await Engine.create({ cfg: loadConfig(QENV), chain, store: new MemoryStateStore(), log: () => {} })).quote(sellReq({ tokenIn: USDRIF, tokenOut: USDT0, amountIn }));
    expect(routeOnly.ok && routeOnly.quote.strategy === "route" && routeOnly.quote.amountOut < v.quote.amountOut).toBe(true);
    // Direct delivery never quotes inventory (an EOA cannot fill a delta-verify order).
    const direct = await e.quote(sellReq({ tokenIn: USDRIF, tokenOut: USDT0, amountIn, delivery: "direct" }));
    expect(direct.ok && direct.quote.strategy).toBe("route");
  });

  it("inventory refuses what it could not fill (wallet balance): the route quote stands", async () => {
    const { chain } = fake({ usdt0Balance: 1_000_000n });
    const e = await Engine.create({ cfg: loadConfig({ ...ENV, INVENTORY_ENABLED: "1" }), chain, store: new MemoryStateStore(), log: () => {} });
    const v = await e.quote(sellReq({ tokenIn: USDRIF, tokenOut: USDT0, amountIn: 100n * 10n ** 18n }));
    expect(v.ok && v.quote.strategy).toBe("route");
  });
});

describe("QuoteBook: an order is recognised as signed from our quote", () => {
  const now = 1_800_000_000;
  const q = (over: Partial<IssuedQuote> = {}): IssuedQuote => ({
    id: "q1", tokenIn: WRBTC.toLowerCase(), tokenOut: USDT0.toLowerCase(), amountIn: (10n ** 16n).toString(), amountOut: "998000000",
    maker: MAKER.toLowerCase(), delivery: "pull", issuedAt: now * 1000, validUntil: now + 30, ...over,
  });
  const o = dutch(998_000_000n, 995_000_000n);

  it("matches the app's Dutch order that starts AT the quote (and a smaller, balance-clamped one at the same rate)", () => {
    expect(quoteMatches(q(), o, now + 5, 120)).toBe(true);
    const half = dutch(499_000_000n, 497_500_000n, { legsIn: [{ token: WRBTC, start: 5n * 10n ** 15n, end: 0n }] });
    expect(quoteMatches(q(), half, now + 5, 120)).toBe(true);
    // BUY: fixed output, the input RISING from the quoted rate: start rate = the quote's.
    const buy = order({
      side: OrderSide.BUY, legsIn: [{ token: USDT0, start: 19_940_000n, end: 20_000_000n }],
      legsOut: [{ token: WRBTC, start: 199_400_000_000_000n, end: 0n, recipient: zeroAddress }],
    });
    expect(quoteMatches(q({ tokenIn: USDT0.toLowerCase(), tokenOut: WRBTC.toLowerCase(), amountIn: "20000000", amountOut: "200000000000000" }), buy, now, 120)).toBe(true);
  });

  it.each([
    ["another maker", dutch(998_000_000n, 995_000_000n, { maker: OTHER }), now],
    ["a better start price than quoted", dutch(999_000_000n, 995_000_000n), now],
    ["a larger input than quoted", dutch(998_000_000n, 995_000_000n, { legsIn: [{ token: WRBTC, start: 2n * 10n ** 16n, end: 0n }] }), now],
    ["another delivery mode (bit 104)", dutch(998_000_000n, 995_000_000n, { timing: packTiming(now, 60, 0) | (1n << 104n), exclusiveFiller: SOLVER }), now],
    ["other tokens", dutch(998_000_000n, 995_000_000n, { legsIn: [{ token: USDRIF, start: 10n ** 16n, end: 0n }] }), now],
    ["first seen after validUntil + grace", o, now + 30 + 121],
  ])("does not match %s", (_w, ord, at) => {
    expect(quoteMatches(q(), ord as Order, at as number, 120)).toBe(false);
  });

  it("a quote without a maker matches any maker; one quote binds ONE order; the binding survives a restart", () => {
    const book = new QuoteBook();
    book.issue(q({ maker: undefined }), now * 1000, 120);
    const h1 = ("0x" + "01".repeat(32)) as Hex;
    const h2 = ("0x" + "02".repeat(32)) as Hex;
    expect(book.match(h1, dutch(998_000_000n, 995_000_000n, { maker: OTHER }), now * 1000, 120)?.id).toBe("q1");
    expect(book.match(h2, o, now * 1000, 120)).toBeUndefined(); // consumed
    const back = new QuoteBook(JSON.parse(JSON.stringify(book.toJSON())));
    // Bound: matched again past the grace (the order lives 300 s), until the order expires.
    expect(back.match(h1, o, (now + 250) * 1000, 120)?.id).toBe("q1");
  });

  it("prunes expired unbound quotes and bound ones past their order's expiry; bounded at MAX_QUOTES", () => {
    const book = new QuoteBook();
    book.issue(q({ id: "old" }), now * 1000, 120);
    book.issue(q({ id: "new", validUntil: now + 500 }), (now + 200) * 1000, 120);
    expect(book.toJSON().map((x) => x.id)).toEqual(["new"]);
    for (let i = 0; i < MAX_QUOTES + 5; i++) book.issue(q({ id: `q${i}`, validUntil: now + 500 }), (now + 200) * 1000, 120);
    expect(book.size).toBe(MAX_QUOTES);
  });
});

describe("filler: an order signed from OUR quote is filled at the quote, without the haircut", () => {
  const owedOf = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[3] as { minOut: bigint; maxPay: bigint };

  async function setup(o: { quoteMaker?: Address; orderMaker?: Address } = {}) {
    const { chain, w } = fake();
    const store = new MemoryStateStore();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store, log: () => {} });
    const v = await e.quote(sellReq({ maker: o.quoteMaker ?? MAKER }));
    if (!v.ok) throw new Error(v.reason);
    const quote = v.quote;
    // The app's order: start AT the quote, decaying 30 bps over 60 s; the lens previews
    // the start (the first tick after posting).
    const ord = dutch(quote.amountOut, (quote.amountOut * 9_970n) / 10_000n, { maker: o.orderMaker ?? MAKER });
    w.owed = quote.amountOut;
    w.received = 10n ** 16n;
    return { e, w, quote, ord, store };
  }

  it("the next tick SENDS the fill at the quoted start (the 10 bps haircut would have refused it)", async () => {
    const { e, w, quote, ord, store } = await setup();
    // The haircut gate at the start: 1000 × (1 − 10 bps) = 999 USDT0 < owed (≈ 998.84) + gas (≈ 0.92).
    expect((quote.grossOut * 9_990n) / 10_000n).toBeLessThan(quote.amountOut + rbtcToUsdt0(352_000n * GAS_PRICE));
    const t = await e.tick({ fetchEntries: async () => [entry("0a", ord)] });
    expect(t.outcomes[0]?.status).toBe("pending");
    expect(w.sent).toHaveLength(1);
    const plan = owedOf(w.sent[0]!.data);
    expect(plan.maxPay).toBe(quote.amountOut);
    // The plan's on-chain floor: owed + the fill's priced gas — a move before inclusion reverts.
    expect(plan.minOut).toBe(quote.amountOut + rbtcToUsdt0(352_000n * GAS_PRICE));
    expect(e.pending?.info?.tag).toMatch(/quoted q_/);
    const saved = await store.get<FillerState>(STATE_KEY);
    expect(saved!.quotes![0]!.order).toBe(("0x" + "0a".repeat(32)).toLowerCase());
  });

  it("the same order NOT from our quote (another maker than quoted) keeps the haircut: it rests", async () => {
    const { e, w, ord } = await setup({ orderMaker: OTHER });
    const t = await e.tick({ fetchEntries: async () => [entry("0b", ord)] });
    expect(t.outcomes[0]?.status).toBe("skipped");
    expect(t.outcomes[0]?.reason).toMatch(/unprofitable: quote \d+ −10bps/);
    expect(w.sent).toHaveLength(0);
  });

  it("a quoted order the market moved against is NOT filled at a loss: the gate still needs live out ≥ owed + gas", async () => {
    const { e, w, ord } = await setup();
    w.owed = 999_900_000n; // owed above route output − gas (e.g. the preview at a price that moved)
    const t = await e.tick({ fetchEntries: async () => [entry("0c", ord)] });
    expect(t.outcomes[0]?.status).toBe("skipped");
    expect(t.outcomes[0]?.reason).toMatch(/unprofitable: quote \d+ −0bps/);
    expect(w.sent).toHaveLength(0);
  });
});

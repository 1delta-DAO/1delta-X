/**
 * NATIVE DELIVERY through the `NativeBalance` view (task 30) and ITEM FILLS through
 * `executeItemFill` (task 31):
 *  • config (NATIVE_BALANCE, NATIVE_DIRECT_GAS, ITEM_FILLS, NETTED_DELIVERY_FUNDED_ITEMS, ITEM_FILL_GAS);
 *  • the exact DIRECT NativeBalance shape (one leg, to the maker, exclusive to the solver),
 *    routed as WRBTC; the start-up check against the solver's NATIVE_BALANCE / WNATIVE;
 *  • `nativeOut` quotes resolve to DIRECT, priced + NATIVE_DIRECT_GAS, and bind only a
 *    NativeBalance order;
 *  • item-bearing pull orders go through executeItemFill with the SDK's `lateItems`, no
 *    bump floor, no output patch — and only what the Settlement's capability flag admits.
 */
import { AGGREGATOR_FILL_SOLVER_ABI, decodePoolRoute, forLegPreFund, ItemOp, ItemPolicy, NO_PATCH, OrderSide, nativeOutLeg, packTiming, withDeltaVerifyOutputs, withItemPolicy, type Item, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { legacyRouteConfig, loadConfig, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { gasShape } from "../src/gasRatio";
import { plainShape } from "../src/policy";
import { parseQuoteRequest, quoteMatches, type IssuedQuote, type QuoteRequest } from "../src/quote";
import { classifyRoute, NATIVE_OUT_NOT_ROUTABLE } from "../src/route";
import { MemoryStateStore } from "../src/state";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const LEGACY = getAddress("0x00000000000000000000000000000000000050a0");
const LEGACY_SANDBOX = getAddress("0x0000000000000000000000000000000000005a4c");
const NB = getAddress("0x00000000000000000000000000000000000a7b01");
const MAKER = getAddress("0x00000000000000000000000000000000000000bb");
const STRANGER = getAddress("0x00000000000000000000000000000000000000cc");
const MODULE = getAddress("0x00000000000000000000000000000000000000d1");
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
  NATIVE_BALANCE: NB,
};
const WRBTC = getAddress(ROOTSTOCK.wrbtc);
const USDT0 = getAddress(ROOTSTOCK.usdt0);
const GAS_PRICE = 26_065_600n;
const eqa = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** WRBTC = $100k on the fake pools. */
function rate(tin: string, tout: string, amt: bigint): bigint {
  if (eqa(tin, WRBTC) && eqa(tout, USDT0)) return amt / 10n ** 7n;
  if (eqa(tin, USDT0) && eqa(tout, WRBTC)) return amt * 10n ** 7n;
  return 0n;
}

/** A chain whose solver is v3 (`nativeDelivery()` = (NB, WRBTC)), v3 with native off (`(0, 0)`), pre-v3 (`none`: the getter reverts) or mis-wired. */
function fake(o: { solverNative?: "v3" | "none" | "other" | "off" } = {}) {
  const w = { owed: 0n, received: 0n, sent: [] as Array<{ data: Hex; gas?: bigint; to?: Address }> };
  const pub: Record<string, unknown> = {
    getCode: async () => "0x60",
    getGasPrice: async () => GAS_PRICE,
    getTransactionCount: async () => 0,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      w.sent.push({ data: t.data!, gas: t.gas, ...(t.to ? { to: getAddress(t.to) } : {}) });
      return keccak256(serializedTransaction);
    },
    getTransactionReceipt: async () => {
      throw new Error("Transaction receipt could not be found");
    },
    getTransaction: async () => ({}),
    readContract: async ({ functionName, address }: { functionName: string; address?: Address }) => {
      const legacy = address !== undefined && (eqa(address, LEGACY) || eqa(address, LEGACY_SANDBOX));
      switch (functionName) {
        case "SETTLEMENT": return ENV.SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return legacy ? LEGACY_SANDBOX : SANDBOX;
        case "POOL_VENUES": return 1n;
        case "poolVenue": return ["0xaF37EC98A00FD63689CF3060BF3B6784E00caD82", "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"];
        case "factory": return "0xaF37EC98A00FD63689CF3060BF3B6784E00caD82";
        case "OWNER": return legacy ? LEGACY : SOLVER;
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "nativeDelivery":
          // Solver v3's one getter for its (NativeBalance, WNATIVE) pair; a pre-v3 solver has none.
          if ((o.solverNative ?? "v3") === "none" || legacy) throw new Error("execution reverted"); // the legacy (v2) solver has none
          if (o.solverNative === "off") return [zeroAddress, zeroAddress];
          return [o.solverNative === "other" ? STRANGER : NB, WRBTC];
        case "previewFill": return [0n, [w.received], [w.owed]];
        case "previewBump": return 0n;
        case "decimals": return 6;
        case "balanceOf": return 10n ** 12n;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ functionName, args }: { functionName: string; args: unknown[] }) => {
      if (functionName === "quoteExactInputSingle" || functionName === "quoteExactOutputSingle") throw new Error("single-hop quoter not faked");
      const path = args[0] as Hex;
      return { result: [rate(`0x${path.slice(2, 42)}`, `0x${path.slice(-40)}`, args[1] as bigint), [], [], 100_000n] };
    },
    call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [w.owed] }) }),
    estimateGas: async () => 400_000n,
  };
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const now = () => Math.floor(Date.now() / 1000);

/** The app's DIRECT native market order: 50 USD₮0 → 0.0005 RBTC through the NativeBalance view. */
function nativeOrder(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: BigInt(now() + 300),
    legsIn: [{ token: USDT0, start: 50_000_000n, end: 0n }],
    legsOut: [nativeOutLeg({ nativeBalance: NB, start: 5n * 10n ** 14n })],
    timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}
const entry = (h: string, o: Order) => ({
  orderHash: ("0x" + h.repeat(32)) as Hex,
  announce: { order: o, sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: o.legsIn[0]!.start, validatorsPass: true },
});

describe("config", () => {
  it("NATIVE_BALANCE: unset = the SDK constant (the deployed Rootstock view), \"\" = off; NATIVE_DIRECT_GAS default 30k", () => {
    const { NATIVE_BALANCE: _nb, ...noNb } = ENV;
    expect(loadConfig(noNb).route!.nativeBalance).toBe(getAddress("0xA45ec37619C9F9B2f9d54692d578D1b1246c854c"));
    expect(loadConfig({ ...ENV, NATIVE_BALANCE: "" }).route!.nativeBalance).toBeUndefined();
    expect(loadConfig(ENV).route!.nativeBalance).toBe(NB);
    expect(loadConfig(ENV).route!.nativeDirectGas).toBe(30_000n);
    expect(loadConfig({ ...ENV, NATIVE_DIRECT_GAS: "35000" }).route!.nativeDirectGas).toBe(35_000n);
    expect(() => loadConfig({ ...ENV, NATIVE_BALANCE: "0x12" })).toThrow(/NATIVE_BALANCE/);
  });

  it("ITEM_FILLS off by default; on, the live-Settlement capability (false) unless NETTED_DELIVERY_FUNDED_ITEMS", () => {
    expect(loadConfig(ENV).route!.itemFills).toBeUndefined();
    expect(loadConfig({ ...ENV, ITEM_FILLS: "1" }).route!.itemFills).toEqual({ nettedDeliveryFundedItems: false, gas: 120_000n });
    expect(loadConfig({ ...ENV, ITEM_FILLS: "1", NETTED_DELIVERY_FUNDED_ITEMS: "1", ITEM_FILL_GAS: "90000" }).route!.itemFills).toEqual({ nettedDeliveryFundedItems: true, gas: 90_000n });
  });
});

describe("the DIRECT NativeBalance shape", () => {
  const rc = loadConfig(ENV).route!;
  const ex = { nativeBalance: { view: NB, wrapped: WRBTC } };

  it("accepted exactly, routed as WRBTC", () => {
    expect(plainShape(nativeOrder(), ex)).toEqual({ ok: true, nativeBalance: true });
    const v = classifyRoute(nativeOrder(), rc, ex);
    expect(v.ok && [v.direct, v.native, v.tokenIn, v.tokenOut]).toEqual([true, true, USDT0, WRBTC]);
    // An explicit maker recipient is the maker too.
    expect(classifyRoute(nativeOrder({ legsOut: [{ ...nativeOutLeg({ nativeBalance: NB, start: 1n }), recipient: MAKER }] }), rc, ex).ok).toBe(true);
  });

  it.each([
    ["pull delivery", { timing: 0n, exclusiveFiller: zeroAddress }, /DIRECT/],
    ["another exclusive filler", { exclusiveFiller: STRANGER }, /another filler/],
    ["a third-party recipient", { legsOut: [{ ...nativeOutLeg({ nativeBalance: NB, start: 1n }), recipient: STRANGER }] }, /third party/],
    ["an item", { items: [{ op: ItemOp.MAKE, module: MODULE, amount: 0n, recipient: zeroAddress, data: "0x" as Hex }] }, /items/],
    ["WRBTC in (an unwrap)", { legsIn: [{ token: WRBTC, start: 1n, end: 0n }] }, /unwrap/],
    ["the view as the input", { legsIn: [{ token: NB, start: 1n, end: 0n }], legsOut: [{ token: USDT0, start: 1n, end: 0n, recipient: zeroAddress }] }, /input leg/],
    ["a validator", { validators: [{ target: STRANGER, data: "0x" as Hex }] }, /validators/],
  ] as const)("refuses %s", (_n, over, why) => {
    const v = classifyRoute(nativeOrder(over as Partial<Order>), rc, ex);
    expect(v.ok).toBe(false);
    expect(!v.ok && v.reason).toMatch(why);
  });

  it("with native delivery off the view is just an unknown token", () => {
    const v = classifyRoute(nativeOrder(), rc, {});
    expect(!v.ok && v.reason).toMatch(/ROUTE_TOKENS/);
  });
});

describe("native quotes: DIRECT, + NATIVE_DIRECT_GAS, bound to the NativeBalance order", () => {
  const cfg = loadConfig(ENV);
  const body = { chainId: 30, side: "buy", tokenIn: USDT0, tokenOut: WRBTC, amountIn: "50000000", nativeOut: true };
  const req = (over: Partial<QuoteRequest> = {}): QuoteRequest => ({ chainId: 30, tokenIn: USDT0, tokenOut: WRBTC, amountIn: 50_000_000n, side: "buy", delivery: "direct", maker: MAKER, nativeOut: true, ...over });

  it("parse: `auto` and `direct` resolve to direct, `pull` is refused", () => {
    for (const delivery of ["auto", "direct"]) {
      const v = parseQuoteRequest({ ...body, delivery }, cfg);
      expect(v.ok && [v.req.delivery, v.req.nativeOut]).toEqual(["direct", true]);
    }
    const p = parseQuoteRequest({ ...body, delivery: "pull" }, cfg);
    expect(!p.ok && p.reason).toMatch(/direct delivery/);
  });

  it("a v3 solver quotes it at the direct fallback + NATIVE_DIRECT_GAS, learned under the `+native` WRBTC shape", async () => {
    const { chain } = fake();
    const e = await Engine.create({ cfg, chain, store: new MemoryStateStore(), log: () => {} });
    const q = await e.quote(req());
    if (!q.ok) throw new Error(q.reason);
    expect([q.quote.delivery, q.quote.strategy, q.quote.nativeOut]).toEqual(["direct", "route", true]);
    expect(q.quote.gasUnits).toBe(((360_000n + 30_000n) * 880_000n) / 1_000_000n);
    expect(q.quote.grossOut).toBe(5n * 10n ** 14n); // $50 of WRBTC at $100k
    // The quote binds the NativeBalance order it prices, and nothing else.
    const issued = e.quotes.toJSON().at(-1)!;
    expect(issued.tokenOut).toBe(NB.toLowerCase());
    const ord = nativeOrder({ side: OrderSide.BUY, legsOut: [nativeOutLeg({ nativeBalance: NB, start: q.quote.amountOut })] });
    expect(quoteMatches(issued, ord, now(), 120)).toBe(true);
    expect(quoteMatches(issued, nativeOrder({ legsOut: [{ token: WRBTC, start: q.quote.amountOut, end: 0n, recipient: zeroAddress }] }), now(), 120)).toBe(false);
    // A learned `+native` shape replaces the fallback.
    const shape = gasShape("route", "direct", USDT0, WRBTC, SOLVER, undefined, "native");
    expect(shape).toMatch(/\+plain\+native$/);
    e.gasRatios.record(shape, 400_000n, 360_000n, 1);
    const learned = await e.quote(req({ amountIn: 60_000_000n }));
    expect(learned.ok && learned.quote.gasUnits).toBe(e.gasRatios.priced(shape, 400_000n));
  });

  it("refused when the solver is not v3 or delivers through another view, or NATIVE_BALANCE is off", async () => {
    for (const solverNative of ["none", "other", "off"] as const) {
      const { chain } = fake({ solverNative });
      const e = await Engine.create({ cfg, chain, store: new MemoryStateStore(), log: () => {} });
      const q = await e.quote(req());
      expect(!q.ok && q.reason).toMatch(/native delivery is off/);
    }
    const { chain } = fake();
    const off = await Engine.create({ cfg: loadConfig({ ...ENV, NATIVE_BALANCE: "" }), chain, store: new MemoryStateStore(), log: () => {} });
    const q = await off.quote(req());
    expect(!q.ok && q.reason).toMatch(/NATIVE_BALANCE unset/);
  });

  it("a plain quote never binds a NativeBalance order; no quote binds an item order", () => {
    const q: IssuedQuote = { id: "q", tokenIn: USDT0.toLowerCase(), tokenOut: WRBTC.toLowerCase(), amountIn: "50000000", amountOut: (5n * 10n ** 14n).toString(), delivery: "direct", issuedAt: 0, validUntil: 2_000_000_000 };
    expect(quoteMatches(q, nativeOrder(), 1, 30)).toBe(false);
    const wrbtcOrder = nativeOrder({ legsOut: [{ token: WRBTC, start: 5n * 10n ** 14n, end: 0n, recipient: zeroAddress }] });
    expect(quoteMatches(q, wrbtcOrder, 1, 30)).toBe(true);
    expect(quoteMatches(q, { ...wrbtcOrder, items: [{ op: ItemOp.TAKE, module: MODULE, amount: 1n, recipient: zeroAddress, data: "0x" }] }, 1, 30)).toBe(false);
  });
});

describe("native fills: executeFill with a pool plan ending in WRBTC", () => {
  it("routes USD₮0 → WRBTC exact-output of the owed amount (the solver is the payee on-chain), priced + NATIVE_DIRECT_GAS", async () => {
    const { chain, w } = fake();
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    w.received = 50_000_000n;
    w.owed = 4n * 10n ** 14n; // $40 of RBTC for $50: plenty of margin
    const t = await e.tick({ fetchEntries: async () => [entry("1a", nativeOrder({ legsOut: [nativeOutLeg({ nativeBalance: NB, start: w.owed })] }))] });
    expect(t.outcomes[0]?.status).toBe("pending");
    expect(w.sent).toHaveLength(1);
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: w.sent[0]!.data });
    expect(d.functionName).toBe("executeFill");
    const plan = d.args[3] as { data: Hex; amountOutOffset: bigint; minBumpBps: bigint };
    const route = decodePoolRoute(plan.data);
    expect(route.tokens.map((x) => x.toLowerCase())).toEqual([USDT0.toLowerCase(), WRBTC.toLowerCase()]);
    expect(route.amountOut).toBe(w.owed);
    expect(e.pending?.info?.tag).toMatch(/direct\+native/);
    expect(e.pending?.gasMeter?.shape).toBe(gasShape("route", "direct", USDT0, WRBTC, SOLVER, undefined, "native"));
  });

  it("a pre-v3 solver: the order rests (native delivery off), nothing is sent", async () => {
    const { chain, w } = fake({ solverNative: "none" });
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    w.received = 50_000_000n;
    w.owed = 4n * 10n ** 14n;
    const t = await e.tick({ fetchEntries: async () => [entry("1b", nativeOrder())] });
    expect(t.outcomes[0]?.status).toBe("skipped");
    expect(t.outcomes[0]?.reason).toMatch(/native delivery is off/);
    expect(w.sent).toHaveLength(0);
  });
});

describe("item fills: executeItemFill with the SDK's lateItems", () => {
  const word = (v: bigint): Hex => encodeAbiParameters([{ type: "uint256" }], [v]);
  /** A PULL order selling 1 WRBTC-cent for USD₮0, carrying `items`. */
  const itemOrder = (items: Item[], over: Partial<Order> = {}): Order =>
    nativeOrder({
      legsIn: [{ token: WRBTC, start: 10n ** 16n, end: 0n }],
      legsOut: [{ token: USDT0, start: 900_000_000n, end: 0n, recipient: zeroAddress }],
      timing: 0n,
      exclusiveFiller: zeroAddress,
      items,
      ...over,
    });
  const TAKE: Item = { op: ItemOp.TAKE, module: MODULE, amount: 10n ** 16n, recipient: zeroAddress, data: word(0n) };
  const MAKE_PULL: Item = { op: ItemOp.MAKE, module: MODULE, amount: 900_000_000n, recipient: zeroAddress, data: word(7n) };
  const MAKE_PREFUND: Item = { op: ItemOp.MAKE, module: MODULE, amount: 0n, recipient: zeroAddress, data: word(forLegPreFund(0, USDT0, 0)) };

  async function run(env: Record<string, string>, o: Order) {
    const { chain, w } = fake();
    const e = await Engine.create({ cfg: loadConfig({ ...ENV, ...env }), chain, store: new MemoryStateStore(), log: () => {} });
    w.received = 10n ** 16n;
    w.owed = 900_000_000n; // $900 for $1000 of WRBTC
    const t = await e.tick({ fetchEntries: async () => [entry("2a", o)] });
    return { t, w, e };
  }

  it("off by default: items are refused", async () => {
    const { t, w } = await run({}, itemOrder([TAKE]));
    expect(t.outcomes[0]?.reason).toMatch(/items not supported/);
    expect(w.sent).toHaveLength(0);
  });

  it("withdraw → swap → deposit on the LIVE Settlement: TAKE early, pull MAKE late; no bump floor, no output patch", async () => {
    const { t, w, e } = await run({ ITEM_FILLS: "1" }, itemOrder([TAKE, MAKE_PULL]));
    expect(t.outcomes[0]?.status).toBe("pending");
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: w.sent[0]!.data });
    expect(d.functionName).toBe("executeItemFill");
    const plan = d.args[3] as { minBumpBps: bigint; amountOutOffset: bigint; maxPay: bigint };
    expect([plan.minBumpBps, plan.amountOutOffset, plan.maxPay]).toEqual([0n, NO_PATCH, 900_000_000n]);
    expect(d.args[5]).toBe(0b10n); // lateItems: item 1 (the MAKE) after delivery
    expect(e.pending?.gasMeter?.shape).toBe(gasShape("route", "pull", WRBTC, USDT0, SOLVER, undefined, "items"));
  });

  it("a pre-funded MAKE (swap → supply) waits for the task-31 Settlement; then its leg may go to the module", async () => {
    const supply = itemOrder([MAKE_PREFUND], { legsOut: [{ token: USDT0, start: 900_000_000n, end: 0n, recipient: MODULE }] });
    const live = await run({ ITEM_FILLS: "1" }, supply);
    expect(live.t.outcomes[0]?.reason).toMatch(/pre-funded MAKE.*nettedDeliveryFundedItems/);
    expect(live.w.sent).toHaveLength(0);
    const next = await run({ ITEM_FILLS: "1", NETTED_DELIVERY_FUNDED_ITEMS: "1" }, supply);
    expect(next.t.outcomes[0]?.status).toBe("pending");
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: next.w.sent[0]!.data });
    expect([d.functionName, d.args[5]]).toEqual(["executeItemFill", 1n]);
    // …but never to a module no item consumes it with.
    const stray = await run({ ITEM_FILLS: "1", NETTED_DELIVERY_FUNDED_ITEMS: "1" }, itemOrder([MAKE_PULL], { legsOut: [{ token: USDT0, start: 1n, end: 0n, recipient: MODULE }] }));
    expect(stray.t.outcomes[0]?.reason).toMatch(/third party/);
  });

  it("refusals from the classifier: CANONICAL policy, DIRECT with items, the module native-out shape", async () => {
    const canon = await run({ ITEM_FILLS: "1" }, itemOrder([TAKE], { timing: withItemPolicy(0n, ItemPolicy.CANONICAL) }));
    expect(canon.t.outcomes[0]?.reason).toMatch(/CANONICAL/);
    const direct = await run({ ITEM_FILLS: "1" }, itemOrder([TAKE], { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }));
    expect(direct.t.outcomes[0]?.reason).toMatch(/DIRECT/);
    // The pre-task-31 NativeUnwrapModule shape signed CANONICAL: forward-only, never
    // schedulable by the solver.
    const unwrap = getAddress(ROOTSTOCK.nativeUnwrap);
    const moduleShape = (policy: ItemPolicy) =>
      nativeOrder({
        legsIn: [{ token: USDT0, start: 50_000_000n, end: 0n }],
        legsOut: [{ token: WRBTC, start: 4n * 10n ** 14n, end: 0n, recipient: unwrap }],
        timing: withItemPolicy(packTiming(0, 0, 0), policy),
        exclusiveFiller: zeroAddress,
        items: [{ op: ItemOp.MAKE, module: unwrap, amount: 0n, recipient: zeroAddress, data: encodeAbiParameters([{ type: "uint256" }, { type: "address" }], [forLegPreFund(0, WRBTC, 0), zeroAddress]) }],
      });
    const m = await run({ ITEM_FILLS: "1", NETTED_DELIVERY_FUNDED_ITEMS: "1" }, moduleShape(ItemPolicy.CANONICAL));
    expect(m.t.outcomes[0]?.reason).toContain(NATIVE_OUT_NOT_ROUTABLE);
    expect(m.t.outcomes[0]?.reason).toMatch(/CANONICAL/);
  });

  it("the module native-out shape signed ORDERED (the app since task 31) fills zero-capital on the task-31 Settlement: the unwrap runs late", async () => {
    const unwrap = getAddress(ROOTSTOCK.nativeUnwrap);
    const o = nativeOrder({
      legsIn: [{ token: USDT0, start: 50_000_000n, end: 0n }],
      legsOut: [{ token: WRBTC, start: 4n * 10n ** 14n, end: 0n, recipient: unwrap }],
      timing: withItemPolicy(packTiming(0, 0, 0), ItemPolicy.ORDERED),
      exclusiveFiller: zeroAddress,
      items: [{ op: ItemOp.MAKE, module: unwrap, amount: 0n, recipient: zeroAddress, data: encodeAbiParameters([{ type: "uint256" }, { type: "address" }], [forLegPreFund(0, WRBTC, 0), zeroAddress]) }],
    });
    const { chain, w } = fake();
    const e = await Engine.create({ cfg: loadConfig({ ...ENV, ITEM_FILLS: "1", NETTED_DELIVERY_FUNDED_ITEMS: "1" }), chain, store: new MemoryStateStore(), log: () => {} });
    w.received = 50_000_000n;
    w.owed = 4n * 10n ** 14n;
    const t = await e.tick({ fetchEntries: async () => [entry("2f", o)] });
    expect(t.outcomes[0]?.status).toBe("pending");
    const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: w.sent[0]!.data });
    expect([d.functionName, d.args[5]]).toEqual(["executeItemFill", 1n]);
    // On the LIVE Settlement it waits (pre-funded MAKE refused on the netted path).
    const live = await run({ ITEM_FILLS: "1" }, o);
    expect(live.t.outcomes[0]?.reason).toMatch(/pre-funded MAKE/);
  });
});

describe("solver migration: AGGREGATOR_SOLVER_LEGACY", () => {
  const LEGACY_ENV = { ...ENV, AGGREGATOR_SOLVER_LEGACY: LEGACY, ROUTE_PROFIT_RECIPIENT: SOLVER };
  const wrbtcDirect = (exclusiveFiller: Address) =>
    nativeOrder({ legsOut: [{ token: WRBTC, start: 4n * 10n ** 14n, end: 0n, recipient: zeroAddress }], exclusiveFiller });

  it("config: the legacy list parses; listing the primary itself is refused", () => {
    expect(loadConfig(LEGACY_ENV).route!.legacySolvers).toEqual([LEGACY]);
    expect(loadConfig(ENV).route!.legacySolvers).toEqual([]);
    expect(() => loadConfig({ ...ENV, AGGREGATOR_SOLVER_LEGACY: SOLVER })).toThrow(/must not list AGGREGATOR_SOLVER/);
  });

  it("legacyRouteConfig: same routing, its own solver and retained spread, no native / item fills", () => {
    const rc = loadConfig(LEGACY_ENV).route!;
    const l = legacyRouteConfig(rc, LEGACY);
    expect(l.solver).toBe(LEGACY);
    expect(l.onlyNamed).toBe(true);
    expect(l.profitRecipient).toBe(LEGACY); // retain mode follows the solver
    expect(l.nativeBalance).toBeUndefined();
    expect(l.itemFills).toBeUndefined();
    const treasury = getAddress("0x00000000000000000000000000000000000077ee");
    expect(legacyRouteConfig({ ...rc, profitRecipient: treasury }, LEGACY).profitRecipient).toBe(treasury);
  });

  it("an order naming the legacy solver is filled THROUGH the legacy solver; any other through the primary", async () => {
    const { chain, w } = fake();
    const e = await Engine.create({ cfg: loadConfig(LEGACY_ENV), chain, store: new MemoryStateStore(), log: () => {} });
    expect(e.legacyRoutes).toHaveLength(1);
    w.received = 50_000_000n;
    w.owed = 4n * 10n ** 14n;
    const t1 = await e.tick({ fetchEntries: async () => [entry("2a", wrbtcDirect(LEGACY))] });
    expect(t1.outcomes[0]?.status).toBe("pending");
    expect(w.sent.at(-1)!.to).toBe(LEGACY);

    const { chain: chain2, w: w2 } = fake();
    const e2 = await Engine.create({ cfg: loadConfig(LEGACY_ENV), chain: chain2, store: new MemoryStateStore(), log: () => {} });
    w2.received = 50_000_000n;
    w2.owed = 4n * 10n ** 14n;
    const t2 = await e2.tick({ fetchEntries: async () => [entry("2b", wrbtcDirect(SOLVER))] });
    expect(t2.outcomes[0]?.status).toBe("pending");
    expect(w2.sent.at(-1)!.to).toBe(getAddress(SOLVER));
  });

  it("the legacy instance passes on orders it is not named in without a single read", async () => {
    const { chain } = fake();
    const e = await Engine.create({ cfg: loadConfig(LEGACY_ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const l = e.legacyRoutes[0]!;
    const other = entry("2c", wrbtcDirect(SOLVER));
    expect(l.accepts(other as never)).toBe(false);
    const o = await l.consider(other as never);
    expect(o.status).toBe("skipped");
    expect(o.reason).toMatch(/does not name it/);
  });

  it("native orders stay with the primary: the legacy (v2) instance has no native delivery", () => {
    const l = legacyRouteConfig(loadConfig(LEGACY_ENV).route!, LEGACY);
    expect(classifyRoute(nativeOrder({ exclusiveFiller: LEGACY }), l, { graph: [], anyPath: true }).ok).toBe(false);
  });
});

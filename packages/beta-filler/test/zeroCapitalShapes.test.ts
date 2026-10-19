/**
 * REVIEW-2026-10-18-zero-capital-fills.md, the off-chain half:
 *  • §4  the route admits the shapes the deployed solver v3 already fills zero-capital —
 *        fee legs, proportional inputs, validators, fill/pricing modules, third-party
 *        recipients, sigless orders — each behind its ROUTE_ADMIT_* switch, with the
 *        filler math each needs (owed over the anchor legs, the in-kind leg kept back,
 *        the remainder sentinel for a proportional fill);
 *  • §4  the operator sweep of retained solver balances (SOLVER_SWEEP);
 *  • S-5 a LOST RACE is not a strike: the on-chain remainder is re-quoted;
 *  • M-3 / S-4 fused composites are flash-required and go nowhere but the flash stub.
 */
import {
  AGGREGATOR_FILL_SOLVER_ABI,
  AGGREGATOR_FILL_SOLVER_V4_ABI,
  decodePoolRoute,
  encodePoolRoute,
  NO_PATCH,
  encodeProportional,
  ItemOp,
  OrderSide,
  withDeltaVerifyOutputs,
  withFillOnce,
  type Item,
  type Order,
} from "@1delta-x/sdk";
import { decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, keccak256, maxUint256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { legacyRouteConfig, loadConfig, parseCompositeModules, parseInventoryCaps, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { flashCandidates, flashJob, flashUnavailable, pathUsesPool, v3FlashFee } from "../src/flash";
import { Guard, RACE_HOLD_MS } from "../src/guard";
import { entryFromJson, fetchOrders } from "../src/intake";
import { classify, plainShape } from "../src/policy";
import { classifyRoute, isExactInputPlan, legAmounts, sentinelPlan } from "../src/route";
import { MemoryStateStore } from "../src/state";
import { planSweep, SOLVER_SWEEP_ABI, SWEEP_ALL_SELECTOR, sweepWorthIt } from "../src/sweep";
import { FlashKind, hashOrderStruct, MATCH_FLASH_SOLVER_ABI, orderToJson } from "@1delta-x/sdk";

const SOLVER = getAddress("0x00000000000000000000000000000000000050a1");
const SANDBOX = getAddress("0x0000000000000000000000000000000000005a4d");
const LEGACY = getAddress("0x00000000000000000000000000000000000050a0");
const SETTLEMENT = getAddress("0x0000000000000000000000000000000000000001");
const MAKER = getAddress("0x00000000000000000000000000000000000000bb");
const STRANGER = getAddress("0x00000000000000000000000000000000000000cc");
const TREASURY = getAddress("0x0000000000000000000000000000000000007e45");
const COMPOSITE = getAddress("0x00000000000000000000000000000000000000c0");
const FLASH = getAddress("0x000000000000000000000000000000000000f1a5");
const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT,
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
  AGGREGATOR_SOLVER: SOLVER,
  INVENTORY_ENABLED: "0",
  SUSHI_ENABLED: "0",
  ROUTE_DISCOVERY: "0",
  DRY_RUN: "0",
  NATIVE_BALANCE: "",
};
const WRBTC = getAddress(ROOTSTOCK.wrbtc);
const USDT0 = getAddress(ROOTSTOCK.usdt0);
const GAS_PRICE = 26_065_600n;
const eqa = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const now = () => Math.floor(Date.now() / 1000);

/** WRBTC = $100k on the fake pools. */
function rate(tin: string, tout: string, amt: bigint): bigint {
  if (eqa(tin, WRBTC) && eqa(tout, USDT0)) return amt / 10n ** 7n;
  if (eqa(tin, USDT0) && eqa(tout, WRBTC)) return amt * 10n ** 7n;
  return 0n;
}

/** A chain whose lens previews `paid` per output leg, with Settlement's `filled` / nonce state and the solver's balances. */
function fake() {
  const w = {
    received: 10n ** 16n,
    paid: [900_000_000n] as bigint[],
    previewAmounts: [] as bigint[],
    sent: [] as Array<{ data: Hex; to?: Address }>,
    receipt: "none" as "none" | "success" | "reverted",
    mined: 0,
    filled: 0n,
    remaining: undefined as bigint | undefined,
    nonceUsed: false,
    operator: true,
    code: "0x60" as Hex,
    solverBalances: {} as Record<string, bigint>,
    /** What the flash solver's simulated executeMatch sweeps, per token (WRBTC, USDT0). */
    flashProfit: [0n, 9_000_000n] as bigint[],
    reads: {} as Record<string, number>,
  };
  const pub: Record<string, unknown> = {
    getCode: async () => w.code,
    getGasPrice: async () => GAS_PRICE,
    getTransactionCount: async () => w.mined,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      w.sent.push({ data: t.data!, ...(t.to ? { to: getAddress(t.to) } : {}) });
      return keccak256(serializedTransaction);
    },
    getTransactionReceipt: async () => {
      if (w.receipt === "none") throw new Error("Transaction receipt could not be found");
      w.mined = w.sent.length;
      return { status: w.receipt, gasUsed: 100_000n, effectiveGasPrice: GAS_PRICE };
    },
    getTransaction: async () => ({}),
    readContract: async ({ functionName, address, args }: { functionName: string; address?: Address; args?: unknown[] }) => {
      w.reads[functionName] = (w.reads[functionName] ?? 0) + 1;
      switch (functionName) {
        case "SETTLEMENT": return SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return w.operator;
        case "SANDBOX": return SANDBOX;
        case "POOL_VENUES": return 1n;
        case "poolVenue": return ["0xaF37EC98A00FD63689CF3060BF3B6784E00caD82", "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"];
        case "factory": return "0xaF37EC98A00FD63689CF3060BF3B6784E00caD82";
        case "OWNER": return SOLVER;
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "nativeDelivery": return [zeroAddress, zeroAddress];
        case "previewFill":
          w.previewAmounts.push(args![1] as bigint);
          return [0n, [w.received], w.paid];
        case "previewBump": return 0n;
        case "decimals": return 6;
        case "filled": return w.filled;
        case "remaining": return w.remaining ?? 10n ** 30n;
        case "isNonceCancelled": return w.nonceUsed;
        case "balanceOf": return eqa(args![0] as string, SOLVER) ? w.solverBalances[address!.toLowerCase()] ?? 0n : 10n ** 12n;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ functionName, args }: { functionName: string; args: unknown[] }) => {
      if (functionName === "quoteExactInputSingle" || functionName === "quoteExactOutputSingle") throw new Error("single-hop quoter not faked");
      const path = args[0] as Hex;
      return { result: [rate(`0x${path.slice(2, 42)}`, `0x${path.slice(-40)}`, args[1] as bigint), [], [], 100_000n] };
    },
    call: async ({ to }: { to?: Address }) =>
      to && eqa(to, FLASH)
        ? { data: encodeFunctionResult({ abi: MATCH_FLASH_SOLVER_ABI, functionName: "executeMatch", result: [[WRBTC, USDT0], w.flashProfit] }) }
        : { data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: w.paid }) },
    estimateGas: async () => 400_000n,
  };
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

/** A PULL order selling 0.01 WRBTC for 900 USD₮0. */
function order(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 7n, expiry: BigInt(now() + 3_600),
    legsIn: [{ token: WRBTC, start: 10n ** 16n, end: 0n }],
    legsOut: [{ token: USDT0, start: 900_000_000n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}
const entry = (h: string, o: Order, fillable = o.legsIn[0]!.start) => ({
  orderHash: ("0x" + h.repeat(32)) as Hex,
  announce: { order: o, sig: "0x01" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: fillable, validatorsPass: true },
});
/** In-kind fee FIRST (WRBTC → stranger), the maker's USD₮0, and a USD₮0 fee leg. */
const feeOrder = () =>
  order({
    legsOut: [
      { token: WRBTC, start: 10n ** 14n, end: 0n, recipient: STRANGER },
      { token: USDT0, start: 900_000_000n, end: 0n, recipient: zeroAddress },
      { token: USDT0, start: 2_000_000n, end: 0n, recipient: STRANGER },
    ],
  });
const decodeFill = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data });

async function engine(env: Record<string, string> = {}, f = fake()) {
  const logs: string[] = [];
  const e = await Engine.create({ cfg: loadConfig({ ...ENV, ...env }), chain: f.chain, store: new MemoryStateStore(), log: (m) => logs.push(m) });
  return { e, w: f.w, logs };
}

describe("§4 shape admissions: config", () => {
  it("defaults: fee legs, proportional, third-party ON (solver-tested); validators, modules, sigless OFF", () => {
    expect(loadConfig(ENV).route!.admit).toEqual({ feeLegs: true, proportional: true, thirdPartyRecipients: true, validators: false, modules: false, sigless: false });
    const off = loadConfig({ ...ENV, ROUTE_ADMIT_FEE_LEGS: "0", ROUTE_ADMIT_PROPORTIONAL: "0", ROUTE_ADMIT_THIRD_PARTY: "0", ROUTE_ADMIT_VALIDATORS: "1", ROUTE_ADMIT_MODULES: "1", ROUTE_ADMIT_SIGLESS: "1" });
    expect(off.route!.admit).toEqual({ feeLegs: false, proportional: false, thirdPartyRecipients: false, validators: true, modules: true, sigless: true });
  });

  it("a legacy instance takes the plain shape only (no admissions, no flash, no sweep)", () => {
    const rc = loadConfig({ ...ENV, MATCH_FLASH_SOLVER: STRANGER, SOLVER_SWEEP: "1", SOLVER_SWEEP_TO: TREASURY }).route!;
    const l = legacyRouteConfig(rc, LEGACY);
    expect([l.admit, l.matchFlashSolver, l.sweep]).toEqual([{}, undefined, undefined]);
  });

  it("the inventory strategy is unchanged: no admission reaches it", () => {
    const tokens = loadConfig(ENV).tokens;
    const cfg = { tokens, policy: { buyUsdrif: true, sellUsdrif: true } };
    const usdrifOrder = order({ legsIn: [{ token: tokens.usdrif, start: 10n ** 18n, end: 0n }], legsOut: [{ token: tokens.usdt0, start: 1n, end: 0n, recipient: STRANGER }] });
    expect(classify(usdrifOrder, cfg, MAKER).ok).toBe(false);
    expect(classify(usdrifOrder, cfg, MAKER, { sigless: true }).ok).toBe(false);
  });
});

describe("§4 shape admissions: classification", () => {
  const rc = loadConfig(ENV).route!;
  const ex = { admit: rc.admit };
  const none = { admit: {} };

  it("fee legs: PULL, in-kind + anchor-token legs, routed into the ANCHOR (not legsOut[0]'s token)", () => {
    const v = classifyRoute(feeOrder(), rc, ex);
    expect(v.ok && [v.tokenIn, v.tokenOut, v.feeLegs, v.direct]).toEqual([WRBTC, USDT0, true, false]);
    expect(classifyRoute(feeOrder(), rc, none)).toMatchObject({ ok: false, reason: expect.stringMatching(/fee legs/) });
    // DIRECT: the pool route pays legsOut[0] only.
    expect(classifyRoute(order({ ...feeOrder(), timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }), rc, ex)).toMatchObject({ ok: false, reason: expect.stringMatching(/PULL/) });
    // A fee in a third token: no single-output route produces it.
    const third = order({ legsOut: [...order().legsOut, { token: getAddress(ROOTSTOCK.rif), start: 1n, end: 0n, recipient: STRANGER }] });
    expect(classifyRoute(third, rc, ex)).toMatchObject({ ok: false, reason: expect.stringMatching(/third token/) });
  });

  it("legAmounts: owed = Σ anchor-token legs, kept = Σ in-kind legs, routeIn = received − kept", () => {
    const pv = { received: [10n ** 16n], paid: [10n ** 14n, 900_000_000n, 2_000_000n] };
    expect(legAmounts(feeOrder(), pv, USDT0)).toEqual({ received: 10n ** 16n, owed: 902_000_000n, kept: 10n ** 14n, routeIn: 10n ** 16n - 10n ** 14n });
    expect(legAmounts(order(), { received: [5n], paid: [3n] }, USDT0)).toEqual({ received: 5n, owed: 3n, kept: 0n, routeIn: 5n });
  });

  it("proportional input: PULL, item-free; refused DIRECT, with items, or switched off", () => {
    const prop = order({ legsIn: [{ token: WRBTC, start: encodeProportional(10_000n), end: 10n ** 17n }] });
    expect(classifyRoute(prop, rc, ex)).toMatchObject({ ok: true, proportional: true });
    expect(classifyRoute(prop, rc, none)).toMatchObject({ ok: false, reason: expect.stringMatching(/proportional/) });
    expect(classifyRoute({ ...prop, timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }, rc, ex)).toMatchObject({ ok: false, reason: expect.stringMatching(/PULL/) });
    const item: Item = { op: ItemOp.TAKE, module: STRANGER, amount: 1n, recipient: zeroAddress, data: "0x" };
    expect(plainShape({ ...prop, items: [item] }, { ...ex, itemFills: { nettedDeliveryFundedItems: true } })).toMatchObject({ ok: false, reason: expect.stringMatching(/items/) });
  });

  it("validators / invariants and fill / pricing modules: off by default, admitted when switched on", () => {
    const val = order({ validators: [{ target: STRANGER, data: "0x" }] });
    const inv = order({ invariants: [{ target: STRANGER, data: "0x" }] });
    const fm = order({ fillModule: STRANGER });
    const pm = order({ pricingModule: STRANGER });
    for (const o of [val, inv]) {
      expect(classifyRoute(o, rc, ex)).toMatchObject({ ok: false, reason: expect.stringMatching(/validators/) });
      expect(classifyRoute(o, rc, { admit: { validators: true } }).ok).toBe(true);
    }
    for (const o of [fm, pm]) {
      expect(classifyRoute(o, rc, ex)).toMatchObject({ ok: false, reason: expect.stringMatching(/modules/) });
      expect(classifyRoute(o, rc, { admit: { modules: true } }).ok).toBe(true);
    }
  });

  it("third-party recipients: admitted on item-free orders (pull and direct), refused when switched off", () => {
    const pull = order({ legsOut: [{ token: USDT0, start: 1n, end: 0n, recipient: STRANGER }] });
    const direct = { ...pull, timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER };
    expect(classifyRoute(pull, rc, ex).ok).toBe(true);
    expect(classifyRoute(direct, rc, ex).ok).toBe(true);
    expect(classifyRoute(pull, rc, { admit: { ...rc.admit, thirdPartyRecipients: false } })).toMatchObject({ ok: false, reason: expect.stringMatching(/third party/) });
  });

  it("sigless: off by default, admitted when switched on; a single-signature permit order never", () => {
    expect(classifyRoute(order(), rc, { ...ex, sigless: true })).toMatchObject({ ok: false, reason: expect.stringMatching(/sigless/) });
    expect(classifyRoute(order(), rc, { admit: { sigless: true }, sigless: true }).ok).toBe(true);
    expect(classifyRoute(order(), rc, { admit: { sigless: true, feeLegs: true }, hasPermitBatch: true })).toMatchObject({ ok: false, reason: expect.stringMatching(/permit/) });
  });

  it("the intake keeps a sigless announce: `sigless: true` with an EMPTY signature only", async () => {
    const o = order();
    const item = (sig: string, sigless?: boolean) => ({ orderHash: hashOrderStruct(o), order: orderToJson(o), sig, ...(sigless ? { sigless } : {}), state: { ok: true, status: "Fillable", fillableAmount: "1", validatorsPass: true } });
    const res = (orders: unknown[]) => ({ ok: true, json: async () => ({ orders }) }) as unknown as Response;
    const got = await fetchOrders("http://book", async () => res([item("0x", true), item("0x"), item("0x01", true), item("0x01")]));
    expect(got.entries.map((e) => [e.announce.sig, e.announce.sigless ?? false])).toEqual([["0x", true], ["0x01", false]]);
    expect(got.skipped).toBe(2);
    expect(entryFromJson({ order: orderToJson(o), sig: "0x", sigless: true }).announce.sigless).toBe(true);
    expect(() => entryFromJson({ order: orderToJson(o), sig: "0x01", sigless: true })).toThrow(/sigless/);
  });
});

describe("§4 shape admissions: the fill", () => {
  it("fee legs: the pool route swaps input − the in-kind leg; maxPay = minOut floor = Σ the USD₮0 legs", async () => {
    const { e, w } = await engine();
    w.paid = [10n ** 14n, 900_000_000n, 2_000_000n];
    const t = await e.tick({ fetchEntries: async () => [entry("f1", feeOrder())] });
    expect(t.outcomes[0]?.status).toBe("pending");
    const d = decodeFill(w.sent[0]!.data);
    expect(d.functionName).toBe("executeFill");
    const plan = d.args[3] as { maxPay: bigint; minOut: bigint; data: Hex };
    expect(plan.maxPay).toBe(902_000_000n);
    expect(plan.minOut > 902_000_000n).toBe(true);
    const route = decodePoolRoute(plan.data);
    expect([getAddress(route.tokens[0]!), getAddress(route.tokens[route.tokens.length - 1]!), route.amountIn]).toEqual([WRBTC, USDT0, 10n ** 16n - 10n ** 14n]);
    expect(d.args[2]).toBe(10n ** 16n); // the explicit size
  });

  it("proportional: previewed and filled WHOLE with the remainder sentinel", async () => {
    const { e, w } = await engine();
    const prop = order({ legsIn: [{ token: WRBTC, start: encodeProportional(10_000n), end: 10n ** 17n }] });
    const t = await e.tick({ fetchEntries: async () => [entry("f2", prop, 10n ** 16n)] });
    expect(t.outcomes[0]?.status).toBe("pending");
    expect(w.previewAmounts).toEqual([maxUint256]);
    expect(decodeFill(w.sent[0]!.data).args[2]).toBe(maxUint256);
  });

  it("an ordinary order keeps the explicit size (no sentinel: minOut is sized for it)", async () => {
    const { e, w } = await engine();
    await e.tick({ fetchEntries: async () => [entry("f3", order(), 4n * 10n ** 15n)] });
    expect(decodeFill(w.sent[0]!.data).args[2]).toBe(4n * 10n ** 15n);
  });
});

describe("S-5: a lost race is not a strike", () => {
  it("filled moved on-chain → no strike, no backoff; the next look fills the ON-CHAIN remainder", async () => {
    const { e, w, logs } = await engine();
    const en = entry("a1", order());
    await e.tick({ fetchEntries: async () => [en] });
    expect(e.pending?.race).toEqual({ settlement: SETTLEMENT, filledBefore: "0" });
    // A competitor filled 30 % before our tx landed; ours reverted (OverFill).
    w.filled = 3n * 10n ** 15n;
    w.remaining = 7n * 10n ** 15n;
    w.receipt = "reverted";
    const t2 = await e.tick({ fetchEntries: async () => [en] });
    expect(t2.resolution).toMatchObject({ status: "reverted", lostRace: { filledBefore: "0", filledAfter: (3n * 10n ** 15n).toString() } });
    expect(e.guard.entry(en.orderHash)).toBeUndefined(); // no strike
    expect(e.guard.raced(en.orderHash, Date.now())).toBe(true);
    expect(logs.some((l) => /LOST A RACE/.test(l))).toBe(true);
    // Same tick: the book still says the whole order — the fill is sized from the lens remainder.
    expect(t2.sent).toBeDefined();
    expect(decodeFill(w.sent[1]!.data).args[2]).toBe(7n * 10n ** 15n);
  });

  it("…a fully-filled one rests (remainder 0), nothing is sent", async () => {
    const { e, w } = await engine();
    const en = entry("a2", order());
    await e.tick({ fetchEntries: async () => [en] });
    w.filled = 10n ** 16n;
    w.remaining = 0n;
    w.receipt = "reverted";
    const t2 = await e.tick({ fetchEntries: async () => [en] });
    expect(t2.outcomes[0]).toMatchObject({ status: "skipped", rest: true, reason: expect.stringMatching(/another filler/) });
    expect(w.sent).toHaveLength(1);
  });

  it("a FILL-ONCE order: its nonce consumed by another fill is a lost race too", async () => {
    const { e, w } = await engine();
    const en = entry("a3", order({ timing: withFillOnce(0n) }));
    await e.tick({ fetchEntries: async () => [en] });
    expect(e.pending?.race).toEqual({ settlement: SETTLEMENT, filledBefore: "0", fillOnce: { maker: MAKER, nonce: "7" } });
    w.nonceUsed = true;
    w.receipt = "reverted";
    const t2 = await e.tick({});
    expect(t2.resolution?.lostRace).toEqual({ filledBefore: "0", nonceUsed: true });
    expect(e.guard.entry(en.orderHash)).toBeUndefined();
  });

  it("a genuine failure (nothing moved on-chain) is still a strike", async () => {
    const { e, w } = await engine();
    const en = entry("a4", order());
    await e.tick({ fetchEntries: async () => [en] });
    w.receipt = "reverted";
    const t2 = await e.tick({});
    expect(t2.resolution?.status).toBe("reverted");
    expect(t2.resolution?.lostRace).toBeUndefined();
    expect(e.guard.entry(en.orderHash)?.strikes).toBe(1);
    expect(e.guard.raced(en.orderHash, Date.now())).toBe(false);
  });

  it("the raced mark lapses after RACE_HOLD_MS and survives a restart", () => {
    const g = new Guard(loadConfig(ENV).gas);
    g.onLostRace("0xAB", 1_000);
    expect(g.raced("0xab", 1_000 + RACE_HOLD_MS - 1)).toBe(true);
    expect(new Guard(loadConfig(ENV).gas, g.toJSON()).raced("0xab", 2_000)).toBe(true);
    expect(g.raced("0xab", 1_000 + RACE_HOLD_MS)).toBe(false);
  });
});

describe("M-3 / S-4: fused composites are flash-required", () => {
  const word = (v: bigint): Hex => encodeAbiParameters([{ type: "uint256" }], [v]);
  /** Dolomite BatchOpen (TAKE, op word 4): one item both consumes the delivery and funds the pull. */
  const batchOpen: Item = { op: ItemOp.TAKE, module: COMPOSITE, amount: 10n ** 16n, recipient: zeroAddress, data: word(4n) };
  const env = { ITEM_FILLS: "1", COMPOSITE_MODULES: `dolomite-operator:${COMPOSITE}` };

  it("COMPOSITE_MODULES parses kind:address; refuses an unknown kind", () => {
    expect(parseCompositeModules(`dolomite-operator:${COMPOSITE}; river-open:${STRANGER}`)).toEqual({ [COMPOSITE.toLowerCase()]: "dolomite-operator", [STRANGER.toLowerCase()]: "river-open" });
    expect(() => parseCompositeModules(`nope:${COMPOSITE}`)).toThrow(/bad kind/);
    expect(loadConfig(ENV).route!.compositeModules).toEqual({});
    expect(loadConfig(ENV).route!.matchFlashSolver).toBeUndefined();
  });

  it("without MATCH_FLASH_SOLVER: a resting skip, never executeItemFill", async () => {
    const { e, w } = await engine(env);
    const t = await e.tick({ fetchEntries: async () => [entry("c1", order({ items: [batchOpen] }))] });
    expect(t.outcomes[0]).toMatchObject({ status: "skipped", rest: true, reason: expect.stringMatching(/flash-required.*fused composite.*no MATCH_FLASH_SOLVER/) });
    expect(w.sent).toHaveLength(0);
  });

  /** A cycle: borrow 100 USD₮0 against the delivered 0.0009 WRBTC (the flash fronts the WRBTC). */
  const cycle = () =>
    order({
      legsIn: [{ token: USDT0, start: 100_000_000n, end: 0n }],
      legsOut: [{ token: WRBTC, start: 9n * 10n ** 14n, end: 0n, recipient: zeroAddress }],
      items: [batchOpen],
    });
  const flashEnv = { ...env, MATCH_FLASH_SOLVER: FLASH };
  const flashWorld = () => {
    const f = fake();
    f.w.received = 100_000_000n;
    f.w.paid = [9n * 10n ** 14n];
    return f;
  };

  it("with MATCH_FLASH_SOLVER: a UNI_V3_SWAP executeMatch on the one Oku pool (a flash there would LOK its own repayment)", async () => {
    const { e, w } = await engine(flashEnv, flashWorld());
    const t = await e.tick({ fetchEntries: async () => [entry("c2", cycle(), 100_000_000n)] });
    expect(t.outcomes[0]?.status).toBe("pending");
    expect(w.sent[0]!.to).toBe(FLASH);
    const d = decodeFunctionData({ abi: MATCH_FLASH_SOLVER_ABI, data: w.sent[0]!.data });
    expect(d.functionName).toBe("executeMatch");
    const [g, job, plan] = d.args as unknown as [
      { orderHashes: Hex[]; expectedFilled: bigint[]; nonceMakers: Address[] },
      { flash: { kind: number; token: Address; amount: bigint; pairToken: Address; fee: number; venue: number; maxRepay: bigint }; swaps: unknown[]; recipient: Address; minProfit: Array<{ token: Address; min: bigint }> },
      { schedule: bigint[]; callTargets: Address[]; fillAmounts: bigint[]; profitRecipient: Address },
    ];
    expect([g.orderHashes, g.expectedFilled, g.nonceMakers]).toEqual([[("0x" + "c2".repeat(32)) as Hex], [0n], []]);
    expect(job.flash).toMatchObject({ kind: FlashKind.UNI_V3_SWAP, token: WRBTC, amount: 9n * 10n ** 14n, pairToken: USDT0, fee: 3000, venue: 0, maxRepay: 100_000_000n });
    expect(job.swaps).toEqual([]);
    expect(job.recipient).toBe(zeroAddress); // the operator (no external profit recipient configured)
    // The on-chain profit floor: gas at the measured estimate × r + min profit, in USD₮0.
    expect(job.minProfit).toHaveLength(1);
    expect(getAddress(job.minProfit[0]!.token)).toBe(USDT0);
    expect(job.minProfit[0]!.min > 0n && job.minProfit[0]!.min < 9_000_000n).toBe(true);
    // CALL → DELIVER → ITEM 0 → PULL 0 (F-4: draws a venue rounding shortfall, 0 otherwise).
    expect([plan.schedule, plan.callTargets, plan.fillAmounts, plan.profitRecipient]).toEqual([[4n, 1n, 2n, 0n], [FLASH], [100_000_000n], zeroAddress]);
    expect(e.pending).toMatchObject({ kind: "fill", strategy: "route", race: { settlement: SETTLEMENT, filledBefore: "0" } });
  });

  it("…a simulated profit below the measured gas + min profit is a resting skip, nothing is sent", async () => {
    const f = flashWorld();
    f.w.flashProfit = [0n, 1_000n];
    const { e, w } = await engine(flashEnv, f);
    const t = await e.tick({ fetchEntries: async () => [entry("c4", cycle(), 100_000_000n)] });
    expect(t.outcomes[0]).toMatchObject({ status: "skipped", rest: true, reason: expect.stringMatching(/unprofitable at the measured gas/) });
    expect(w.sent).toHaveLength(0);
  });

  it("…and a SETTLE item or a fee leg is refused before any RPC", async () => {
    const settle: Item = { op: ItemOp.SETTLE, module: STRANGER, amount: 1n, recipient: zeroAddress, data: "0x" };
    const { e, w } = await engine({ ...flashEnv, NETTED_DELIVERY_FUNDED_ITEMS: "1" }, flashWorld());
    const t = await e.tick({ fetchEntries: async () => [entry("c5", { ...cycle(), items: [batchOpen, settle] }, 100_000_000n)] });
    expect(t.outcomes[0]).toMatchObject({ status: "skipped", rest: true, reason: expect.stringMatching(/SETTLE/) });
    expect(w.sent).toHaveLength(0);
  });

  it("flashCandidates: a flash is never repaid on its own pool; both kinds priced, best first", async () => {
    const p3000 = { tokens: [USDT0, WRBTC], fees: [3000], venue: 0 };
    const p500 = { tokens: [USDT0, WRBTC], fees: [500], venue: 0 };
    expect(pathUsesPool(p3000, WRBTC, USDT0, 3000, 0)).toBe(true);
    expect(pathUsesPool(p3000, WRBTC, USDT0, 3000, 1)).toBe(false);
    const host = {
      // 1 USD₮0 → 1e7 wei WRBTC on both pools; 500 slightly better.
      quote: async (p: { fees: number[] }, amt: bigint) => (amt * 10n ** 7n * (p.fees[0] === 500 ? 1001n : 1000n)) / 1000n,
      quoteExactOut: async (_p: unknown, out: bigint) => ({ need: out / 10n ** 7n, gasUnits: 0n }),
      tokenValueWei: async (t: Address, a: bigint) => (eqa(t, WRBTC) ? a : a * 10n ** 7n),
    };
    const owed = 9n * 10n ** 14n;
    const c = await flashCandidates(host, { x: USDT0, c: WRBTC, received: 100_000_000n, owed, paths: [p3000, p500], slippageBps: 0n });
    const flashes = c.filter((k) => k.kind === FlashKind.UNI_V3_FLASH);
    expect(flashes.map((k) => [k.flashPool.fee, k.repay!.fees[0]])).toEqual(expect.arrayContaining([[3000, 500], [500, 3000]]));
    expect(flashes.every((k) => k.flashPool.fee !== k.repay!.fees[0])).toBe(true);
    expect(c.filter((k) => k.kind === FlashKind.UNI_V3_SWAP)).toHaveLength(2);
    const f = flashes.find((k) => k.flashPool.fee === 3000)!;
    expect(f.repayAmount).toBe(owed + v3FlashFee(owed, 3000));
    expect(f.profit).toBe((100_000_000n * 10n ** 7n * 1001n) / 1000n - f.repayAmount);
    // The job: the repayment swap spends the whole X balance, floored at what the flash takes back.
    const j = flashJob(f, { x: USDT0, c: WRBTC, owed, received: 100_000_000n, recipient: TREASURY, floor: 5n });
    expect(j.flash).toMatchObject({ kind: FlashKind.UNI_V3_FLASH, fee: 3000, maxRepay: f.repayAmount });
    expect(j.swaps).toHaveLength(1);
    expect(j.swaps[0]).toMatchObject({ amountIn: 0n, minOut: f.repayAmount });
    expect(j.minProfit).toEqual([{ token: WRBTC, min: 5n }]);
    expect(flashUnavailable("x")).toMatchObject({ ok: false, rest: true });
    expect(loadConfig({ ...ENV, MATCH_FLASH_SOLVER: FLASH }).route!.matchFlashGas).toBe(700_000n);
  });

  it("the same module's non-composite op (Borrow, op word 0) still schedules executeItemFill", async () => {
    const { e, w } = await engine(env);
    await e.tick({ fetchEntries: async () => [entry("c3", order({ items: [{ ...batchOpen, data: word(0n) }] }))] });
    expect(decodeFill(w.sent[0]!.data).functionName).toBe("executeItemFill");
  });
});

describe("§4 the operator sweep (SOLVER_SWEEP)", () => {
  const sweepEnv = { SOLVER_SWEEP: "1", SOLVER_SWEEP_TO: TREASURY, SOLVER_SWEEP_TOKENS: `${USDT0},${WRBTC}` };

  it("config: off by default; needs a destination in retain mode; never a solver", () => {
    expect(loadConfig(ENV).route!.sweep).toBeUndefined();
    expect(loadConfig({ ...ENV, ...sweepEnv }).route!.sweep).toMatchObject({ to: TREASURY, tokens: [USDT0, WRBTC], intervalMs: 3_600_000, minWei: 5n * 10n ** 13n, gasMult: 10n, afterFill: true });
    expect(() => loadConfig({ ...ENV, SOLVER_SWEEP: "1", ROUTE_PROFIT_RECIPIENT: SOLVER })).toThrow(/SOLVER_SWEEP_TO/);
    expect(loadConfig({ ...ENV, SOLVER_SWEEP: "1", ROUTE_PROFIT_RECIPIENT: TREASURY }).route!.sweep?.to).toBe(TREASURY);
    expect(() => loadConfig({ ...ENV, SOLVER_SWEEP: "1", SOLVER_SWEEP_TO: SOLVER })).toThrow(/must not be a solver/);
    expect(() => loadConfig({ ...ENV, SOLVER_SWEEP: "1", AGGREGATOR_SOLVER_LEGACY: LEGACY, SOLVER_SWEEP_TO: LEGACY })).toThrow(/must not be a solver/);
  });

  it("planSweep / sweepWorthIt: the 1-wei floors stay; batched = one sweepAll; else the most valuable token", () => {
    const bal = [
      { token: USDT0, balance: 50_000_001n, valueWei: 5n * 10n ** 14n },
      { token: WRBTC, balance: 1n, valueWei: 0n },
      { token: STRANGER, balance: 9n },
    ];
    const all = planSweep(SOLVER, TREASURY, bal, true)!;
    expect(decodeFunctionData({ abi: SOLVER_SWEEP_ABI, data: all.data }).args).toEqual([[USDT0, STRANGER], TREASURY, 1n]);
    expect(all.valueWei).toBe(5n * 10n ** 14n);
    const one = planSweep(SOLVER, TREASURY, bal, false)!;
    expect(decodeFunctionData({ abi: SOLVER_SWEEP_ABI, data: one.data }).args).toEqual([USDT0, TREASURY, 50_000_000n]);
    expect(planSweep(SOLVER, TREASURY, [{ token: USDT0, balance: 1n }], true)).toBeUndefined();
    const cfg = { minWei: 100n, gasMult: 10n };
    expect(sweepWorthIt(99n, 1n, cfg)).toMatch(/MIN_RBTC/);
    expect(sweepWorthIt(100n, 11n, cfg)).toMatch(/gas cost/);
    expect(sweepWorthIt(110n, 11n, cfg)).toBeUndefined();
  });

  it("an idle tick sweeps the retained balances with sweepAll from the operator, then waits SOLVER_SWEEP_SECONDS", async () => {
    const f = fake();
    f.w.code = `0x60${SWEEP_ALL_SELECTOR.slice(2)}` as Hex;
    f.w.solverBalances[USDT0.toLowerCase()] = 50_000_001n; // $50 of retained spread + the floor
    f.w.solverBalances[WRBTC.toLowerCase()] = 1n; // the floor alone
    const { e, w } = await engine(sweepEnv, f);
    const t = await e.tick({ fetchEntries: async () => [] });
    expect(t.solverSweep).toMatchObject({ status: "sent", solver: SOLVER, tokens: 1 });
    expect(w.sent[0]!.to).toBe(SOLVER);
    expect(decodeFunctionData({ abi: SOLVER_SWEEP_ABI, data: w.sent[0]!.data })).toMatchObject({ functionName: "sweepAll", args: [[USDT0], TREASURY, 1n] });
    expect(e.pending).toMatchObject({ kind: "sweep", strategy: "route" });
    w.receipt = "success";
    const t2 = await e.tick({ fetchEntries: async () => [] });
    expect(t2.solverSweep).toBeUndefined(); // not due again for an hour
    expect(w.sent).toHaveLength(1);
  });

  it("below the value threshold nothing is sent; an older solver gets one sweep(token) per tick; a non-operator never sweeps", async () => {
    const small = fake();
    small.w.solverBalances[USDT0.toLowerCase()] = 1_000_001n; // $1 < 0.00005 RBTC ($5)
    const a = await engine(sweepEnv, small);
    expect((await a.e.tick({ fetchEntries: async () => [] })).solverSweep).toMatchObject({ status: "skipped", reason: expect.stringMatching(/MIN_RBTC/) });
    expect(small.w.sent).toHaveLength(0);

    const old = fake();
    old.w.solverBalances[USDT0.toLowerCase()] = 50_000_001n;
    const b = await engine(sweepEnv, old);
    await b.e.tick({ fetchEntries: async () => [] });
    expect(decodeFunctionData({ abi: SOLVER_SWEEP_ABI, data: old.w.sent[0]!.data })).toMatchObject({ functionName: "sweep", args: [USDT0, TREASURY, 50_000_000n] });

    const stranger = fake();
    stranger.w.solverBalances[USDT0.toLowerCase()] = 50_000_001n;
    const c = await engine(sweepEnv, stranger);
    stranger.w.operator = false; // init passed; the sweeper asks again for itself
    expect((await c.e.tick({ fetchEntries: async () => [] })).solverSweep).toMatchObject({ status: "skipped", reason: expect.stringMatching(/not an operator/) });
    expect(stranger.w.sent).toHaveLength(0);
  });

  it("DRY_RUN only logs the plan", async () => {
    const f = fake();
    f.w.solverBalances[USDT0.toLowerCase()] = 50_000_001n;
    const { e, w, logs } = await engine({ ...sweepEnv, DRY_RUN: "1" }, f);
    expect((await e.tick({ fetchEntries: async () => [] })).solverSweep?.status).toBe("dry-run");
    expect(w.sent).toHaveLength(0);
    expect(logs.some((l) => /\[dry-run\] \[sweep\] would sweep/.test(l))).toBe(true);
  });
});

describe("solver v4 (in-tree) next to v3 (live): per-instance ABI", () => {
  const V4_CODE = `0x6080${"50358c9e"}${"ac44b909"}` as Hex;
  const v4World = () => {
    const f = fake();
    f.w.code = V4_CODE;
    return f;
  };
  const decodeV4 = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_V4_ABI, data });

  it("config: AGGREGATOR_SOLVER_VERSION 3 | 4 (unset = detect), ROUTE_INVENTORY_CAPS token:amount (< 2^128)", () => {
    expect(loadConfig(ENV).route!.solverVersion).toBeUndefined();
    expect(loadConfig({ ...ENV, AGGREGATOR_SOLVER_VERSION: "4" }).route!.solverVersion).toBe(4);
    expect(() => loadConfig({ ...ENV, AGGREGATOR_SOLVER_VERSION: "5" })).toThrow(/3 or 4/);
    expect(loadConfig(ENV).route!.inventoryCaps).toEqual({});
    expect(parseInventoryCaps(`${USDT0}:5000000`)).toEqual({ [USDT0.toLowerCase()]: 5_000_000n });
    expect(() => parseInventoryCaps(`${USDT0}:${1n << 128n}`)).toThrow(/AmountTooLarge/);
    expect(() => parseInventoryCaps("nope")).toThrow(/bad entry/);
    const l = legacyRouteConfig(loadConfig({ ...ENV, AGGREGATOR_SOLVER_VERSION: "4", ROUTE_INVENTORY_CAPS: `${USDT0}:1` }).route!, LEGACY);
    expect([l.solverVersion, l.inventoryCaps]).toEqual([undefined, {}]);
  });

  it("a v4 instance (detected): executeFill 0x50358c9e, the remainder sentinel on the input-patched pull plan, the inventory cap in the plan", async () => {
    const { e, w } = await engine({ ROUTE_INVENTORY_CAPS: `${USDT0}:5000000` }, v4World());
    await e.tick({ fetchEntries: async () => [entry("d1", order())] });
    expect(w.sent[0]!.data.slice(0, 10)).toBe("0x50358c9e");
    const d = decodeV4(w.sent[0]!.data);
    expect(d.args![2]).toBe(maxUint256);
    expect((d.args![3] as { inventory: bigint }).inventory).toBe(5_000_000n);
    expect(e.route!.version).toBe(4);
  });

  it("…an explicit size where the book's fillable is below the on-chain remainder (an under-funded maker)", async () => {
    const { e, w } = await engine({}, v4World());
    await e.tick({ fetchEntries: async () => [entry("d2", order(), 4n * 10n ** 15n)] });
    const d = decodeV4(w.sent[0]!.data);
    expect([d.args![2], (d.args![3] as { inventory: bigint }).inventory]).toEqual([4n * 10n ** 15n, 0n]);
  });

  it("…item fills carry the ItemFillGuard: the order hash, `filled` as read, liveNonce for a fill-once order", async () => {
    const word = (v: bigint): Hex => encodeAbiParameters([{ type: "uint256" }], [v]);
    const take: Item = { op: ItemOp.TAKE, module: STRANGER, amount: 10n ** 16n, recipient: zeroAddress, data: word(0n) };
    const f = v4World();
    f.w.filled = 0n;
    const { e, w } = await engine({ ITEM_FILLS: "1" }, f);
    await e.tick({ fetchEntries: async () => [entry("d3", order({ items: [take] }))] });
    const d = decodeV4(w.sent[0]!.data);
    expect(d.functionName).toBe("executeItemFill");
    expect(d.args![2]).toBe(10n ** 16n); // explicit on the item path (the guard races it instead)
    expect(d.args![7]).toEqual({ orderHash: ("0x" + "d3".repeat(32)) as Hex, expectedFilled: 0n, liveNonce: false, receipts: [] });
    const g = v4World();
    const two = await engine({ ITEM_FILLS: "1" }, g);
    await two.e.tick({ fetchEntries: async () => [entry("d4", order({ items: [take], timing: withFillOnce(0n) }))] });
    expect((decodeV4(g.w.sent[0]!.data).args![7] as { liveNonce: boolean }).liveNonce).toBe(true);
  });

  it("a v3 instance (the live one) keeps the old ABI — and AGGREGATOR_SOLVER_VERSION overrides detection", async () => {
    const { e, w, logs } = await engine({ ROUTE_INVENTORY_CAPS: `${USDT0}:5000000` });
    await e.tick({ fetchEntries: async () => [entry("d5", order())] });
    expect(w.sent[0]!.data.slice(0, 10)).toBe("0xd828b11a");
    expect(decodeFill(w.sent[0]!.data).args[2]).toBe(10n ** 16n);
    expect(logs.some((l) => /ROUTE_INVENTORY_CAPS ignored/.test(l))).toBe(true);
    const forced = await engine({ AGGREGATOR_SOLVER_VERSION: "4" });
    await forced.e.tick({ fetchEntries: async () => [entry("d6", order())] });
    expect(forced.w.sent[0]!.data.slice(0, 10)).toBe("0x50358c9e");
  });

  it("D-7: the inventory cap never rides on a DIRECT plan (it could not draw; it would only add the typed callback)", async () => {
    const { e, w } = await engine({ ROUTE_INVENTORY_CAPS: `${USDT0}:5000000` }, v4World());
    await e.tick({ fetchEntries: async () => [entry("d7", order({ timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER }))] });
    const d = decodeV4(w.sent[0]!.data);
    expect((d.args![3] as { inventory: bigint }).inventory).toBe(0n);
  });

  it("F-2: the remainder sentinel needs a patched input AND no absolute in-route floor (never a Sushi route)", () => {
    const base = { minOut: 1n, maxPay: 1n, minBumpBps: 0n, profitRecipient: zeroAddress, originator: zeroAddress, originatorPpm: 0, router: STRANGER, amountOutOffset: NO_PATCH, data: "0x" as Hex };
    expect(sentinelPlan({ ...base, amountInOffset: 4n }, "pool")).toBe(true);
    expect(sentinelPlan({ ...base, amountInOffset: 4n }, "sushi")).toBe(false);
    expect(sentinelPlan({ ...base, amountInOffset: NO_PATCH }, "pool")).toBe(false);
    expect(sentinelPlan({ ...base, amountInOffset: NO_PATCH }, "nordstern")).toBe(false);
  });

  it("S-6: only an exact-input plan may run an item fill", () => {
    const base = { minOut: 1n, maxPay: 1n, minBumpBps: 0n, profitRecipient: zeroAddress, originator: zeroAddress, originatorPpm: 0 };
    const pool = (amountOut: bigint) => ({ ...base, router: zeroAddress, amountInOffset: 0n, amountOutOffset: NO_PATCH, data: encodePoolRoute({ tokens: [WRBTC, USDT0], fees: [3000], venues: [0], amountIn: 1n, amountOut }).data });
    expect(isExactInputPlan(pool(0n))).toBe(true);
    expect(isExactInputPlan(pool(5n))).toBe(false);
    expect(isExactInputPlan({ ...pool(0n), router: STRANGER, amountOutOffset: 4n, data: "0x1234567890" })).toBe(false);
    expect(isExactInputPlan({ ...pool(0n), router: STRANGER, data: "0x12" })).toBe(true);
  });

  it("S-3: a further input currency is refused up front (MultiInputUnrouted), no RPC", () => {
    const rc = loadConfig(ENV).route!;
    const two = order({ legsIn: [{ token: WRBTC, start: 1n, end: 0n }, { token: getAddress(ROOTSTOCK.rif), start: 1n, end: 0n }] });
    expect(classifyRoute(two, rc, { admit: rc.admit })).toMatchObject({ ok: false, reason: expect.stringMatching(/MultiInputUnrouted/) });
  });
});

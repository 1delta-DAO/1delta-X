/**
 * Regression tests for the 2026-10 beta-filler quick audit (M-1..M-3, L-1, L-3..L-6,
 * I-1..I-3). Each started life as the auditor's repro of the bug; they now assert
 * the FIXED behaviour.
 */
import {
  AGGREGATOR_FILL_SOLVER_ABI,
  NO_PATCH,
  OrderSide,
  SUSHI_RED_SNWAPPER_ABI,
  packTiming,
  withDeltaVerifyOutputs,
  type Order,
} from "@1delta-x/sdk";
import {
  concat,
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionData,
  encodeFunctionResult,
  keccak256,
  parseTransaction,
  TransactionNotFoundError,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { afterEach, describe, expect, it, vi } from "vitest";

import { loadConfig, parsePaths, parsePools, ROOTSTOCK } from "../src/config";
import { dispatch, type Strategy } from "../src/dispatch";
import { Filler, type FillOutcome } from "../src/filler";
import { BACKOFF, GAS, Guard, resolvePending } from "../src/guard";
import { Budget } from "../src/policy";
import { grossUp, TYPED_CALLBACK_GAS } from "../src/route";
import { ROUTE_FILLS, RouteFiller } from "../src/routeFiller";
import { sanitize } from "../src/sanitize";
import { SUSHI_RED_SNWAPPER_ROOTSTOCK, validateSushiRoute } from "../src/sushi";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const MAKER = "0x00000000000000000000000000000000000000bb" as Address;
const EVIL = "0x000000000000000000000000000000000000dEaD" as Address;
const ENV = {
  PRIVATE_KEY: "0x" + "11".repeat(32),
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://localhost:8080/",
  AGGREGATOR_SOLVER: SOLVER,
  DRY_RUN: "0",
  SUSHI_ENABLED: "0",
};

function order(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.wrbtc, start: 10n ** 16n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: 900_000_000n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}

const GAS_PRICE = 26_065_600n;
const OWED = 900_000_000n;
const RECEIVED = 10n ** 16n;
const LS = String.fromCharCode(0x2028);
const ACCOUNT = privateKeyToAccount(("0x" + "11".repeat(32)) as Hex);
/** 1 RBTC = 100,000 USDT0 (6 dec): the fake QuoterV2's price along any path. */
const rbtcToUsdt0 = (wei: bigint) => (wei * 100_000n * 10n ** 6n + 10n ** 18n - 1n) / 10n ** 18n;

type Receipt = "success" | "reverted" | "timeout";
type Sent = { data: Hex; gas?: bigint; gasPrice?: bigint; type?: string; nonce?: number; hash: Hex };

/**
 * The send side every fake shares: a real local account signs, `sendRawTransaction`
 * records the decoded tx, and `getTransactionReceipt` answers per `state.receipt`
 * ("timeout" = not mined yet). Nonces advance as txs are "mined".
 */
function sender(state: { receipt: Receipt }, gasPrice: bigint, gasUsed: bigint) {
  const sent: Sent[] = [];
  const pub = {
    // A tx without a receipt yet has not consumed its nonce.
    getTransactionCount: async () => sent.length - (state.receipt === "timeout" && sent.length ? 1 : 0),
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      const hash = keccak256(serializedTransaction);
      sent.push({ data: t.data!, gas: t.gas, gasPrice: t.gasPrice, type: t.type, nonce: t.nonce, hash });
      return hash;
    },
    getTransactionReceipt: async () => {
      if (state.receipt === "timeout") throw new Error("Transaction receipt could not be found");
      return { status: state.receipt, gasUsed, effectiveGasPrice: gasPrice };
    },
    getTransaction: async () => ({}),
  };
  return { sent, pub };
}

/** A fake Chain: lens preview, QuoterV2 (1 RBTC = 100k USDT0), a passing simulation. */
function fakeChain(o: { simGas: bigint | bigint[]; receipt: Receipt; gasPrice?: bigint; makerPpm?: number; protocolPpm?: number }) {
  const gasSeq = Array.isArray(o.simGas) ? [...o.simGas] : undefined;
  const counts = { call: 0, estimateGas: 0 };
  const state = { receipt: o.receipt as Receipt };
  const tx = sender(state, o.gasPrice ?? GAS_PRICE, 300_000n);
  const sent = tx.sent;
  const pub = {
    ...tx.pub,
    getCode: async () => "0x60",
    getGasPrice: async () => o.gasPrice ?? GAS_PRICE,
    readContract: async ({ functionName }: { functionName: string }) => {
      switch (functionName) {
        case "SETTLEMENT": return ENV.SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return SANDBOX;
        case "OWNER": return SOLVER;
        case "MAKER_SURPLUS_PPM": return o.makerPpm ?? 0;
        case "PROTOCOL_SURPLUS_PPM": return o.protocolPpm ?? 0;
        case "previewFill": return [0n, [RECEIVED], [OWED]];
        case "previewBump": return 0n; // the route plan's minBumpBps (task 08)
        case "decimals": return 6;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ args }: { args: [Hex, bigint] }) => ({ result: [(args[1] * 100_000n * 10n ** 6n) / 10n ** 18n, [], [], 100_000n] }),
    call: async () => {
      counts.call++;
      return { data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [OWED] }) };
    },
    estimateGas: async () => {
      counts.estimateGas++;
      return gasSeq ? (gasSeq.length > 1 ? gasSeq.shift()! : gasSeq[0]!) : (o.simGas as bigint);
    },
  };
  return { chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never, sent, counts, state };
}

function routeFiller(cfgEnv: Record<string, string>, chain: unknown, guard?: Guard) {
  const cfg = loadConfig({ ...ENV, ...cfgEnv });
  const budget = new Budget({ [ROUTE_FILLS]: cfg.route!.hourlyFills });
  const g = guard ?? new Guard(cfg.gas);
  const logs: string[] = [];
  return { rf: new RouteFiller(cfg, chain as never, budget, (m) => logs.push(m), () => {}, g), budget, guard: g, logs, cfg };
}

const entry = (hash = "01") => {
  const ord = order();
  return { orderHash: ("0x" + hash.repeat(32)) as Hex, announce: { order: ord, sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: RECEIVED, validatorsPass: true } };
};

const planOf = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[3] as { minOut: bigint };

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("M-1: the sent plan's floor is priced at the MEASURED gas; the limit adds headroom only (2026-10-07)", () => {
  it("a fill whose simulation burns more than MAX_ROUTE_GAS is refused (was: sent with a 320k-priced floor)", async () => {
    const { chain, sent } = fakeChain({ simGas: 5_000_000n, receipt: "success" });
    const { rf } = routeFiller({}, chain);
    const out = await rf.consider(entry() as never);
    expect(out.status).toBe("skipped");
    expect(out.reason).toMatch(/MAX_ROUTE_GAS/);
    expect(sent).toHaveLength(0);
  });

  it("simulated gas above the estimate: plan REBUILT at gasUsed, RE-SIMULATED, sent with a gasUsed × 1.25 limit", async () => {
    const { chain, sent, counts } = fakeChain({ simGas: 500_000n, receipt: "success" });
    const { rf, cfg } = routeFiller({}, chain);
    const out = await rf.consider(entry() as never);
    expect(out.status).toBe("pending"); // sent; the receipt is read by a later tick
    expect(counts.call).toBe(2); // first plan, then the re-priced plan
    expect(sent).toHaveLength(1);
    const gasLimit = sent[0]!.gas!;
    expect(gasLimit).toBe(625_000n);
    const floorProfit = planOf(sent[0]!.data).minOut - OWED; // what the chain guarantees the bot
    // Priced at the measurement (estimateGas = gross, before refunds), not the limit:
    // pricing the 1.25× limit overcharged every quote by ~40 %.
    const measuredCostOut = rbtcToUsdt0(500_000n * GAS_PRICE);
    expect(floorProfit).toBe(measuredCostOut + rbtcToUsdt0(cfg.route!.minProfitWei));
    expect(floorProfit).toBeLessThan(rbtcToUsdt0(gasLimit * GAS_PRICE));
  });

  it("simulated gas below the estimate: no rebuild; the gas limit is the estimate the floor was priced at", async () => {
    const { chain, sent, counts } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf, cfg } = routeFiller({}, chain);
    expect((await rf.consider(entry() as never)).status).toBe("pending");
    expect(counts.call).toBe(1);
    expect(sent[0]!.gas).toBe(cfg.route!.gasEstimate);
    expect(planOf(sent[0]!.data).minOut - OWED).toBeGreaterThanOrEqual(rbtcToUsdt0(cfg.route!.gasEstimate * GAS_PRICE));
  });

  it("a re-simulation that measures still more gas re-prices again (converges on the measured gas)", async () => {
    const { chain, sent, counts } = fakeChain({ simGas: [400_000n, 480_000n, 480_000n], receipt: "success" });
    const { rf } = routeFiller({}, chain);
    expect((await rf.consider(entry() as never)).status).toBe("pending");
    expect(counts.call).toBe(3);
    expect(sent[0]!.gas).toBe(600_000n); // 480k × 1.25
    expect(planOf(sent[0]!.data).minOut - OWED).toBeGreaterThanOrEqual(rbtcToUsdt0(480_000n * GAS_PRICE));
  });

  it("MAX_ROUTE_GAS is configurable, and must be ≥ ROUTE_GAS_ESTIMATE", () => {
    expect(loadConfig(ENV).route!.maxGas).toBe(1_200_000n);
    expect(loadConfig({ ...ENV, MAX_ROUTE_GAS: "900000" }).route!.maxGas).toBe(900_000n);
    expect(() => loadConfig({ ...ENV, MAX_ROUTE_GAS: "300000" })).toThrow(/MAX_ROUTE_GAS/);
  });
});

describe("M-2: per-order backoff; the budget is checked against gas LIMIT × price and charged on reverts", () => {
  it("route: a fill that reverts on-chain is NOT retried next sweep — one send, gas charged", async () => {
    const { chain, sent } = fakeChain({ simGas: 300_000n, receipt: "reverted" });
    const { rf, guard, budget, cfg } = routeFiller({}, chain);
    const a = await rf.consider(entry() as never);
    expect(a).toMatchObject({ status: "pending", tx: sent[0]!.hash, final: true });
    expect(budget.remaining(ROUTE_FILLS, Date.now())).toBe(59n); // reserved while pending
    expect((await resolvePending(chain, guard))?.status).toBe("reverted");
    const b = await rf.consider(entry() as never);
    expect(b.status).toBe("skipped");
    expect(b.final).toBe(true);
    expect(b.reason).toMatch(/backoff after 1 on-chain revert/);
    expect(sent).toHaveLength(1);
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 300_000n * GAS_PRICE); // the receipt's cost
    expect(budget.remaining(ROUTE_FILLS, Date.now())).toBe(60n); // no fill counted
  });

  it("route: the gas pre-check uses the gas LIMIT — a budget that covers the estimate but not the limit sends nothing", async () => {
    const { chain, sent } = fakeChain({ simGas: 500_000n, receipt: "reverted" }); // limit 625k
    // Budget barely above one ESTIMATED fill: 320k × gasPrice + 1 wei.
    const capWei = 320_000n * GAS_PRICE + 1n;
    const { rf, guard } = routeFiller({ HOURLY_GAS_RBTC: (Number(capWei) / 1e18).toFixed(18).replace(/0+$/, "") }, chain);
    expect(guard.gas.remaining(GAS, Date.now()) >= 320_000n * GAS_PRICE).toBe(true);
    const out = await rf.consider(entry() as never);
    expect(out.status).toBe("skipped");
    expect(out.reason).toMatch(/hourly gas budget/);
    expect(sent).toHaveLength(0);
  });

  it("backoff schedule: 1 m, 4 m, 16 m, 1 h, then blacklisted until the order's expiry", () => {
    const g = new Guard(loadConfig(ENV).gas);
    const h = ("0x" + "02".repeat(32)) as Hex;
    const expiry = 2_000_000_000n;
    let now = 1_000_000;
    const delays: number[] = [];
    for (let i = 0; i < 5; i++) {
      g.onRevert(h, now, expiry, "x");
      delays.push(g.entry(h)!.until - now);
      now = g.entry(h)!.until + 1;
    }
    expect(delays.slice(0, 4)).toEqual([60_000, 240_000, 960_000, 3_600_000]);
    expect(g.entry(h)!.strikes).toBe(BACKOFF.maxStrikes);
    expect(g.entry(h)!.until).toBe(Number(expiry) * 1000);
  });

  it("the backoff survives a restart (STATE_FILE round-trip)", async () => {
    const policy = loadConfig(ENV).gas;
    const g = new Guard(policy);
    const h = ("0x" + "03".repeat(32)) as Hex;
    const now = Date.now();
    g.onRevert(h, now, 2_000_000_000n, "boom");
    g.chargeGas(1234n, now);
    const restored = new Guard(policy, JSON.parse(JSON.stringify(g.toJSON())));
    expect(restored.admit(h, "route", now + 1)).toMatchObject({ global: true });
    expect(restored.gas.remaining(GAS, now)).toBe(policy.hourlyWei - 1234n);
  });

  it("a simulation failure gets a short, strategy-scoped backoff (the other strategy may still try)", async () => {
    const g = new Guard(loadConfig(ENV).gas);
    const h = ("0x" + "04".repeat(32)) as Hex;
    g.onSimFail(h, "inventory", 0);
    expect(g.admit(h, "inventory", 1)).toMatchObject({ global: false });
    expect(g.admit(h, "route", 1)).toBeUndefined();
    expect(g.admit(h, "inventory", BACKOFF.simBaseMs)).toBeUndefined();
    g.onSimFail(h, "inventory", BACKOFF.simBaseMs);
    expect(g.admit(h, "inventory", BACKOFF.simBaseMs * 2.5)).toBeDefined(); // doubled
  });

  it("route: a simulation revert backs the order off for the route strategy", async () => {
    const { chain, sent } = fakeChain({ simGas: 300_000n, receipt: "success" });
    (chain as { pub: { call: () => Promise<never> } }).pub.call = async () => { throw new Error("execution reverted"); };
    const { rf, guard } = routeFiller({}, chain);
    expect((await rf.consider(entry() as never)).status).toBe("skipped");
    expect(guard.admit(entry().orderHash, "route", Date.now())).toMatchObject({ global: false });
    expect(sent).toHaveLength(0);
  });
});

/** The auditor's inventory fake: receive 100 USDRIF, pay 99 USDT0. */
// Inventory fixture: 100 USDRIF for 90 USDT0 (a 10% spread) so the all-in gas gate
// (fill gas + rebalance share + min profit, priced at the fake's $100k RBTC) passes.
function inventoryChain(o: { gasPrice: bigint; receipt: Receipt }) {
  const state = { receipt: o.receipt };
  const tx = sender(state, o.gasPrice, 150_000n);
  const fillUpToResult = encodeAbiParameters(
    [{ type: "int256" }, { type: "uint256[]" }, { type: "uint256[]" }],
    [0n, [100n * 10n ** 18n], [90_000_000n]],
  );
  const pub = {
    ...tx.pub,
    getGasPrice: async () => o.gasPrice,
    readContract: async ({ functionName }: { functionName: string }) => {
      switch (functionName) {
        case "previewFill": return [0n, [100n * 10n ** 18n], [90_000_000n]];
        case "balanceOf": return 10_000n * 10n ** 6n;
        case "getPACtp": return 10n ** 17n;
        case "previewBump": return 0n;
        case "allowance": return 10n ** 30n;
      }
      throw new Error(functionName);
    },
    simulateContract: async () => ({ result: [100_000_000n] }),
    call: async () => ({ data: fillUpToResult }),
    estimateGas: async () => 160_000n,
  };
  return { chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never, sent: tx.sent, state };
}

const inventoryEntry = () => ({
  orderHash: ("0x" + "02".repeat(32)) as Hex,
  announce: { order: order({ legsIn: [{ token: ROOTSTOCK.usdrif, start: 100n * 10n ** 18n, end: 0n }], legsOut: [{ token: ROOTSTOCK.usdt0, start: 90_000_000n, end: 0n, recipient: zeroAddress }] }), sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: 100n * 10n ** 18n, validatorsPass: true },
});

describe("B13: the inventory EOA inside the app's soft window (exclusiveFiller = the SOLVER contract)", () => {
  const cfg = loadConfig({ ...ENV, MIN_EXIT_EDGE_BPS: "0" });
  const invBudget = () => new Budget({ [ROOTSTOCK.usdt0.toLowerCase()]: 10n ** 12n });
  const windowed = (overrideBps: bigint) => {
    const e = inventoryEntry();
    const nowS = Math.floor(Date.now() / 1000);
    return { ...e, announce: { ...e.announce, order: { ...e.announce.order, exclusiveFiller: SOLVER, timing: packTiming(0, 0, nowS + 60), exclusivityOverrideBps: overrideBps } } };
  };

  it("SOFT window: the EOA is an outsider; it previews AS ITSELF (so the premium is priced) and fills if the gates pass", async () => {
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "success" });
    const pub = (chain as unknown as { pub: { readContract: (a: { functionName: string; args?: unknown[] }) => Promise<unknown> } }).pub;
    const inner = pub.readContract;
    const fillers: unknown[] = [];
    pub.readContract = async (a) => {
      if (a.functionName === "previewFill") fillers.push(a.args?.[2]);
      return inner(a);
    };
    const logs: string[] = [];
    const out = await new Filler(cfg, chain, invBudget(), (m) => logs.push(m)).consider(windowed(5n) as never);
    expect(out).toMatchObject({ status: "pending", strategy: "inventory" });
    expect(sent).toHaveLength(1);
    // Previewed for msg.sender = our EOA — the lens applies OrderGates.exclusivityOverride to it.
    expect(fillers.length).toBeGreaterThan(0);
    for (const f of fillers) expect(String(f).toLowerCase()).toBe(ACCOUNT.address.toLowerCase());
    expect(logs.some((l) => /in-window outsider: \+5 bps to the maker/.test(l))).toBe(true);
  });

  it("HARD window (override 0): refused with zero RPC until it ends", async () => {
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "success" });
    const f = new Filler(cfg, chain, invBudget(), () => {});
    expect(f.accepts(windowed(0n) as never)).toBe(false);
    const out = await f.consider(windowed(0n) as never);
    expect(out).toMatchObject({ status: "skipped", rest: true });
    expect(out.reason).toMatch(/hard window/);
    expect(sent).toHaveLength(0);
  });
});

describe("M-3: the inventory strategy has the gas budget, the gas-price ceiling and the backoff", () => {
  const cfg = loadConfig({ ...ENV, MIN_EXIT_EDGE_BPS: "0" });
  const invBudget = () => new Budget({ [ROOTSTOCK.usdt0.toLowerCase()]: 10n ** 12n });

  it("refuses to send above MAX_GAS_PRICE_GWEI (default 0.1 gwei)", async () => {
    expect(cfg.gas.maxGasPriceWei).toBe(100_000_000n);
    const { chain, sent } = inventoryChain({ gasPrice: 10n ** 18n, receipt: "success" });
    const f = new Filler(cfg, chain, invBudget(), () => {});
    const out = await f.consider(inventoryEntry() as never);
    expect(out.status).toBe("skipped");
    expect(out.reason).toMatch(/MAX_GAS_PRICE_GWEI/);
    expect(sent).toHaveLength(0);
  });

  it("a reverting order is sent ONCE, then backed off; gas charged to the shared budget; legacy tx with an explicit limit", async () => {
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "reverted" });
    const guard = new Guard(cfg.gas);
    const f = new Filler(cfg, chain, invBudget(), () => {}, () => {}, guard);
    const first = await f.consider(inventoryEntry() as never);
    expect(first).toMatchObject({ status: "pending", final: true });
    expect((await resolvePending(chain, guard))?.status).toBe("reverted");
    for (let i = 0; i < 4; i++) expect((await f.consider(inventoryEntry() as never)).status).toBe("skipped");
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ type: "legacy", gasPrice: GAS_PRICE, gas: 200_000n }); // 160k × 1.25
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 150_000n * GAS_PRICE);
  });

  it("the inventory pre-check uses the shared hourly gas budget", async () => {
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "success" });
    const guard = new Guard(cfg.gas);
    guard.chargeGas(cfg.gas.hourlyWei - 1n, Date.now()); // e.g. the route strategy spent it
    const out = await new Filler(cfg, chain, invBudget(), () => {}, () => {}, guard).consider(inventoryEntry() as never);
    expect(out.reason).toMatch(/hourly gas budget/);
    expect(sent).toHaveLength(0);
  });

  it("dispatch does not fall through to the route strategy on an order that just reverted on-chain", async () => {
    const { chain } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "reverted" });
    const guard = new Guard(cfg.gas);
    const f = new Filler(cfg, chain, invBudget(), () => {}, () => {}, guard);
    const route = vi.fn(async (): Promise<FillOutcome> => ({ orderHash: "0x02", status: "filled", strategy: "route" }));
    const strategies: Strategy[] = [
      { name: "inventory", consider: (e) => f.consider(e) },
      { name: "route", consider: route },
    ];
    expect((await dispatch(inventoryEntry() as never, strategies))?.strategy).toBe("inventory");
    expect((await dispatch(inventoryEntry() as never, strategies))?.final).toBe(true); // pending: blocked
    expect((await resolvePending(chain, guard))?.status).toBe("reverted");
    expect((await dispatch(inventoryEntry() as never, strategies))?.final).toBe(true); // still blocked next sweep
    expect(route).not.toHaveBeenCalled();
  });

  it("a pre-send inventory failure still falls through to route", async () => {
    const inv = vi.fn(async (): Promise<FillOutcome> => ({ orderHash: "0x02", status: "failed", strategy: "inventory" }));
    const route = vi.fn(async (): Promise<FillOutcome> => ({ orderHash: "0x02", status: "dry-run", strategy: "route" }));
    expect((await dispatch(inventoryEntry() as never, [{ name: "inventory", consider: inv }, { name: "route", consider: route }]))?.strategy).toBe("route");
  });
});

describe("review 2026-10-05 §6: the sell side's recorded profit_est includes the MoC mint fee", () => {
  it("profitEst = received − mint replacement cost (×(1 + 0.2%)), the same figure the all-in gate uses", async () => {
    const cfg = loadConfig({ ...ENV, BUY_USDRIF: "0", SELL_USDRIF: "1", INVENTORY_MIN_PROFIT_USDT0: "0" });
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "success" });
    // Maker buys 100 USDRIF for 102 USDT0: we receive 102 USDT0, pay 100 USDRIF.
    const result = encodeAbiParameters([{ type: "int256" }, { type: "uint256[]" }, { type: "uint256[]" }], [0n, [102_000_000n], [100n * 10n ** 18n]]);
    const pub = (chain as unknown as { pub: Record<string, unknown> }).pub;
    const read = pub.readContract as (a: { functionName: string }) => Promise<unknown>;
    pub.readContract = async (a: { functionName: string }) => {
      if (a.functionName === "previewFill") return [0n, [102_000_000n], [100n * 10n ** 18n]];
      if (a.functionName === "balanceOf") return 10_000n * 10n ** 18n; // USDRIF inventory
      return read(a);
    };
    pub.call = async () => ({ data: result });
    const guard = new Guard(cfg.gas);
    const budget = new Budget({ [ROOTSTOCK.usdrif.toLowerCase()]: 10n ** 30n });
    const e = {
      orderHash: ("0x" + "03".repeat(32)) as Hex,
      announce: { order: order({ legsIn: [{ token: ROOTSTOCK.usdt0, start: 102_000_000n, end: 0n }], legsOut: [{ token: ROOTSTOCK.usdrif, start: 100n * 10n ** 18n, end: 0n, recipient: zeroAddress }] }), sig: "0x" as Hex },
      state: { ok: true, status: "Fillable", fillableAmount: 102_000_000n, validatorsPass: true },
    };
    const out = await new Filler(cfg, chain, budget, () => {}, () => {}, guard).consider(e as never);
    expect(out, out.reason).toMatchObject({ status: "pending" });
    expect(sent).toHaveLength(1);
    // 102 − 100 × 1.002 = 1.8 USDT0 (was 2.0: the mint fee was left out).
    expect(guard.pending!.info).toMatchObject({ profitEst: "1800000", profitToken: ROOTSTOCK.usdt0 });
  });
});

describe("L-5: a receipt timeout charges conservatively and parks the order until its tx status is known", () => {
  it("route: pending → charged at the full limit → blocked while unmined → a revert becomes a strike", async () => {
    const { chain, sent, state } = fakeChain({ simGas: 200_000n, receipt: "timeout" });
    const { rf, guard, budget, cfg } = routeFiller({}, chain);
    const a = await rf.consider(entry() as never);
    expect(a).toMatchObject({ status: "pending", tx: sent[0]!.hash, final: true });
    const t0 = Date.now();
    expect((await resolvePending(chain, guard, t0 + 1_000))?.status).toBe("waiting");
    expect((await resolvePending(chain, guard, t0 + cfg.gas.receiptTimeoutMs + 1))?.status).toBe("timeout");
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - cfg.route!.gasEstimate * GAS_PRICE);
    expect(budget.remaining(ROUTE_FILLS, Date.now())).toBe(59n);
    const b = await rf.consider(entry() as never);
    expect(b).toMatchObject({ status: "skipped", final: true });
    expect(b.reason).toMatch(/still pending/);
    state.receipt = "reverted";
    const late = await resolvePending(chain, guard, t0 + cfg.gas.receiptTimeoutMs + 2);
    expect(late).toMatchObject({ status: "reverted", gasUsed: 300_000n, gasCostWei: 300_000n * GAS_PRICE });
    const c = await rf.consider(entry() as never);
    expect(c.reason).toMatch(/backoff after 1 on-chain revert/);
    // Timed out first: the route-fill reservation is final, but the gas is settled to
    // the late receipt's real cost — the one the fills row records (review 2026-10-05 §6).
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 300_000n * GAS_PRICE);
    expect(budget.remaining(ROUTE_FILLS, Date.now())).toBe(59n);
    expect(guard.pending).toBeUndefined();
    expect(sent).toHaveLength(1);
  });

  it("a pending tx that later succeeds clears the order", async () => {
    const { chain, state } = fakeChain({ simGas: 200_000n, receipt: "timeout" });
    const { rf, guard } = routeFiller({}, chain);
    await rf.consider(entry() as never);
    state.receipt = "success";
    expect((await resolvePending(chain, guard))?.status).toBe("success");
    expect(guard.entry(entry().orderHash)).toBeUndefined();
    expect(guard.pending).toBeUndefined();
  });

  it("a pending tx that vanished from the mempool after 15 min is dropped with a short backoff", async () => {
    const g = new Guard(loadConfig(ENV).gas);
    const h = ("0x" + "05".repeat(32)) as Hex;
    const tx = ("0x" + "ab".repeat(32)) as Hex;
    g.setPending({ hash: tx, nonce: 0, gasLimit: "1", gasPrice: "1", kind: "fill", strategy: "route", orderHash: h, expiry: "2000000000", sentAt: 0 });
    const pub = { getTransactionReceipt: async () => { throw new Error("nf"); }, getTransaction: async () => { throw new TransactionNotFoundError({ hash: tx }); } };
    expect(g.admit(h, "route", 60_000)).toMatchObject({ reason: expect.stringMatching(/pending/) });
    expect((await resolvePending({ pub } as never, g, 60_000))?.status).toBe("waiting");
    expect((await resolvePending({ pub } as never, g, BACKOFF.pendingDropMs - 1))?.status).toBe("timeout");
    const t = BACKOFF.pendingDropMs + 1;
    expect((await resolvePending({ pub } as never, g, t))?.status).toBe("dropped");
    expect(g.pending).toBeUndefined();
    expect(g.admit(h, "route", t)).toMatchObject({ global: true }); // short backoff
    expect(g.admit(h, "route", t + BACKOFF.simBaseMs)).toBeUndefined();
  });

  it("a pending tx still in the mempool after 15 min stays pending", async () => {
    const g = new Guard(loadConfig(ENV).gas);
    g.setPending({ hash: ("0x" + "ab".repeat(32)) as Hex, nonce: 0, gasLimit: "1", gasPrice: "1", kind: "fill", strategy: "route", expiry: "0", sentAt: 0, timedOut: true });
    const pub = { getTransactionReceipt: async () => { throw new Error("nf"); }, getTransaction: async () => ({ hash: "0x" }) };
    expect((await resolvePending({ pub } as never, g, BACKOFF.pendingDropMs * 4))?.status).toBe("waiting");
    expect(g.pending).toBeDefined();
  });

  it("inventory: a timeout charges the outflow and the gas limit, and blocks the order", async () => {
    const cfg = loadConfig({ ...ENV, MIN_EXIT_EDGE_BPS: "0" });
    const { chain, sent } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "timeout" });
    const guard = new Guard(cfg.gas);
    const budget = new Budget({ [ROOTSTOCK.usdt0.toLowerCase()]: 10n ** 12n });
    const f = new Filler(cfg, chain, budget, () => {}, () => {}, guard);
    expect((await f.consider(inventoryEntry() as never)).status).toBe("pending");
    expect((await resolvePending(chain, guard, Date.now() + cfg.gas.receiptTimeoutMs))?.status).toBe("timeout");
    expect(budget.remaining(ROOTSTOCK.usdt0, Date.now())).toBe(10n ** 12n - 90_000_000n);
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 200_000n * GAS_PRICE);
    expect((await f.consider(inventoryEntry() as never)).reason).toMatch(/pending/);
    expect(sent).toHaveLength(1);
  });

  it("inventory: a TIMELY revert charges the receipt's gas and releases the outflow reservation", async () => {
    const cfg = loadConfig({ ...ENV, MIN_EXIT_EDGE_BPS: "0" });
    const { chain } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "reverted" });
    const guard = new Guard(cfg.gas);
    const budget = new Budget({ [ROOTSTOCK.usdt0.toLowerCase()]: 10n ** 12n });
    const f = new Filler(cfg, chain, budget, () => {}, () => {}, guard);
    await f.consider(inventoryEntry() as never);
    expect(budget.remaining(ROOTSTOCK.usdt0, Date.now())).toBe(10n ** 12n - 90_000_000n); // reserved
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 200_000n * GAS_PRICE); // at the limit
    expect((await resolvePending(chain, guard))?.status).toBe("reverted");
    expect(budget.remaining(ROOTSTOCK.usdt0, Date.now())).toBe(10n ** 12n);
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 150_000n * GAS_PRICE); // the receipt's cost
  });

  it("inventory: a success keeps the outflow and charges the receipt's gas", async () => {
    const cfg = loadConfig({ ...ENV, MIN_EXIT_EDGE_BPS: "0" });
    const { chain } = inventoryChain({ gasPrice: GAS_PRICE, receipt: "success" });
    const guard = new Guard(cfg.gas);
    const budget = new Budget({ [ROOTSTOCK.usdt0.toLowerCase()]: 10n ** 12n });
    await new Filler(cfg, chain, budget, () => {}, () => {}, guard).consider(inventoryEntry() as never);
    const r = await resolvePending(chain, guard);
    expect(r).toMatchObject({ status: "success", gasUsed: 150_000n });
    expect(r!.pending.info).toMatchObject({ paid: "90000000", received: String(100n * 10n ** 18n) });
    expect(budget.remaining(ROOTSTOCK.usdt0, Date.now())).toBe(10n ** 12n - 90_000_000n);
    expect(guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 150_000n * GAS_PRICE);
  });
});

describe("L-1: decodeSnwap / validateSushiRoute strictness", () => {
  const base = encodeFunctionData({
    abi: SUSHI_RED_SNWAPPER_ABI,
    functionName: "snwap",
    args: [ROOTSTOCK.usdrif, 10n ** 20n, SOLVER, ROOTSTOCK.usdt0, 99_000_000n, EVIL, "0xdeadbeef"],
  });
  const req = { chainId: 30, tokenIn: ROOTSTOCK.usdrif as Address, tokenOut: ROOTSTOCK.usdt0 as Address, amountIn: 10n ** 20n, sender: SANDBOX, recipient: SOLVER, slippageBps: 30n };
  const body = (data: Hex) => ({ status: "Success", assumedAmountOut: "100000000", tx: { to: SUSHI_RED_SNWAPPER_ROOTSTOCK, data } });
  const router = SUSHI_RED_SNWAPPER_ROOTSTOCK;

  it("SUSHI_EXECUTORS: empty = not pinned; set = only those executors", () => {
    expect(validateSushiRoute(body(base), req, { router, executors: [] }).ok).toBe(true);
    const pinned = validateSushiRoute(body(base), req, { router, executors: ["0xc10EE9031F2a0B84766A86b55A8d90F357910fb4"] });
    expect(pinned.ok).toBe(false);
    if (!pinned.ok) expect(pinned.reason).toMatch(/SUSHI_EXECUTORS/);
    expect(validateSushiRoute(body(base), req, { router, executors: [EVIL] }).ok).toBe(true);
    expect(loadConfig({ ...ENV, SUSHI_EXECUTORS: `${EVIL}, 0xc10EE9031F2a0B84766A86b55A8d90F357910fb4` }).route!.sushi.executors).toHaveLength(2);
    expect(() => loadConfig({ ...ENV, SUSHI_EXECUTORS: "zzz" })).toThrow(/SUSHI_EXECUTORS/);
  });

  it("refuses trailing garbage after the ABI body", () => {
    const d = concat([base, ("0x" + "ff".repeat(100)) as Hex]);
    const v = validateSushiRoute(body(d), req, { router });
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.reason).toMatch(/non-canonical/);
  });

  it("refuses a non-canonical executorData offset", () => {
    const head = base.slice(0, 2 + 8 + 64 * 6);
    const tail = base.slice(2 + 8 + 64 * 7);
    const d = (head + (0x100).toString(16).padStart(64, "0") + "00".repeat(32) + tail) as Hex;
    expect(validateSushiRoute(body(d), req, { router }).ok).toBe(false);
  });

  it("tx.value: '0x0' and '0' handling (hex refused, fail-closed)", () => {
    expect(validateSushiRoute({ ...body(base), tx: { ...body(base).tx, value: "0x0" } }, req, { router }).ok).toBe(false);
    expect(validateSushiRoute({ ...body(base), tx: { ...body(base).tx, value: "0" } }, req, { router }).ok).toBe(true);
  });

  it("init warns when Sushi is on and no executor is pinned", async () => {
    const { chain } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf, logs } = routeFiller({ SUSHI_ENABLED: "1" }, chain);
    await rf.init();
    expect(logs.some((l) => /SUSHI_EXECUTORS is empty/.test(l))).toBe(true);
    const pinned = routeFiller({ SUSHI_ENABLED: "1", SUSHI_EXECUTORS: EVIL }, fakeChain({ simGas: 1n, receipt: "success" }).chain);
    await pinned.rf.init();
    expect(pinned.logs.some((l) => /SUSHI_EXECUTORS is empty/.test(l))).toBe(false);
  });
});

describe("I-2: API strings are sanitized before logging", () => {
  it("the API's status string can no longer inject a log line", () => {
    const req = { chainId: 30, tokenIn: ROOTSTOCK.usdrif as Address, tokenOut: ROOTSTOCK.usdt0 as Address, amountIn: 1n, sender: SANDBOX, recipient: SOLVER, slippageBps: 30n };
    const v = validateSushiRoute({ status: "x\n2026-10-04T00:00:00Z ✓ [route] filled FAKE\r" + LS }, req, { router: SUSHI_RED_SNWAPPER_ROOTSTOCK });
    expect(v.ok).toBe(false);
    if (!v.ok) expect(new RegExp("[\\n\\r" + LS + "]").test(v.reason)).toBe(false);
  });
  it("sanitize strips control characters and truncates", () => {
    expect(sanitize("a\nb\u0000c" + String.fromCharCode(0x202e) + "d")).toBe("a b c d");
    expect(sanitize("x".repeat(500), 10)).toBe("xxxxxxxxxx...");
  });
});

describe("L-3: RBTC is priced at the HIGHER of the pool and RBTC_PRICE_USD", () => {
  // The fake pool says $100,000 / RBTC.
  it("uses the configured price when it is higher than the pool's", async () => {
    const { rf } = routeFiller({ RBTC_PRICE_USD: "200000" }, fakeChain({ simGas: 1n, receipt: "success" }).chain);
    expect(await rf.nativeToToken(10n ** 13n, ROOTSTOCK.usdt0 as Address)).toBe(2_000_000n);
  });
  it("uses the pool when it is higher than the configured price", async () => {
    const { rf } = routeFiller({ RBTC_PRICE_USD: "50000" }, fakeChain({ simGas: 1n, receipt: "success" }).chain);
    expect(await rf.nativeToToken(10n ** 13n, ROOTSTOCK.usdt0 as Address)).toBe(1_000_000n);
  });
  it("pool only without RBTC_PRICE_USD", async () => {
    const { rf } = routeFiller({}, fakeChain({ simGas: 1n, receipt: "success" }).chain);
    expect(await rf.nativeToToken(10n ** 13n, ROOTSTOCK.usdt0 as Address)).toBe(1_000_000n);
  });
});

describe("L-4: the profit gate accounts for the solver's maker/protocol surplus split", () => {
  it("the sent floor grosses gas + profit up by 1e6 / (1e6 − maker − protocol)", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success", makerPpm: 150_000, protocolPpm: 50_000 });
    const { rf, cfg, logs } = routeFiller({}, chain);
    expect((await rf.consider(entry() as never)).status).toBe("pending");
    const cost = rbtcToUsdt0(cfg.route!.gasEstimate * GAS_PRICE) + rbtcToUsdt0(cfg.route!.minProfitWei);
    const floor = planOf(sent[0]!.data).minOut - OWED;
    expect(floor).toBe(grossUp(cost, 800_000n));
    expect((floor * 800_000n) / 1_000_000n).toBeGreaterThanOrEqual(cost); // OUR share still covers gas + profit
    expect(logs.some((l) => /we keep 800000/.test(l))).toBe(true);
  });
  it("init refuses a split that leaves the filler nothing", async () => {
    const { chain } = fakeChain({ simGas: 1n, receipt: "success", makerPpm: 600_000, protocolPpm: 400_000 });
    await expect(routeFiller({}, chain).rf.init()).rejects.toThrow(/leaves the filler nothing/);
  });
});

describe("L-6: Sushi API calls are capped per sweep", () => {
  it("at most SUSHI_MAX_PER_SWEEP fetches until beginSweep()", async () => {
    const fetchMock = vi.fn(async () => new Response("{}", { status: 500 }));
    vi.stubGlobal("fetch", fetchMock);
    const { chain } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf } = routeFiller({ SUSHI_ENABLED: "1", SUSHI_MAX_PER_SWEEP: "2", DRY_RUN: "1" }, chain);
    for (const h of ["01", "02", "03"]) expect((await rf.consider(entry(h) as never)).status).toBe("dry-run"); // Oku still fills
    expect(fetchMock).toHaveBeenCalledTimes(2);
    rf.beginSweep();
    await rf.consider(entry("04") as never);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});

describe("I-1: config fails closed", () => {
  it("parsePools / parsePaths refuse a non-numeric or out-of-range fee", () => {
    expect(() => parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/abc`)).toThrow(/fee/);
    expect(() => parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/0`)).toThrow(/fee/);
    expect(() => parsePools(`${ROOTSTOCK.wrbtc}/${ROOTSTOCK.usdt0}/16777216`)).toThrow(/fee/);
    expect(() => parsePaths(`${ROOTSTOCK.wrbtc}>3000.5>${ROOTSTOCK.usdt0}`)).toThrow(/fee/);
  });
  it.each([
    ["POLL_MS", "fast"],
    ["POLL_MS", "0"],
    ["ROUTE_GAS_ESTIMATE", "0"],
    ["ROUTE_GAS_ESTIMATE", ""],
    ["ROUTE_GAS_ESTIMATE", "1e6"],
    ["MAX_ROUTE_GAS", "-1"],
    ["SUSHI_TIMEOUT_MS", "x"],
    ["SUSHI_MAX_PER_SWEEP", "0"],
    ["CHAIN_ID", "abc"],
    ["CHAIN_ID", "30.5"],
    ["RIF_USDT0_FEE", "abc"],
    ["RIF_USDT0_FEE", "0"],
    ["ROUTE_SLIPPAGE_BPS", ""],
    ["ROUTE_HOURLY_FILLS", "x"],
    ["MAX_GAS_PRICE_GWEI", "0"],
    ["MAX_GAS_PRICE_GWEI", "abc"],
    ["RECEIPT_TIMEOUT_MS", "0"],
    ["RBTC_PRICE_USD", "0"],
  ])("%s=%j is refused", (key, value) => {
    expect(() => loadConfig({ ...ENV, [key]: value })).toThrow();
  });
  it("valid values parse", () => {
    const c = loadConfig({ ...ENV, POLL_MS: "5000", CHAIN_ID: "31", RIF_USDT0_FEE: "500", MAX_GAS_PRICE_GWEI: "0.06", HOURLY_GAS_RBTC: "0.01" });
    expect(c.pollMs).toBe(5000);
    expect(c.chainId).toBe(31);
    expect(c.uniswap.rifUsdt0Fee).toBe(500);
    expect(c.gas.maxGasPriceWei).toBe(60_000_000n);
    expect(c.gas.hourlyWei).toBe(10n ** 16n);
    // The pre-2026-10 name still works.
    expect(loadConfig({ ...ENV, ROUTE_HOURLY_GAS_RBTC: "0.003" }).gas.hourlyWei).toBe(3n * 10n ** 15n);
  });
  it("DRY_RUN fails closed", () => {
    for (const v of ["", "no", "off", "False ", "00"]) expect(loadConfig({ ...ENV, DRY_RUN: v }).dryRun).toBe(true);
  });
});

describe("task 08: the route plan carries the filler's on-chain bump floor", () => {
  it("previews at the SEND gas price and sends previewBump as plan.minBumpBps", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const pub = (chain as unknown as { pub: Record<string, unknown> }).pub;
    const read = pub.readContract as (a: { functionName: string }) => Promise<unknown>;
    const seen: Record<string, unknown> = {};
    pub.readContract = async (a: { functionName: string; gasPrice?: bigint; args?: readonly unknown[] }) => {
      if (a.functionName === "previewBump") {
        seen.bump = { gasPrice: a.gasPrice, filler: a.args?.[1] };
        return 3_333n;
      }
      if (a.functionName === "previewFill") seen.fill = { gasPrice: a.gasPrice, filler: a.args?.[2] };
      return read(a);
    };
    const { rf } = routeFiller({}, chain);
    await rf.consider(entry() as never);
    expect(seen.fill).toEqual({ gasPrice: GAS_PRICE, filler: SOLVER });
    expect(seen.bump).toEqual({ gasPrice: GAS_PRICE, filler: SOLVER });
    expect(sent).toHaveLength(1);
    const { functionName, args } = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: sent[0]!.data });
    expect(functionName).toBe("executeFill");
    expect((args[3] as { minBumpBps: bigint }).minBumpBps).toBe(3_333n);
  });
});

describe("task 05: a direct SELL still decaying patches the live owed; the typed gas is priced", () => {
  const directEntry = (decaying: boolean, end = 895_000_000n) => {
    const now = Math.floor(Date.now() / 1000);
    const ord = order({
      timing: withDeltaVerifyOutputs(packTiming(now - 10, 60, 0)),
      exclusiveFiller: SOLVER,
      legsOut: [{ token: ROOTSTOCK.usdt0, start: 905_000_000n, end: decaying ? end : 0n, recipient: zeroAddress }],
    });
    return { orderHash: ("0x" + "05".repeat(32)) as Hex, announce: { order: ord, sig: "0x" as Hex }, state: { ok: true, status: "Fillable", fillableAmount: RECEIVED, validatorsPass: true } };
  };
  const planFields = (data: Hex) =>
    decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[3] as { amountOutOffset: bigint; amountInOffset: bigint };

  it("decaying direct SELL: amountOutOffset = the exactOutputSingle amountOut word; gas limit = estimate + TYPED_CALLBACK_GAS", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf, cfg, logs } = routeFiller({}, chain);
    expect((await rf.consider(directEntry(true) as never)).status).toBe("pending");
    const plan = planFields(sent[0]!.data);
    expect(plan.amountOutOffset).toBe(132n);
    expect(plan.amountInOffset).toBe(NO_PATCH);
    expect(sent[0]!.gas).toBe(cfg.route!.gasEstimate + TYPED_CALLBACK_GAS);
    expect(logs.some((l) => l.includes("direct+live"))).toBe(true);
  });

  it("a decay worth less than the typed path's gas per block: NO_PATCH, untyped gas (small tickets pay nothing extra)", async () => {
    // 1,000 units (0.001 USDT0) of decay over 60 s: one block captures ~500 units,
    // far below 6k gas at the test gas price.
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf, cfg, logs } = routeFiller({}, chain);
    expect((await rf.consider(directEntry(true, 904_999_000n) as never)).status).toBe("pending");
    expect(planFields(sent[0]!.data).amountOutOffset).toBe(NO_PATCH);
    expect(sent[0]!.gas).toBe(cfg.route!.gasEstimate);
    expect(logs.some((l) => l.includes("direct+live"))).toBe(false);
  });

  it("fixed-output direct order: NO_PATCH and the untyped gas estimate", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf, cfg } = routeFiller({}, chain);
    expect((await rf.consider(directEntry(false) as never)).status).toBe("pending");
    expect(planFields(sent[0]!.data).amountOutOffset).toBe(NO_PATCH);
    expect(sent[0]!.gas).toBe(cfg.route!.gasEstimate);
  });

  it("pull orders never patch the output", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf } = routeFiller({}, chain);
    expect((await rf.consider(entry() as never)).status).toBe("pending");
    expect(planFields(sent[0]!.data).amountOutOffset).toBe(NO_PATCH);
  });
});

describe("I-3: route sends are explicit legacy transactions", () => {
  it("type: legacy, gasPrice = the priced one", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success" });
    const { rf } = routeFiller({}, chain);
    await rf.consider(entry() as never);
    expect(sent[0]).toMatchObject({ type: "legacy", gasPrice: GAS_PRICE });
  });
  it("the route strategy refuses above MAX_GAS_PRICE_GWEI too", async () => {
    const { chain, sent } = fakeChain({ simGas: 200_000n, receipt: "success", gasPrice: 200_000_000n });
    const out = await routeFiller({}, chain).rf.consider(entry() as never);
    expect(out.reason).toMatch(/MAX_GAS_PRICE_GWEI/);
    expect(sent).toHaveLength(0);
  });
});

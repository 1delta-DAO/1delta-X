/**
 * 2026-10-07 gas pricing: every tx is sent at the latest block's minimumGasPrice × 1.03
 * (eth_gasPrice without one), and fills are PRICED at eth_estimateGas × r, r learned per
 * fill shape from the filler's own receipts — the gas LIMIT keeps its 1.25× headroom.
 */
import { AGGREGATOR_FILL_SOLVER_ABI, OrderSide, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { quantity, readSendGasPrice, withSendGasPrice } from "../src/chain";
import { DEFAULT_GAS_PRICE_MIN_MULT_BPS, loadConfig, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { DEFAULT_RATIO_PPM, gasShape, GasRatios, MAX_SHAPES, WINDOW } from "../src/gasRatio";
import { GAS, Guard } from "../src/guard";
import { Budget } from "../src/policy";
import { ROUTE_FILLS, RouteFiller } from "../src/routeFiller";
import { MemoryStateStore, STATE_KEY, type FillerState } from "../src/state";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
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
/** Rootstock's live block minimum (2026-10-07) and what eth_gasPrice answers for it (× 1.1). */
const MIN = 23_696_000n;
const ETH_GAS_PRICE = 26_065_600n;
const SEND = 24_406_880n; // ⌈MIN × 1.03⌉ — the default GAS_PRICE_MIN_MULT_BPS
const SEND_102 = 24_169_920n; // ⌈MIN × 1.02⌉
const OWED = 900_000_000n;
const RECEIVED = 10n ** 16n;
const rbtcToUsdt0 = (wei: bigint) => (wei * 100_000n * 10n ** 6n + 10n ** 18n - 1n) / 10n ** 18n;

function order(over: Partial<Order> = {}): Order {
  return {
    maker: "0x00000000000000000000000000000000000000bb", side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.wrbtc, start: RECEIVED, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: OWED, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}
const entry = (h: string) => ({
  orderHash: ("0x" + h.repeat(32)) as Hex,
  announce: { order: order(), sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: RECEIVED, validatorsPass: true },
});

/**
 * A route chain: `block` is what eth_getBlockByNumber("latest") answers (undefined =
 * no getBlock at all), estimateGas measures `estimate`, a mined fill burns `gasUsed`.
 */
function fake(o: { block?: Record<string, unknown> | (() => never); estimate: bigint; gasUsed: bigint }) {
  const w = { receipt: "none" as "none" | "success", sent: [] as Array<{ data: Hex; gas?: bigint; gasPrice?: bigint; hash: Hex }>, mined: 0, calls: { block: 0, gasPrice: 0 } };
  const pub: Record<string, unknown> = {
    getCode: async () => "0x60",
    getGasPrice: async () => {
      w.calls.gasPrice++;
      return ETH_GAS_PRICE;
    },
    getTransactionCount: async () => w.mined,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      const hash = keccak256(serializedTransaction);
      w.sent.push({ data: t.data!, gas: t.gas, gasPrice: t.gasPrice, hash });
      return hash;
    },
    getTransactionReceipt: async () => {
      if (w.receipt === "none") throw new Error("Transaction receipt could not be found");
      w.mined = w.sent.length;
      return { status: "success", gasUsed: o.gasUsed, effectiveGasPrice: w.sent.at(-1)!.gasPrice };
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
        case "previewFill": return [0n, [RECEIVED], [OWED]];
        case "previewBump": return 0n;
        case "decimals": return 6;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ args }: { args: [Hex, bigint] }) => ({ result: [(args[1] * 100_000n * 10n ** 6n) / 10n ** 18n, [], [], 100_000n] }),
    call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [OWED] }) }),
    estimateGas: async () => o.estimate,
  };
  if (o.block !== undefined) {
    pub.getBlock = async () => {
      w.calls.block++;
      return typeof o.block === "function" ? o.block() : o.block;
    };
  }
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const minOutOf = (data: Hex) => (decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[3] as { minOut: bigint }).minOut;

describe("send gas price: latest block minimumGasPrice × GAS_PRICE_MIN_MULT_BPS", () => {
  it("defaults: 10300 bps (+3 %), 0.88 receipt ratio; GAS_PRICE_MIN_MULT_BPS must be 10000..20000", () => {
    const cfg = loadConfig(ENV);
    expect(cfg.gas.minGasPriceMultBps).toBe(10_300n);
    expect(DEFAULT_GAS_PRICE_MIN_MULT_BPS).toBe(10_300);
    // +3 % outlasts two maximal (+1 %, RSKIP-09) rises of the block minimum; +2 % only one.
    const rise = (m: bigint) => m + m / 100n;
    expect(rise(rise(MIN))).toBeLessThan((MIN * 10_300n) / 10_000n);
    expect(rise(rise(MIN))).toBeGreaterThan((MIN * 10_200n) / 10_000n);
    expect(cfg.gas.defaultReceiptRatioPpm).toBe(880_000n);
    expect(loadConfig({ ...ENV, GAS_PRICE_MIN_MULT_BPS: "10000" }).gas.minGasPriceMultBps).toBe(10_000n);
    expect(() => loadConfig({ ...ENV, GAS_PRICE_MIN_MULT_BPS: "9999" })).toThrow(/GAS_PRICE_MIN_MULT_BPS/);
    expect(() => loadConfig({ ...ENV, GAS_PRICE_MIN_MULT_BPS: "20001" })).toThrow(/GAS_PRICE_MIN_MULT_BPS/);
    expect(loadConfig({ ...ENV, DEFAULT_GAS_RECEIPT_RATIO: "0.95" }).gas.defaultReceiptRatioPpm).toBe(950_000n);
    expect(() => loadConfig({ ...ENV, DEFAULT_GAS_RECEIPT_RATIO: "0.5" })).toThrow(/DEFAULT_GAS_RECEIPT_RATIO/);
    expect(() => loadConfig({ ...ENV, DEFAULT_GAS_RECEIPT_RATIO: "1.1" })).toThrow(/DEFAULT_GAS_RECEIPT_RATIO/);
  });

  it("reads the block's minimumGasPrice (viem passes the unknown hex field through) and rounds UP", async () => {
    const { chain, w } = fake({ block: { number: 1n, minimumGasPrice: "0x1699280" }, estimate: 1n, gasUsed: 1n });
    const r = await readSendGasPrice((chain as { pub: never }).pub, 10_200n);
    expect(r).toEqual({ wei: SEND_102, source: "minimumGasPrice", minWei: MIN });
    expect(w.calls.gasPrice).toBe(0);
    // ⌈ ⌉: 101 × 1.02 = 103.02 → 104
    const odd = fake({ block: { minimumGasPrice: "0x65" }, estimate: 1n, gasUsed: 1n });
    expect((await readSendGasPrice((odd.chain as { pub: never }).pub, 10_200n)).wei).toBe(104n);
  });

  it("falls back to eth_gasPrice: no field (anvil), a zero field, a failed block read, no getBlock", async () => {
    for (const block of [{ number: 1n }, { minimumGasPrice: "0x0" }, { minimumGasPrice: "garbage" }, () => { throw new Error("429"); }, undefined]) {
      const { chain, w } = fake({ block: block as never, estimate: 1n, gasUsed: 1n });
      expect(await readSendGasPrice((chain as { pub: never }).pub, 10_200n)).toEqual({ wei: ETH_GAS_PRICE, source: "eth_gasPrice" });
      expect(w.calls.gasPrice).toBe(1);
    }
  });

  it("quantity(): hex, decimal, bigint; undefined for anything else", () => {
    expect(quantity("0x1699280")).toBe(MIN);
    expect(quantity("23696000")).toBe(MIN);
    expect(quantity(MIN)).toBe(MIN);
    expect(quantity(null)).toBeUndefined();
    expect(quantity("0x")).toBeUndefined();
    expect(quantity(1.5)).toBeUndefined();
  });

  it("withSendGasPrice: one read per TTL, the source logged once (and again when it changes)", async () => {
    const block: Record<string, unknown> = { minimumGasPrice: "0x1699280" };
    const { chain, w } = fake({ block, estimate: 1n, gasUsed: 1n });
    let t = 0;
    const logs: string[] = [];
    const c = withSendGasPrice(chain, { multBps: 10_300n, now: () => t, log: (m) => logs.push(m) });
    expect(await c.pub.getGasPrice()).toBe(SEND);
    expect(await c.pub.getGasPrice()).toBe(SEND);
    expect(w.calls.block).toBe(1);
    t = 10_000;
    expect(await c.pub.getGasPrice()).toBe(SEND);
    expect(w.calls.block).toBe(2);
    expect(logs).toHaveLength(1);
    expect(logs[0]).toMatch(/minimumGasPrice 23696000 × 10300 bps = 24406880/);
    delete block.minimumGasPrice;
    t = 20_000;
    expect(await c.pub.getGasPrice()).toBe(ETH_GAS_PRICE);
    expect(logs).toHaveLength(2);
    expect(logs[1]).toMatch(/no minimumGasPrice — sending at eth_gasPrice/);
  });

  it("engine: the route fill is SENT at min × 1.03 and its gate, floor and budget charge use that same price", async () => {
    const { chain, w } = fake({ block: { minimumGasPrice: "0x1699280" }, estimate: 400_000n, gasUsed: 340_000n });
    const cfg = loadConfig(ENV);
    const e = await Engine.create({ cfg, chain, store: new MemoryStateStore(), log: () => {} });
    const t = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.sent).toBeDefined();
    expect(w.sent[0]!.gasPrice).toBe(SEND);
    expect(e.pending!.gasPrice).toBe(SEND.toString());
    const limit = w.sent[0]!.gas!;
    expect(limit).toBe(500_000n); // 400k × 1.25 — headroom unchanged
    expect(e.guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - limit * SEND);
    // The floor covers 400k × 0.88 = 352k gas AT THE SEND PRICE, nothing more.
    expect(minOutOf(w.sent[0]!.data) - OWED).toBe(rbtcToUsdt0(352_000n * SEND));
  });

  it("engine on a chain without minimumGasPrice (anvil): eth_gasPrice prices and sends", async () => {
    const { chain, w } = fake({ block: { number: 1n }, estimate: 400_000n, gasUsed: 340_000n });
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(w.sent[0]!.gasPrice).toBe(ETH_GAS_PRICE);
  });

  it("MAX_GAS_PRICE_GWEI still applies to the send price", async () => {
    const { chain, w } = fake({ block: { minimumGasPrice: "0x" + (200_000_000n).toString(16) }, estimate: 400_000n, gasUsed: 340_000n });
    const e = await Engine.create({ cfg: loadConfig(ENV), chain, store: new MemoryStateStore(), log: () => {} });
    const t = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.outcomes[0]?.reason).toMatch(/MAX_GAS_PRICE_GWEI/);
    expect(w.sent).toHaveLength(0);
  });
});

describe("gas ratio learning (receipt / estimate per fill shape)", () => {
  const A = gasShape("route", "pull", ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0);
  const B = gasShape("route", "direct", ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0);

  it("default 0.88 before any receipt; priced = ⌈estimate × r⌉", () => {
    const g = new GasRatios();
    expect(g.ratioPpm(A)).toBe(DEFAULT_RATIO_PPM);
    expect(g.priced(A, 400_000n)).toBe(352_000n);
    expect(g.priced(A, 420_000n)).toBe(369_600n);
    expect(g.priced(A, 1n)).toBe(1n); // rounds up
  });

  it("learns from receipts: r = the MAX of the recent ratios (conservative), per shape", () => {
    const g = new GasRatios();
    g.record(A, 362_894n, 317_478n, 1); // 0.8749
    expect(g.ratioPpm(A)).toBe(874_851n);
    g.record(A, 403_523n, 341_007n, 2); // 0.8451 — lower, r stays at the max
    expect(g.ratioPpm(A)).toBe(874_851n);
    g.record(A, 400_000n, 360_000n, 3); // 0.90 — higher, r rises
    expect(g.ratioPpm(A)).toBe(900_000n);
    expect(g.ratioPpm(B)).toBe(DEFAULT_RATIO_PPM); // another shape is untouched
    g.record(B, 400_000n, 280_000n, 4);
    expect(g.ratioPpm(B)).toBe(700_000n);
    expect(g.ratioPpm(A)).toBe(900_000n);
  });

  it("clamped to [0.6, 1.0]", () => {
    const g = new GasRatios();
    g.record(A, 400_000n, 100_000n, 1);
    expect(g.ratioPpm(A)).toBe(600_000n);
    g.record(B, 400_000n, 480_000n, 1);
    expect(g.ratioPpm(B)).toBe(1_000_000n);
    expect(new GasRatios(100_000n).ratioPpm(A)).toBe(600_000n); // the default is clamped too
  });

  it("a window of the last 20 receipts: a heavy outlier ages out after 20 lighter fills", () => {
    const g = new GasRatios();
    g.record(A, 100n, 95n, 0);
    for (let i = 1; i < WINDOW; i++) g.record(A, 100n, 80n, i);
    expect(g.ratioPpm(A)).toBe(950_000n);
    g.record(A, 100n, 80n, WINDOW);
    expect(g.ratioPpm(A)).toBe(800_000n);
    expect(g.toJSON()[A]!.s).toHaveLength(WINDOW);
  });

  it("bounded shapes: the least recently updated is evicted", () => {
    const g = new GasRatios();
    for (let i = 0; i <= MAX_SHAPES; i++) g.record(`s${i}`, 100n, 70n, i);
    expect(Object.keys(g.toJSON())).toHaveLength(MAX_SHAPES);
    expect(g.ratioPpm("s0")).toBe(DEFAULT_RATIO_PPM);
    expect(g.ratioPpm(`s${MAX_SHAPES}`)).toBe(700_000n);
  });

  it("persists (JSON round trip); a malformed state is ignored", () => {
    const g = new GasRatios();
    g.record(A, 400_000n, 320_000n, 5);
    const back = new GasRatios(DEFAULT_RATIO_PPM, JSON.parse(JSON.stringify(g.toJSON())));
    expect(back.ratioPpm(A)).toBe(800_000n);
    const bad = new GasRatios(DEFAULT_RATIO_PPM, { [A]: { s: [-1, 1.5, "x" as never], at: 0 }, [B]: null as never });
    expect(bad.ratioPpm(A)).toBe(DEFAULT_RATIO_PPM);
    expect(bad.ratioPpm(B)).toBe(DEFAULT_RATIO_PPM);
  });

  it("route gate + plan floor priced at r × estimate; the gas LIMIT stays max(priced, estimate × 1.25)", async () => {
    const { chain, w } = fake({ estimate: 400_000n, gasUsed: 1n });
    const cfg = loadConfig(ENV);
    const ratios = new GasRatios(cfg.gas.defaultReceiptRatioPpm);
    const shape = gasShape("route", "pull", ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0);
    ratios.record(shape, 400_000n, 300_000n, 1); // learned r = 0.75
    const rf = new RouteFiller(cfg, chain, new Budget({ [ROUTE_FILLS]: 60n }), () => {}, () => {}, new Guard(cfg.gas), ratios);
    expect((await rf.consider(entry("01") as never)).status).toBe("pending");
    expect(minOutOf(w.sent[0]!.data) - OWED).toBe(rbtcToUsdt0(300_000n * ETH_GAS_PRICE)); // 400k × 0.75
    expect(w.sent[0]!.gas).toBe(500_000n);
  });

  it("engine: the estimate is recorded at send, the ratio learned from the receipt, persisted, and prices the next fill", async () => {
    const { chain, w } = fake({ block: { minimumGasPrice: "0x1699280" }, estimate: 400_000n, gasUsed: 320_000n });
    const store = new MemoryStateStore();
    const cfg = loadConfig(ENV);
    const e = await Engine.create({ cfg, chain, store, log: () => {} });
    await e.tick({ fetchEntries: async () => [entry("01")] });
    const shape = gasShape("route", "pull", ROOTSTOCK.wrbtc, ROOTSTOCK.usdt0);
    expect(e.pending!.gasMeter).toEqual({ shape, estimate: "400000" });
    expect(minOutOf(w.sent[0]!.data) - OWED).toBe(rbtcToUsdt0(352_000n * SEND)); // default 0.88
    w.receipt = "success";
    await e.tick({ fetchEntries: async () => [] });
    expect(e.gasRatios.ratioPpm(shape)).toBe(800_000n);
    const saved = await store.get<FillerState>(STATE_KEY);
    expect(saved!.gasRatios![shape]!.s).toEqual([800_000]);
    // A restarted engine keeps it, and prices the next fill of that shape at 0.80.
    const e2 = await Engine.create({ cfg, chain, store, log: () => {} });
    expect(e2.gasRatios.ratioPpm(shape)).toBe(800_000n);
    w.receipt = "none";
    await e2.tick({ fetchEntries: async () => [entry("02")] });
    expect(minOutOf(w.sent[1]!.data) - OWED).toBe(rbtcToUsdt0(320_000n * SEND));
    expect(w.sent[1]!.gas).toBe(500_000n);
  });
});

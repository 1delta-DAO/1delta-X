/**
 * Gasless makers: an order funded only by the maker's ERC-2612 permit (spender =
 * Settlement). The engine stages it (./src/permit.ts); the ROUTE strategy fills it
 * with the permit INSIDE `executeFill` (`permits`, one tx, simulated together), the
 * gate charging PERMIT_IN_FILL_GAS; the inventory strategy (EOA `fillUpTo`) cannot
 * carry it and skips the order until something else funds it.
 */
import {
  AGGREGATOR_FILL_SOLVER_ABI,
  erc2612PermitToJson,
  hashOrderStruct,
  orderToJson,
  OrderSide,
  type Erc2612Permit,
  type Order,
  type Permit2612,
} from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import { Engine } from "../src/engine";
import { Filler } from "../src/filler";
import { fetchOrders } from "../src/intake";
import { permitFillable, permitStage } from "../src/permit";
import { Budget } from "../src/policy";
import { PERMIT_IN_FILL_GAS } from "../src/route";
import { MemoryStateStore } from "../src/state";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const SETTLEMENT = "0x0000000000000000000000000000000000000001" as Address;
const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const MAKER = "0x00000000000000000000000000000000000000bb" as Address;
const USDT0 = ROOTSTOCK.usdt0 as Address;
const IN = 1_000_000_000n; // 1,000 USD₮0
const OWED = 9n * 10n ** 15n; // 0.009 WRBTC
const GAS_PRICE = 26_000_000n;
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT,
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
  AGGREGATOR_SOLVER: SOLVER,
  INVENTORY_ENABLED: "0",
  SUSHI_ENABLED: "0",
  NORDSTERN_ENABLED: "0",
  DRY_RUN: "0",
};

/** Maker sells 1,000 USD₮0 for ≥ 0.009 WRBTC — a pull order on the Oku pool. */
function order(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: USDT0, start: IN, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.wrbtc as Address, start: OWED, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}

const PERMIT: Erc2612Permit = {
  token: USDT0,
  spender: SETTLEMENT,
  value: IN,
  nonce: 0n,
  deadline: 2_000_000_000n,
  v: 27,
  r: `0x${"11".repeat(32)}`,
  s: `0x${"22".repeat(32)}`,
};

const entry = (over: { permit?: Erc2612Permit | null; fillable?: bigint; order?: Order } = {}) => {
  const o = over.order ?? order();
  return {
    orderHash: hashOrderStruct(o),
    announce: { order: o, sig: "0x" as Hex, ...(over.permit === null ? {} : { erc2612Permit: over.permit ?? PERMIT }) },
    // The book's reading: the lens's allowance-capped fillable, 0 until the permit runs.
    state: { ok: true, status: "Fillable", fillableAmount: over.fillable ?? 0n, validatorsPass: true },
  };
};

/** The `permits` argument of a sent / simulated `executeFill`. */
const permitsOf = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[5] as readonly Permit2612[];
const fillAmountOf = (data: Hex) => decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data }).args[2] as bigint;

/**
 * A chain where the maker's USD₮0 allowance to Settlement exists only once a `permit`
 * ran — someone else's tx, or the solver's call inside `executeFill`. The simulated
 * `executeFill` mirrors the solver: run each permit (nonce must match), else accept an
 * existing allowance ≥ value, else revert `PermitFailed`; a fill nothing funds reverts.
 */
function world(o: { received?: bigint; owed?: bigint } = {}) {
  const received = o.received ?? IN;
  const owed = o.owed ?? OWED;
  const w = {
    nonce: 0n, // USD₮0 nonces(maker)
    funded: false, // an allowance exists: the lens reports the order fillable
    makerBalance: IN,
    quoteOut: 10n ** 16n, // the pool's output for the whole input
    receipt: "none" as "none" | "success" | "reverted",
    sent: [] as Array<{ to?: Address; data: Hex; hash: Hex; gas?: bigint }>,
    simulated: [] as Hex[],
    mined: 0,
  };
  /** The solver's `_permits`, as a state transition: returns whether the fill is funded after it. */
  const runPermits = (data: Hex): boolean => {
    for (const p of permitsOf(data)) {
      if (p.owner.toLowerCase() !== MAKER.toLowerCase()) throw new Error("execution reverted: PermitOwnerNotMaker");
      if (w.nonce === PERMIT.nonce) {
        w.nonce++;
        w.funded = true;
      } else if (!w.funded) {
        throw new Error("execution reverted: PermitFailed");
      }
    }
    return w.funded;
  };
  const pub = {
    getCode: async () => "0x60",
    getGasPrice: async () => GAS_PRICE,
    getTransactionCount: async () => w.mined,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      const hash = keccak256(serializedTransaction);
      w.sent.push({ to: t.to ?? undefined, data: t.data!, hash, gas: t.gas });
      return hash;
    },
    getTransactionReceipt: async () => {
      if (w.receipt === "none") throw new Error("Transaction receipt could not be found");
      w.mined = w.sent.length;
      return { status: w.receipt, gasUsed: 280_000n, effectiveGasPrice: GAS_PRICE };
    },
    getTransaction: async () => ({}),
    readContract: async ({ functionName, address }: { functionName: string; address: Address }) => {
      switch (functionName) {
        case "SETTLEMENT": return SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return SANDBOX;
        case "OWNER": return SOLVER;
        // One pool venue (Oku) whose QuoterV2 prices the same factory: venue 1 is dropped at init.
        case "POOL_VENUES": return 1n;
        case "poolVenue": return ["0xaF37EC98A00FD63689CF3060BF3B6784E00caD82", "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"];
        case "factory": return "0xaF37EC98A00FD63689CF3060BF3B6784E00caD82";
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "previewFill": return [0n, [received], [owed]];
        case "previewBump": return 0n;
        case "decimals": return 18;
        case "getOrderRelevantState": return [1, w.funded ? IN : 0n, true, true];
        case "remaining": return IN;
        case "nonces": return w.nonce;
        case "balanceOf": return address.toLowerCase() === USDT0.toLowerCase() ? w.makerBalance : 0n;
        case "allowance": return 10n ** 30n;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async () => ({ result: [w.quoteOut, [], [], 100_000n] }),
    // eth_call / estimateGas run on a COPY of the state: the permit's effect does not persist.
    call: async ({ data }: { data: Hex }) => {
      w.simulated.push(data);
      const saved = { nonce: w.nonce, funded: w.funded };
      try {
        if (!runPermits(data)) throw new Error("execution reverted: TRANSFER_FROM_FAILED");
      } finally {
        Object.assign(w, saved);
      }
      return { data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [owed] }) };
    },
    estimateGas: async () => 200_000n,
  };
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

async function engine(env: Record<string, string> = {}, legs: { received?: bigint; owed?: bigint } = {}) {
  const { w, chain } = world(legs);
  const logs: string[] = [];
  const e = await Engine.create({ cfg: loadConfig({ ...ENV, ...env }), chain, store: new MemoryStateStore(), log: (m) => logs.push(m) });
  return { e, w, logs, chain };
}

describe("gasless maker: the permit rides IN the fill (executeFill permits)", () => {
  it("one executeFill tx carries the maker's permit (owner = maker, spender implied = Settlement), sized by the permit stage", async () => {
    const { e, w } = await engine();
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.sent).toMatchObject({ kind: "fill", strategy: "route" });
    expect(w.sent).toHaveLength(1); // no separate permit tx
    expect(w.sent[0]!.to?.toLowerCase()).toBe(SOLVER.toLowerCase());
    expect(permitsOf(w.sent[0]!.data)).toEqual([
      { token: USDT0, owner: MAKER, value: IN, deadline: PERMIT.deadline, v: 27, r: PERMIT.r, s: PERMIT.s },
    ]);
    // The book said 0 fillable; the stage sized it from the permit (min of remaining, balance, value).
    expect(fillAmountOf(w.sent[0]!.data)).toBe(IN);
    // The simulation ran WITH the permit (without it the fill reverts — nothing funds it).
    expect(w.simulated.every((d) => permitsOf(d).length === 1)).toBe(true);
  });

  it("the gate charges PERMIT_IN_FILL_GAS only when the fill carries the permit", async () => {
    // Pre-simulation gas at r = 0.88 (output = WRBTC, so gas wei = output units):
    //   funded: (320k − 30k) × 0.88 = 255,200 × 26 Mwei ≈ 6.64e12
    //   permit: (320k − 30k + 60k) × 0.88 = 308,000 × 26 Mwei ≈ 8.01e12
    // A quote whose haircut leaves owed + 7.3e12 passes the first and fails the second.
    const target = OWED + 7_300_000_000_000n;
    const quoteOut = (target * 10_000n + 9_989n) / 9_990n;
    expect(PERMIT_IN_FILL_GAS).toBe(60_000n);

    const withPermit = await engine();
    withPermit.w.quoteOut = quoteOut;
    const t1 = await withPermit.e.tick({ fetchEntries: async () => [entry()] });
    expect(t1.sent).toBeUndefined();
    expect(withPermit.w.sent).toHaveLength(0);
    expect(t1.outcomes[0]!.reason).toMatch(/unprofitable/);

    const funded = await engine();
    funded.w.quoteOut = quoteOut;
    funded.w.funded = true; // the maker approved: no permit needed, no permit gas
    const t2 = await funded.e.tick({ fetchEntries: async () => [entry({ fillable: IN })] });
    expect(t2.sent).toMatchObject({ kind: "fill" });
    expect(permitsOf(funded.w.sent[0]!.data)).toEqual([]);
  });

  it("an unprofitable order is never sent, permit or not", async () => {
    const { e, w } = await engine();
    w.quoteOut = OWED - 1n;
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.sent).toBeUndefined();
    expect(w.sent).toHaveLength(0);
  });

  it("someone else already ran the permit (nonce moved, allowance exists): the fill goes out WITHOUT it", async () => {
    const { e, w } = await engine();
    w.nonce = 1n;
    w.funded = true;
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.sent).toMatchObject({ kind: "fill" });
    expect(w.sent).toHaveLength(1);
    expect(w.sent[0]!.to?.toLowerCase()).toBe(SOLVER.toLowerCase());
    expect(permitsOf(w.sent[0]!.data)).toEqual([]); // the solver would accept it too; not passing it saves gas
  });

  it("a permit spent elsewhere with nothing funding the order is skipped and held (dead)", async () => {
    const { e, w, logs } = await engine();
    w.nonce = 1n; // the maker used the nonce for another permit
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.sent).toBeUndefined();
    expect(t.outcomes[0]).toMatchObject({ status: "skipped", rest: true });
    expect(logs.join("\n")).toMatch(/spent or superseded/);
    const t2 = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t2.held).toBe(1);
  });

  it("a permit about to expire, or a maker without the token, is dead", async () => {
    const soon = await engine();
    const nowS = BigInt(Math.floor(Date.now() / 1000));
    const t = await soon.e.tick({ fetchEntries: async () => [entry({ permit: { ...PERMIT, deadline: nowS + 30n } })] });
    expect(t.sent).toBeUndefined();
    expect(t.outcomes[0]!.reason).toMatch(/expires too soon/);
    const broke = await engine();
    broke.w.makerBalance = 0n;
    const t2 = await broke.e.tick({ fetchEntries: async () => [entry()] });
    expect(t2.sent).toBeUndefined();
    expect(t2.outcomes[0]!.reason).toMatch(/holds none/);
  });

  it("a permit for another spender is ignored (stage none): the order is judged on the book's fillable alone", async () => {
    const { e, w } = await engine();
    const t = await e.tick({ fetchEntries: async () => [entry({ permit: { ...PERMIT, spender: SANDBOX } })] });
    expect(t.sent).toBeUndefined();
    expect(w.sent).toHaveLength(0);
    expect(t.outcomes[0]!.reason).toMatch(/nothing fillable/);
  });

  it("PERMIT_FILLS_ENABLED=0 skips permit-only orders", async () => {
    const { e, w } = await engine({ PERMIT_FILLS_ENABLED: "0" });
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.sent).toBeUndefined();
    expect(w.sent).toHaveLength(0);
    expect(t.outcomes[0]!.reason).toMatch(/PERMIT_FILLS_ENABLED=0/);
  });

  it("the removed relay knobs are gone from the config", () => {
    const cfg = loadConfig({ ...ENV, PERMIT_RELAY_ENABLED: "0", PERMIT_RELAY_GAS: "1" });
    expect(cfg.permitFills).toBe(true);
    expect("permitRelay" in cfg).toBe(false);
  });

  it("dry run: simulates WITH the permit, sends nothing", async () => {
    const { e, w, logs } = await engine({ DRY_RUN: "1" });
    const t = await e.tick({ fetchEntries: async () => [entry()] });
    expect(t.outcomes[0]).toMatchObject({ status: "dry-run" });
    expect(w.sent).toHaveLength(0);
    expect(w.simulated.length).toBeGreaterThan(0);
    expect(permitsOf(w.simulated[0]!)).toHaveLength(1);
    expect(logs.join("\n")).toMatch(/pull\+permit/);
  });
});

describe("the inventory strategy cannot carry a permit", () => {
  // Maker BUYS 100 USDRIF with 101 USD₮0 (our sell side): inventory's shape and price.
  const usdrifOrder = order({
    legsIn: [{ token: USDT0, start: 101_000_000n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdrif as Address, start: 100n * 10n ** 18n, end: 0n, recipient: zeroAddress }],
  });
  const usdrifPermit = { ...PERMIT, value: 101_000_000n };

  it("Filler: an entry carrying a fill permit is not accepted and skipped before any RPC; once funded it is", async () => {
    const cfg = loadConfig({ ...ENV, INVENTORY_ENABLED: "1", SELL_USDRIF: "1" });
    let reads = 0;
    const chain = { pub: new Proxy({}, { get: () => () => (reads++, Promise.reject(new Error("no RPC expected"))) }), me: ACCOUNT.address } as never;
    const f = new Filler(cfg, chain, new Budget({}), () => {});
    const unfunded = { ...entry({ order: usdrifOrder, permit: usdrifPermit }), state: { ok: true, status: "Fillable", fillableAmount: 101_000_000n, validatorsPass: true }, fillPermit: usdrifPermit };
    expect(f.accepts(unfunded)).toBe(false);
    const out = await f.consider(unfunded);
    expect(out).toMatchObject({ status: "skipped", strategy: "inventory", rest: true });
    expect(out.reason).toMatch(/cannot carry/);
    expect(reads).toBe(0);
    // Funded (the lens has an allowance): no fill permit attached — inventory takes it by shape.
    const { fillPermit: _, ...funded } = unfunded;
    expect(f.accepts(funded)).toBe(true);
  });

  it("engine, both strategies on: inventory passes on the unfunded permit order and the ROUTE fills it with the permit", async () => {
    const { e, w } = await engine({ INVENTORY_ENABLED: "1", SELL_USDRIF: "1" }, { received: 101_000_000n, owed: 100n * 10n ** 18n });
    w.makerBalance = 101_000_000n;
    w.quoteOut = 102n * 10n ** 18n; // USD₮0 → USDRIF on the 0.05 % pool, and the gas price reference
    const t = await e.tick({ fetchEntries: async () => [entry({ order: usdrifOrder, permit: usdrifPermit })] });
    expect(t.sent).toMatchObject({ kind: "fill", strategy: "route" });
    expect(w.sent).toHaveLength(1);
    expect(permitsOf(w.sent[0]!.data)).toHaveLength(1);
  });
});

describe("permitStage", () => {
  it("none / funded / permit / dead from the lens and token state", async () => {
    const cfg = loadConfig(ENV);
    const { w, chain } = world();
    const nowS = BigInt(Math.floor(Date.now() / 1000));
    expect(await permitStage(chain, cfg, entry({ permit: null }), nowS)).toEqual({ kind: "none" });
    expect(await permitStage(chain, cfg, entry(), nowS)).toEqual({ kind: "permit", fillable: IN, permit: PERMIT });
    w.funded = true;
    expect(await permitStage(chain, cfg, entry(), nowS)).toEqual({ kind: "funded", fillable: IN });
    w.funded = false;
    w.nonce = 5n;
    expect((await permitStage(chain, cfg, entry(), nowS)).kind).toBe("dead");
  });
});

describe("permitFillable", () => {
  it("caps a fixed-input SELL in the permit token by balance and permit value", () => {
    expect(permitFillable(order(), PERMIT, IN, IN / 2n)).toBe(IN / 2n);
    expect(permitFillable(order(), { ...PERMIT, value: IN / 4n }, IN, IN)).toBe(IN / 4n);
    const buy = { ...order(), side: OrderSide.BUY };
    expect(permitFillable(buy, PERMIT, 77n, 0n)).toBe(77n);
  });
});

describe("intake carries the permit", () => {
  it("parses erc2612Permit from GET /orders and drops an entry whose permit is malformed", async () => {
    const o = order();
    const row = (permit: unknown) => ({
      orderHash: hashOrderStruct(o),
      order: orderToJson(o),
      sig: `0x${"ab".repeat(65)}`,
      state: { status: "Fillable", ok: true, fillableAmount: "0", isSignatureValid: true, validatorsPass: true, erc2612Live: true },
      erc2612Permit: permit,
    });
    const good = await fetchOrders("https://b", async () => new Response(JSON.stringify({ orders: [row(erc2612PermitToJson(PERMIT))] })));
    expect(good.entries[0]!.announce.erc2612Permit).toEqual({ ...PERMIT, token: PERMIT.token, spender: PERMIT.spender });
    const bad = await fetchOrders("https://b", async () => new Response(JSON.stringify({ orders: [row({ token: USDT0 })] })));
    expect(bad.entries).toHaveLength(0);
    expect(bad.skipped).toBe(1);
  });
});

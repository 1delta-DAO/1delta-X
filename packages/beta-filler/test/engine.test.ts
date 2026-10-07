/**
 * The non-blocking tick model (2026-10): one outstanding tx, receipts read by later
 * ticks, state in an injected StateStore, the rebalancer under the shared Guard.
 */
import { AGGREGATOR_FILL_SOLVER_ABI, OrderSide, packTiming, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, erc20Abi, keccak256, parseTransaction, TransactionNotFoundError, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { MOC_CORE_ABI } from "../src/chain";
import { loadConfig, ROOTSTOCK } from "../src/config";
import { Engine, roundRobin } from "../src/engine";
import { GAS, Guard, broadcast } from "../src/guard";
import { MemoryStateStore, STATE_KEY, type FillerState } from "../src/state";

const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const GAS_PRICE = 26_065_600n;
const OWED = 900_000_000n;
const RECEIVED = 10n ** 16n;
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
  REDEEM_MIN_USDRIF: "50", // the rebalancer fixtures hold < 1000 USDRIF (the production default)
};

function order(): Order {
  return {
    maker: "0x00000000000000000000000000000000000000bb", side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.wrbtc, start: RECEIVED, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: OWED, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
  } as Order;
}
const entry = (h: string, over: Partial<Order> = {}, fillable = RECEIVED) => ({
  orderHash: ("0x" + h.repeat(32)) as Hex,
  announce: { order: { ...order(), ...over } as Order, sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: fillable, validatorsPass: true },
});

/** A route-strategy chain plus the MoC/ERC-20 reads the rebalancer needs. */
function world() {
  const w = {
    receipt: "none" as "none" | "success" | "reverted",
    sent: [] as Array<{ to?: Address; data: Hex; hash: Hex; gas?: bigint; nonce?: number; value?: bigint }>,
    mined: 0,
    inFlightExtra: 0,
    refuseRaw: false,
    gasPrice: GAS_PRICE,
    usdrif: 0n,
    rif: 0n,
    allowance: 10n ** 30n,
    firstOperId: 0n,
    operIdCount: 7n,
    previews: 0,
    /** What the fake lens previews as owed (raise it to make every route quote unprofitable). */
    owed: OWED,
    gasPriceCalls: 0,
    /** Effects of mined txs not applied yet (approve → allowance, redeemTP → balance). */
    applied: 0,
    redeems: [] as bigint[],
    approvals: [] as bigint[],
    /** RPC calls, by method (fake). */
    calls: {} as Record<string, number>,
  };
  const hit = (m: string) => {
    w.calls[m] = (w.calls[m] ?? 0) + 1;
  };
  /** Apply what the mined txs did to the fake ERC-20 / MoC state. */
  const applyMined = () => {
    for (; w.applied < w.sent.length; w.applied++) {
      const t = w.sent[w.applied]!;
      try {
        const d = decodeFunctionData({ abi: erc20Abi, data: t.data });
        if (d.functionName === "approve") {
          w.allowance = d.args[1] as bigint;
          w.approvals.push(w.allowance);
        }
        continue;
      } catch {
        // not an ERC-20 call
      }
      try {
        const d = decodeFunctionData({ abi: MOC_CORE_ABI, data: t.data });
        if (d.functionName === "redeemTP") {
          const q = d.args[1] as bigint;
          w.usdrif -= q;
          w.allowance -= q;
          w.redeems.push(q);
        }
      } catch {
        // a fill
      }
    }
  };
  const pub = {
    getCode: async () => "0x60",
    getGasPrice: async () => {
      hit("eth_gasPrice");
      w.gasPriceCalls++;
      return w.gasPrice;
    },
    getTransactionCount: async ({ blockTag }: { blockTag: string }) => w.mined + (blockTag === "pending" ? w.inFlightExtra : 0),
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      if (w.refuseRaw) throw new Error("nonce too low");
      const t = parseTransaction(serializedTransaction);
      const hash = keccak256(serializedTransaction);
      w.sent.push({ to: t.to ?? undefined, data: t.data!, hash, gas: t.gas, nonce: t.nonce, value: t.value });
      return hash;
    },
    getTransactionReceipt: async () => {
      if (w.receipt === "none") throw new Error("Transaction receipt could not be found");
      w.mined = w.sent.length;
      if (w.receipt === "success") applyMined();
      return { status: w.receipt, gasUsed: 100_000n, effectiveGasPrice: w.gasPrice };
    },
    getTransaction: async ({ hash }: { hash: Hex }) => {
      if (w.refuseRaw) throw new TransactionNotFoundError({ hash });
      return {};
    },
    readContract: async ({ functionName, address }: { functionName: string; address: Address }) => {
      hit(functionName);
      switch (functionName) {
        case "SETTLEMENT": return ENV.SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return SANDBOX;
        case "OWNER": return SOLVER;
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "previewFill": w.previews++; return [0n, [RECEIVED], [w.owed]];
        case "previewBump": return 0n; // the route plan's minBumpBps (task 08)
        case "decimals": return 6;
        case "balanceOf": return address.toLowerCase() === ROOTSTOCK.usdrif.toLowerCase() ? w.usdrif : address.toLowerCase() === ROOTSTOCK.rif.toLowerCase() ? w.rif : 0n;
        case "allowance": return w.allowance;
        case "getPACtp": return 10n ** 17n; // 10 RIF per USDRIF
        case "getExecFee": return 1_000n;
        case "firstOperId": return w.firstOperId;
        case "operIdCount": return w.operIdCount;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ args }: { args: [unknown, bigint] }) => {
      hit("quote");
      const amountIn = typeof args[1] === "bigint" ? args[1] : (args[0] as { amountIn: bigint }).amountIn;
      return { result: [(amountIn * 100_000n * 10n ** 6n) / 10n ** 18n, [], [], 100_000n] };
    },
    call: async () => ({ data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [OWED] }) }),
    estimateGas: async () => 200_000n,
  };
  return { w, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

async function engine(env: Record<string, string> = {}, store = new MemoryStateStore(), chain?: unknown) {
  const cfg = loadConfig({ ...ENV, ...env });
  const logs: string[] = [];
  const c = chain ?? world().chain;
  const e = await Engine.create({ cfg, chain: c as never, store, log: (m) => logs.push(m) });
  return { e, logs, store, cfg };
}

describe("tick state machine", () => {
  it("sends ONE tx and records it pending; nothing else is sent until its receipt is read", async () => {
    const { w, chain } = world();
    const { e, cfg } = await engine({}, undefined, chain);
    const entries = [entry("01"), entry("02"), entry("03")];
    const t1 = await e.tick({ fetchEntries: async () => entries });
    expect(t1).toMatchObject({ pending: true, evaluated: 1 });
    expect(w.sent).toHaveLength(1);
    expect(e.pending).toMatchObject({ hash: w.sent[0]!.hash, nonce: 0, kind: "fill", strategy: "route", orderHash: entries[0]!.orderHash });
    // Charged conservatively at the gas LIMIT until the receipt is read.
    expect(e.guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - BigInt(e.pending!.gasLimit) * GAS_PRICE);

    const t2 = await e.tick({ fetchEntries: async () => entries });
    expect(t2).toMatchObject({ pending: true, evaluated: 0 });
    expect(t2.resolution?.status).toBe("waiting");
    expect(w.sent).toHaveLength(1);

    w.receipt = "success";
    const t3 = await e.tick({ fetchEntries: async () => entries });
    expect(t3.resolution?.status).toBe("success");
    expect(e.guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei - 100_000n * GAS_PRICE - BigInt(t3.sent!.gasLimit) * GAS_PRICE);
    // The next order, at the next nonce (round-robin: after 0x01…).
    expect(t3.sent).toMatchObject({ orderHash: entries[1]!.orderHash, nonce: 1 });
    expect(w.sent).toHaveLength(2);
  });

  it("refuses to send while the account has an untracked tx in flight", async () => {
    const { w, chain } = world();
    w.inFlightExtra = 1;
    const { e } = await engine({}, undefined, chain);
    const t = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.pending).toBe(false);
    expect(t.outcomes[0]!.reason).toMatch(/untracked tx/);
    expect(w.sent).toHaveLength(0);
  });

  it("a raw tx the node refuses undoes the charges and backs the order off for the strategy", async () => {
    const { w, chain } = world();
    w.refuseRaw = true;
    const { e, cfg } = await engine({}, undefined, chain);
    const t = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.pending).toBe(false);
    expect(t.outcomes[0]).toMatchObject({ status: "failed" });
    expect(e.pending).toBeUndefined();
    expect(e.guard.gas.remaining(GAS, Date.now())).toBe(cfg.gas.hourlyWei);
    expect(e.budgetsLeft().routeFills).toBe(60n);
    expect(e.guard.admit(entry("01").orderHash, "route", Date.now())).toMatchObject({ global: false });
  });

  it("paused: resolves the outstanding tx but sends nothing new", async () => {
    const { w, chain } = world();
    const { e } = await engine({}, undefined, chain);
    await e.tick({ fetchEntries: async () => [entry("01"), entry("02")] });
    w.receipt = "success";
    const t = await e.tick({ fetchEntries: async () => [entry("01"), entry("02")], paused: true });
    expect(t).toMatchObject({ paused: true, pending: false });
    expect(t.resolution?.status).toBe("success");
    expect(w.sent).toHaveLength(1);
  });

  it("dry run: sends nothing, and does not re-evaluate a dry-run order within the recheck window", async () => {
    const { w, chain } = world();
    const { e } = await engine({ DRY_RUN: "1" }, undefined, chain);
    const t1 = await e.tick({ fetchEntries: async () => [entry("01"), entry("02")] });
    expect(t1.outcomes.map((o) => o.status)).toEqual(["dry-run", "dry-run"]);
    const previews = w.previews;
    const t2 = await e.tick({ fetchEntries: async () => [entry("01"), entry("02")] });
    expect(t2.evaluated).toBe(0);
    expect(w.previews).toBe(previews);
    expect(w.sent).toHaveLength(0);
  });
});

describe("per-tick work bound", () => {
  it("evaluates at most maxOrders, round-robin from the stored cursor", async () => {
    const { w, chain } = world();
    const { e } = await engine({ DRY_RUN: "1" }, undefined, chain);
    const entries = ["05", "01", "04", "02", "03"].map((h) => entry(h));
    const seen: string[] = [];
    for (let i = 0; i < 3; i++) {
      const t = await e.tick({ fetchEntries: async () => entries, limits: { maxOrders: 2 } });
      expect(t.evaluated).toBeLessThanOrEqual(2);
      seen.push(...t.outcomes.map((o) => o.orderHash.slice(2, 4)));
    }
    // 01 02 | 03 04 | 05 (01, 02 dry-ran < 60 s ago: skipped for free)
    expect(seen).toEqual(["01", "02", "03", "04", "05"]);
    expect(w.sent).toHaveLength(0);
  });

  it("canContinue = false stops the sweep before the next order", async () => {
    const { e } = await engine({ DRY_RUN: "1" });
    let n = 0;
    const t = await e.tick({ fetchEntries: async () => ["01", "02", "03"].map((h) => entry(h)), limits: { canContinue: () => n++ < 1 } });
    expect(t.evaluated).toBe(1);
    expect(t.bounded).toBe(true);
  });

  it("roundRobin wraps after the cursor", () => {
    const es = ["03", "01", "02"].map((h) => entry(h));
    expect(roundRobin(es, entry("02").orderHash).map((x) => x.orderHash.slice(2, 4))).toEqual(["03", "01", "02"]);
    expect(roundRobin(es, entry("09").orderHash).map((x) => x.orderHash.slice(2, 4))).toEqual(["01", "02", "03"]);
  });
});

describe("state store", () => {
  it("the pending tx, the budgets and the cursor survive a restart (new Engine on the same store)", async () => {
    const { w, chain } = world();
    const store = new MemoryStateStore();
    const a = await engine({}, store, chain);
    await a.e.tick({ fetchEntries: async () => [entry("01")] });
    const hash = a.e.pending!.hash;
    const b = await engine({}, store, chain);
    expect(b.e.pending?.hash).toBe(hash);
    expect(b.e.budgetsLeft().routeFills).toBe(59n);
    w.receipt = "reverted";
    const t = await b.e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.resolution?.status).toBe("reverted");
    expect(b.e.budgetsLeft().routeFills).toBe(60n); // timely revert: reservation released
    expect(t.outcomes[0]!.reason).toMatch(/backoff after 1 on-chain revert/);
    // A restarted engine treats the book as never seen (evaluated first, cursor kept);
    // from its second sweep the order is in the round-robin and moves the cursor.
    await b.e.tick({ fetchEntries: async () => [entry("01")] });
    const saved = (await store.get<FillerState>(STATE_KEY))!;
    expect(saved.guard?.pending).toBeUndefined();
    expect(saved.cursor).toBe(entry("01").orderHash);
  });

  it("a pre-2026-10 STATE_FILE with a per-order pending tx loads: it becomes THE pending tx", async () => {
    const store = new MemoryStateStore();
    const h = entry("07").orderHash;
    await store.put(STATE_KEY, {
      spends: [],
      routeSpends: [{ token: "route:fills", amount: "1", at: Date.now() }],
      guard: { gasSpends: [], backoff: { [h]: { strikes: 0, until: 0, expiry: "0", pending: { tx: "0x" + "cd".repeat(32), at: Date.now() }, reason: "receipt timeout" } } },
    });
    const { e } = await engine({}, store);
    expect(e.pending).toMatchObject({ hash: "0x" + "cd".repeat(32), orderHash: h, timedOut: true });
    expect(e.guard.entry(h)?.pending).toBeUndefined();
    expect(e.budgetsLeft().routeFills).toBe(59n);
  });
});

describe("rebalancer under the Guard", () => {
  const INV = { INVENTORY_ENABLED: "1", ROUTE_ENABLED: "0", AGGREGATOR_SOLVER: "" };

  it("redeem: approval first (its own tx), then redeemTP with the exec fee as value; the op id is tracked once mined", async () => {
    const { w, chain } = world();
    w.usdrif = 100n * 10n ** 18n;
    w.allowance = 0n;
    const { e } = await engine(INV, undefined, chain);
    const t1 = await e.tick({ fetchEntries: async () => [] });
    expect(t1.rebalance).toMatchObject({ action: "redeem", status: "sent", approval: true });
    expect(decodeFunctionData({ abi: erc20Abi, data: w.sent[0]!.data }).functionName).toBe("approve");
    expect(e.pending).toMatchObject({ kind: "approve", strategy: "rebalance" });
    w.receipt = "success";
    w.allowance = 10n ** 30n;
    const t2 = await e.tick({ fetchEntries: async () => [] });
    expect(t2.resolution?.status).toBe("success");
    expect(t2.rebalance).toMatchObject({ action: "redeem", status: "sent" });
    expect(w.sent[1]).toMatchObject({ to: ROOTSTOCK.mocCore.toLowerCase(), value: 1_000n });
    expect(e.pending).toMatchObject({ kind: "redeem", backoffKey: "rebalance:redeem" });
    w.usdrif = 0n;
    const t3 = await e.tick({ fetchEntries: async () => [] });
    expect(t3.resolution?.status).toBe("success");
    expect(e.rebalancer.pendingRedemption()?.opId).toBe(6n);
    expect(t3.rebalance?.status).toBe("held"); // waiting for the MoC queue
    w.firstOperId = 7n;
    const t4 = await e.tick({ fetchEntries: async () => [] });
    expect(e.rebalancer.pendingRedemption()).toBeUndefined();
    expect(t4.rebalance).toBeUndefined();
  });

  it("refuses above MAX_GAS_PRICE_GWEI and within the gas budget, like fills", async () => {
    const { w, chain } = world();
    w.usdrif = 100n * 10n ** 18n;
    w.gasPrice = 10n ** 18n;
    const { e } = await engine(INV, undefined, chain);
    const t = await e.tick({ fetchEntries: async () => [] });
    expect(t.rebalance).toMatchObject({ status: "skipped", reason: expect.stringMatching(/MAX_GAS_PRICE_GWEI/) });
    expect(w.sent).toHaveLength(0);
  });

  it("a reverted redemption backs the action off", async () => {
    const { w, chain } = world();
    w.usdrif = 100n * 10n ** 18n;
    const { e } = await engine(INV, undefined, chain);
    await e.tick({ fetchEntries: async () => [] });
    w.receipt = "reverted";
    const t = await e.tick({ fetchEntries: async () => [] });
    expect(t.resolution?.status).toBe("reverted");
    expect(t.rebalance).toMatchObject({ status: "skipped", reason: expect.stringMatching(/backoff after 1/) });
    expect(w.sent).toHaveLength(1);
  });
});

describe("broadcast", () => {
  it("refuses a second send while one is pending", async () => {
    const { w, chain } = world();
    const g = new Guard(loadConfig(ENV).gas);
    const req = { to: SOLVER, data: "0x" as Hex, gas: 100_000n, gasPrice: GAS_PRICE, kind: "fill" as const, strategy: "route" as const };
    expect((await broadcast(chain, g, req)).kind).toBe("sent");
    expect(await broadcast(chain, g, req)).toMatchObject({ kind: "refused", reason: expect.stringMatching(/still pending/) });
    expect(w.sent).toHaveLength(1);
  });

  it("signs an explicit legacy tx with the chain id", async () => {
    const { w, chain } = world();
    const g = new Guard(loadConfig(ENV).gas);
    await broadcast(chain, g, { to: SOLVER, data: "0x1234", gas: 100_000n, gasPrice: GAS_PRICE, kind: "fill", strategy: "route" });
    expect(w.sent[0]).toMatchObject({ gas: 100_000n, nonce: 0 });
    expect(g.pending).toMatchObject({ gasLimit: "100000", gasPrice: String(GAS_PRICE), nonce: 0 });
  });
});

describe("M1: a resting book is not re-quoted every tick", () => {
  /** A clock the test moves (the engine's holds, the gas-price cache). */
  const clock = () => {
    const c = { t: 1_800_000_000_000 };
    return { c, now: () => c.t };
  };
  async function engineAt(now: () => number, env: Record<string, string> = {}, chain?: unknown) {
    const cfg = loadConfig({ ...ENV, ...env });
    return Engine.create({ cfg, chain: (chain ?? world().chain) as never, store: new MemoryStateStore(), log: () => {}, now });
  }

  it("an order every strategy passed on is held until its book fillable changes or RESTING_RECHECK_SECONDS pass", async () => {
    const { w, chain } = world();
    w.owed = 5_000_000_000n; // the route quote (1000 USDT0) never covers it: unprofitable
    const { c, now } = clock();
    const e = await engineAt(now, {}, chain);
    const book = [entry("01"), entry("02"), entry("03")];
    const t1 = await e.tick({ fetchEntries: async () => book });
    expect(t1.outcomes.map((o) => [o.status, o.rest])).toEqual([["skipped", true], ["skipped", true], ["skipped", true]]);
    const quoted = w.previews;
    expect(quoted).toBe(3);

    // The next ticks: nothing is re-quoted (zero RPC per resting order).
    for (let i = 0; i < 5; i++) {
      c.t += 5_000;
      const t = await e.tick({ fetchEntries: async () => book });
      expect(t).toMatchObject({ evaluated: 0, held: 3 });
    }
    expect(w.previews).toBe(quoted);

    // The book reports a different fillable for one of them: only that one is re-quoted.
    c.t += 5_000;
    await e.tick({ fetchEntries: async () => [book[0]!, entry("02", {}, RECEIVED / 2n), book[2]!] });
    expect(w.previews).toBe(quoted + 1);

    // RESTING_RECHECK_SECONDS (300) later every one of them is re-quoted once.
    c.t += 300_000;
    const t = await e.tick({ fetchEntries: async () => [book[0]!, entry("02", {}, RECEIVED / 2n), book[2]!] });
    expect(t.evaluated).toBe(3);
    expect(w.previews).toBe(quoted + 4);
  });

  it("transient refusals are NOT held (gas price ceiling, budgets): the order is retried next tick", async () => {
    const { w, chain } = world();
    w.gasPrice = 10n ** 18n; // above MAX_GAS_PRICE_GWEI
    const { c, now } = clock();
    const e = await engineAt(now, {}, chain);
    const t1 = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t1.outcomes[0]).toMatchObject({ status: "skipped", rest: false, reason: expect.stringMatching(/MAX_GAS_PRICE_GWEI/) });
    w.gasPrice = GAS_PRICE;
    c.t += 15_000; // past the gas-price cache
    const t2 = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t2.sent).toBeDefined();
  });

  it("a price that moves with time (a decaying leg) is held at most 30 s", async () => {
    const { w, chain } = world();
    w.owed = 5_000_000_000n;
    const { c, now } = clock();
    const e = await engineAt(now, {}, chain);
    const decaying = entry("01", { legsOut: [{ token: ROOTSTOCK.usdt0, start: OWED, end: OWED / 2n, recipient: zeroAddress }] });
    await e.tick({ fetchEntries: async () => [decaying] });
    c.t += 20_000;
    expect((await e.tick({ fetchEntries: async () => [decaying] })).evaluated).toBe(0);
    c.t += 15_000;
    expect((await e.tick({ fetchEntries: async () => [decaying] })).evaluated).toBe(1);
  });

  it("B13: a held order is re-quoted when its exclusivity window ends, not a full hold later", async () => {
    const { w, chain } = world();
    w.owed = 5_000_000_000n; // unprofitable: every strategy passes, the order is held
    const { c, now } = clock();
    const e = await engineAt(now, {}, chain);
    const nowS = Math.floor(c.t / 1000);
    // The app's pull-market shape: our solver's soft window ends 10 s from now (a fixed
    // price, so without the cap the hold would be RESTING_RECHECK_SECONDS = 300 s).
    const windowed = entry("01", { exclusiveFiller: SOLVER, timing: packTiming(0, 0, nowS + 10), exclusivityOverrideBps: 5n });
    await e.tick({ fetchEntries: async () => [windowed] });
    const quoted = w.previews;
    expect(quoted).toBeGreaterThan(0);
    c.t += 5_000;
    expect((await e.tick({ fetchEntries: async () => [windowed] })).evaluated).toBe(0);
    c.t += 5_000; // the window ends
    expect((await e.tick({ fetchEntries: async () => [windowed] })).evaluated).toBe(1);
    // After it, the ordinary resting hold applies again.
    c.t += 5_000;
    expect((await e.tick({ fetchEntries: async () => [windowed] })).evaluated).toBe(0);
  });

  it("never-seen orders go first: a new order is picked up on the next tick however many rest in the book", async () => {
    const { w, chain } = world();
    const { c, now } = clock();
    const e = await engineAt(now, { DRY_RUN: "1" }, chain);
    // 30 resting orders (dry-run marks each for 60 s), 3 per tick.
    const resting = Array.from({ length: 30 }, (_, i) => entry((i + 0x10).toString(16)));
    for (let k = 0; k < 10; k++) {
      await e.tick({ fetchEntries: async () => resting, limits: { maxOrders: 3 } });
      c.t += 5_000;
    }
    // A new order whose hash sorts LAST (round-robin alone would reach it last).
    const fresh = entry("ff", {}, RECEIVED);
    const t = await e.tick({ fetchEntries: async () => [...resting, fresh], limits: { maxOrders: 3 } });
    expect(t.outcomes[0]).toMatchObject({ orderHash: fresh.orderHash, status: "dry-run" });
    void w;
  });

  it("never-seen orders are taken oldest first (the book's addedAt)", async () => {
    const { now } = clock();
    const e = await engineAt(now, { DRY_RUN: "1" });
    const book = [
      { ...entry("01"), addedAt: 300 },
      { ...entry("02"), addedAt: 100 },
      { ...entry("03"), addedAt: 200 },
    ];
    const t = await e.tick({ fetchEntries: async () => book, limits: { maxOrders: 3 } });
    expect(t.outcomes.map((o) => o.orderHash.slice(2, 4))).toEqual(["02", "03", "01"]);
  });

  it("orders expiring within EXPIRY_MARGIN_SECONDS are skipped without any RPC", async () => {
    const { w, chain } = world();
    const { c, now } = clock();
    const e = await engineAt(now, {}, chain);
    const soon = entry("01", { expiry: BigInt(Math.floor(c.t / 1000) + 60) }); // < 90 s
    const t = await e.tick({ fetchEntries: async () => [soon] });
    expect(t).toMatchObject({ evaluated: 0, held: 1, outcomes: [] });
    expect(w.calls).toEqual({});
    const later = entry("02", { expiry: BigInt(Math.floor(c.t / 1000) + 120) });
    expect((await e.tick({ fetchEntries: async () => [later] })).sent).toBeDefined();
  });

  it("eth_gasPrice is read once per ~10 s, not per order per strategy", async () => {
    const { w, chain } = world();
    w.owed = 5_000_000_000n;
    const { c, now } = clock();
    const e = await engineAt(now, { RESTING_RECHECK_SECONDS: "0" }, chain); // no holds: every order re-quoted
    const book = ["01", "02", "03", "04"].map((h) => entry(h));
    await e.tick({ fetchEntries: async () => book });
    expect(w.previews).toBe(4);
    expect(w.gasPriceCalls).toBe(1);
    c.t += 5_000;
    await e.tick({ fetchEntries: async () => book });
    expect(w.gasPriceCalls).toBe(1);
    c.t += 6_000;
    await e.tick({ fetchEntries: async () => book });
    expect(w.gasPriceCalls).toBe(2);
  });
});

describe("M1(e): the inventory strategy's zero-RPC price pre-filter", () => {
  const INV = { INVENTORY_ENABLED: "1", ROUTE_ENABLED: "0", AGGREGATOR_SOLVER: "", MAX_BUY_PRICE: "0.995" };
  const usdrifOrder = (usdt0: bigint, over: Partial<Order> = {}): Partial<Order> => ({
    legsIn: [{ token: ROOTSTOCK.usdrif, start: 100n * 10n ** 18n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: usdt0, end: 0n, recipient: zeroAddress }],
    ...over,
  });

  it("a fixed-price order above MAX_BUY_PRICE is refused by accepts() and consider() without RPC", async () => {
    const { w, chain } = world();
    const cfg = loadConfig({ ...ENV, ...INV });
    const e = await Engine.create({ cfg, chain: chain as never, store: new MemoryStateStore(), log: () => {} });
    const over = entry("01", usdrifOrder(100_000_000n), 100n * 10n ** 18n); // $1.00 per USDRIF > 0.995
    expect(e.filler!.accepts(over as never)).toBe(false);
    const t = await e.tick({ fetchEntries: async () => [over], rebalance: false });
    expect(t.outcomes[0]).toMatchObject({ status: "skipped", rest: true, reason: expect.stringMatching(/fixed-price order: price 1\.0+ above max 0\.995/) });
    expect(w.calls).toEqual({});
    // At or below the bound it is accepted (and priced on a live preview).
    expect(e.filler!.accepts(entry("02", usdrifOrder(99_000_000n), 100n * 10n ** 18n) as never)).toBe(true);
    // A decaying order is never pre-filtered: its price moves toward us.
    const decaying = entry("03", usdrifOrder(100_000_000n, { legsOut: [{ token: ROOTSTOCK.usdt0, start: 100_000_000n, end: 90_000_000n, recipient: zeroAddress }] }), 100n * 10n ** 18n);
    expect(e.filler!.accepts(decaying as never)).toBe(true);
  });
});

describe("M5: an order we just filled is not re-quoted while the book still serves it", () => {
  it("held until the book's fillable changes or RESTING_RECHECK_SECONDS pass; the hold survives a restart", async () => {
    const { w, chain } = world();
    const c = { t: 1_800_000_000_000 };
    const store = new MemoryStateStore();
    const mk = async () => Engine.create({ cfg: loadConfig(ENV), chain: chain as never, store, log: () => {}, now: () => c.t });
    const e = await mk();
    const book = [entry("01")];
    const t1 = await e.tick({ fetchEntries: async () => book });
    expect(t1.sent).toMatchObject({ orderHash: book[0]!.orderHash, bookFillable: RECEIVED.toString() });
    w.receipt = "success";
    c.t += 3_000;
    const t2 = await e.tick({ fetchEntries: async () => book }); // resolves the fill; the book still serves the order
    expect(t2.resolution?.status).toBe("success");
    expect(t2).toMatchObject({ evaluated: 0, held: 1 });
    const previews = w.previews;
    for (let i = 0; i < 3; i++) {
      c.t += 20_000;
      expect(await e.tick({ fetchEntries: async () => book })).toMatchObject({ evaluated: 0, held: 1 });
    }
    // A restart keeps the hold.
    const e2 = await mk();
    expect(await e2.tick({ fetchEntries: async () => book })).toMatchObject({ evaluated: 0, held: 1 });
    expect(w.previews).toBe(previews);
    // The book's fillable for it changes (a partial fill indexed): re-evaluated.
    const t3 = await e2.tick({ fetchEntries: async () => [entry("01", {}, RECEIVED / 4n)] });
    expect(t3.evaluated).toBe(1);
  });

  it("a reverted fill is not held (the per-order backoff governs the retry)", async () => {
    const { w, chain } = world();
    const { e } = await engine({}, undefined, chain);
    await e.tick({ fetchEntries: async () => [entry("01")] });
    w.receipt = "reverted";
    const t = await e.tick({ fetchEntries: async () => [entry("01")] });
    expect(t.resolution?.status).toBe("reverted");
    expect(t.held ?? 0).toBe(0);
    expect(t.outcomes[0]!.reason).toMatch(/backoff after 1 on-chain revert/);
  });
});

describe("M2: the rebalancer does not churn approvals", () => {
  const INV = { INVENTORY_ENABLED: "1", ROUTE_ENABLED: "0", AGGREGATOR_SOLVER: "" }; // REDEEM_MIN_USDRIF = 50 (ENV)
  const USDRIF = (n: number) => BigInt(n) * 10n ** 18n;

  it("a balance that grows between steps (new fills) no longer resets the allowance: the redeem goes out", async () => {
    // The old sequence: approve EXACTLY the balance (100) → a fill lands (160) → the
    // allowance no longer covers it → reset to 0 → approve 160 → a fill lands → …
    // forever, and no redemption is ever sent.
    const { w, chain } = world();
    w.usdrif = USDRIF(100);
    w.allowance = 0n;
    const { e } = await engine(INV, undefined, chain);
    const t1 = await e.tick({ fetchEntries: async () => [] });
    expect(t1.rebalance).toMatchObject({ action: "redeem", status: "sent", approval: true });
    w.receipt = "success";
    w.usdrif += USDRIF(60); // a fill landed meanwhile
    const t2 = await e.tick({ fetchEntries: async () => [] }); // the approval mines; the redemption follows at once
    expect(t2.resolution?.status).toBe("success");
    // (The old code sent "approval reset (0)" here, then re-approved 160, then reset again …)
    expect(t2.rebalance).toMatchObject({ action: "redeem", status: "sent" });
    expect(t2.rebalance?.approval).toBeUndefined();
    const redeem = decodeFunctionData({ abi: MOC_CORE_ABI, data: w.sent[1]!.data });
    expect(redeem.functionName).toBe("redeemTP");
    expect(redeem.args[1]).toBe(USDRIF(160)); // min(balance 160, allowance 200)
    // One approval, to a bounded headroom — max(balance, 4 × REDEEM_MIN_USDRIF), never
    // unlimited — and no reset to 0.
    expect(w.approvals).toEqual([USDRIF(200)]);
  });

  it("redeems only what the allowance covers, and re-approves only once it is below one batch", async () => {
    const { w, chain } = world();
    w.usdrif = USDRIF(300);
    w.allowance = USDRIF(120); // covers a batch (50), not the whole balance
    const { e } = await engine(INV, undefined, chain);
    const t1 = await e.tick({ fetchEntries: async () => [] });
    expect(t1.rebalance).toMatchObject({ action: "redeem", status: "sent" });
    expect(decodeFunctionData({ abi: MOC_CORE_ABI, data: w.sent[0]!.data }).args[1]).toBe(USDRIF(120));
    // Mined (and executed by the MoC queue): 180 USDRIF left, allowance 0 < one batch
    // → re-approve, to max(180, 4 × 50) = 200.
    w.receipt = "success";
    w.firstOperId = 100n;
    const t2 = await e.tick({ fetchEntries: async () => [] });
    expect(t2.resolution?.status).toBe("success");
    expect(t2.rebalance).toMatchObject({ action: "redeem", status: "sent", approval: true });
    expect(decodeFunctionData({ abi: erc20Abi, data: w.sent[1]!.data }).args).toEqual([ROOTSTOCK.mocCore, USDRIF(200)]);
    // The approval mines: the rest is redeemed.
    const t3 = await e.tick({ fetchEntries: async () => [] });
    expect(t3.rebalance).toMatchObject({ action: "redeem", status: "sent" });
    expect(decodeFunctionData({ abi: MOC_CORE_ABI, data: w.sent[2]!.data }).args[1]).toBe(USDRIF(180));
    expect(w.approvals).toEqual([USDRIF(200)]);
  });
});

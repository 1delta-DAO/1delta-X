/**
 * SPOT reserves (INVENTORY-POLICY §9, ./src/spot.ts): small tickets filled from the wallet,
 * valued at the pool with half its fee handed to the maker, quoted at a direct swap's gas; reserves kept in a band against USD₮0.
 */
import { OrderSide, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeAbiParameters, getAddress, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { SWAP_ROUTER02_ABI } from "../src/chain";
import { loadConfig, parseSpotReserves, ROOTSTOCK } from "../src/config";
import { GasRatios } from "../src/gasRatio";
import { Guard } from "../src/guard";
import { Budget } from "../src/policy";
import { Rebalancer } from "../src/rebalance";
import { pathFeePpm } from "../src/routeFiller";
import { feeShared, SPOT_BUDGET_KEY, SpotFiller, type SpotHost } from "../src/spot";

const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const MAKER = getAddress("0x00000000000000000000000000000000000000bb");
const USD0 = getAddress(ROOTSTOCK.usdt0);
const WRBTC = getAddress(ROOTSTOCK.wrbtc);
const USDRIF = getAddress(ROOTSTOCK.usdrif);
const RIF = getAddress(ROOTSTOCK.rif);
const GAS_PRICE = 26_065_600n;
const E18 = 10n ** 18n;
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
  DRY_RUN: "0",
  SPOT_RESERVES: `${WRBTC}:60:3000,${USDRIF}:50:500`,
};
const cfg = loadConfig(ENV);

/** Pool prices, USD per whole token; every DEX swap loses 0.3 %. WRBTC $100k. */
const PX: Record<string, { usd: number; dec: number }> = { [USD0.toLowerCase()]: { usd: 1, dec: 6 }, [WRBTC.toLowerCase()]: { usd: 100_000, dec: 18 }, [USDRIF.toLowerCase()]: { usd: 1, dec: 18 } };
function dex(tin: Address, tout: Address, amt: bigint): bigint {
  const a = PX[tin.toLowerCase()]!;
  const b = PX[tout.toLowerCase()]!;
  // amt (tin units) → USD (1e18 fixed) → tout units, × 0.997
  const usd18 = (amt * BigInt(Math.round(a.usd * 1e6)) * 10n ** 12n) / 10n ** BigInt(a.dec);
  return (((usd18 * 10n ** BigInt(b.dec)) / (BigInt(Math.round(b.usd * 1e6)) * 10n ** 12n)) * 997n) / 1000n;
}
const deps = {
  dexQuote: async (a: Address, b: Address, n: bigint) => (a.toLowerCase() === b.toLowerCase() ? n : dex(a, b, n)),
  dexQuoteFee: async (a: Address, b: Address, n: bigint) => (a.toLowerCase() === b.toLowerCase() ? { amount: n, feePpm: 0 } : { amount: dex(a, b, n), feePpm: 3000 }),
  // RBTC wei → token units at $100k / RBTC.
  nativeToToken: async (wei: bigint, t: Address) => {
    const p = PX[t.toLowerCase()]!;
    return (wei * 100_000n * 10n ** BigInt(p.dec)) / BigInt(Math.round(p.usd * 1e6)) / 10n ** 18n * 1_000_000n / 1_000_000n;
  },
};

function order(tin: Address, inAmt: bigint, tout: Address, outAmt: bigint, over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: tin, start: inAmt, end: 0n }],
    legsOut: [{ token: tout, start: outAmt, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}
const entry = (o: Order) => ({
  orderHash: ("0x" + "5a".repeat(32)) as Hex,
  announce: { order: o, sig: "0x" as Hex },
  state: { ok: true, status: "Fillable", fillableAmount: o.legsIn[0]!.start, validatorsPass: true },
});

/** A fake chain: the lens previews `received`/`paid`, balances per token, every allowance set. */
function fakeChain(bal: Record<string, bigint>, preview: { received: bigint; paid: bigint }) {
  const sent: Array<{ to: Address; data: Hex }> = [];
  const result = encodeAbiParameters([{ type: "int256" }, { type: "uint256[]" }, { type: "uint256[]" }], [0n, [preview.received], [preview.paid]]);
  const pub: Record<string, unknown> = {
    getGasPrice: async () => GAS_PRICE,
    getTransactionCount: async () => sent.length,
    estimateGas: async () => 92_000n,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      sent.push({ to: t.to!, data: t.data! });
      return keccak256(serializedTransaction);
    },
    readContract: async ({ functionName, address }: { functionName: string; address: string }) => {
      switch (functionName) {
        case "previewFill": return [0n, [preview.received], [preview.paid]];
        case "previewBump": return 0n;
        case "balanceOf": return bal[address.toLowerCase()] ?? 0n;
        case "allowance": return 10n ** 40n;
        case "getPACtp": return 8n * 10n ** 16n; // $0.08 per RIF
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ args }: { args: [{ tokenIn: Address; tokenOut: Address; amountIn: bigint }] }) => ({ result: [dex(args[0].tokenIn, args[0].tokenOut, args[0].amountIn), 0n, 0, 0n] }),
    call: async () => ({ data: result }),
  };
  return { sent, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const host = (): SpotHost & { skips: string[] } => {
  const skips: string[] = [];
  return {
    skips,
    skip: (orderHash, reason, rest) => (skips.push(reason), { orderHash, status: "skipped", reason, strategy: "inventory", ...(rest ? { rest: true } : {}) }),
    sendApproval: async () => {
      throw new Error("no approval expected");
    },
    onSpend: () => {},
    log: () => {},
  };
};

function spot(chain: never) {
  const budget = new Budget({ [SPOT_BUDGET_KEY]: cfg.policy.spot.hourlyUsd6 });
  const guard = new Guard(cfg.gas);
  guard.register("inventory", budget);
  return { s: new SpotFiller(cfg, chain, budget, guard, new GasRatios(cfg.gas.defaultReceiptRatioPpm), deps), budget, guard };
}

describe("spot config and pairs", () => {
  it("SPOT_RESERVES parses token:targetUsd:fee; empty = off", () => {
    expect(parseSpotReserves("")).toEqual([]);
    expect(cfg.policy.spot.reserves).toEqual([
      { token: WRBTC, targetUsd6: 60_000_000n, fee: 3000 },
      { token: USDRIF, targetUsd6: 50_000_000n, fee: 500 },
    ]);
    expect(() => parseSpotReserves("0xnope:60:3000")).toThrow(/address/);
    // An optional 4th field: the reserve's own band (a stablecoin's wider).
    expect(parseSpotReserves(`${USDRIF}:100:500:10000`)).toEqual([{ token: USDRIF, targetUsd6: 100_000_000n, fee: 500, bandBps: 10_000n }]);
    expect(() => parseSpotReserves(`${USDRIF}:100:500:20000`)).toThrow(/band/);
    expect(cfg.policy.spot).toMatchObject({ bandBps: 5000n, maxTicketUsd6: 100_000_000n, chargeGas: 150_000n, feeShareBps: 5000n });
  });

  it("any two of {USD₮0, reserves}, except a pair an enabled direction owns (USDRIF → USD₮0 is the buy side's)", () => {
    const { s } = spot(fakeChain({}, { received: 1n, paid: 1n }).chain);
    expect(s.isSpotPair(USD0, WRBTC)).toBe(true);
    expect(s.isSpotPair(WRBTC, USD0)).toBe(true);
    expect(s.isSpotPair(WRBTC, USDRIF)).toBe(true);
    expect(s.isSpotPair(USD0, USDRIF)).toBe(true); // SELL_USDRIF is off
    expect(s.isSpotPair(USDRIF, USD0)).toBe(false); // BUY_USDRIF owns it
    expect(s.isSpotPair(USD0, RIF)).toBe(false); // not a reserve
    // With the old buy side off (live since 2026-10-20), USDRIF → USD₮0 is spot's too.
    const off = new SpotFiller(loadConfig({ ...ENV, BUY_USDRIF: "0" }), fakeChain({}, { received: 1n, paid: 1n }).chain, new Budget({}), new Guard(cfg.gas), new GasRatios(cfg.gas.defaultReceiptRatioPpm), deps);
    expect(off.isSpotPair(USDRIF, USD0)).toBe(true);
  });
});

describe("spot quote: the pool's pre-fee rate less the kept fee share, a direct swap's gas, capped by the reserve", () => {
  it("feeShared: out × (1e6 − fee × (1 − share)) / (1e6 − fee); pathFeePpm compounds the hops", () => {
    expect(feeShared(997_000n, 3000, 0n)).toBe(997_000n); // the DEX price
    expect(feeShared(997_000n, 3000, 10_000n)).toBe(1_000_000n); // the pre-fee rate
    expect(feeShared(997_000n, 3000, 5000n)).toBe(998_500n); // half the fee back: +0.15 %
    expect(feeShared(999_500n, 500, 5000n)).toBe(999_750n); // a 0.05 % pool: +0.025 %
    expect(pathFeePpm([3000])).toBe(3000);
    expect(pathFeePpm([500, 3000])).toBe(3498); // 1 − 0.9995 × 0.997 = 0.34985 %, rounded down
    expect(pathFeePpm([])).toBe(0);
  });

  it("20 USD₮0 → WRBTC: gross = the pool quote with half its fee back (beats the DEX), cost = 150k × r of gas + min profit", async () => {
    const { s } = spot(fakeChain({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n }, { received: 1n, paid: 1n }).chain);
    const v = await s.quote(USD0, WRBTC, 20_000_000n, GAS_PRICE);
    if (!v.ok) throw new Error(v.reason);
    const pool = dex(USD0, WRBTC, 20_000_000n);
    expect(v.candidate).toMatchObject({ strategy: "inventory", source: "inventory-spot", grossOut: feeShared(pool, 3000, 5000n), gasUnits: 132_000n });
    expect(v.candidate.grossOut).toBeGreaterThan(pool);
    expect(v.candidate.capOut).toBe(6n * 10n ** 14n);
    // SPOT_FEE_SHARE_BPS=0: the DEX price, as before.
    const c0 = loadConfig({ ...ENV, SPOT_FEE_SHARE_BPS: "0" });
    const v0 = await new SpotFiller(c0, fakeChain({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n }, { received: 1n, paid: 1n }).chain, new Budget({ [SPOT_BUDGET_KEY]: c0.policy.spot.hourlyUsd6 }), new Guard(c0.gas), new GasRatios(c0.gas.defaultReceiptRatioPpm), deps).quote(USD0, WRBTC, 20_000_000n, GAS_PRICE);
    expect(v0.ok && v0.candidate.grossOut).toBe(pool);
  });

  it("refused above SPOT_MAX_TICKET_USD and when the reserve cannot pay", async () => {
    const { s } = spot(fakeChain({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n }, { received: 1n, paid: 1n }).chain);
    expect(await s.quote(USD0, WRBTC, 150_000_000n, GAS_PRICE)).toMatchObject({ ok: false, reason: expect.stringMatching(/SPOT_MAX_TICKET_USD/) });
    const thin = spot(fakeChain({ [WRBTC.toLowerCase()]: 10n ** 13n }, { received: 1n, paid: 1n }).chain).s; // $1 of WRBTC
    expect(await thin.quote(USD0, WRBTC, 20_000_000n, GAS_PRICE)).toMatchObject({ ok: false, reason: expect.stringMatching(/reserve too small/) });
  });
});

describe("spot fill: valued at the pool with the maker's fee share, gated at the real estimate", () => {
  // A maker pays 20 USD₮0 for WRBTC. The pool gives 0.00019940 WRBTC for it.
  const value = dex(USD0, WRBTC, 20_000_000n);

  it("fills when value − paid covers the fill's gas + its rebalance share + min profit; the USD outflow is reserved", async () => {
    const paid = 193n * 10n ** 12n; // 0.000193 WRBTC: ~$0.64 under the pool
    const { sent, chain } = fakeChain({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n }, { received: 20_000_000n, paid });
    const { s, budget } = spot(chain);
    const h = host();
    const out = await s.fill(h, entry(order(USD0, 20_000_000n, WRBTC, paid)) as never, USD0, WRBTC);
    expect(out, h.skips.join("; ")).toMatchObject({ status: "pending", strategy: "inventory", paid, received: 20_000_000n });
    expect(sent).toHaveLength(1);
    expect(budget.remaining(SPOT_BUDGET_KEY, Date.now())).toBe(cfg.policy.spot.hourlyUsd6 - 20_000_000n);
    expect(value - paid).toBeGreaterThan(0n);
  });

  it("never grows a RECEIVED reserve past its band top (no automatic rebalancing sells it down)", async () => {
    // A maker sells 0.0003 WRBTC ($30) for USD₮0; the wallet already holds $70 of WRBTC: $100 > the $90 top.
    const received = 3n * 10n ** 14n;
    const paid = 29_000_000n;
    const { sent, chain } = fakeChain({ [WRBTC.toLowerCase()]: 7n * 10n ** 14n, [USD0.toLowerCase()]: 400_000_000n }, { received, paid });
    const h = host();
    await spot(chain).s.fill(h, entry(order(WRBTC, received, USD0, paid)) as never, WRBTC, USD0);
    expect(h.skips[0]).toMatch(/over its band top/);
    expect(sent).toHaveLength(0);
    expect(await spot(chain).s.quote(WRBTC, USD0, received, GAS_PRICE)).toMatchObject({ ok: false, reason: expect.stringMatching(/band top/) });
  });

  it("refuses a price that does not cover the costs (rests), and a reserve that cannot pay", async () => {
    const tight = feeShared(value, 3000, 5000n) - 10n ** 11n; // $0.01 under the maker's price (the pool + half its fee)
    const a = fakeChain({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n }, { received: 20_000_000n, paid: tight });
    const h = host();
    expect(await spot(a.chain).s.fill(h, entry(order(USD0, 20_000_000n, WRBTC, tight)) as never, USD0, WRBTC)).toMatchObject({ status: "skipped", rest: true });
    expect(h.skips[0]).toMatch(/unprofitable/);
    expect(a.sent).toHaveLength(0);
    const b = fakeChain({ [WRBTC.toLowerCase()]: 10n ** 13n }, { received: 20_000_000n, paid: 193n * 10n ** 12n });
    const h2 = host();
    await spot(b.chain).s.fill(h2, entry(order(USD0, 20_000_000n, WRBTC, 193n * 10n ** 12n)) as never, USD0, WRBTC);
    expect(h2.skips[0]).toMatch(/reserve/);
  });
});

describe("at a threshold, spot passes and the ROUTE takes the order (never blocked)", () => {
  it("a spot skip is not final: the dispatcher hands the order to the next strategy", async () => {
    const { dispatch } = await import("../src/dispatch");
    const e = entry(order(USD0, 20_000_000n, WRBTC, 193n * 10n ** 12n));
    const spotPass = { name: "inventory" as const, consider: async () => ({ orderHash: e.orderHash, status: "skipped" as const, reason: "spot: reserve short", strategy: "inventory" as const }) };
    const route = { name: "route" as const, consider: async () => ({ orderHash: e.orderHash, status: "pending" as const, strategy: "route" as const, tx: "0x01" as Hex }) };
    expect(await dispatch(e as never, [spotPass, route])).toMatchObject({ status: "pending", strategy: "route" });
  });
});

describe("spot rebalancing — an operator action only (spotStep): each reserve back within ±50 % of its target", () => {
  const rebal = (bal: Record<string, bigint>, env: Record<string, string> = {}) => {
    const c = loadConfig({ ...ENV, ...env });
    const f = fakeChain(bal, { received: 1n, paid: 1n });
    return { ...f, r: new Rebalancer(c, f.chain, () => {}, new Guard(c.gas), {}, () => {}, deps.dexQuote) };
  };
  const swapOf = (data: Hex) => decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data }).args[0];

  it("the regular rebalancer step NEVER swaps a spot reserve (operator's rule: no swaps on their own)", async () => {
    const low = { [WRBTC.toLowerCase()]: 2n * 10n ** 14n, [USD0.toLowerCase()]: 400_000_000n, [USDRIF.toLowerCase()]: 50n * E18 };
    const { sent, r } = rebal(low);
    expect(await r.step()).toBeUndefined();
    expect(sent).toHaveLength(0);
  });

  it("WRBTC at $20 (< $30): buy back to $60 with USD₮0 on the 0.3 % pool", async () => {
    const { sent, r } = rebal({ [WRBTC.toLowerCase()]: 2n * 10n ** 14n, [USD0.toLowerCase()]: 400_000_000n, [USDRIF.toLowerCase()]: 50n * E18 });
    expect(await r.spotStep()).toMatchObject({ action: "spot", status: "sent" });
    const p = swapOf(sent[0]!.data);
    expect([p.tokenIn, p.tokenOut, p.fee]).toEqual([USD0, WRBTC, 3000]);
    expect(p.amountIn).toBe(60_000_000n - dex(WRBTC, USD0, 2n * 10n ** 14n));
  });

  it("admin — WRBTC at $100 (> $90): sell the excess down to $60", async () => {
    const { sent, r } = rebal({ [WRBTC.toLowerCase()]: 10n ** 15n, [USD0.toLowerCase()]: 400_000_000n, [USDRIF.toLowerCase()]: 50n * E18 });
    await r.spotStep();
    const p = swapOf(sent[0]!.data);
    expect([p.tokenIn, p.tokenOut]).toEqual([WRBTC, USD0]);
    const v = dex(WRBTC, USD0, 10n ** 15n);
    expect(p.amountIn).toBe((10n ** 15n * (v - 60_000_000n)) / v);
  });

  it("inside the band nothing moves; USD₮0 under its reserve is never spent", async () => {
    const ok = rebal({ [WRBTC.toLowerCase()]: 6n * 10n ** 14n, [USD0.toLowerCase()]: 400_000_000n, [USDRIF.toLowerCase()]: 50n * E18 });
    expect(await ok.r.spotStep()).toBeUndefined();
    const poor = rebal({ [WRBTC.toLowerCase()]: 0n, [USD0.toLowerCase()]: 102_000_000n, [USDRIF.toLowerCase()]: 50n * E18 }, { USDT0_RESERVE: "100" });
    expect(await poor.r.spotStep()).toBeUndefined(); // only 2 USD₮0 free: under MIN_FILL_USDT0
    expect(poor.sent).toHaveLength(0);
  });

  it("the RIF rail leaves the spot USDRIF reserve alone (up to its band's top, $75)", async () => {
    // $300 USD₮0 + 150 USDRIF + 1406.25 RIF ($112.50) = $562.50: RIF at 20 %, the target.
    const bal = { [USD0.toLowerCase()]: 300_000_000n, [USDRIF.toLowerCase()]: 150n * E18, [RIF.toLowerCase()]: 140_625n * 10n ** 16n, [WRBTC.toLowerCase()]: 6n * 10n ** 14n };
    const rail = { SELL_RIF: "1", BUY_RIF: "1" };
    // With the spot reserve: 150 − 75 = 75 free < the 100 batch → the rail holds.
    expect(await rebal(bal, rail).r.railStep()).toBeUndefined();
    // Without it: all 150 free ≥ 100, RIF at target → swapped out to USD₮0.
    expect(await rebal(bal, { ...rail, SPOT_RESERVES: "" }).r.railStep()).toMatchObject({ action: "drain", status: "sent" });
  });
});


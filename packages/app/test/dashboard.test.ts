import { describe, expect, it } from "vitest";
import { hashOrderStruct, orderToJson, type Order } from "@1delta-x/sdk";
import { encodeAbiParameters, zeroAddress } from "viem";

import { pinnedToken } from "../src/config/markets";
import { dashStats, fillerName, nettedUsd, toDashFill, turnoverShares, type FillWire } from "../src/lib/dashboard";
import { hopsOf, hopUsd, SWAP_V3_TOPIC } from "../src/lib/turnover";
import { buildOrder } from "../src/lib/order";

/** The dashboard (2026-10-20): every indexed fill, sized on its anchor leg, priced in USD. */

const MAKER = "0x00000000000000000000000000000000000000aa" as const;
const INVENTORY = "0xcafe35944e3195d59b4a354ea23d60a0445c083a";
const T0 = 1_792_000_000;
const usd = (s: string) => ({ "USD₮0": 1, USDRIF: 1, WRBTC: 80_000 })[s];

function order(side: "sell" | "buy", nonce: bigint, amountIn = 100): Order {
  const usdrif = pinnedToken(30, "USDRIF")!;
  const usd0 = pinnedToken(30, "USD₮0")!;
  return buildOrder({
    maker: MAKER,
    side,
    pay: side === "sell" ? usdrif : usd0,
    recv: side === "sell" ? usd0 : usdrif,
    amountIn,
    targetOut: side === "sell" ? 99.5 : 100,
    minOut: side === "sell" ? 99.5 : 100,
    ttlSeconds: 3600,
    decaySeconds: 0,
    solver: zeroAddress,
    nonce,
    now: T0,
  }).order;
}

const wire = (o: Order, amount: bigint | null, at: number, extra: Partial<FillWire> = {}): FillWire => ({
  orderHash: hashOrderStruct(o),
  order: orderToJson(o),
  maker: MAKER,
  solver: INVENTORY,
  txHash: `0x${String(at).padStart(64, "0")}`,
  logIndex: 0,
  at,
  amount: amount === null ? null : amount.toString(),
  ...extra,
});

describe("dashboard fills", () => {
  it("sizes a fill on its anchor leg (a SELL's input) and prices it in USD", () => {
    const f = toDashFill(30, wire(order("sell", 1n), 40n * 10n ** 18n, T0), usd);
    expect(f).toMatchObject({ pay: "USDRIF", recv: "USD₮0", anchor: { symbol: "USDRIF", amount: 40 }, usd: 40, solver: INVENTORY });
  });

  it("a BUY's anchor is the output it received", () => {
    const o = order("buy", 2n);
    const f = toDashFill(30, wire(o, o.legsOut[0]!.start, T0), usd);
    expect(f.anchor?.symbol).toBe("USDRIF");
    expect(f.usd).toBeCloseTo(f.anchor!.amount, 9);
  });

  it("counts a fill it cannot size: no served order, a forged hash, no amount", () => {
    const o = order("sell", 3n);
    const { order: _, ...bare } = wire(o, 10n ** 18n, T0);
    expect(toDashFill(30, bare, usd)).toMatchObject({ pay: "?", recv: "?" });
    expect(toDashFill(30, { ...wire(o, 10n ** 18n, T0), orderHash: `0x${"11".repeat(32)}` }, usd).usd).toBeUndefined();
    expect(toDashFill(30, wire(o, null, T0), usd)).toMatchObject({ pay: "USDRIF" });
    expect(toDashFill(30, wire(o, null, T0), usd).usd).toBeUndefined();
  });

  it("aggregates totals, the last 24 h, daily buckets, pairs and fillers", () => {
    const now = (T0 + 3 * 86_400) * 1000;
    const fills = [
      toDashFill(30, wire(order("sell", 4n), 50n * 10n ** 18n, T0 + 3 * 86_400 - 60), usd), // today-ish, $50
      toDashFill(30, wire(order("sell", 5n), 20n * 10n ** 18n, T0, { solver: "0x5987a4afe1b680dac657506b69c56b06ffe86cd1" }), usd), // 3 days ago, $20
      toDashFill(30, { orderHash: `0x${"22".repeat(32)}`, txHash: "0x01", at: T0 }, usd), // unsized
    ];
    const s = dashStats(30, fills, now, 7);
    expect([s.fills, s.sized, s.volume, s.turnover, s.volume24h, s.fills24h, s.makers]).toEqual([3, 2, 70, 70, 50, 1, 1]);
    expect(s.daily).toHaveLength(7);
    expect(s.daily.reduce((a, d) => a + d.volume, 0)).toBe(70);
    expect(s.pairs[0]).toEqual({ key: "USDRIF → USD₮0", fills: 2, volume: 70, turnover: 70 });
    expect(s.fillers.map((f) => f.key)).toEqual(["1delta inventory", "1delta solver v3", "unknown"]);
    expect(fillerName(30, "0x00000000000000000000000000000000000000bb")).toBe("0x0000…00bb");
  });

  it("VOLUME nets opposite fills in one transaction (turnover counts both); same-direction fills add up", () => {
    const tx = { txHash: `0x${"ab".repeat(32)}` };
    const sell = toDashFill(30, wire(order("sell", 6n), 60n * 10n ** 18n, T0, { ...tx, logIndex: 1 }), usd); // USDRIF → USD₮0, $60
    const buy = toDashFill(30, wire(order("buy", 7n), 40n * 10n ** 18n, T0, { ...tx, logIndex: 2 }), usd); // USD₮0 → USDRIF, $40
    const net = nettedUsd([sell, buy]);
    expect([net.get(sell.id), net.get(buy.id)]).toEqual([60, 0]); // $40 of it offset: $60 changed hands
    const s = dashStats(30, [sell, buy], (T0 + 60) * 1000, 7);
    expect([s.volume, s.turnover]).toEqual([60, 100]);
    // Two sells in one transaction (a batch of independent orders): both are volume.
    const sell2 = toDashFill(30, wire(order("sell", 8n), 10n * 10n ** 18n, T0, { ...tx, logIndex: 3 }), usd);
    expect(dashStats(30, [sell, sell2], (T0 + 60) * 1000, 7).volume).toBe(70);
    // The same orders in separate transactions: nothing nets.
    const apart = toDashFill(30, wire(order("buy", 9n), 40n * 10n ** 18n, T0 + 1), usd);
    expect(dashStats(30, [sell, apart], (T0 + 60) * 1000, 7).volume).toBe(100);
  });
});


describe("turnover: every pool hop a fill ran", () => {
  const POOL = "0x00000000000000000000000000000000000000p1".replace("p", "a");
  const swapLog = (a0: bigint, a1: bigint) => ({
    address: POOL,
    topics: [SWAP_V3_TOPIC, `0x${"00".repeat(32)}`, `0x${"00".repeat(32)}`],
    data: encodeAbiParameters(
      [{ type: "int256" }, { type: "int256" }, { type: "uint160" }, { type: "uint128" }, { type: "int24" }],
      [a0, a1, 1n, 1n, 0],
    ),
  });

  it("reads v3 Swap logs and values each hop at what the pool received (else what it paid out)", () => {
    const hops = hopsOf([swapLog(10n ** 18n * 50n, -49_900_000n), { address: POOL, topics: ["0xddf252ad"], data: "0x" }]);
    expect(hops).toEqual([{ pool: POOL, amount0: (50n * 10n ** 18n).toString(), amount1: "-49900000" }]);
    const pool = { token0: "usdrif", token1: "usd0" };
    const value = (t: string, w: bigint) => (t === "usdrif" ? Number(w) / 1e18 : t === "usd0" ? Number(w) / 1e6 : undefined);
    expect(hopUsd(hops[0]!, pool, value)).toBe(50);
    expect(hopUsd(hops[0]!, { token0: "unknown", token1: "usd0" }, value)).toBeCloseTo(49.9, 9); // the paid-out side
    expect(hopUsd(hops[0]!, undefined, value)).toBeUndefined();
  });

  it("a two-hop route counts ~2× its fill; a tx without hops keeps its fills; volume is untouched", () => {
    const routed = toDashFill(30, wire(order("sell", 10n), 50n * 10n ** 18n, T0), usd); // $50 fill
    const inventory = toDashFill(30, wire(order("sell", 11n), 20n * 10n ** 18n, T0 + 1), usd); // $20, no swap
    const tt = new Map([[routed.tx.toLowerCase(), 99.8]]); // two hops of ~$50
    expect(turnoverShares([routed, inventory], tt).get(routed.id)).toBe(99.8);
    const s = dashStats(30, [routed, inventory], (T0 + 60) * 1000, 7, tt);
    expect([s.volume, s.turnover]).toEqual([70, 119.8]);
  });
});

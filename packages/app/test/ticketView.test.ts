/**
 * What the form and the book show for a ticket (lib/ticketView.ts), 2026-10-11:
 * market figures are QUOTE-FIRST (the ladder is only the fallback), the quote is
 * drawn into the right side of the book, and the balance lines / Max / sign button.
 */
import { describe, expect, it } from "vitest";

import { quote as ladderQuote } from "../src/lib/ladder";
import type { QuoteView } from "../src/lib/quote";
import {
  balanceState,
  DETAILS_KEY,
  effectivePrice,
  fmtBalance,
  marketFigures,
  markerIndex,
  maxSpendableWei,
  NATIVE_GAS_RESERVE_WEI,
  quoteMarkers,
  readDetailsOpen,
  signButton,
  sourceName,
  writeDetailsOpen,
} from "../src/lib/ticketView";
import type { Level } from "../src/lib/types";

/** The screenshot's case: 0.1 WRBTC quoted at 8,246 USD0 next to a ladder averaging 78,202. */
const rfq: QuoteView = {
  quoteId: "q1",
  amountIn: 0.1,
  receive: 8246,
  gross: 8246.706367,
  gas: 0.706367,
  gasBps: 1,
  permitGas: 0,
  gasMarginBps: 2000,
  minOut: 8246 * 0.997,
  slippageBps: 30,
  source: "sushi",
  validUntil: 2e9,
  live: true,
};
const bids: Level[] = [
  { price: 78202.2, size: 0.871955, source: "UNI" },
  { price: 69914.1, size: 2.11, source: "SUSHI" },
];
const asks: Level[] = [
  { price: 84546.6, size: 0.164, source: "UNI" },
  { price: 85222.6, size: 0.2447, source: "SUSHI" },
  { price: 90294.9, size: 0.7277, source: "UNI" },
];
const ladder = ladderQuote({ bids, asks, side: "sell", amountIn: 0.1, limit: null, slippageBps: 30 });

describe("marketFigures — the quote is THE price", () => {
  it("every figure derives from the quote when one is present, never from the ladder", () => {
    const f = marketFigures({ side: "sell", rfq, ladder, mid: 81374.42 })!;
    expect(f.basis).toBe("quote");
    expect(f.receive).toBe(8246);
    expect(f.price).toBeCloseTo(82460, 6);
    expect(f.minOut).toBeCloseTo(8221.262, 3);
    expect(f.minPrice).toBeCloseTo(82212.62, 2);
    // Above the mid, as the quote is — not the ladder's −3.90 %.
    expect(f.vsMidPct!).toBeCloseTo((82460 / 81374.42 - 1) * 100, 9);
    expect(f.vsMidPct!).toBeGreaterThan(0);
    expect(f.networkFee).toBeCloseTo(0.706367, 9);
    expect(f.source).toBe("sushi");
    expect(ladder.avg).toBeCloseTo(78202.2, 6); // the contradicting walk is NOT what is shown
  });

  it("a quote breaks the receive down: swap output − network fee (permit share shown) = receive", () => {
    const plain = marketFigures({ side: "sell", rfq, ladder, mid: null })!;
    expect(plain.grossReceive).toBeCloseTo(8246.706367, 9);
    expect(plain.grossReceive! - plain.networkFee!).toBeCloseTo(plain.receive, 9);
    expect(plain.permitFee).toBeNull();
    // The 2026-10-12 gasless USDRIF ticket: 15.91 out, 0.58 fee of which ~0.11 the permit.
    const gasless: QuoteView = { ...rfq, receive: 15.33, gross: 15.91, gas: 0.58, permitGas: 0.107 };
    const g = marketFigures({ side: "buy", rfq: gasless, ladder: null, mid: null })!;
    expect(g.permitFee).toBe(0.107);
    expect(g.grossReceive! - g.networkFee!).toBeCloseTo(g.receive, 9);
    // The ladder estimate has no gross/net split to show.
    expect(marketFigures({ side: "sell", rfq: null, ladder, fallbackGas: 0.7, mid: null })!.grossReceive).toBeNull();
  });

  it("a BUY's effective price is input per output (quote per base)", () => {
    const buy: QuoteView = { ...rfq, amountIn: 1000, receive: 0.0119, minOut: 0.0119 * 0.997 };
    const f = marketFigures({ side: "buy", rfq: buy, ladder: null, mid: 83000 })!;
    expect(f.price).toBeCloseTo(1000 / 0.0119, 6);
    expect(f.minPrice).toBeGreaterThan(f.price); // the minimum receive is the WORST (highest) price
  });

  it("falls back to the ladder walk only without a quote, with the plan's signed minimum and gas estimate", () => {
    const f = marketFigures({ side: "sell", rfq: null, ladder, fallbackMinOut: 7800, fallbackGas: 0.7, mid: 81374.42 })!;
    expect(f.basis).toBe("ladder");
    expect(f.receive).toBeCloseTo(ladder.crossedOut, 9);
    expect(f.price).toBeCloseTo(ladder.avg, 9);
    expect(f.minOut).toBe(7800);
    expect(f.networkFee).toBe(0.7);
    expect(f.source).toBeNull();
    // Without the plan's floor: the walk's own flat minimum.
    expect(marketFigures({ side: "sell", rfq: null, ladder, mid: null })!.minOut).toBeCloseTo(ladder.minReceived, 9);
    expect(marketFigures({ side: "sell", rfq: null, ladder, mid: null })!.vsMidPct).toBeNull();
  });

  it("nothing to show: no quote and nothing crosses", () => {
    expect(marketFigures({ side: "sell", rfq: null, ladder: null, mid: 1 })).toBeNull();
    const empty = ladderQuote({ bids: [], asks: [], side: "sell", amountIn: 1, limit: null, slippageBps: 30 });
    expect(marketFigures({ side: "sell", rfq: null, ladder: empty, mid: 1 })).toBeNull();
  });

  it("effectivePrice guards zero legs", () => {
    expect(effectivePrice("sell", 0, 5)).toBe(0);
    expect(effectivePrice("buy", 5, 0)).toBe(0);
  });

  it("sourceName", () => {
    expect(sourceName("sushi")).toBe("Sushi");
    expect(sourceName("uniswap-v3")).toBe("Uniswap");
    expect(sourceName("oku")).toBe("Uniswap"); // Oku runs a Uniswap v3 deployment; it is the indexer, not the venue
    expect(sourceName(null)).toBe("our filler");
    expect(sourceName("?")).toBe("our filler");
  });
});

describe("the quote line in the book", () => {
  it("a SELL quote lands on the BID side, above a best bid it beats", () => {
    const m = quoteMarkers("sell", { price: 82460, minPrice: 82212.6 }, bids.map((b) => b.price))!;
    expect(m.side).toBe("bid");
    expect(m.index).toBe(0);
    expect(m.minIndex).toBe(0);
  });

  it("…and between the rungs where it falls", () => {
    const m = quoteMarkers("sell", { price: 75000, minPrice: 69000 }, bids.map((b) => b.price))!;
    expect(m.index).toBe(1); // under 78,202, over 69,914
    expect(m.minIndex).toBe(2); // past every row
  });

  it("a BUY quote lands on the ASK side (ascending best-first)", () => {
    const m = quoteMarkers("buy", { price: 85000, minPrice: 85300 }, asks.map((a) => a.price))!;
    expect(m.side).toBe("ask");
    expect(m.index).toBe(1); // after 84,546.6, before 85,222.6
    expect(m.minIndex).toBe(2);
  });

  it("markerIndex at the edges", () => {
    expect(markerIndex([], 5, true)).toBe(0);
    expect(markerIndex([3, 2, 1], 2, true)).toBe(1); // a tie sits in front of the row at the same price
    expect(markerIndex([1, 2, 3], 4, false)).toBe(3);
    expect(quoteMarkers("sell", { price: 0, minPrice: 0 }, [1])).toBeNull();
  });
});

describe("balances", () => {
  it("fmtBalance truncates (never shows more than you hold) and scales precision", () => {
    expect(fmtBalance(0.12349)).toBe("0.1234");
    expect(fmtBalance(0.00012349)).toBe("0.0001234");
    expect(fmtBalance(12.34567)).toBe("12.3456");
    expect(fmtBalance(12345.678)).toBe("12,345.67");
    expect(fmtBalance(0)).toBe("0");
    expect(fmtBalance(1e-12)).toBe("<0.00000001");
    expect(fmtBalance(Number.NaN)).toBe("—");
  });

  it("Max: an ERC-20 (WRBTC) spends the whole balance; a native coin keeps a gas reserve", () => {
    const bal = 123456789012345678n;
    expect(maxSpendableWei(bal, false)).toBe(bal);
    expect(maxSpendableWei(bal, true)).toBe(bal - NATIVE_GAS_RESERVE_WEI);
    expect(maxSpendableWei(NATIVE_GAS_RESERVE_WEI / 2n, true)).toBe(0n);
    expect(maxSpendableWei(0n, false)).toBe(0n);
  });

  it("balanceState: connect / wrong network / loading / a number", () => {
    expect(balanceState({ connected: false, onChain: false, value: 1, symbol: "WRBTC" })).toEqual({ kind: "disconnected", text: "Connect wallet" });
    // Another network: the balance still shows (read over the public RPC); signing asks to switch.
    expect(balanceState({ connected: true, onChain: false, value: 1, symbol: "WRBTC" })).toEqual({ kind: "ok", text: "1 WRBTC", value: 1 });
    expect(balanceState({ connected: true, onChain: true, value: undefined, symbol: "WRBTC" }).kind).toBe("loading");
    expect(balanceState({ connected: true, onChain: true, value: 0.1234, symbol: "WRBTC" })).toEqual({ kind: "ok", text: "0.1234 WRBTC", value: 0.1234 });
  });

  it("the sign button says when the balance is short", () => {
    const base = { signing: false, amount: 1, overBalance: false, payToken: "WRBTC", ready: true, quoting: false, priced: true };
    expect(signButton(base)).toEqual({ label: "Sign order", disabled: false });
    expect(signButton({ ...base, overBalance: true })).toEqual({ label: "Insufficient WRBTC balance", disabled: true });
    expect(signButton({ ...base, amount: 0 }).label).toBe("Enter an amount");
    expect(signButton({ ...base, priced: false, quoting: true }).label).toBe("Fetching quote…");
    expect(signButton({ ...base, signing: true, overBalance: true }).label).toBe("Waiting for signature…");
  });
});

describe("the Details disclosure remembers open/closed per viewer", () => {
  it("closed by default; round-trips; a throwing storage reads closed and writes nothing", () => {
    const mem = new Map<string, string>();
    const store = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => void mem.set(k, v) };
    expect(readDetailsOpen(store)).toBe(false);
    writeDetailsOpen(store, true);
    expect(mem.get(DETAILS_KEY)).toBe("open");
    expect(readDetailsOpen(store)).toBe(true);
    writeDetailsOpen(store, false);
    expect(readDetailsOpen(store)).toBe(false);
    const broken = {
      getItem: () => {
        throw new Error("SecurityError");
      },
      setItem: () => {
        throw new Error("QuotaExceeded");
      },
    };
    expect(readDetailsOpen(broken)).toBe(false);
    expect(() => writeDetailsOpen(broken, true)).not.toThrow();
    expect(readDetailsOpen(undefined)).toBe(false);
  });
});

describe("fmtFee", () => {
  it("two significant figures under 1", async () => {
    const { fmtFee } = await import("../src/lib/ticketView");
    expect(fmtFee(0.706367)).toBe("0.71");
    expect(fmtFee(0.00000844)).toBe("0.0000084");
    expect(fmtFee(12.345)).toBe("12.35");
    expect(fmtFee(0)).toBe("0");
  });
});

describe("exceedsBalance — the TYPED amount, not the balance-capped commitment", () => {
  it("over, exact (Max), under, unknown", async () => {
    const { exceedsBalance } = await import("../src/lib/ticketView");
    const bal = 123400000000000000n; // 0.1234
    expect(exceedsBalance("0.5", 18, bal)).toBe(true);
    expect(exceedsBalance("0.1234", 18, bal)).toBe(false);
    expect(exceedsBalance("0.12340000000000000001", 18, bal)).toBe(false); // beyond the token's decimals: truncated
    expect(exceedsBalance("0.1", 18, bal)).toBe(false);
    expect(exceedsBalance("5", 18, undefined)).toBe(false);
    expect(exceedsBalance("", 18, bal)).toBe(false);
  });
});

describe("plainDecimal: amount fields never show scientific notation", () => {
  it("dust, normal and integral values", async () => {
    const { plainDecimal } = await import("../src/lib/format");
    expect(plainDecimal(2.2e-8)).toBe("0.000000022");
    expect(plainDecimal(Number((8e-8 * 0.25).toPrecision(3)))).toBe("0.00000002");
    expect(plainDecimal(12.5)).toBe("12.5");
    expect(plainDecimal(1e21)).not.toMatch(/e/);
  });
});

describe("route attribution: mixed venues and the solver hover", () => {
  it("names every venue of a mixed route, and the hops in the hover", async () => {
    const { sourceName, routeHover } = await import("../src/lib/ticketView");
    expect(sourceName("oku+sushi-v3")).toBe("Uniswap + Sushi");
    expect(sourceName("oku")).toBe("Uniswap");
    const sym: Record<string, string> = { "0xa": "USD₮0", "0xb": "RIF", "0xc": "RIFP" };
    expect(routeHover("oku+sushi-v3", { tokens: ["0xa", "0xb", "0xc"], fees: [3000, 3000], venues: ["oku", "sushi-v3"] }, (a) => sym[a]!)).toBe(
      "Filled by the 1delta solver: USD₮0 → RIF on Uniswap v3 (0.30 %) → RIFP on SushiSwap v3 (0.30 %)",
    );
    expect(routeHover("nordstern", undefined, () => "?")).toBe("Filled by the 1delta solver via Nordstern");
  });
});

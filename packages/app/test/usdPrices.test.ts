import { describe, expect, it } from "vitest";

import { fetchUsdTable, fmtUsd, parseUsdTable, usdPrice, type UsdContext } from "../src/lib/usdPrices";

const ADDR: Record<string, string> = {
  WRBTC: "0x542fda317318ebf1d3deaf76e0b632741a7e677d",
  USD0: "0x779ded0c9e1022225f8e0630b35a9b54be713736",
  RIF: "0x2acc95758f8b5f583470ba265eb685a8f45fc9d5",
};
const ctx = (mid: number | null, base = "WRBTC", quote = "USD₮0"): UsdContext => ({ chainId: 30, addressOf: (s) => ADDR[s], market: { base, quote, mid } });

describe("USD reference prices: Sushi's price API, else a heuristic, else nothing", () => {
  it("parses only finite positive prices under addresses", () => {
    expect(parseUsdTable({ [ADDR.WRBTC!.toUpperCase().replace("0X", "0x")]: 82_000, bad: 1, "0x00000000000000000000000000000000000000aa": -1, [ADDR.RIF!]: "0.08" })).toEqual({ [ADDR.WRBTC!]: 82_000 });
    expect(parseUsdTable(null)).toEqual({});
    expect(parseUsdTable([1, 2])).toEqual({});
  });

  it("the API figure wins when present", () => {
    expect(usdPrice({ [ADDR.WRBTC!]: 82_770 }, ctx(80_000), "WRBTC")).toBe(82_770);
  });

  it("fallback: stables are $1, the market's other leg goes through its mid; unknown → undefined", () => {
    expect(usdPrice({}, ctx(83_000), "USD₮0")).toBe(1);
    expect(usdPrice({}, ctx(83_000), "WRBTC")).toBe(83_000);
    expect(usdPrice({ [ADDR.WRBTC!]: 80_000 }, ctx(0.000001, "RIF", "WRBTC"), "RIF")).toBeCloseTo(0.08, 9);
    expect(usdPrice({}, ctx(null), "WRBTC")).toBeUndefined();
    expect(usdPrice({}, ctx(83_000), "RIF")).toBeUndefined(); // not on the market on screen
  });

  it("a failed or slow API throws (the hook keeps the last table / the heuristic)", async () => {
    await expect(fetchUsdTable(30, (async () => new Response("no", { status: 502 })) as typeof fetch)).rejects.toThrow(/502/);
    const t = await fetchUsdTable(30, (async () => Response.json({ [ADDR.USD0!]: 1 })) as typeof fetch);
    expect(t).toEqual({ [ADDR.USD0!]: 1 });
  });

  it("fmtUsd", () => {
    expect(fmtUsd(12.746)).toBe("$12.75");
    expect(fmtUsd(1234.5)).toBe("$1,235");
    expect(fmtUsd(0.0421)).toBe("$0.042");
    expect(fmtUsd(0.004)).toBe("<$0.01");
  });
});

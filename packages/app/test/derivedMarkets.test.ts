import { describe, expect, it } from "vitest";

import { isSynthetic, marketById, marketFor, pairsWith, symbolsOn } from "../src/config/markets";

describe("markets follow the user's token pair: a pool market, else a route via a hub", () => {
  it("a pair with a pool resolves to its pool market (never a route)", () => {
    const m = marketFor(30, "WRBTC", "USD₮0")!;
    expect(m.id).toBe("rsk-30-wrbtc-usd0");
    expect(isSynthetic(m)).toBe(false);
  });

  it("a pair without a pool is DERIVED: base → hub → quote over two pool markets", () => {
    const m = marketFor(30, "USDRIF", "WRBTC")!;
    expect(m.id).toBe("rsk-30-wrbtc-usdrif"); // the id synthetic orders were signed under
    expect([m.base, m.quote]).toEqual(["WRBTC", "USDRIF"]);
    expect(m.via!.map((h) => `${h.base}/${h.quote}`)).toEqual(["WRBTC/USD₮0", "USDRIF/USD₮0"]);
    expect(m.pools.map((p) => p.address)).toEqual(m.via!.flatMap((h) => h.pools.map((p) => p.address)));
    // RIFPro has a pool only against RIF: routed via RIF.
    const rifp = marketFor(30, "RIFP", "USD₮0")!;
    expect(rifp.via!.map((h) => `${h.base}/${h.quote}`)).toEqual(["RIFP/RIF", "RIF/USD₮0"]);
  });

  it("derived markets are stable objects and resolve back from their id", () => {
    const a = marketFor(30, "WETH", "USD₮0")!;
    expect(marketFor(30, "USD₮0", "WETH")).toBe(a);
    expect(marketById(a.id)).toBe(a);
  });

  it("a pair no single hub connects is not offered", () => {
    expect(marketFor(30, "USDC.e", "RIFP")).toBeUndefined();
    expect(pairsWith(30, "USDC.e")).not.toContain("RIFP");
  });

  it("every Rootstock token trades against USD₮0 or WRBTC, directly or routed", () => {
    for (const s of symbolsOn(30)) {
      if (s === "USD₮0" || s === "WRBTC") continue;
      expect(pairsWith(30, s).some((o) => o === "USD₮0" || o === "WRBTC"), s).toBe(true);
    }
  });
});

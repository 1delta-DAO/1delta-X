import { afterEach, describe, expect, it, vi } from "vitest";

import { CHAINS } from "../src/config/chains";
import { MARKETS, TOKENS, assertPoolTokens, marketById } from "../src/config/markets";
import { buildTokenIndex } from "../src/hooks/useTokenIndex";
import { fetchPoolMeta, type PoolMeta } from "../src/lib/oku";
import { resolveMarket } from "../src/lib/poolbook";
import { TOKEN_CACHE_TTL_MS, parseTokenCache } from "../src/lib/tokens";

const BAD = "0xbad0000000000000000000000000000000000bad" as const;
const USD0 = TOKENS[30]!.USD0!.address;
const USDRIF = TOKENS[30]!.USDRIF!.address;
const RSK = CHAINS.find((c) => c.chainId === 30)!;
const USDRIF_MARKET = marketById("rsk-30-usdrif-usd0");

afterEach(() => {
  vi.unstubAllGlobals();
});

function poisonedMeta(): PoolMeta {
  // An indexer response for the right pool that names a worthless token under
  // the right SYMBOL and reports a zero scale.
  return {
    pool: USDRIF_MARKET.pools[0]!.address,
    fee: 500,
    token0: { address: USDRIF, symbol: "USDRIF", name: "USDRIF", decimals: 18 },
    token1: { address: BAD, symbol: "USD0", name: "USD0", decimals: 0 },
    tvlUsd: 0,
  };
}

describe("G-TS_SIGN-1 — signed token identity is pinned, not indexer-sourced", () => {
  it("test_audit_G_TS_SIGN_1_tokenIndexIgnoresPoisonedFeeds", () => {
    // A poisoned token list says USD0 has 0 decimals and lives at 0xBAD.
    const index = buildTokenIndex(30, [
      { address: BAD, symbol: "USD0", name: "USD0", decimals: 0, logoURI: "https://evil/logo.png" },
      { address: USD0, symbol: "USD₮0", name: "USDT0", decimals: 0, logoURI: "https://ok/usd0.png" },
    ]);
    const v = index.view("USD0");
    expect(v.address).toBe(USD0);
    expect(v.decimals).toBe(6);
    // Logo matched by the pinned ADDRESS only.
    expect(v.logoURI).toBe("https://ok/usd0.png");
    // A symbol with no pin has no address, so nothing can be signed for it.
    expect(index.view("NOPE").address).toBeUndefined();
  });

  it("test_audit_G_TS_SIGN_1_resolveMarketRejectsPoisonedPair", async () => {
    await expect(resolveMarket(USDRIF_MARKET, RSK, poisonedMeta())).rejects.toThrow(/pinned/);
    // The honest pair resolves, oriented by address, with pinned decimals.
    const honest = poisonedMeta();
    honest.token1 = { address: USD0, symbol: "USD₮0", name: "USDT0", decimals: 0 };
    const r = await resolveMarket(USDRIF_MARKET, RSK, honest);
    expect(r.base.address).toBe(USDRIF);
    expect(r.quote.address).toBe(USD0);
    expect(r.quote.decimals).toBe(6);
  });

  it("test_audit_G_TS_SIGN_1_okuMetaMustNameRequestedPool", async () => {
    const pool = USDRIF_MARKET.pools[0]!.address;
    const other = "0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd";
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            result: {
              pools: [
                {
                  address: other,
                  fee: 500,
                  t0: USDRIF,
                  t0_name: "x",
                  t0_symbol: "USDRIF",
                  t0_decimals: 18,
                  t1: BAD,
                  t1_name: "x",
                  t1_symbol: "USD0",
                  t1_decimals: 6,
                  tvl_usd: 0,
                },
              ],
            },
          }),
        ),
      ),
    );
    await expect(fetchPoolMeta("rootstock", pool)).rejects.toThrow(/not the requested/);
  });

  it("test_audit_G_TS_SIGN_1_assertPoolTokensByAddress", () => {
    expect(assertPoolTokens(USDRIF_MARKET, "p", USDRIF, USD0)).toEqual({ baseIsToken0: true });
    expect(assertPoolTokens(USDRIF_MARKET, "p", USD0, USDRIF)).toEqual({ baseIsToken0: false });
    expect(() => assertPoolTokens(USDRIF_MARKET, "p", USDRIF, BAD)).toThrow(/refusing/);
  });

  it("test_audit_G_TS_SIGN_1_everyMarketHasPinnedTokens", () => {
    for (const m of MARKETS) {
      for (const s of [m.base, m.quote]) {
        const t = TOKENS[m.chainId]?.[s];
        expect(t, `${m.id} ${s}`).toBeDefined();
        expect(t!.address).toMatch(/^0x[0-9a-f]{40}$/);
        expect(t!.decimals).toBeGreaterThan(0);
      }
    }
  });

  it("test_audit_G_TS_SIGN_1_tokenCacheExpires", () => {
    const entries = { "30:0x1": { address: "0x1", symbol: "A", name: "A", decimals: 0 } };
    const now = 10 * TOKEN_CACHE_TTL_MS;
    expect(parseTokenCache(JSON.stringify({ savedAt: now - 1000, entries }), now)).toEqual(entries);
    expect(parseTokenCache(JSON.stringify({ savedAt: now - TOKEN_CACHE_TTL_MS - 1, entries }), now)).toEqual({});
    // The old never-expiring v1 shape (a bare map) is not trusted.
    expect(parseTokenCache(JSON.stringify(entries), now)).toEqual({});
    expect(parseTokenCache("not json", now)).toEqual({});
  });

  it("test_audit_G_TS_SIGN_1_formShowsReceiveAddress", async () => {
    const { readFileSync } = await import("node:fs");
    const form = readFileSync(new URL("../src/components/OrderForm.tsx", import.meta.url), "utf8");
    expect(form).toContain("you sign for {recvToken} at");
  });
});

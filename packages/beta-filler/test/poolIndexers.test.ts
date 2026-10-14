import { getAddress, type Address } from "viem";
import { describe, expect, it } from "vitest";

import { okuPools, sqrtPriceX96FromPrice, sushiPools, type IndexerConfig } from "../src/poolIndexers";

const INIT = "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54" as const;
const OKU = { factory: getAddress("0xaf37ec98a00fd63689cf3060bf3b6784e00cad82"), initCodeHash: INIT };
const SUSHI = { factory: getAddress("0x46b3fdf7b5cde91ac049936bf0bdb12c5d22202e"), initCodeHash: INIT };
const USDT0 = getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736");
const RIF = getAddress("0x2acc95758f8b5f583470ba265eb685a8f45fc9d5");
const WRBTC = getAddress("0x542fda317318ebf1d3deaf76e0b632741a7e677d");
const STRANGER = getAddress("0x00000000000000000000000000000000000000aa");
const TOKENS: Address[] = [USDT0, RIF, WRBTC];
const FEES = new Set([100, 500, 3000, 10000]);
const CFG: IndexerConfig = { okuBase: "https://oku.test", okuChain: "rootstock", sushiSubgraph: "https://sushi.test/gn", minTvlUsd: 1000, timeoutMs: 1000 };

/** The live pools (2026-10-14): Oku RIF/USD₮0 0.3 %, Sushi WRBTC/RIF 0.3 %. */
const OKU_RIF_USDT0 = "0x57079b2d3071eb06cce6dbafb9b0306bcc49b020";
const SUSHI_WRBTC_RIF = "0x7a110977b642b64ddde6c6d2d4d370ad48993a74";

describe("pool discovery from the indexers: TVL-filtered, CREATE2-verified, graph tokens only", () => {
  it("Oku: keeps the real pool, drops dust (TVL), a forged address and a pair outside the graph", async () => {
    const pools = [
      { address: OKU_RIF_USDT0, fee: 3000, t0: RIF, t1: USDT0, t0_decimals: 18, t1_decimals: 6, liquidity: "704628276554271244", t0_price: 0.0825, tvl_usd: 85_000 },
      { address: "0x069081b7de3edbdfcee339e01c72e4802b259278", fee: 500, t0: RIF, t1: WRBTC, t0_decimals: 18, t1_decimals: 18, liquidity: "1", t0_price: 1e-6, tvl_usd: 12 }, // dust
      { address: "0x000000000000000000000000000000000000dead", fee: 3000, t0: RIF, t1: USDT0, t0_decimals: 18, t1_decimals: 6, liquidity: "5", t0_price: 0.08, tvl_usd: 1e9 }, // forged
      { address: OKU_RIF_USDT0, fee: 3000, t0: RIF, t1: STRANGER, t0_decimals: 18, t1_decimals: 18, liquidity: "5", t0_price: 1, tvl_usd: 1e6 }, // not a graph token
    ];
    const fakeFetch = (async () => Response.json({ result: { pools } })) as unknown as typeof fetch;
    const warnings: string[] = [];
    const got = await okuPools(CFG, 0, OKU, TOKENS, FEES, fakeFetch, warnings);
    expect(got.map((p) => p.pool.toLowerCase())).toEqual([OKU_RIF_USDT0]);
    expect(got[0]).toMatchObject({ fee: 3000, venue: 0, liquidity: 704628276554271244n, tvlUsd: 85_000 });
    expect(got[0]!.sqrtPriceX96).toBeGreaterThan(0n);
    expect(warnings.some((w) => /CREATE2/.test(w))).toBe(true);
  });

  it("Sushi: the subgraph's pools, the same checks; an indexer error throws (the caller falls back to the RPC probe)", async () => {
    const fakeFetch = (async () =>
      Response.json({
        data: {
          pools: [
            { id: SUSHI_WRBTC_RIF, feeTier: "3000", liquidity: "868875495504746066974", sqrtPrice: "79805146126160172265121160", totalValueLockedUSD: "58000", token0: { id: RIF }, token1: { id: WRBTC } },
            { id: SUSHI_WRBTC_RIF, feeTier: "3000", liquidity: "1", sqrtPrice: "1", totalValueLockedUSD: "3", token0: { id: RIF }, token1: { id: WRBTC } },
          ],
        },
      })) as unknown as typeof fetch;
    const got = await sushiPools(CFG, 1, SUSHI, TOKENS, FEES, fakeFetch, []);
    expect(got.map((p) => p.pool.toLowerCase())).toEqual([SUSHI_WRBTC_RIF]);
    const down = (async () => new Response("bad gateway", { status: 502 })) as unknown as typeof fetch;
    await expect(sushiPools(CFG, 1, SUSHI, TOKENS, FEES, down, [])).rejects.toThrow(/502/);
  });

  it("sqrtPriceX96 from a human price (Oku reports none): 1:1 at equal decimals is 2^96", () => {
    expect(sqrtPriceX96FromPrice(1, 18, 18)).toBe(2n ** 96n);
    expect(sqrtPriceX96FromPrice(0, 18, 18)).toBeUndefined();
  });
});

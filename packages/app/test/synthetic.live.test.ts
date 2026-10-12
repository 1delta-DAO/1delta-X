/**
 * LIVE gate for a synthetic market (docs/synthetic-pairs.md "Validation"): the composed
 * book vs Uniswap's QuoterV2 on the same multi-hop path, Rootstock mainnet.
 *
 *   LIVE_RSK=1 VITE_OKU_BASE=https://omni.icarus.tools npx vitest run test/synthetic.live.test.ts
 *
 * Skipped by default (network). Only the Uniswap (Oku) pools are composed here, so
 * both sides price the same liquidity. The app also adds Sushi's pool to hop 1, which
 * can only make its book deeper than this.
 */
import { createPublicClient, encodePacked, http, parseAbi, parseUnits, formatUnits } from "viem";
import { describe, expect, it } from "vitest";

import { chainById } from "../src/config/chains";
import { marketById, pinnedToken, type Market } from "../src/config/markets";
import { refine, walk } from "../src/lib/ladder";
import { fetchVenue, resolveMarket, venueTokens } from "../src/lib/poolbook";
import { composeBook } from "../src/lib/synthetic";

const QUOTER = "0xb51727c996c68e60f598a923a5006853cd2feb31";
const RPC = process.env.RSK_RPC ?? "https://rpc-gateway.1delta.io/30";
const quoterAbi = parseAbi(["function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] a, uint32[] b, uint256 gas)"]);

describe.skipIf(!process.env.LIVE_RSK)("synthetic WRBTC/USDRIF: composed book vs QuoterV2 (live)", () => {
  it("within 5 bps at $10 / $100 / $1k / $10k on both sides", async () => {
    const full = marketById("rsk-30-wrbtc-usdrif");
    const via = full.via!.map((h) => ({ ...h, pools: h.pools.filter((p) => p.dex === "uniswap-v3") }));
    const market: Market = { ...full, via, pools: via.flatMap((h) => h.pools) };
    const chain = chainById(30)!;
    const resolved = await resolveMarket(market, chain);
    const results = await Promise.all(market.pools.map((p) => fetchVenue(p, chain, venueTokens(market, resolved, p.address).base, undefined, venueTokens(market, resolved, p.address))));
    for (const r of results) expect(r.venue.error, r.venue.pool).toBeUndefined();
    const hops = via.map((h) => {
      const mine = results.filter((r) => h.pools.some((p) => p.address === r.venue.pool));
      return { base: h.base, quote: h.quote, bids: mine.flatMap((r) => r.bids), asks: mine.flatMap((r) => r.asks) };
    });
    const book = composeBook(hops, "WRBTC", "USDRIF");

    const c = createPublicClient({ transport: http(RPC) });
    const W = pinnedToken(30, "WRBTC")!;
    const U = pinnedToken(30, "USD0")!;
    const R = pinnedToken(30, "USDRIF")!;
    const quoteOut = async (path: `0x${string}`, amountIn: bigint) =>
      (await c.simulateContract({ address: QUOTER, abi: quoterAbi, functionName: "quoteExactInput", args: [path, amountIn] })).result[0];
    const sellPath = encodePacked(["address", "uint24", "address", "uint24", "address"], [W.address, 3000, U.address, 500, R.address]);
    const buyPath = encodePacked(["address", "uint24", "address", "uint24", "address"], [R.address, 500, U.address, 3000, W.address]);

    const rows: string[] = [];
    for (const usd of [10, 100, 1_000, 10_000]) {
      // Bids: sell `usd` of WRBTC.
      const wrbtc = usd / 83_000;
      const composedSell = walk(refine(book.bids, true), wrbtc, "sell", null).crossedOut;
      const onchainSell = Number(formatUnits(await quoteOut(sellPath, parseUnits(wrbtc.toFixed(18), 18)), R.decimals));
      // Asks: spend `usd` of USDRIF on WRBTC.
      const composedBuy = walk(refine(book.asks, false), usd, "buy", null).crossedOut;
      const onchainBuy = Number(formatUnits(await quoteOut(buyPath, parseUnits(String(usd), 18)), W.decimals));
      const dSell = (composedSell / onchainSell - 1) * 1e4;
      const dBuy = (composedBuy / onchainBuy - 1) * 1e4;
      rows.push(`$${usd}: sell ${dSell.toFixed(2)} bps, buy ${dBuy.toFixed(2)} bps`);
      expect(Math.abs(dSell), `sell $${usd}`).toBeLessThan(5);
      expect(Math.abs(dBuy), `buy $${usd}`).toBeLessThan(5);
    }
    console.log(rows.join("\n"));
  }, 60_000);
});

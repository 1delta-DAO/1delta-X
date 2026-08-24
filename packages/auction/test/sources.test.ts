import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import { QuoteSolver, defaultRouteSources, floorNumericAmount, nordsternSource, sushiSource } from "../src/index";
import type { FetchLike } from "../src/sources/http";
import { privateKeyToAccount } from "viem/accounts";
import type { QuoteBinding } from "@1delta-x/sdk";

const TOKEN_IN = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_OUT = "0x2222222222222222222222222222222222222222" as Address;
const ME = "0x00000000000000000000000000000000000000a1" as Address;
const NATIVE_ZERO = "0x0000000000000000000000000000000000000000" as Address;

const req = { chainId: 31, tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT, amountIn: 1_000n, recipient: ME };

/** Records the URL and replies with a canned body. */
function stub(body: unknown, ok = true): { fetchImpl: FetchLike; urls: string[] } {
  const urls: string[] = [];
  return {
    urls,
    fetchImpl: async (url) => {
      urls.push(url);
      return { ok, status: ok ? 200 : 500, json: async () => body };
    },
  };
}

describe("floorNumericAmount", () => {
  it("floors a fractional JSON number rather than throwing on it", () => {
    // BigInt(1234.5) throws; rounding up would overstate what the solver receives.
    expect(floorNumericAmount(1234.5)).toBe(1234n);
    expect(floorNumericAmount("1234.99")).toBe(1234n);
    expect(floorNumericAmount("5000")).toBe(5000n);
  });

  it("returns null for nothing, zero and garbage", () => {
    expect(floorNumericAmount(undefined)).toBeNull();
    expect(floorNumericAmount(0)).toBeNull();
    expect(floorNumericAmount("abc")).toBeNull();
  });
});

describe("sushiSource", () => {
  it("hits swap/v7 with slippage as a DECIMAL and reads assumedAmountOut", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1750", tx: { to: ME, data: "0xabcd", value: "0" } });
    const quote = await sushiSource({ fetchImpl: s.fetchImpl, slippagePercent: 0.5 }).quote(req);
    expect(quote!.amountOut).toBe(1750n);
    expect(quote!.source).toBe("sushiswap");
    expect(s.urls[0]).toContain("/swap/v7/31");
    expect(s.urls[0]).toContain("maxSlippage=0.005"); // 0.5% as a decimal
  });

  it("carries the tx so the winner can execute what it priced", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1750", tx: { to: ME, data: "0xabcd", value: "7" } });
    const quote = await sushiSource({ fetchImpl: s.fetchImpl }).quote(req);
    expect(quote!.route).toEqual({ to: ME, data: "0xabcd", value: 7n });
  });

  it("refuses a non-Success response rather than bidding on a stale number", async () => {
    const s = stub({ status: "NoWay", assumedAmountOut: "1750" });
    expect(await sushiSource({ fetchImpl: s.fetchImpl }).quote(req)).toBeNull();
  });

  it("maps native to the 0xEeee placeholder", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1" });
    await sushiSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenIn: NATIVE_ZERO });
    expect(s.urls[0]!.toLowerCase()).toContain("tokenin=0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
  });

  it("returns null on an HTTP error instead of throwing into the bid loop", async () => {
    const s = stub({}, false);
    expect(await sushiSource({ fetchImpl: s.fetchImpl }).quote(req)).toBeNull();
  });
});

describe("nordsternSource", () => {
  it("hits /aggregator with slippage as a PERCENT and reads toAmount", async () => {
    const s = stub({ toAmount: 1800, tx: { to: ME, data: "0xbeef", value: 0 } });
    const quote = await nordsternSource({ fetchImpl: s.fetchImpl, slippagePercent: 0.5 }).quote(req);
    expect(quote!.amountOut).toBe(1800n);
    expect(s.urls[0]).toContain("/aggregator/31");
    expect(s.urls[0]).toContain("slippage=0.5"); // percent, NOT the decimal Sushi wants
  });

  it("floors a fractional toAmount — the API returns a JSON number", async () => {
    const s = stub({ toAmount: 1800.9 });
    expect((await nordsternSource({ fetchImpl: s.fetchImpl }).quote(req))!.amountOut).toBe(1800n);
  });

  it("maps native to the ZERO address, not the placeholder", async () => {
    const s = stub({ toAmount: 1 });
    await nordsternSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenIn: NATIVE_ZERO });
    expect(s.urls[0]).toContain("src=0x0000000000000000000000000000000000000000");
  });

  it("returns null when the route is empty", async () => {
    const s = stub({ toAmount: 0 });
    expect(await nordsternSource({ fetchImpl: s.fetchImpl }).quote(req)).toBeNull();
  });
});

describe("defaultRouteSources — the floor competitors must beat", () => {
  it("bids off the BETTER of the two", async () => {
    const both: FetchLike = async (url) => ({
      ok: true,
      status: 200,
      json: async () =>
        url.includes("sushi") ? { status: "Success", assumedAmountOut: "1500" } : { toAmount: 1800 },
    });
    const solver = new QuoteSolver({
      account: privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11"),
      binding: { module: "0x00000000000000000000000000000000000000cc", chainId: 31 } as QuoteBinding,
      routes: defaultRouteSources({ fetchImpl: both }),
    });
    const best = await solver.bestRoute(req);
    expect(best!.amountOut).toBe(1800n);
    expect(best!.source).toBe("nordstern");
  });

  it("degrades to whichever source is up rather than to nothing", async () => {
    const oneDown: FetchLike = async (url) =>
      url.includes("sushi")
        ? { ok: false, status: 503, json: async () => ({}) }
        : { ok: true, status: 200, json: async () => ({ toAmount: 1600 }) };
    const solver = new QuoteSolver({
      account: privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11"),
      binding: { module: "0x00000000000000000000000000000000000000cc", chainId: 31 } as QuoteBinding,
      routes: defaultRouteSources({ fetchImpl: oneDown }),
    });
    expect((await solver.bestRoute(req))!.amountOut).toBe(1600n);
  });
});

// ─────────────── price-only quoting: the two adapters must agree ───────────────

describe("quoting without a real recipient", () => {
  const priceOnly = { ...req, recipient: "0x0000000000000000000000000000000000000000" as Address };

  it("Sushi switches to the recipient-less quote/v6 endpoint", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1750", tx: { to: ME, data: "0xabcd", value: "0" } });
    const quote = await sushiSource({ fetchImpl: s.fetchImpl }).quote(priceOnly);
    expect(s.urls[0]).toContain("/quote/v6/31");
    expect(s.urls[0]).not.toContain("recipient=");
    expect(quote!.amountOut).toBe(1750n);
  });

  it("Nordstern stands in the dummy caller on its single endpoint", async () => {
    const s = stub({ toAmount: 1800, tx: { to: ME, data: "0xbeef", value: 0 } });
    const quote = await nordsternSource({ fetchImpl: s.fetchImpl }).quote(priceOnly);
    expect(s.urls[0]).toContain("from=0x0000000000000000000000000000000000000001");
    expect(quote!.amountOut).toBe(1800n);
  });

  it("NEITHER returns an executable route — the calldata is not for this caller", async () => {
    // The safety property: a tx built for the dummy would deliver the output to
    // the placeholder, so it must never reach a caller that might execute it.
    const sushi = stub({ status: "Success", assumedAmountOut: "1750", tx: { to: ME, data: "0xabcd", value: "0" } });
    const nord = stub({ toAmount: 1800, tx: { to: ME, data: "0xbeef", value: 0 } });
    expect((await sushiSource({ fetchImpl: sushi.fetchImpl }).quote(priceOnly))!.route).toBeUndefined();
    expect((await nordsternSource({ fetchImpl: nord.fetchImpl }).quote(priceOnly))!.route).toBeUndefined();
  });

  it("both still return an executable route for a real recipient", async () => {
    const sushi = stub({ status: "Success", assumedAmountOut: "1750", tx: { to: ME, data: "0xabcd", value: "0" } });
    const nord = stub({ toAmount: 1800, tx: { to: ME, data: "0xbeef", value: 0 } });
    expect((await sushiSource({ fetchImpl: sushi.fetchImpl }).quote(req))!.route).toBeDefined();
    expect((await nordsternSource({ fetchImpl: nord.fetchImpl }).quote(req))!.route).toBeDefined();
  });

  it("treats a malformed recipient as price-only rather than sending it upstream", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1" });
    await sushiSource({ fetchImpl: s.fetchImpl }).quote({ ...req, recipient: "0xnope" as Address });
    expect(s.urls[0]).toContain("/quote/v6/");
  });
});

// ───────── order-leg tokens are untrusted strings on the wire ─────────

/**
 * An order arrives as JSON, so `Address` is a compile-time claim and nothing
 * more. A token field carrying `&recipient=…` used to be concatenated straight
 * into the query — ahead of the legitimate `recipient` — so an aggregator that
 * resolves duplicate keys first-wins would return calldata paying the attacker.
 */
const INJECTED = "0x1111111111111111111111111111111111111111&recipient=0x000000000000000000000000000000000000dead" as Address;

describe("outbound URLs — parameter injection", () => {
  it("sushi REFUSES to quote a malformed token rather than interpolating it", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1750" });
    expect(await sushiSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenIn: INJECTED })).toBeNull();
    expect(await sushiSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenOut: INJECTED })).toBeNull();
    expect(s.urls).toEqual([]); // nothing was even sent
  });

  it("nordstern refuses the same", async () => {
    const s = stub({ toAmount: "1750" });
    expect(await nordsternSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenIn: INJECTED })).toBeNull();
    expect(await nordsternSource({ fetchImpl: s.fetchImpl }).quote({ ...req, tokenOut: INJECTED })).toBeNull();
    expect(s.urls).toEqual([]);
  });

  it("and encodes every value it does send, so no field can add a parameter", async () => {
    const s = stub({ status: "Success", assumedAmountOut: "1750" });
    await sushiSource({ fetchImpl: s.fetchImpl }).quote(req);
    // Exactly the parameters the adapter meant to send — one `recipient`, one
    // `tokenIn`, and no stray keys.
    const params = new URL(s.urls[0]!).searchParams;
    expect(params.getAll("recipient")).toEqual([ME]);
    expect(params.getAll("tokenIn")).toEqual([TOKEN_IN]);
    expect([...params.keys()].sort()).toEqual([
      "amount",
      "maxSlippage",
      "recipient",
      "sender",
      "simulate",
      "tokenIn",
      "tokenOut",
      "validate",
    ]);
  });
});

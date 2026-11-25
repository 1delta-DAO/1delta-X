/**
 * `auto` quotes on large tickets (2026-11-25, ./src/quote.ts): the route is priced on
 * DIRECT and — when `RouteFiller.autoPullWorthIt` says the ticket is large enough and an
 * API source is on — on PULL too, where Sushi / Nordstern / SwaptoX compete; the better
 * net wins and names its delivery. Small tickets never wait on the pull leg.
 */
import type { Address } from "viem";
import { describe, expect, it, vi } from "vitest";

import { loadConfig, ROOTSTOCK } from "../src/config";
import { QuoteBook, Quoter, type PricedCandidate, type QuoteRequest } from "../src/quote";
import type { RouteFiller } from "../src/routeFiller";

const ENV = {
  PRIVATE_KEY: "0x" + "11".repeat(32),
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://localhost:8080/",
  AGGREGATOR_SOLVER: "0x00000000000000000000000000000000000050a1",
};
const USDT0 = ROOTSTOCK.usdt0 as Address;
const RIF = ROOTSTOCK.rif as Address;
const E18 = 10n ** 18n;

const cand = (grossOut: bigint, source: string): PricedCandidate => ({ strategy: "route", grossOut, costOut: 13n * E18, gasUnits: 400_000n, source });

/** A route stub: the pool route on direct, an API route (better) on pull; `large` decides the pull leg. */
function setup(large: boolean) {
  const route = {
    autoPullWorthIt: vi.fn(async () => large),
    quoteRoute: vi.fn(async (a: { direct: boolean }) => ({ ok: true as const, candidate: a.direct ? cand(197_324n * E18, "oku") : cand(204_316n * E18, "nordstern") })),
  };
  const q = new Quoter(loadConfig(ENV), { pub: { getGasPrice: async () => 24_406_880n } }, { checkGasPrice: () => undefined }, new QuoteBook(), {
    route: route as unknown as RouteFiller,
  });
  const req = (delivery: QuoteRequest["delivery"]): QuoteRequest => ({ chainId: 30, tokenIn: USDT0, tokenOut: RIF, amountIn: 10_000_000_000n, side: "buy", delivery });
  return { route, q, req };
}

describe("auto quotes: the route on PULL too for a large ticket", () => {
  it("a large ticket: the pull-only API route wins on net and the quote names PULL delivery", async () => {
    const { route, q, req } = setup(true);
    const v = await q.quote(req("auto"));
    if (!v.ok) throw new Error(v.reason);
    expect(v.quote).toMatchObject({ delivery: "pull", route: { source: "nordstern" }, grossOut: 204_316n * E18 });
    expect(route.quoteRoute.mock.calls.map((c) => c[0].direct).sort()).toEqual([false, true]);
  });
  it("a small ticket: direct only, no pull leg priced", async () => {
    const { route, q, req } = setup(false);
    const v = await q.quote(req("auto"));
    if (!v.ok) throw new Error(v.reason);
    expect(v.quote).toMatchObject({ delivery: "direct", route: { source: "oku" } });
    expect(route.quoteRoute).toHaveBeenCalledOnce();
  });
  it("an explicit delivery is priced as asked, whatever the size", async () => {
    const { route, q, req } = setup(true);
    const v = await q.quote(req("direct"));
    if (!v.ok) throw new Error(v.reason);
    expect(v.quote.delivery).toBe("direct");
    expect(route.autoPullWorthIt).not.toHaveBeenCalled();
  });
  it("ROUTE_AUTO_PULL_USD: default 500, 0 = always", () => {
    expect(loadConfig(ENV).route!.autoPullUsd).toBe(500);
    expect(loadConfig({ ...ENV, ROUTE_AUTO_PULL_USD: "0" }).route!.autoPullUsd).toBe(0);
  });
});

import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";

import { ROOTSTOCK } from "../src/config";
import { fillUsd6 } from "../src/totalCap";

const USDT0 = getAddress(ROOTSTOCK.usdt0);
const USDRIF = getAddress(ROOTSTOCK.usdrif);
const RIF = getAddress(ROOTSTOCK.rif);
const cfg = { tokens: { usdt0: USDT0, usdrif: USDRIF, rif: RIF } } as never;
const price = async (t: Address, a: bigint) => (t.toLowerCase() === RIF.toLowerCase() ? (a * 75n) / 10n ** 15n : undefined); // RIF at $0.075

describe("pre-audit total fill cap: a fill's USD value", () => {
  it("is its stable leg (USD₮0 at face, USDRIF at $1; the larger when both)", async () => {
    expect(await fillUsd6(cfg, { payToken: USDT0, paid: "45394047", recvToken: USDRIF, received: (46n * 10n ** 18n).toString() }, price)).toBe(46_000_000n);
    expect(await fillUsd6(cfg, { payToken: RIF, paid: (1000n * 10n ** 18n).toString(), recvToken: USDT0, received: "74000000" }, price)).toBe(74_000_000n);
  });

  it("else the received token at the pool, else the paid one; unpriceable = undefined", async () => {
    const WRBTC = getAddress(ROOTSTOCK.wrbtc);
    expect(await fillUsd6(cfg, { payToken: WRBTC, paid: "100", recvToken: RIF, received: (100n * 10n ** 18n).toString() }, price)).toBe(7_500_000n);
    expect(await fillUsd6(cfg, { payToken: WRBTC, paid: "100", recvToken: WRBTC, received: "100" }, price)).toBeUndefined();
  });
});

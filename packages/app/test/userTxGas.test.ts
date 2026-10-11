/**
 * The app's own transactions (wrap, approve, grant, unwrap, cancel) on Rootstock are
 * priced at the block's `minimumGasPrice` + 1 % instead of the wallet's
 * `eth_gasPrice` (= minimum + 10 %).
 */
import { describe, expect, it } from "vitest";
import { USER_GAS_PRICE_MULT_BPS, userTxGas, type GasReader } from "../src/lib/chain";

const MIN = 23_696_000n;
const reader = (o: { min?: unknown; gasPrice?: bigint; blockThrows?: boolean; priceThrows?: boolean }): GasReader => ({
  getGasPrice: async () => {
    if (o.priceThrows) throw new Error("rpc");
    return o.gasPrice ?? (MIN * 11n) / 10n;
  },
  getBlock: async () => {
    if (o.blockThrows) throw new Error("rpc");
    return { minimumGasPrice: o.min };
  },
});

describe("userTxGas", () => {
  it("Rootstock: legacy tx at the block minimum + 1 %, rounded up", async () => {
    expect(USER_GAS_PRICE_MULT_BPS).toBe(10_100);
    expect(await userTxGas(reader({ min: "0x1699280" }), 30)).toEqual({ type: "legacy", gasPrice: 23_932_960n });
    expect(await userTxGas(reader({ min: 23_696_001n }), 31)).toEqual({ type: "legacy", gasPrice: 23_932_962n });
  });
  it("no block field: eth_gasPrice / 1.1 × 1.01", async () => {
    expect(await userTxGas(reader({ gasPrice: 26_065_600n }), 30)).toEqual({ type: "legacy", gasPrice: 23_932_960n });
  });
  it("other chains, or both reads failing: leave pricing to the wallet", async () => {
    expect(await userTxGas(reader({ min: MIN }), 1)).toEqual({});
    expect(await userTxGas(reader({ blockThrows: true, priceThrows: true }), 30)).toEqual({});
  });
});

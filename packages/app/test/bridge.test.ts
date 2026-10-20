import { describe, expect, it } from "vitest";
import { maxUint256, type Address, type Hex } from "viem";

import { APPROVE_GAS_FALLBACK, BRIDGE_SOURCES, bridgeSource, NATIVE_USD_REF, ROOTSTOCK_USDT0, SEND_GAS_FALLBACK } from "../src/config/bridge";
import { TOKENS } from "../src/config/markets";
import { approveForBridge, approvalsNeeded, arrived, minReceived, nativeNeeded, quoteBridge, sendParamFor, sendToRootstock, toBytes32, withFeeBuffer, withGasBuffer, type BridgeClient } from "../src/lib/bridge";

const OWNER = "0x00000000000000000000000000000000000000a1" as Address;

describe("USD₮0 on-ramp table", () => {
  it("lands on the USD₮0 the markets pin, with unique chains and EIDs", () => {
    expect(ROOTSTOCK_USDT0.token).toBe(TOKENS[30]!["USD₮0"]!.address);
    expect(new Set(BRIDGE_SOURCES.map((s) => s.chain.id)).size).toBe(BRIDGE_SOURCES.length);
    expect(new Set(BRIDGE_SOURCES.map((s) => s.eid)).size).toBe(BRIDGE_SOURCES.length);
    for (const s of BRIDGE_SOURCES) {
      expect(s.token).toBe(s.token.toLowerCase());
      expect(s.oft).toBe(s.oft.toLowerCase());
      expect(s.eid).not.toBe(ROOTSTOCK_USDT0.eid);
    }
    expect(bridgeSource("ethereum")!.symbol).toBe("USDT");
    for (const k of ["ethereum", "arbitrum", "monad", "hyperevm"]) expect(bridgeSource(k)).toBeDefined();
  });
});

describe("send parameters", () => {
  it("always sends to the owner's own bytes32 on Rootstock with empty options", () => {
    const p = sendParamFor(OWNER, 25_000_000n, 24_990_000n);
    expect(p).toEqual({ dstEid: 30333, to: toBytes32(OWNER), amountLD: 25_000_000n, minAmountLD: 24_990_000n, extraOptions: "0x", composeMsg: "0x", oftCmd: "0x" });
    expect(toBytes32(OWNER)).toBe(`0x${"0".repeat(24)}${OWNER.slice(2)}`);
  });
  it("refuses a quote that credits more than sent or loses more than 0.5 %", () => {
    expect(minReceived(1_000_000n, 1_000_000n)).toBe(1_000_000n);
    expect(minReceived(1_000_000n, 995_000n)).toBe(995_000n);
    expect(minReceived(1_000_000n, 994_999n)).toBeNull();
    expect(minReceived(1_000_000n, 1_000_001n)).toBeNull();
    expect(withFeeBuffer(1000n)).toBe(1100n);
    expect(arrived(5n, 15n, 10n)).toBe(true);
    expect(arrived(5n, 14n, 10n)).toBe(false);
  });
});

/** A scripted chain: records writes, answers reads. */
function fake(over: { approvalRequired?: boolean; allowance?: bigint; received?: bigint; estimate?: bigint | "revert"; native?: bigint } = {}) {
  const writes: Array<{ functionName: string; args: readonly unknown[]; value?: bigint }> = [];
  const estimates: Array<{ functionName: string; value?: bigint }> = [];
  const c: BridgeClient = {
    async estimateGas(a) {
      estimates.push({ functionName: a.functionName, value: a.value });
      if (over.estimate === "revert") throw new Error("execution reverted");
      return over.estimate ?? 300_000n;
    },
    gasPrice: async () => 10n,
    nativeBalance: async () => over.native ?? 10n ** 18n,
    async read<T>(a: { functionName: string; args?: readonly unknown[] }): Promise<T> {
      switch (a.functionName) {
        case "balanceOf":
          return 100_000_000n as T;
        case "approvalRequired":
          return (over.approvalRequired ?? false) as T;
        case "allowance":
          return (over.allowance ?? 0n) as T;
        case "quoteOFT": {
          const sp = a.args![0] as { amountLD: bigint };
          return [{}, [], { amountSentLD: sp.amountLD, amountReceivedLD: over.received ?? sp.amountLD }] as T;
        }
        case "quoteSend":
          return { nativeFee: 1_000n, lzTokenFee: 0n } as T;
      }
      throw new Error(a.functionName);
    },
    async write(a) {
      writes.push({ functionName: a.functionName, args: a.args, ...(a.value !== undefined ? { value: a.value } : {}) });
      return `0x${"11".repeat(32)}` as Hex;
    },
    waitForReceipt: async () => ({ status: "success" }),
  };
  return { c, writes, estimates };
}

describe("bridge steps", () => {
  const arb = bridgeSource("arbitrum")!;
  const eth = bridgeSource("ethereum")!;

  it("an OFT without approval: quote, then one payable send with the buffered fee", async () => {
    const { c, writes } = fake();
    const q = await quoteBridge(c, arb, OWNER, 25_000_000n);
    expect(q).toMatchObject({ amountLD: 25_000_000n, minAmountLD: 25_000_000n, nativeFee: 1_100n, approvalRequired: false, allowance: maxUint256 });
    await approveForBridge(c, arb, q);
    await sendToRootstock(c, arb, OWNER, q);
    expect(writes).toEqual([
      { functionName: "send", args: [sendParamFor(OWNER, 25_000_000n, 25_000_000n), { nativeFee: 1_100n, lzTokenFee: 0n }, OWNER], value: 1_100n },
    ]);
  });

  it("the Ethereum adapter: exact approval, and USDT's zero-reset when an old allowance stands", async () => {
    const fresh = fake({ approvalRequired: true });
    const q = await quoteBridge(fresh.c, eth, OWNER, 25_000_000n);
    await approveForBridge(fresh.c, eth, q);
    expect(fresh.writes).toEqual([{ functionName: "approve", args: [eth.oft, 25_000_000n] }]);

    const stale = fake({ approvalRequired: true, allowance: 3n });
    const q2 = await quoteBridge(stale.c, eth, OWNER, 25_000_000n);
    await approveForBridge(stale.c, eth, q2);
    expect(stale.writes.map((w) => w.args[1])).toEqual([0n, 25_000_000n]);

    const enough = fake({ approvalRequired: true, allowance: 30_000_000n });
    await approveForBridge(enough.c, eth, await quoteBridge(enough.c, eth, OWNER, 25_000_000n));
    expect(enough.writes).toEqual([]);
  });

  it("prices gas: a live send estimate when it can run, the measured fallbacks otherwise", async () => {
    const live = fake({ estimate: 300_000n });
    const q = await quoteBridge(live.c, arb, OWNER, 25_000_000n);
    expect(live.estimates).toEqual([{ functionName: "send", value: 1_100n }]);
    expect(q).toMatchObject({ approvals: 0, gasEstimated: true, gasCost: withGasBuffer(300_000n * 10n), nativeBalance: 10n ** 18n });
    expect(nativeNeeded(q)).toBe(1_100n + withGasBuffer(3_000_000n));

    // Pending approval: the send would revert, so nothing is simulated.
    const stale = fake({ approvalRequired: true, allowance: 3n });
    const q2 = await quoteBridge(stale.c, eth, OWNER, 25_000_000n);
    expect(stale.estimates).toEqual([]);
    expect(q2).toMatchObject({ approvals: 2, gasEstimated: false, gasCost: withGasBuffer((SEND_GAS_FALLBACK + 2n * APPROVE_GAS_FALLBACK) * 10n) });

    // A node that will not simulate, and a wallet too poor to: fallback, not an error.
    expect(await quoteBridge(fake({ estimate: "revert" }).c, arb, OWNER, 25_000_000n)).toMatchObject({ gasEstimated: false, gasCost: withGasBuffer(SEND_GAS_FALLBACK * 10n) });
    const poor = fake({ native: 0n });
    expect(await quoteBridge(poor.c, arb, OWNER, 25_000_000n)).toMatchObject({ gasEstimated: false, nativeBalance: 0n });
    expect(poor.estimates).toEqual([]);

    expect([approvalsNeeded(false, 0n, 5n), approvalsNeeded(true, 0n, 5n), approvalsNeeded(true, 1n, 5n), approvalsNeeded(true, 5n, 5n)]).toEqual([0, 1, 2, 0]);
  });

  it("every source's native coin has a USD reference, except Mantle's (unlisted)", () => {
    for (const s of BRIDGE_SOURCES) {
      const ref = NATIVE_USD_REF[s.chain.nativeCurrency.symbol];
      if (s.key === "mantle") expect(ref).toBeUndefined();
      else expect(ref?.token).toBe(ref?.token.toLowerCase());
    }
  });

  it("refuses to send when the quote credits suspiciously little", async () => {
    const { c } = fake({ received: 20_000_000n });
    await expect(quoteBridge(c, arb, OWNER, 25_000_000n)).rejects.toThrow(/unexpected amount/);
  });
});

import { describe, expect, it } from "vitest";
import { OrderSide, SETTLEMENT_LENS_ABI, hashOrderStruct, orderTypedData, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { encodeFunctionData, zeroAddress, type Hex, type PublicClient } from "viem";

import { Verifier, OrderStatus } from "../src/verify";
import type { OrderAnnounce } from "../src/messages";
import { toDeployment } from "../src/config";

/**
 * F29 P1/P2. The Verifier's Layer 2 used to hand the AUTHORING `Order` to the lens
 * ABI, which takes the WIRE order (packed `bytes` legs, `uint256 params`); viem's
 * encoder threw and every `POST /orders` 500'd against a real lens — invisible
 * because the only tests stubbed `readContract` past the encoder. This stub
 * ENCODES what it is handed with the real ABI before answering, so the call
 * shape is exercised even without a chain. It also fakes an honest verdict so
 * the cache-key test can show a re-announce with a different `sig` is NOT served
 * the cached verdict (P2).
 */
const config = { chainId: 31, settlement: "0x0000000000000000000000000000000000000001" as const, permit3: zeroAddress, lens: zeroAddress, rpcUrl: "" };
const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

function orderFor(nonce = 1n): Order {
  return {
    maker: account.address,
    side: OrderSide.SELL,
    nonce,
    expiry: 4_000_000_000n,
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 800n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    baselinePriorityFeeWei: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };
}

function encodingClient(calls: { functionName: string; sigs: Hex[] }[]): PublicClient {
  return {
    readContract: async (args: { abi: unknown; functionName: string; args: unknown[] }) => {
      // The real encoder: throws exactly where the old code threw.
      encodeFunctionData({ abi: SETTLEMENT_LENS_ABI, functionName: args.functionName as never, args: args.args as never });
      const sigs = args.args[1] as Hex[];
      calls.push({ functionName: args.functionName, sigs });
      const n = (args.args[0] as unknown[]).length;
      // Fillable, signature valid iff the sig is 65 bytes (a stand-in for "the lens checked it").
      return [
        new Array(n).fill(OrderStatus.Fillable),
        new Array(n).fill(1000n),
        sigs.map((s) => s.length === 132),
        new Array(n).fill(true),
      ];
    },
  } as unknown as PublicClient;
}

describe("Verifier — Layer 2 wire shape and cache identity", () => {
  it("packs the order before calling the lens (P1)", async () => {
    const calls: { functionName: string; sigs: Hex[] }[] = [];
    const v = new Verifier(encodingClient(calls), config);
    const res = await v.verifyLayer2([{ order: orderFor(), sig: "0x", sigless: true }]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.functionName).toBe("getOrderRelevantStates");
    expect(res[0]!.status).toBe(OrderStatus.Fillable);
  });

  it("does not serve one announce's verdict to a re-announce with a different sig (P2)", async () => {
    const calls: { functionName: string; sigs: Hex[] }[] = [];
    const v = new Verifier(encodingClient(calls), config);
    const order = orderFor();
    const good = await account.signTypedData(orderTypedData(order, toDeployment(config)) as never);
    const honest: OrderAnnounce = { order, sig: good };
    const first = await v.verifyAnnounce(honest);
    expect(first.ok).toBe(true);
    expect(calls).toHaveLength(1);

    // Same hash, `sigless` re-announce by a stranger: MUST hit the lens again
    // under its own key, not inherit the honest verdict.
    const poison: OrderAnnounce = { order, sig: "0x", sigless: true };
    await v.verifyAnnounce(poison);
    expect(calls).toHaveLength(2);
    expect(calls[1]!.sigs[0]).toBe("0x");
    expect(hashOrderStruct(order)).toBe(first.orderHash);
  });
});

import { describe, expect, it } from "vitest";
import { decodeFunctionData } from "viem";

import {
  SETTLEMENT_ABI,
  MULTI_OUTPUT_SOLVER_ABI,
  MULTI_INPUT_SOLVER_ABI,
  encodeFill,
  encodeFillWithPermit,
  encodeCancelOrders,
  encodeExecuteFillMultiInput,
  encodeExecuteFillMultiOutput,
  permitBatch,
  tokenPermit,
  type OutputLeg,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";
import { packOrder } from "../src";

const SIG = ("0x" + "11".repeat(65)) as `0x${string}`;

describe("calldata builders round-trip", () => {
  it("fill encodes and decodes", () => {
    const data = encodeFill(CANONICAL_ORDER, SIG, 123n);
    const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
    expect(functionName).toBe("fill");
    expect((args as any)[2]).toBe(123n);
    // The order crosses the wire PACKED, so the decoded members are blobs, not
    // arrays. Assert the exact bytes the packer produced — a length check on a
    // hex string would pass for almost any encoding.
    const wire = packOrder(CANONICAL_ORDER);
    expect((args as any)[0].legsIn).toBe(wire.legsIn);
    expect((args as any)[0].items).toBe(wire.items);
    // ...and that the blobs really are count-prefixed as the contract expects.
    expect((args as any)[0].legsIn.slice(0, 4)).toBe("0x02"); // two input legs
    expect((args as any)[0].items.slice(0, 4)).toBe("0x02"); // two items
  });

  it("fillWithPermit encodes and decodes", () => {
    const batch = permitBatch([tokenPermit(CANONICAL_ORDER.maker, CANONICAL_ORDER.legsIn[0]!.token, 1n, 1)], [], 0n, 9n);
    const data = encodeFillWithPermit(CANONICAL_ORDER, batch, SIG, 456n);
    const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
    expect(functionName).toBe("fillWithPermit");
    expect((args as any)[3]).toBe(456n);
    expect((args as any)[1].tokens.length).toBe(1);
  });

  it("cancelOrders encodes and decodes", () => {
    const data = encodeCancelOrders([1n, 2n, 3n]);
    const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
    expect(functionName).toBe("cancelOrders");
    expect((args as any)[0]).toEqual([1n, 2n, 3n]);
  });

  it("multi-input executeFill encodes and decodes", () => {
    const data = encodeExecuteFillMultiInput({
      flashSource: CANONICAL_ORDER.legsOut[0]!.token,
      flashAmount: 1n,
      order: CANONICAL_ORDER,
      sig: SIG,
      fillAmountIn: 2n,
      dexFees: [500, 3000],
      minSwapOuts: [0n, 0n],
    });
    const { functionName, args } = decodeFunctionData({ abi: MULTI_INPUT_SOLVER_ABI, data });
    expect(functionName).toBe("executeFill");
    expect((args as any)[5]).toEqual([500, 3000]);
  });

  it("multi-output executeFill encodes and decodes", () => {
    const legs: OutputLeg[] = [
      { token: CANONICAL_ORDER.legsOut[0]!.token, flashAmount: 1n, dexFee: 500, spendIn: 2n, minOut: 1n },
    ];
    const data = encodeExecuteFillMultiOutput({ order: CANONICAL_ORDER, sig: SIG, fillAmountIn: 7n, legs });
    const { functionName, args } = decodeFunctionData({ abi: MULTI_OUTPUT_SOLVER_ABI, data });
    expect(functionName).toBe("executeFill");
    expect((args as any)[2]).toBe(7n);
    expect((args as any)[3][0].dexFee).toBe(500);
  });
});

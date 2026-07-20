import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { getAddress, recoverTypedDataAddress } from "viem";

import {
  hashOrderStruct,
  orderTypedData,
  permitWitnessTypedData,
  permitBatch,
  tokenPermit,
  takerPermit,
  refOf,
  type Deployment,
} from "../src";
import { CANONICAL_ORDER, GOLDEN_ORDER_HASH } from "./canonicalOrder";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const DEPLOYMENT: Deployment = {
  chainId: 1,
  settlement: getAddress("0x00000000000000000000000000000000000000a1"),
  permit3: getAddress("0x00000000000000000000000000000000000000b2"),
};

describe("EIP-712 parity", () => {
  it("order hashStruct matches the on-chain golden (cross-verifies typed-data defs)", () => {
    expect(hashOrderStruct(CANONICAL_ORDER)).toBe(GOLDEN_ORDER_HASH);
  });

  it("order signature recovers to the signer (fill path)", async () => {
    const td = orderTypedData(CANONICAL_ORDER, DEPLOYMENT);
    const sig = await account.signTypedData(td as any);
    const recovered = await recoverTypedDataAddress({ ...(td as any), signature: sig });
    expect(recovered).toBe(account.address);
  });

  it("permit-witness signature recovers to the signer (fillWithPermit path)", async () => {
    const batch = permitBatch(
      [tokenPermit(DEPLOYMENT.settlement, CANONICAL_ORDER.legsIn[0]!.token, 2_000_000_000n, 2_000_000_000)],
      [takerPermit(DEPLOYMENT.settlement, refOf(CANONICAL_ORDER.items[1]!.data), 1_500_000_000n, 2_000_000_000)],
      0n,
      1_000_000n,
    );
    const td = permitWitnessTypedData(batch, CANONICAL_ORDER, DEPLOYMENT);
    const sig = await account.signTypedData(td as any);
    const recovered = await recoverTypedDataAddress({ ...(td as any), signature: sig });
    expect(recovered).toBe(account.address);
  });
});

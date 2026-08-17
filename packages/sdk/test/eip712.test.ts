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
import { ORDER_TYPE, ORDER_TYPESTRING, packOrder } from "../src";

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
      [
        takerPermit(
          DEPLOYMENT.settlement,
          CANONICAL_ORDER.items[1]!.module,
          refOf(CANONICAL_ORDER.items[1]!.data),
          1_500_000_000n,
          2_000_000_000,
        ),
      ],
      0n,
      1_000_000n,
    );
    const td = permitWitnessTypedData(batch, CANONICAL_ORDER, DEPLOYMENT);
    const sig = await account.signTypedData(td as any);
    const recovered = await recoverTypedDataAddress({ ...(td as any), signature: sig });
    expect(recovered).toBe(account.address);
  });
});

describe("encoding is pinned to the contract, not just to itself", () => {
  // The canonical-hash test above compares against a constant duplicated in
  // HashGolden.t.sol. That duplication once let this file drift two migrations
  // behind the contract while both suites stayed green. These assertions pin the
  // SHAPE independently, so a field added, removed or re-typed on one side fails
  // here even if someone updates the golden constant to match themselves.
  it("ORDER_TYPE matches the contract's literal typestring", () => {
    const members = ORDER_TYPE.map((f) => `${f.type} ${f.name}`).join(",");
    expect(`Order(${members})`).toBe(ORDER_TYPESTRING);
  });

  it("the array members are packed bytes, and `side` is not a member", () => {
    // The contract carries these as packed blobs; typing them as struct arrays
    // is precisely the drift that broke signing.
    for (const name of ["legsIn", "legsOut", "curve", "items", "validators", "invariants"]) {
      const f = ORDER_TYPE.find((x) => x.name === name);
      expect(f, `${name} missing`).toBeDefined();
      expect(f!.type, `${name} must be bytes`).toBe("bytes");
    }
    expect(ORDER_TYPE.find((x) => x.name === "side"), "`side` belongs in timing bit 101").toBeUndefined();
  });

  it("packOrder folds `side` into timing bit 101 and refuses a pre-set bit", () => {
    const wire = packOrder(CANONICAL_ORDER);
    expect((wire.timing >> 101n) & 1n).toBe(BigInt(CANONICAL_ORDER.side));
    expect(wire.timing & 0xffffffffn).toBe(CANONICAL_ORDER.timing & 0xffffffffn); // clocks preserved
    expect(() => packOrder({ ...CANONICAL_ORDER, timing: 1n << 101n })).toThrow(/bit 101/);
  });

  it("an empty packed array is the single byte 0x00", () => {
    const wire = packOrder({ ...CANONICAL_ORDER, items: [], validators: [], invariants: [], curve: [] });
    expect(wire.items).toBe("0x00");
    expect(wire.validators).toBe("0x00");
    expect(wire.curve).toBe("0x00");
  });
});

import { describe, expect, it } from "vitest";
import { decodeFunctionData, getAddress, keccak256, recoverTypedDataAddress, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  PERMIT3_ABI,
  buildRevokeAll,
  encodeApproveTaker,
  encodeLockdownAll,
  encodePermitTake,
  encodeSetStrictMode,
  permitTake,
  permitTakeTypedData,
  refFor,
  signPermitTake,
  spenderRefPair,
  tokenSpenderPair,
  type Deployment,
} from "../src";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const DEPLOYMENT: Deployment = {
  chainId: 1,
  settlement: getAddress("0x00000000000000000000000000000000000000a1"),
  permit3: getAddress("0x00000000000000000000000000000000000000b2"),
};

const MODULE = getAddress("0x00000000000000000000000000000000000000c3");
const SPENDER = DEPLOYMENT.settlement;
const SIG = ("0x" + "11".repeat(65)) as `0x${string}`;

describe("Permit3 calldata builders round-trip", () => {
  it("approveTaker carries the module in the key", () => {
    const ref = refFor("0xdeadbeef");
    const data = encodeApproveTaker(SPENDER, MODULE, ref, 1_000_000n, 1_893_456_000);
    const { functionName, args } = decodeFunctionData({ abi: PERMIT3_ABI, data });
    expect(functionName).toBe("approveTaker");
    expect(args).toEqual([SPENDER, MODULE, ref, 1_000_000n, 1_893_456_000]);
  });

  it("refFor equals keccak256(data)", () => {
    expect(refFor("0xdeadbeef")).toBe(keccak256("0xdeadbeef"));
  });

  it("permitTake encodes its tuple", () => {
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, 7n, 1_893_456_000n);
    const data = encodePermitTake(p, account.address, account.address, "0xc0ffee", SIG);
    const { functionName, args } = decodeFunctionData({ abi: PERMIT3_ABI, data });
    expect(functionName).toBe("permitTake");
    expect((args as any)[0]).toEqual(p);
    expect((args as any)[4]).toBe(SIG);
  });

  it("setStrictMode encodes the bool", () => {
    const { args } = decodeFunctionData({ abi: PERMIT3_ABI, data: encodeSetStrictMode(true) });
    expect(args).toEqual([true]);
  });

  it("lockdownAll encodes both books and the nonce arrays", () => {
    const data = encodeLockdownAll(
      [tokenSpenderPair(MODULE, SPENDER)],
      [spenderRefPair(SPENDER, MODULE, refFor("0x01"))],
      [0n],
      [(1n << 5n) | (1n << 9n)],
    );
    const { functionName, args } = decodeFunctionData({ abi: PERMIT3_ABI, data });
    expect(functionName).toBe("lockdownAll");
    expect((args as any)[2]).toEqual([0n]);
    expect((args as any)[3]).toEqual([(1n << 5n) | (1n << 9n)]);
  });
});

describe("permitTake signature binds spender and recovers to signer", () => {
  it("recovers to the owner", async () => {
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, 7n, 1_893_456_000n);
    const td = permitTakeTypedData(p, SPENDER, DEPLOYMENT);
    const sig = await signPermitTake(account, p, SPENDER, DEPLOYMENT);
    const recovered = await recoverTypedDataAddress({ ...(td as any), signature: sig });
    expect(recovered).toBe(account.address);
  });

  it("a different spender changes the digest (leaked sig is useless elsewhere)", async () => {
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, 7n, 1_893_456_000n);
    const sig = await signPermitTake(account, p, SPENDER, DEPLOYMENT);
    const otherSpender = getAddress("0x00000000000000000000000000000000000000d4");
    const tdOther = permitTakeTypedData(p, otherSpender, DEPLOYMENT);
    const recovered = await recoverTypedDataAddress({ ...(tdOther as any), signature: sig });
    expect(recovered).not.toBe(account.address);
  });
});

describe("buildRevokeAll bundles the Permit3 side with protocol-native revokes", () => {
  it("puts lockdownAll first, then the protocol calls", () => {
    const aaveDebt = getAddress("0x00000000000000000000000000000000000000e5");
    const protocolRevoke = { to: aaveDebt, data: toHex("approveDelegation(module,0)") };
    const calls = buildRevokeAll({
      permit3: DEPLOYMENT.permit3,
      takers: [spenderRefPair(SPENDER, MODULE, refFor("0x01"))],
      nonces: [{ word: 0n, mask: 1n }],
      protocolRevokes: [protocolRevoke],
    });
    expect(calls).toHaveLength(2);
    expect(calls[0]!.to).toBe(DEPLOYMENT.permit3);
    expect(decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data }).functionName).toBe("lockdownAll");
    expect(calls[1]).toEqual(protocolRevoke);
  });

  it("omits the Permit3 call when there is nothing on that side", () => {
    const calls = buildRevokeAll({ permit3: DEPLOYMENT.permit3, protocolRevokes: [] });
    expect(calls).toHaveLength(0);
  });
});

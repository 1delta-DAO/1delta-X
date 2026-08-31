import { describe, expect, it } from "vitest";
import { decodeFunctionData, getAddress, keccak256, recoverTypedDataAddress, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  Permit3MessageKind,
  permit3Nonce,
  permit3NonceKind,
  permit3NonceMask,
  permit3NonceWord,
} from "../src/permit3nonce";
import { permitBatch } from "../src/permit";
import {
  PERMIT3_ABI,
  buildRevokeAll,
  buildStrictOnboarding,
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
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, permit3Nonce(Permit3MessageKind.Take, 7n), 1_893_456_000n);
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
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, permit3Nonce(Permit3MessageKind.Take, 7n), 1_893_456_000n);
    const td = permitTakeTypedData(p, SPENDER, DEPLOYMENT);
    const sig = await signPermitTake(account, p, SPENDER, DEPLOYMENT);
    const recovered = await recoverTypedDataAddress({ ...(td as any), signature: sig });
    expect(recovered).toBe(account.address);
  });

  it("a different spender changes the digest (leaked sig is useless elsewhere)", async () => {
    const p = permitTake(MODULE, refFor("0xc0ffee"), 500n, permit3Nonce(Permit3MessageKind.Take, 7n), 1_893_456_000n);
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

// The two-surface rule: `Permit3TransferLib.transferFromWithFallback` falls through
// to a plain `transferFrom` whenever the Permit3 leg fails — INCLUDING because it was
// revoked — so a bundle that clears only the hub has not revoked anything for a payer
// who also holds a direct approval. See docs/reference-audits.md, finding F1.
describe("buildRevokeAll closes the direct-approval fallback too", () => {
  const TOKEN = getAddress("0x00000000000000000000000000000000000000d4");

  it("zeroes the direct ERC-20 approval, addressed to the token not the hub", () => {
    const calls = buildRevokeAll({
      permit3: DEPLOYMENT.permit3,
      tokens: [tokenSpenderPair(TOKEN, SPENDER)],
      directApprovals: [tokenSpenderPair(TOKEN, SPENDER)],
    });
    expect(calls).toHaveLength(2);
    expect(decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data }).functionName).toBe("lockdownAll");

    // The direct leg goes to the TOKEN — the hub has no authority over an allowance
    // it was never part of.
    const direct = calls[1]!;
    expect(direct.to).toBe(TOKEN);
    const decoded = decodeFunctionData({ abi: ERC20_ABI, data: direct.data });
    expect(decoded.functionName).toBe("approve");
    expect(decoded.args).toEqual([SPENDER, 0n]);
  });

  it("sets strict mode FIRST so an interleaved fill cannot use the fallback", () => {
    const calls = buildRevokeAll({
      permit3: DEPLOYMENT.permit3,
      tokens: [tokenSpenderPair(TOKEN, SPENDER)],
      directApprovals: [tokenSpenderPair(TOKEN, SPENDER)],
      strictMode: true,
    });
    expect(calls).toHaveLength(3);
    const first = decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data });
    expect(first.functionName).toBe("setStrictMode");
    expect(first.args).toEqual([true]);
    expect(calls[0]!.data).toBe(encodeSetStrictMode(true));
  });
});

describe("buildStrictOnboarding grants behind strict mode", () => {
  const TOKEN = getAddress("0x00000000000000000000000000000000000000d4");

  it("enables strict mode before the first grant", () => {
    const calls = buildStrictOnboarding({
      permit3: DEPLOYMENT.permit3,
      spender: SPENDER,
      tokens: [{ token: TOKEN, amount: 10n ** 24n, expiration: 0 }],
    });
    expect(calls).toHaveLength(2);
    expect(decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data }).functionName).toBe("setStrictMode");

    const grant = decodeFunctionData({ abi: PERMIT3_ABI, data: calls[1]!.data });
    expect(grant.functionName).toBe("approveToken");
    // expiration 0 == NEVER EXPIRES in Permit3 (the opposite of Permit2).
    expect(grant.args).toEqual([SPENDER, TOKEN, 10n ** 24n, 0]);
  });

  it("can be opted out of, for an integrator that wants the fallback", () => {
    const calls = buildStrictOnboarding({
      permit3: DEPLOYMENT.permit3,
      spender: SPENDER,
      tokens: [{ token: TOKEN, amount: 1n, expiration: 0 }],
      strictMode: false,
    });
    expect(calls).toHaveLength(1);
    expect(decodeFunctionData({ abi: PERMIT3_ABI, data: calls[0]!.data }).functionName).toBe("approveToken");
  });
});

const ERC20_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

// ──────────────────── Permit3 nonce namespacing (F23) ────────────────────
//
// `UnorderedNonces` keeps ONE bitmap per owner, shared by every signed flow, and
// says so: "nonce allocation must be per-owner, not per-message-type." Nothing
// enforced it, so an owner could sign a PermitBatch and a PermitTake onto one
// coordinate — and whoever held either unrelayed message could burn the bit and
// DoS the other (batch returns silently on a spent bit; take and transfer revert).
describe("Permit3 nonce namespacing", () => {
  it("keeps the kinds disjoint whatever seq each allocator picks", () => {
    const seqs = [0n, 1n, 7n, 255n, 1n << 200n, (1n << 248n) - 1n];
    const all = seqs.flatMap((s) => [
      permit3Nonce(Permit3MessageKind.Batch, s),
      permit3Nonce(Permit3MessageKind.Take, s),
      permit3Nonce(Permit3MessageKind.Transfer, s),
    ]);
    expect(new Set(all).size).toBe(all.length);
  });

  it("round-trips the kind", () => {
    for (const k of [Permit3MessageKind.Batch, Permit3MessageKind.Take, Permit3MessageKind.Transfer]) {
      expect(permit3NonceKind(permit3Nonce(k, 42n))).toBe(k);
    }
  });

  it("bounds seq to the 248 bits below the tag", () => {
    expect(() => permit3Nonce(Permit3MessageKind.Take, 1n << 248n)).toThrow(/out of range/);
    expect(() => permit3Nonce(Permit3MessageKind.Take, -1n)).toThrow(/out of range/);
  });

  // The guard is only worth anything at a point every message passes through —
  // the `assertOrderNonce` lesson from F23, where an exported-but-uncalled helper
  // read as a guarantee for months.
  it("is enforced by the builders, not merely exported", () => {
    expect(() => permitTake(MODULE, refFor("0xdeadbeef"), 1n, 7n, 0n)).toThrow(/expected Take/);
    expect(() => permitTake(MODULE, refFor("0xdeadbeef"), 1n, permit3Nonce(Permit3MessageKind.Transfer, 7n), 0n)).toThrow(
      /namespaced for Transfer, expected Take/,
    );
    expect(permitTake(MODULE, refFor("0xdeadbeef"), 1n, permit3Nonce(Permit3MessageKind.Take, 7n), 0n).nonce).toBe(
      permit3Nonce(Permit3MessageKind.Take, 7n),
    );
  });

  // Batch is kind 0 on purpose: a legacy small nonce stays valid, and it still
  // cannot collide with a properly allocated Take or Transfer.
  it("leaves legacy batch nonces working", () => {
    expect(permit3NonceKind(7n)).toBe(Permit3MessageKind.Batch);
    expect(permitBatch([], [], 7n, 0n).nonce).toBe(7n);
  });

  it("locates the bitmap coordinate for invalidateUnorderedNonces", () => {
    const n = permit3Nonce(Permit3MessageKind.Take, 259n);
    expect(permit3NonceWord(n)).toBe(n >> 8n);
    expect(permit3NonceMask(n)).toBe(1n << 3n);
  });
});

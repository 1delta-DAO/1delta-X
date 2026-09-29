import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { decodeFunctionData, getAddress, keccak256, recoverTypedDataAddress, toHex, zeroAddress, type Address } from "viem";

import {
  assertCanCancelOnChain,
  assertOrderNonce,
  buildOrderSignerPermit,
  buildOrderSignerRevocation,
  canRevokeOrderSignerGasless,
  encodeBurnSignerPermits,
  encodeRevokeOrderSigner,
  encodeRevokeOrderSigners,
  encodeSetOrderSignerWithSig,
  isReservedNonce,
  liveDelegates,
  nominateOrderSigner,
  packOrder,
  ORDER_SIGNER_PERMIT_TYPE,
  ORDER_SIGNER_PERMIT_TYPES,
  ORDER_SIGNER_PERMIT_TYPESTRING,
  ORDER_SIGNER_REVOKE_SEQ,
  orderSignerPermitTypedData,
  revokeOrderSignerGasless,
  SETTLEMENT_ABI,
  SIGNER_NONCE_NS,
  signerPermitCoordinate,
  signerPermitNonce,
  type ContractReader,
  type Deployment,
  type OrderSignerPermit,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const d: Deployment = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
};
// Checksummed: viem returns checksummed addresses from `decodeFunctionData`,
// so the fixtures must be in the same form or every round-trip assertion fails
// on casing alone.
const DELEGATE = getAddress("0x00000000000000000000000000000000000000d1");
const OTHER = getAddress("0x00000000000000000000000000000000000000d2");

describe("OrderSignerPermit typed data", () => {
  // The contract hashes the literal typestring into `_ORDER_SIGNER_TYPEHASH`. If
  // the field list here and the string there ever diverge, every relayed
  // nomination fails with an opaque InvalidSigner — so pin both to one hash.
  it("typestring matches the field list", () => {
    const built = `OrderSignerPermit(${ORDER_SIGNER_PERMIT_TYPE.map((f) => `${f.type} ${f.name}`).join(",")})`;
    expect(built).toBe(ORDER_SIGNER_PERMIT_TYPESTRING);
  });

  it("typehash matches the settler's _ORDER_SIGNER_TYPEHASH", () => {
    // Hard-coded from Signatures.sol so a field reorder here fails loudly.
    expect(keccak256(toHex(ORDER_SIGNER_PERMIT_TYPESTRING))).toBe(
      keccak256(
        toHex("OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)"),
      ),
    );
  });

  it("is signed in the Settlement domain and recovers to the maker", async () => {
    const { permit, sig } = await nominateOrderSigner(account, account.address, DELEGATE, 1n << 40n, d, {
      now: 1_000n,
    });
    const typed = orderSignerPermitTypedData(permit, d);
    expect(typed.domain.verifyingContract).toBe(d.settlement);
    expect(typed.domain.chainId).toBe(31);
    await expect(recoverTypedDataAddress({ ...(typed as never), signature: sig })).resolves.toBe(account.address);
  });

  it("defaults to a BOUNDED deadline, not a perpetual one", () => {
    // An unrelayed permit is a standing right to restore the delegate, so an
    // unbounded deadline is a permanent one. Default must expire.
    const p = buildOrderSignerPermit(account.address, DELEGATE, 1n, { now: 1_000n });
    expect(p.deadline).toBe(1_000n + 3600n);
    expect(p.deadline).toBeLessThan(2n ** 256n - 1n);
  });
});

describe("the reserved nonce half (SIGNER_NONCE_NS)", () => {
  it("is bit 255", () => {
    expect(SIGNER_NONCE_NS).toBe(2n ** 255n);
  });

  // The settler does NOT check this on the fill path, by design. If nothing
  // checks it here either, an allocator can silently collide an order with a
  // nomination permit — the whole reason the namespace exists.
  it("rejects an order nonce with bit 255 set", () => {
    expect(() => assertOrderNonce(0n)).not.toThrow();
    expect(() => assertOrderNonce((1n << 254n) | 7n)).not.toThrow();
    expect(() => assertOrderNonce(SIGNER_NONCE_NS)).toThrow(/bit 255/);
    expect(() => assertOrderNonce(SIGNER_NONCE_NS | 42n)).toThrow(/reserved/);
    expect(() => assertOrderNonce(-1n)).toThrow(/out of range/);
    expect(isReservedNonce(SIGNER_NONCE_NS | 1n)).toBe(true);
    expect(isReservedNonce(2n ** 254n)).toBe(false);
  });

  // Permit nonces must never be legal ORDER nonces once namespaced, and must be
  // recomputable from the delegate alone — that is what makes revocation work
  // without any stored bookkeeping.
  it("derives a permit coordinate deterministically from the delegate", () => {
    expect(signerPermitNonce(DELEGATE)).toBe(signerPermitNonce(DELEGATE));
    expect(signerPermitNonce(DELEGATE)).not.toBe(signerPermitNonce(OTHER));
    expect(signerPermitNonce(DELEGATE, 1)).not.toBe(signerPermitNonce(DELEGATE, 0));
    // The BARE nonce is a legal order-space value; only the coordinate is reserved.
    expect(isReservedNonce(signerPermitNonce(DELEGATE))).toBe(false);
    expect(isReservedNonce(signerPermitCoordinate(DELEGATE))).toBe(true);
    expect(signerPermitCoordinate(DELEGATE)).toBe(signerPermitNonce(DELEGATE) | SIGNER_NONCE_NS);
  });

  // ONE byte, not two: the settler enforces `nonce >> 8 === delegate`, so every
  // permit for a delegate shares that delegate's single bitmap word — which is
  // what lets one revocation retire all 256 of them.
  it("bounds seq to 8 bits", () => {
    expect(() => signerPermitNonce(DELEGATE, 0x100)).toThrow(/out of range/);
    expect(() => signerPermitNonce(DELEGATE, -1)).toThrow(/out of range/);
  });

  it("derives the nonce the settler will accept", () => {
    expect(signerPermitNonce(DELEGATE, 7) >> 8n).toBe(BigInt(DELEGATE));
    expect(signerPermitNonce(DELEGATE, 255) >> 8n).toBe(BigInt(DELEGATE));
  });
});

describe("revocation that sticks (M-1)", () => {
  // This used to emit a clear AND a burn, because `setOrderSigner(d, 0)` alone
  // left an unrelayed permit live. The settler now burns the delegate's whole
  // permit word inside that call, so the property no longer depends on the caller
  // reaching for this helper — and the helper is one call again.
  it("is a single registry clear", () => {
    const calls = encodeRevokeOrderSigner(DELEGATE);
    expect(calls).toHaveLength(1);

    const clear = decodeFunctionData({ abi: SETTLEMENT_ABI, data: calls[0] });
    expect(clear.functionName).toBe("setOrderSigner");
    expect(clear.args).toEqual([DELEGATE, 0n]);
  });
});

describe("gasless revocation on a reserved seq (L-2)", () => {
  // Nomination and revocation both defaulted to `seq ?? 0`, so a gasless
  // revocation landed on the coordinate a relayed nomination had already spent
  // (reverts `NonceCancelled`, every time), or one a pending renewal could spend
  // first (a delegate-run front-run). The revocation now has a slot of its own.
  it("never shares a coordinate with any nomination the builders will make", () => {
    const revoke = buildOrderSignerRevocation(account.address, DELEGATE, { now: 1_000n });
    expect(ORDER_SIGNER_REVOKE_SEQ).toBe(0xff);
    expect(revoke.expiry).toBe(0n);
    expect(revoke.nonce).toBe(signerPermitNonce(DELEGATE, ORDER_SIGNER_REVOKE_SEQ));
    expect(revoke.nonce).not.toBe(buildOrderSignerPermit(account.address, DELEGATE, 1n).nonce);
    for (let seq = 0; seq < ORDER_SIGNER_REVOKE_SEQ; seq++) {
      expect(buildOrderSignerPermit(account.address, DELEGATE, 1n, { seq }).nonce).not.toBe(revoke.nonce);
    }
    // Still the delegate's own word — the settler's `nonce >> 8 == signer` check.
    expect(revoke.nonce >> 8n).toBe(BigInt(DELEGATE));
    // Same bounded relay window as a nomination.
    expect(revoke.deadline).toBe(1_000n + 3600n);
  });

  it("nomination builders refuse the reserved seq", async () => {
    expect(() => buildOrderSignerPermit(account.address, DELEGATE, 1n, { seq: ORDER_SIGNER_REVOKE_SEQ })).toThrow(
      /reserved for revocation/,
    );
    await expect(
      nominateOrderSigner(account, account.address, DELEGATE, 1n, d, { seq: ORDER_SIGNER_REVOKE_SEQ }),
    ).rejects.toThrow(/reserved for revocation/);
    expect(() => buildOrderSignerPermit(account.address, DELEGATE, 1n, { seq: 254 })).not.toThrow();
  });

  // Refused, not rerouted: an explicit nomination-range `seq` on a revocation is
  // exactly the collision this fixes, so there is no spelling that allows it.
  it("nomination builders refuse expiry 0n and point at the revocation builder", async () => {
    expect(() => buildOrderSignerPermit(account.address, DELEGATE, 0n)).toThrow(/buildOrderSignerRevocation/);
    expect(() => buildOrderSignerPermit(account.address, DELEGATE, 0n, { seq: 3 })).toThrow(/is a revocation/);
    await expect(nominateOrderSigner(account, account.address, DELEGATE, 0n, d)).rejects.toThrow(
      /buildOrderSignerRevocation/,
    );
  });

  it("is an ordinary OrderSignerPermit: same typed data, maker-signed, relayed by setOrderSignerWithSig", async () => {
    const { permit, sig } = await revokeOrderSignerGasless(account, account.address, DELEGATE, d, { now: 1_000n });
    const typed = orderSignerPermitTypedData(permit, d);
    expect(typed.types).toBe(ORDER_SIGNER_PERMIT_TYPES);
    expect(typed.primaryType).toBe("OrderSignerPermit");
    await expect(recoverTypedDataAddress({ ...typed, signature: sig } as never)).resolves.toBe(account.address);

    const call = decodeFunctionData({ abi: SETTLEMENT_ABI, data: encodeSetOrderSignerWithSig(permit, sig) });
    expect(call.functionName).toBe("setOrderSignerWithSig");
    expect(call.args).toEqual([account.address, DELEGATE, 0n, permit.nonce, permit.deadline, sig]);
  });

  // A model of the settler's permit bookkeeping — Signatures.setOrderSignerWithSig
  // (namespaced coordinate, NonceCancelled, consume) and OrderState._setOrderSigner
  // (expiry 0 burns the delegate's whole word) — replaying the three PoC orderings.
  it("lands after a relayed default nomination and after a front-run renewal; not after a direct re-nomination", () => {
    const burned = new Set<bigint>(); // namespaced coordinates
    const expiryOf = new Map<string, bigint>();
    const relay = (p: OrderSignerPermit) => {
      const coord = p.nonce | SIGNER_NONCE_NS;
      if (burned.has(coord)) throw new Error("NonceCancelled");
      burned.add(coord);
      direct(p.signer, p.expiry);
    };
    const direct = (signer: Address, expiry: bigint) => {
      expiryOf.set(signer, expiry);
      if (expiry === 0n) for (let s = 0; s <= 0xff; s++) burned.add(signerPermitCoordinate(signer, s));
    };

    // (1) nominate at the default seq, relayed; revoke with defaults.
    relay(buildOrderSignerPermit(account.address, DELEGATE, 5_000n));
    expect(() => relay(buildOrderSignerRevocation(account.address, DELEGATE))).not.toThrow();
    expect(expiryOf.get(DELEGATE)).toBe(0n);

    // (2) the delegate front-runs with a pending renewal; the revocation still lands.
    const renewal = buildOrderSignerPermit(account.address, OTHER, 9_000n, { seq: 1 });
    relay(buildOrderSignerPermit(account.address, OTHER, 5_000n));
    relay(renewal);
    relay(buildOrderSignerRevocation(account.address, OTHER));
    expect(expiryOf.get(OTHER)).toBe(0n);
    expect(() => relay(renewal)).toThrow("NonceCancelled");

    // (3) revoked, then re-nominated DIRECTLY: the word stays burned, so gasless
    // revocation is gone and only the direct setter can revoke again.
    direct(DELEGATE, 5_000n);
    expect(() => relay(buildOrderSignerRevocation(account.address, DELEGATE))).toThrow("NonceCancelled");
  });

  it("canRevokeOrderSignerGasless reads the reserved coordinate on the settler", async () => {
    const calls: unknown[] = [];
    const reader = (spent: boolean): ContractReader => ({
      readContract: async (args) => {
        calls.push(args);
        return spent;
      },
    });
    await expect(canRevokeOrderSignerGasless(reader(false), account.address, DELEGATE, d)).resolves.toBe(true);
    await expect(canRevokeOrderSignerGasless(reader(true), account.address, DELEGATE, d)).resolves.toBe(false);
    expect(calls[0]).toMatchObject({
      address: d.settlement,
      functionName: "isNonceCancelled",
      args: [account.address, signerPermitCoordinate(DELEGATE, ORDER_SIGNER_REVOKE_SEQ)],
    });
  });
});

describe("bulk revocation (M-3)", () => {
  it("expands to one clear per delegate", () => {
    expect(encodeRevokeOrderSigners([DELEGATE, OTHER])).toHaveLength(2);
  });

  // There is no on-chain enumeration of delegates, so a maker who has lost the
  // list must rebuild it from events or they cannot contain a compromised desk.
  it("recovers the live delegate set from OrderSignerSet logs, last write wins", () => {
    const logs = [
      { args: { signer: DELEGATE, expiry: 5_000n } },
      { args: { signer: OTHER, expiry: 5_000n } },
      { args: { signer: DELEGATE, expiry: 0n } }, // revoked later
    ];
    expect(liveDelegates(logs, 1_000n)).toEqual([OTHER]);
  });

  it("treats a lapsed expiry as not live, but 0n as 'ignore expiry'", () => {
    const logs = [{ args: { signer: DELEGATE, expiry: 500n } }];
    expect(liveDelegates(logs, 1_000n)).toEqual([]);
    expect(liveDelegates(logs, 0n)).toEqual([DELEGATE]);
  });
});

describe("the cancel asymmetry (L-5)", () => {
  // Nonce cancels called by a non-maker do NOT revert on-chain; they cancel the
  // caller's own nonces and emit an event that looks like success. The guard is
  // the only place that can say so before the transaction is built.
  it("refuses to build a cancel for someone else's orders", () => {
    expect(() => assertCanCancelOnChain(account.address, account.address)).not.toThrow();
    expect(() => assertCanCancelOnChain(DELEGATE, account.address)).toThrow(/keyed by msg.sender/);
    expect(() => assertCanCancelOnChain(DELEGATE, account.address)).toThrow(/do NOT revert/);
  });

  it("is case-insensitive on the address comparison", () => {
    expect(() => assertCanCancelOnChain(account.address.toLowerCase() as never, account.address)).not.toThrow();
  });
});

// ──────────────── the reserved nonce half is enforced where orders are BUILT ────────────────

describe("order nonces cannot enter the signer-permit namespace", () => {
  // The settler does not range-check order nonces — that would tax every fill
  // forever to guard a range no allocator picks — so `packOrder` is the only place
  // the invariant can be enforced end to end. Before this, `assertOrderNonce`
  // existed and nothing called it: the guard was written, exported, documented as
  // "call this wherever order nonces are allocated", and never wired in.
  it("packOrder rejects a nonce with bit 255 set", () => {
    const o = { ...CANONICAL_ORDER, nonce: SIGNER_NONCE_NS };
    expect(() => packOrder(o)).toThrow(/bit 255 set/);
  });

  it("packOrder rejects a nonce that merely happens to be huge", () => {
    const o = { ...CANONICAL_ORDER, nonce: (1n << 255n) | 7n };
    expect(() => packOrder(o)).toThrow(/reserved for OrderSignerPermit/);
  });

  it("packOrder accepts the largest legal order nonce", () => {
    const o = { ...CANONICAL_ORDER, nonce: (1n << 255n) - 1n };
    expect(() => packOrder(o)).not.toThrow();
  });

  // The permit's own coordinate is the mirror image: always in the reserved half,
  // and never reachable by an order that passed the guard above.
  it("a signer-permit coordinate is always in the half orders cannot reach", () => {
    const coord = signerPermitCoordinate("0x00000000000000000000000000000000000000aa" as `0x${string}`, 3);
    expect(isReservedNonce(coord)).toBe(true);
    expect(() => assertOrderNonce(coord)).toThrow();
  });
});

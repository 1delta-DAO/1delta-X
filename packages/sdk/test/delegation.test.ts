import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { decodeFunctionData, getAddress, keccak256, recoverTypedDataAddress, toHex, zeroAddress } from "viem";

import {
  assertCanCancelOnChain,
  assertOrderNonce,
  buildOrderSignerPermit,
  encodeBurnSignerPermits,
  encodeRevokeOrderSigner,
  encodeRevokeOrderSigners,
  encodeSetOrderSignerWithSig,
  isReservedNonce,
  liveDelegates,
  nominateOrderSigner,
  ORDER_SIGNER_PERMIT_TYPE,
  ORDER_SIGNER_PERMIT_TYPESTRING,
  orderSignerPermitTypedData,
  SETTLEMENT_ABI,
  SIGNER_NONCE_NS,
  signerPermitCoordinate,
  signerPermitNonce,
  type Deployment,
} from "../src";

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

  it("bounds seq to 16 bits", () => {
    expect(() => signerPermitNonce(DELEGATE, 0x10000)).toThrow(/out of range/);
    expect(() => signerPermitNonce(DELEGATE, -1)).toThrow(/out of range/);
  });
});

describe("revocation that sticks (M-1)", () => {
  // setOrderSigner(d, 0) alone leaves an unrelayed permit live: whoever holds it
  // can re-nominate. Revocation must ALSO burn the permit's coordinate.
  it("emits both the registry clear and the permit burn", () => {
    const calls = encodeRevokeOrderSigner(DELEGATE);
    expect(calls).toHaveLength(2);

    const clear = decodeFunctionData({ abi: SETTLEMENT_ABI, data: calls[0] });
    expect(clear.functionName).toBe("setOrderSigner");
    expect(clear.args).toEqual([DELEGATE, 0n]);

    const burn = decodeFunctionData({ abi: SETTLEMENT_ABI, data: calls[1] });
    expect(burn.functionName).toBe("cancelOrders");
    expect(burn.args).toEqual([[signerPermitCoordinate(DELEGATE)]]);
  });

  it("burns every seq it is told about", () => {
    const burn = decodeFunctionData({ abi: SETTLEMENT_ABI, data: encodeBurnSignerPermits(DELEGATE, [0, 1, 2]) });
    expect(burn.args).toEqual([[0, 1, 2].map((s) => signerPermitCoordinate(DELEGATE, s))]);
  });

  // The burn must target the reserved half — burning the BARE nonce would cancel
  // a live order instead, which is the exact collision the namespace prevents.
  it("burns only reserved coordinates, never order nonces", () => {
    const burn = decodeFunctionData({ abi: SETTLEMENT_ABI, data: encodeBurnSignerPermits(DELEGATE, [0, 5]) });
    for (const n of (burn.args as readonly bigint[][])[0]) expect(isReservedNonce(n)).toBe(true);
  });

  it("round-trips the relay calldata against the permit", async () => {
    const { permit, sig } = await nominateOrderSigner(account, account.address, DELEGATE, 99n, d, { now: 1n });
    const decoded = decodeFunctionData({ abi: SETTLEMENT_ABI, data: encodeSetOrderSignerWithSig(permit, sig) });
    expect(decoded.functionName).toBe("setOrderSignerWithSig");
    expect(decoded.args).toEqual([permit.maker, permit.signer, permit.expiry, permit.nonce, permit.deadline, sig]);
  });
});

describe("bulk revocation (M-3)", () => {
  it("expands to a clear + burn pair per delegate", () => {
    expect(encodeRevokeOrderSigners([DELEGATE, OTHER])).toHaveLength(4);
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

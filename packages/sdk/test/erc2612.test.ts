import { describe, expect, it } from "vitest";
import { decodeFunctionData, hashTypedData, recoverAddress, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  ERC2612_ABI,
  JsonBodyError,
  announceFromJson,
  announceToJson,
  encodeErc2612Permit,
  erc2612Digest,
  erc2612DomainOf,
  erc2612DomainSeparator,
  erc2612PermitFromJson,
  erc2612PermitToJson,
  erc2612TypedData,
  isCanonicalPermitSig,
  joinPermitSignature,
  splitPermitSignature,
  type Erc2612Permit,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

const USDT0 = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736" as Address;
const SETTLEMENT = "0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5" as Address;
const maker = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

describe("ERC-2612 permit helpers", () => {
  it("pins USD₮0's domain: the separator equals what the token returns on Rootstock mainnet", () => {
    const d = erc2612DomainOf(30, USDT0)!;
    expect(d).toEqual({ name: "USD₮0", version: "1", chainId: 30, verifyingContract: USDT0 });
    // `cast call 0x779D…3736 'DOMAIN_SEPARATOR()(bytes32)' -r https://public-node.rsk.co`, 2026-10-12.
    expect(erc2612DomainSeparator(d)).toBe("0x69a2c0bf1ca3b4903002efdc61f26c645d95c99c053fa05844259a47d2cc97ef");
    expect(erc2612DomainOf(30, "0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37")).toBeUndefined(); // USDRIF: no permit
    expect(erc2612DomainOf(1, USDT0)).toBeUndefined();
  });

  it("the digest from the ON-CHAIN separator equals the wallet's typed-data hash, and recovers the signer", async () => {
    const d = erc2612DomainOf(30, USDT0)!;
    const m = { owner: maker.address, spender: SETTLEMENT, value: 1_234_567n, nonce: 3n, deadline: 1_900_000_000n };
    const td = erc2612TypedData(d, m);
    const digest = erc2612Digest(erc2612DomainSeparator(d), maker.address, m);
    expect(digest).toBe(hashTypedData(td));
    const sig = await maker.signTypedData(td);
    const { v, r, s } = splitPermitSignature(sig);
    expect([27, 28]).toContain(v);
    expect(joinPermitSignature({ v, r, s })).toBe(sig);
    expect(isCanonicalPermitSig({ v, s })).toBe(true);
    expect(await recoverAddress({ hash: digest, signature: sig })).toBe(maker.address);

    const p: Erc2612Permit = { token: USDT0, spender: SETTLEMENT, value: m.value, nonce: m.nonce, deadline: m.deadline, v, r, s };
    const call = decodeFunctionData({ abi: ERC2612_ABI, data: encodeErc2612Permit(maker.address, p) });
    expect(call.functionName).toBe("permit");
    expect(call.args).toEqual([maker.address, SETTLEMENT, m.value, m.deadline, v, r, s]);
  });

  it("refuses v outside {27,28} and a high-s signature", () => {
    const s = "0x0000000000000000000000000000000000000000000000000000000000000001" as const;
    expect(isCanonicalPermitSig({ v: 0, s })).toBe(false);
    expect(isCanonicalPermitSig({ v: 27, s: "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" })).toBe(false);
    expect(isCanonicalPermitSig({ v: 28, s })).toBe(true);
  });
});

describe("announce JSON with an erc2612Permit", () => {
  const permit: Erc2612Permit = {
    token: USDT0,
    spender: SETTLEMENT,
    value: 5_000_000n,
    nonce: 0n,
    deadline: 1_900_000_000n,
    v: 27,
    r: `0x${"11".repeat(32)}`,
    s: `0x${"22".repeat(32)}`,
  };

  it("round-trips, with the permit last and only when present", () => {
    const order = CANONICAL_ORDER;
    const body = announceToJson({ order, sig: "0xabcd", erc2612Permit: permit });
    expect(Object.keys(body)).toEqual(["order", "sig", "erc2612Permit"]);
    const back = announceFromJson(JSON.parse(JSON.stringify(body)));
    expect(back.erc2612Permit).toEqual(permit);
    expect(back.order).toEqual(order);
    expect(Object.keys(announceToJson({ order, sig: "0x" }))).toEqual(["order", "sig"]);
    expect(announceFromJson(JSON.parse(JSON.stringify(announceToJson({ order, sig: "0x" })))).erc2612Permit).toBeUndefined();
  });

  it("parses strictly: unknown key, number value, bad v", () => {
    const j = erc2612PermitToJson(permit);
    expect(() => erc2612PermitFromJson({ ...j, extra: 1 })).toThrow(JsonBodyError);
    expect(() => erc2612PermitFromJson({ ...j, value: 5 })).toThrow(/decimal string/);
    expect(() => erc2612PermitFromJson({ ...j, v: 300 })).toThrow(/uint8/);
    expect(() => erc2612PermitFromJson({ ...j, r: "0x12" })).toThrow(/32-byte/);
  });
});

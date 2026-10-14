/**
 * Gasless funding with an ERC-2612 permit (lib/permit.ts): the maker signs a permit to
 * Settlement next to the order, it rides with the order to the book, and the filler
 * relays it. These pin what the app signs and sends.
 */
import {
  announceFromJson,
  erc2612DomainSeparator,
  erc2612Digest,
  joinPermitSignature,
  OrderSide,
  type Order,
} from "@1delta-x/sdk";
import { decodeFunctionData, erc20Abi, recoverAddress, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

import { encodeOrderBody } from "../src/backend/remote";
import type { Reader } from "../src/lib/chain";
import { hasLeftover, planGasless, revokeCalls } from "../src/lib/funding";
import { gaslessDomain, permitValue, signGaslessPermit } from "../src/lib/permit";

const USDT0 = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736" as Address;
const USDRIF = "0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37" as Address;
const SETTLEMENT = "0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5" as Address;
const PERMIT3 = "0xabaefb5ae495Dcbce40d1e057346f31A500668a8" as Address;
const maker = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

function order(): Order {
  return {
    maker: maker.address, side: OrderSide.SELL, nonce: 5n, expiry: 1_900_000_300n,
    legsIn: [{ token: USDT0, start: 25_000_000n, end: 0n }],
    legsOut: [{ token: USDRIF, start: 24n * 10n ** 18n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
  };
}

const usdt0Domain = gaslessDomain(30, USDT0)!;
const reader = (over: { ds?: Hex; nonce?: bigint } = {}): Reader => ({
  async readContract(a) {
    if (a.functionName === "DOMAIN_SEPARATOR") return over.ds ?? erc2612DomainSeparator(usdt0Domain);
    if (a.functionName === "nonces") return over.nonce ?? 3n;
    throw new Error(a.functionName);
  },
});

describe("gasless permit signing", () => {
  it("is offered for USD₮0 only (the one Rootstock pay token with EIP-2612)", () => {
    expect(gaslessDomain(30, USDT0)).toBeDefined();
    for (const t of [USDRIF, "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d", "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"] as Address[]) {
      expect(gaslessDomain(30, t)).toBeUndefined();
    }
  });

  it("signs exactly the order's input to Settlement, until the order's expiry, at the token's live nonce", async () => {
    const o = order();
    const p = await signGaslessPermit(maker as never, reader(), { chainId: 30, token: USDT0, owner: maker.address, settlement: SETTLEMENT, order: o });
    expect(p).toMatchObject({ token: USDT0, spender: SETTLEMENT, value: 25_000_000n, nonce: 3n, deadline: o.expiry });
    const digest = erc2612Digest(erc2612DomainSeparator(usdt0Domain), maker.address, p);
    expect(await recoverAddress({ hash: digest, signature: joinPermitSignature(p) })).toBe(maker.address);
  });

  it("refuses to sign when the token's domain is not the pinned one", async () => {
    await expect(
      signGaslessPermit(maker as never, reader({ ds: `0x${"00".repeat(32)}` }), { chainId: 30, token: USDT0, owner: maker.address, settlement: SETTLEMENT, order: order() }),
    ).rejects.toThrow(/permit domain/);
  });

  it("permitValue is the largest input leg amount in the token (rising inputs included)", () => {
    const o = { ...order(), legsIn: [{ token: USDT0, start: 10n, end: 30n }] };
    expect(permitValue(o, USDT0)).toBe(30n);
    expect(permitValue(o, USDRIF)).toBe(0n);
  });

  it("the POST /orders body carries the permit, and the SDK's strict parser accepts it", async () => {
    const o = order();
    const p = await signGaslessPermit(maker as never, reader(), { chainId: 30, token: USDT0, owner: maker.address, settlement: SETTLEMENT, order: o });
    const body = JSON.parse(encodeOrderBody({ order: o, sig: "0x1234", erc2612Permit: p }));
    expect(Object.keys(body)).toEqual(["order", "sig", "erc2612Permit"]);
    expect(announceFromJson(body).erc2612Permit).toEqual(p);
    expect(Object.keys(JSON.parse(encodeOrderBody({ order: o, sig: "0x1234" })))).toEqual(["order", "sig"]);
  });
});

describe("planGasless", () => {
  const state = { erc20Allowance: 0n, grantAmount: 0n, grantExpiration: 0, directAllowance: 0n, strict: false };
  const base = { permitSupported: true, needsWrap: false, multiOrder: false, covered: false };
  it("offers it for an unfunded single order in a permit token", () => {
    expect(planGasless(state, base)).toEqual({ available: true, reason: null });
  });
  it("not in strict mode, not for a TWAP, not with a wrap, not when already covered, not for a non-permit token", () => {
    expect(planGasless({ ...state, strict: true }, base).available).toBe(false);
    expect(planGasless({ ...state, strict: true }, base).reason).toMatch(/strict/);
    expect(planGasless(state, { ...base, multiOrder: true }).reason).toMatch(/TWAP/);
    expect(planGasless(state, { ...base, needsWrap: true }).available).toBe(false);
    expect(planGasless(state, { ...base, covered: true })).toEqual({ available: false, reason: null });
    expect(planGasless(state, { ...base, permitSupported: false })).toEqual({ available: false, reason: null });
    expect(planGasless(undefined, base).available).toBe(false);
  });
});

describe("revoke clears the direct surface a relayed permit leaves", () => {
  it("adds approve(Settlement, 0) and counts it as a leftover", () => {
    const st = { erc20Allowance: 0n, grantAmount: 0n, grantExpiration: 0, directAllowance: 25_000_000n };
    expect(hasLeftover(st, 0)).toBe(true);
    const calls = revokeCalls(st, { token: USDT0, permit3: PERMIT3, settlement: SETTLEMENT });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.to).toBe(USDT0);
    expect(decodeFunctionData({ abi: erc20Abi, data: calls[0]!.data }).args).toEqual([SETTLEMENT, 0n]);
  });
});

describe("App wiring", () => {
  const app = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  it("signs the permit AFTER the order (its deadline is the order's expiry) and before posting", () => {
    const signedAt = app.indexOf("let signed = await signDraft({ ...spec, marketId, side, kind: plan.kind, pull, nativeOut });");
    const permitAt = app.indexOf("await signGaslessPermit(");
    const postAt = app.indexOf('setSignPhase("posting");', permitAt);
    expect(signedAt).toBeGreaterThan(0);
    expect(permitAt).toBeGreaterThan(signedAt);
    expect(postAt).toBeGreaterThan(permitAt);
  });
});

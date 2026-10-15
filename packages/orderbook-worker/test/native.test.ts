import { nativeOutLeg, withDeltaVerifyOutputs } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import { loadConfig, type Env } from "../src/config";
import { alice, call, freshBook, resetWorld, signed, testEnv, USDRIF, USDT0, world } from "./helpers";

/**
 * NATIVE RECEIPTS through the `NativeBalance` view (task 30): the book lists the view
 * where it lists tokens, admits it only as the DELTA-VERIFIED output it is, and refuses
 * every other use before spending a lens call.
 */
const NB = "0x00000000000000000000000000000000000a7b01" as Address;
const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;

beforeEach(() => resetWorld());

describe("NATIVE_BALANCE config", () => {
  it("joins a configured ALLOWED_TOKENS list (and stays off the unrestricted default)", () => {
    const listed = loadConfig({ ...testEnv, ALLOWED_TOKENS: `${USDRIF},${USDT0}`, NATIVE_BALANCE: NB } as Env);
    expect(listed.nativeBalance).toBe(NB);
    expect(listed.admission.allowedTokens).toEqual([USDRIF, USDT0, NB]);
    const open = loadConfig({ ...testEnv, ALLOWED_TOKENS: "", NATIVE_BALANCE: NB } as Env);
    expect(open.admission.allowedTokens).toBeUndefined();
    const off = loadConfig({ ...testEnv, ALLOWED_TOKENS: `${USDRIF}`, NATIVE_BALANCE: "" } as Env);
    expect(off.nativeBalance).toBeUndefined();
    expect(off.admission.allowedTokens).toEqual([USDRIF]);
    expect(() => loadConfig({ ...testEnv, NATIVE_BALANCE: "0x12" } as Env)).toThrow(/NATIVE_BALANCE/);
  });
});

describe("POST /orders — the NativeBalance view", () => {
  const direct = { timing: withDeltaVerifyOutputs(0n), exclusiveFiller: SOLVER };

  it("admits the DIRECT native shape", async () => {
    const book = freshBook();
    const o = await signed(alice, { ...direct, legsOut: [nativeOutLeg({ nativeBalance: NB, start: 990n })] });
    const res = await call(book, "POST", "/orders", o.body);
    expect(res.status).toBe(202);
  });

  it.each([
    ["as an input leg", { ...direct, legsIn: [{ token: NB, start: 1_000n, end: 0n }] }, /input leg/],
    ["as a PULL output", { legsOut: [nativeOutLeg({ nativeBalance: NB, start: 990n })] }, /DIRECT/],
    ["as a second output", { ...direct, legsOut: [{ token: USDT0, start: 1n, end: 0n, recipient: zeroAddress }, nativeOutLeg({ nativeBalance: NB, start: 990n })] }, /legsOut\[0\]/],
  ] as const)("refuses it %s — before any lens call", async (_n, over, why) => {
    const book = freshBook();
    const calls = world.lensCalls;
    const o = await signed(alice, over);
    const res = await call(book, "POST", "/orders", o.body);
    expect(res.status).toBe(422);
    expect(res.body.error).toMatch(why);
    expect(world.lensCalls).toBe(calls);
  });
});

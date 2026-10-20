import { describe, expect, it, vi } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress, type Hex } from "viem";
import { answersHash, participationTypedData } from "@1delta-x/sdk";

import { participateView, submitParticipation, type RaffleStatus } from "../src/lib/raffle";

const T = `0x${"7e".repeat(32)}` as Hex;
const A = "0x00000000000000000000000000000000000000a1";
const base: RaffleStatus = { live: true, promotion: "p", terms: T, address: A, traded: false, entered: false };

describe("participateView — what the notice offers", () => {
  it("hides without a live draw and asks to connect without a wallet", () => {
    expect(participateView(null, A, T)).toEqual({ kind: "hidden" });
    expect(participateView({ live: false }, A, T)).toEqual({ kind: "hidden" });
    expect(participateView(base, null, T)).toEqual({ kind: "connect" });
  });
  it("locks until a first swap, opens after it, and shows the entry once made", () => {
    expect(participateView(base, A, T)).toEqual({ kind: "locked" });
    expect(participateView({ ...base, traded: true }, A, T)).toEqual({ kind: "open" });
    expect(participateView({ ...base, traded: true, entered: true, enteredAt: 5 }, A, T)).toEqual({ kind: "entered", enteredAt: 5 });
  });
  it("never offers a form for Terms this build does not ship, or for another address's status", () => {
    expect(participateView({ ...base, traded: true, terms: `0x${"00".repeat(32)}` }, A, T)).toEqual({ kind: "terms-mismatch" });
    expect(participateView({ ...base, traded: true }, "0x00000000000000000000000000000000000000b2", T)).toEqual({ kind: "hidden" });
  });
});

describe("submitParticipation", () => {
  it("signs the SDK typed data and posts exactly what the worker re-hashes", async () => {
    const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
    const answers = { rating: 3, ease: 3, safety: 4, fill: 3 };
    let posted: Record<string, unknown> = {};
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      expect(url).toBe("/api/book/raffle/entries");
      posted = JSON.parse(String(init.body));
      return new Response(JSON.stringify({ entered: true, updated: false, enteredAt: 7 }), { status: 201 });
    });
    const res = await submitParticipation({
      base: "/api/book",
      signer: { signTypedData: (p: never) => account.signTypedData(p) },
      chainId: 30,
      participant: account.address,
      promotion: "p",
      terms: T,
      answers,
      now: () => 1_760_000_000_000,
    });
    vi.unstubAllGlobals();
    expect(res).toEqual({ entered: true, updated: false, enteredAt: 7 });
    expect(posted.issuedAt).toBe("1760000000");
    const td = participationTypedData(30, { participant: account.address, promotion: "p", terms: T, answers: answersHash(answers), issuedAt: 1_760_000_000n });
    expect(await recoverTypedDataAddress({ ...td, signature: posted.signature as Hex })).toBe(account.address);
  });

  it("surfaces the desk's refusal", async () => {
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ error: "make at least one swap with this address first" }), { status: 403 }));
    const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
    await expect(
      submitParticipation({ base: "", signer: { signTypedData: (p: never) => account.signTypedData(p) }, chainId: 30, participant: account.address, promotion: "p", terms: T, answers: {} }),
    ).rejects.toThrow(/first/);
    vi.unstubAllGlobals();
  });
});


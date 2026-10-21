import { describe, expect, it, vi } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress, type Hex } from "viem";
import { answersHash, feedbackTypedData } from "@1delta-x/sdk";

import { participateView, submitParticipation, type RaffleStatus } from "../src/lib/raffle";

const A = "0x00000000000000000000000000000000000000a1";
const base: RaffleStatus = { feedbackForm: true, promotion: "p", address: A, traded: false, entered: false };

describe("participateView — the optional feedback control", () => {
  it("hides without a feedback form on the book and asks to connect without a wallet", () => {
    expect(participateView(null, A)).toEqual({ kind: "hidden" });
    expect(participateView({ feedbackForm: false }, A)).toEqual({ kind: "hidden" });
    expect(participateView(base, null)).toEqual({ kind: "connect" });
  });
  it("locks until a first swap, opens after it, and shows the feedback once given", () => {
    expect(participateView(base, A)).toEqual({ kind: "locked" });
    expect(participateView({ ...base, traded: true }, A)).toEqual({ kind: "open" });
    expect(participateView({ ...base, traded: true, entered: true, enteredAt: 5 }, A)).toEqual({ kind: "entered", enteredAt: 5 });
  });
  it("ignores another address's status", () => {
    expect(participateView({ ...base, traded: true }, "0x00000000000000000000000000000000000000b2")).toEqual({ kind: "hidden" });
  });
});

describe("submitParticipation (feedback)", () => {
  it("signs the SDK typed data and posts exactly what the worker re-hashes — no Terms, not an entry", async () => {
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
      answers,
      now: () => 1_760_000_000_000,
    });
    vi.unstubAllGlobals();
    expect(res).toEqual({ entered: true, updated: false, enteredAt: 7 });
    expect(posted.issuedAt).toBe("1760000000");
    expect(posted.terms).toBeUndefined();
    const td = feedbackTypedData(30, { participant: account.address, promotion: "p", answers: answersHash(answers), issuedAt: 1_760_000_000n });
    expect(await recoverTypedDataAddress({ ...td, signature: posted.signature as Hex })).toBe(account.address);
  });

  it("surfaces the desk's refusal", async () => {
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ error: "make at least one swap with this address first" }), { status: 403 }));
    const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
    await expect(
      submitParticipation({ base: "", signer: { signTypedData: (p: never) => account.signTypedData(p) }, chainId: 30, participant: account.address, promotion: "p", answers: {} }),
    ).rejects.toThrow(/first/);
    vi.unstubAllGlobals();
  });
});


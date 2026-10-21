import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress } from "viem";

import {
  answersHash,
  canonicalAnswers,
  CLAIM_STATEMENT,
  claimTypedData,
  FEEDBACK_STATEMENT,
  feedbackTypedData,
  PARTICIPATION_QUESTIONS,
  termsHash,
  validateAnswers,
} from "../src";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const valid = {
  rating: 4,
  safety: 3,
  purpose: ["Get RBTC", "Exit USDRIF"],
  ease: 4,
  fill: 3,
  friction: "The approval step",
};

describe("participation form", () => {
  it("accepts a complete form and the minimal required one", () => {
    expect(validateAnswers(valid)).toBeNull();
    expect(validateAnswers({ rating: 2, ease: 1, safety: 5, fill: 5 })).toBeNull();
  });

  it("refuses missing required, unknown, out-of-range and off-list answers", () => {
    expect(validateAnswers({ ...valid, safety: undefined as never })).toMatch(/required/);
    expect(validateAnswers({ ...valid, heard: "A friend" })).toMatch(/unknown question/);
    expect(validateAnswers({ ...valid, ease: 6 })).toMatch(/1 to 5/);
    expect(validateAnswers({ ...valid, ease: 2.5 })).toMatch(/1 to 5/);
    expect(validateAnswers({ ...valid, purpose: ["Narnia"] })).toMatch(/options/);
    expect(validateAnswers({ ...valid, purpose: ["Get RBTC", "Get RBTC"] })).toMatch(/repeated/);
    expect(validateAnswers({ ...valid, friction: "x".repeat(1001) })).toMatch(/1000/);
    expect(validateAnswers({ ...valid, friction: " padded" })).toMatch(/spaces/);
    expect(validateAnswers(null)).toMatch(/object/);
    expect(validateAnswers([])).toMatch(/object/);
  });

  it("hashes independently of key order, click order and blank optionals", () => {
    const reordered = { fill: 3, ease: 4, purpose: ["Exit USDRIF", "Get RBTC"], rating: 4, safety: 3, friction: "The approval step", next: [] };
    expect(canonicalAnswers(reordered)).toBe(canonicalAnswers(valid));
    expect(answersHash(reordered)).toBe(answersHash(valid));
    expect(answersHash({ ...valid, ease: 5 })).not.toBe(answersHash(valid));
    // Multi-selects are in option order, not click order.
    expect(JSON.parse(canonicalAnswers(valid)).purpose).toEqual(["Exit USDRIF", "Get RBTC"]);
  });

  it("asks nothing personal", () => {
    expect(PARTICIPATION_QUESTIONS.map((q) => q.id)).not.toContain("contact");
    expect(validateAnswers({ ...valid, contact: "@someone" })).toMatch(/unknown question/);
  });

  it("feedback: signs the fixed statement (no confirmations, no Terms) and recovers the signer", async () => {
    const td = feedbackTypedData(30, { participant: account.address, promotion: "rootstock-beta-1", answers: answersHash(valid), issuedAt: 1_760_000_000n });
    expect(td.message.statement).toBe(FEEDBACK_STATEMENT);
    expect(td.message.statement).toMatch(/not an entry/);
    expect("terms" in td.message).toBe(false);
    expect("verifyingContract" in td.domain).toBe(false);
    const signature = await account.signTypedData(td);
    expect(await recoverTypedDataAddress({ ...td, signature })).toBe(account.address);
  });

  it("claim: a drawn winner's eligibility confirmations, bound to the draw and the Terms", async () => {
    const td = claimTypedData(30, { participant: account.address, promotion: "rootstock-beta-1", draw: "2026-10-25", terms: termsHash("# Terms"), issuedAt: 1_760_000_000n });
    expect(td.message.statement).toBe(CLAIM_STATEMENT);
    expect(CLAIM_STATEMENT).toMatch(/not a U\.S\. Person/);
    expect(CLAIM_STATEMENT).toMatch(/sanctioned jurisdiction/);
    expect(CLAIM_STATEMENT).toMatch(/may be published/);
    const signature = await account.signTypedData(td);
    expect(await recoverTypedDataAddress({ ...td, signature })).toBe(account.address);
    // Another draw or other Terms is another message.
    expect(td.message).not.toEqual(claimTypedData(30, { ...td.message, draw: "2026-10-28" }).message);
  });
});

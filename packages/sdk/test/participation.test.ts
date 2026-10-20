import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress } from "viem";

import {
  answersHash,
  canonicalAnswers,
  participationTypedData,
  PARTICIPATION_QUESTIONS,
  PARTICIPATION_STATEMENT,
  termsHash,
  validateAnswers,
  withoutPersonal,
} from "../src";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const valid = {
  heard: "A friend",
  funds: "I bridged USD₮0 from another chain",
  fundsChain: "Arbitrum",
  purpose: ["Get RBTC", "Exit USDRIF"],
  ease: 4,
  fill: 3,
  friction: "The approval step",
  contact: "@someone",
};

describe("participation form", () => {
  it("accepts a complete form and the minimal required one", () => {
    expect(validateAnswers(valid)).toBeNull();
    expect(validateAnswers({ heard: "Other", funds: "Other", purpose: ["Try the app"], ease: 1, fill: 5 })).toBeNull();
  });

  it("refuses missing required, unknown, out-of-range and off-list answers", () => {
    expect(validateAnswers({ ...valid, heard: "" })).toMatch(/required/);
    expect(validateAnswers({ ...valid, extra: "x" })).toMatch(/unknown question/);
    expect(validateAnswers({ ...valid, ease: 6 })).toMatch(/1 to 5/);
    expect(validateAnswers({ ...valid, ease: 2.5 })).toMatch(/1 to 5/);
    expect(validateAnswers({ ...valid, heard: "Billboard" })).toMatch(/options/);
    expect(validateAnswers({ ...valid, purpose: ["Get RBTC", "Get RBTC"] })).toMatch(/repeated/);
    expect(validateAnswers({ ...valid, friction: "x".repeat(1001) })).toMatch(/1000/);
    expect(validateAnswers({ ...valid, contact: " @padded" })).toMatch(/spaces/);
    expect(validateAnswers(null)).toMatch(/object/);
    expect(validateAnswers([])).toMatch(/object/);
  });

  it("hashes independently of key order, click order and blank optionals", () => {
    const reordered = { contact: "@someone", fill: 3, ease: 4, purpose: ["Exit USDRIF", "Get RBTC"], fundsChain: "Arbitrum", funds: valid.funds, heard: "A friend", friction: "The approval step", next: [] };
    expect(canonicalAnswers(reordered)).toBe(canonicalAnswers(valid));
    expect(answersHash(reordered)).toBe(answersHash(valid));
    expect(answersHash({ ...valid, ease: 5 })).not.toBe(answersHash(valid));
    // Multi-selects are in option order, not click order.
    expect(JSON.parse(canonicalAnswers(valid)).purpose).toEqual(["Exit USDRIF", "Get RBTC"]);
  });

  it("strips only the personal field", () => {
    const stripped = withoutPersonal(valid);
    expect(stripped.contact).toBeUndefined();
    expect(stripped.friction).toBe(valid.friction);
    expect(PARTICIPATION_QUESTIONS.filter((q) => q.kind === "text" && q.personal).map((q) => q.id)).toEqual(["contact"]);
  });

  it("signs the fixed statement and recovers the participant", async () => {
    const td = participationTypedData(30, {
      participant: account.address,
      promotion: "rootstock-beta-1",
      terms: termsHash("# Terms"),
      answers: answersHash(valid),
      issuedAt: 1_760_000_000n,
    });
    expect(td.message.statement).toBe(PARTICIPATION_STATEMENT);
    expect("verifyingContract" in td.domain).toBe(false);
    const signature = await account.signTypedData(td);
    expect(await recoverTypedDataAddress({ ...td, signature })).toBe(account.address);
  });
});

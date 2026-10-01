import { describe, expect, it } from "vitest";
import { PERMIT3_ABI } from "@1delta-x/sdk";
import { decodeFunctionData, erc20Abi, getAddress, zeroAddress } from "viem";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { parseDeployments } from "../src/config/deployments";
import { readFundingState, verifyDeployment, type Reader } from "../src/lib/chain";
import { GRANT_MARGIN_SECONDS, fundingCalls, hasLeftover, planFunding, revokeCalls } from "../src/lib/funding";

const TOKEN = getAddress("0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37");
const PERMIT3 = getAddress("0x000000000000000000000000000000000000p3p3".replace(/p/g, "a"));
const SETTLEMENT = getAddress("0x00000000000000000000000000000000005e771e");
const OWNER = getAddress("0x00000000000000000000000000000000000000aa");
const T = { token: TOKEN, permit3: PERMIT3, settlement: SETTLEMENT };
const NOW = 1_700_000_000;
const src = (p: string) => readFileSync(resolve(__dirname, "..", p), "utf8");

describe("A-IMMUT-1 — the app creates BOTH funding legs", () => {
  it("test_audit_A_IMMUT_1_erc20ApprovalAloneIsNotFunded", () => {
    // Exactly the state the old app left behind: ERC-20 approve to Permit3,
    // no Permit3 book grant to Settlement → Permit3.transferFrom reverts.
    const plan = planFunding({ erc20Allowance: 500n, grantAmount: 0n, grantExpiration: 0 }, 500n, 3600, NOW);
    expect(plan.covered).toBe(false);
    expect(plan.steps).toEqual([{ kind: "permit3-grant", amount: 500n, expiration: NOW + 3600 + GRANT_MARGIN_SECONDS }]);
  });

  it("test_audit_A_IMMUT_1_grantNamesSettlementAsSpender", () => {
    const plan = planFunding({ erc20Allowance: 0n, grantAmount: 0n, grantExpiration: 0 }, 500n, 60, NOW);
    const calls = fundingCalls(plan.steps, T);
    expect(calls).toHaveLength(2);

    expect(calls[0]!.to).toBe(TOKEN);
    const approve = decodeFunctionData({ abi: erc20Abi, data: calls[0]!.data });
    expect(approve.functionName).toBe("approve");
    expect(approve.args).toEqual([PERMIT3, 500n]);

    expect(calls[1]!.to).toBe(PERMIT3);
    const grant = decodeFunctionData({ abi: PERMIT3_ABI, data: calls[1]!.data });
    expect(grant.functionName).toBe("approveToken");
    // spender = SETTLEMENT (msg.sender of Permit3.transferFrom), token, exact amount, a real expiry (never 0).
    expect(grant.args).toEqual([SETTLEMENT, TOKEN, 500n, NOW + 60 + GRANT_MARGIN_SECONDS]);
  });

  it("test_audit_A_IMMUT_1_bothLegsExactIsCovered", () => {
    const plan = planFunding({ erc20Allowance: 500n, grantAmount: 500n, grantExpiration: NOW + 7200 }, 500n, 3600, NOW);
    expect(plan.covered).toBe(true);
    // ...but a grant that lapses before the order does is not.
    expect(planFunding({ erc20Allowance: 500n, grantAmount: 500n, grantExpiration: NOW + 10 }, 500n, 3600, NOW).covered).toBe(
      false,
    );
  });

  it("test_audit_A_IMMUT_1_readsGrantToSettlement", async () => {
    const seen: Array<{ fn: string; args: readonly unknown[] | undefined }> = [];
    const reader: Reader = {
      async readContract(a) {
        seen.push({ fn: a.functionName, args: a.args });
        return a.functionName === "allowance" ? 7n : [9n, 123];
      },
    };
    const state = await readFundingState(reader, { token: TOKEN, owner: OWNER, permit3: PERMIT3, settlement: SETTLEMENT });
    expect(state).toEqual({ erc20Allowance: 7n, grantAmount: 9n, grantExpiration: 123 });
    expect(seen).toContainEqual({ fn: "tokenAllowance", args: [OWNER, SETTLEMENT, TOKEN] });
    expect(seen).toContainEqual({ fn: "allowance", args: [OWNER, PERMIT3] });
  });

  it("test_audit_A_IMMUT_1_appWiresSettlementIntoFunding", () => {
    const app = src("src/App.tsx");
    expect(app).toContain("deployment: deployment ? { permit3: deployment.permit3, settlement: deployment.settlement } : null");
  });
});

describe("G-TS_SIGN-5 — no false 'no standing allowance' promise; trim + revoke", () => {
  it("test_audit_G_TS_SIGN_5_largerAllowanceIsTrimmed", () => {
    // 5,000 left from a lapsed ticket; the new ticket needs 100 → NOT covered.
    const plan = planFunding({ erc20Allowance: 5000n, grantAmount: 5000n, grantExpiration: NOW + 99999 }, 100n, 60, NOW);
    expect(plan.covered).toBe(false);
    expect(plan.trims).toBe(true);
    expect(plan.steps.map((s) => s.amount)).toEqual([100n, 100n]);
  });

  it("test_audit_G_TS_SIGN_5_neverExpiringGrantIsTrimmed", () => {
    const plan = planFunding({ erc20Allowance: 100n, grantAmount: 100n, grantExpiration: 0 }, 100n, 60, NOW);
    expect(plan.covered).toBe(false);
    expect(plan.steps[0]!.kind).toBe("permit3-grant");
  });

  it("test_audit_G_TS_SIGN_5_revokeClearsBothLegs", () => {
    const state = { erc20Allowance: 100n, grantAmount: 100n, grantExpiration: NOW + 10 };
    expect(hasLeftover(state, NOW)).toBe(true);
    const calls = revokeCalls(state, T);
    const decoded = calls.map((c) =>
      c.to === PERMIT3 ? decodeFunctionData({ abi: PERMIT3_ABI, data: c.data }) : decodeFunctionData({ abi: erc20Abi, data: c.data }),
    );
    expect(decoded.map((d) => d.functionName)).toEqual(["revokeToken", "approve"]);
    expect(decoded[0]!.args).toEqual([SETTLEMENT, TOKEN]);
    expect(decoded[1]!.args).toEqual([PERMIT3, 0n]);
    expect(hasLeftover({ erc20Allowance: 0n, grantAmount: 5n, grantExpiration: NOW - 1 }, NOW)).toBe(false);
  });

  it("test_audit_G_TS_SIGN_5_disclosureNoLongerPromisesNoStandingAllowance", () => {
    for (const f of ["src/components/PreAudit.tsx", "src/components/OrderForm.tsx", "src/App.tsx", "README.md"]) {
      const text = src(f);
      expect(text, f).not.toContain("no standing allowance is left behind");
      expect(text, f).not.toContain("no allowance outlives an order that never fills");
      expect(text, f).not.toContain("leaves no standing allowance behind");
    }
    expect(src("src/components/PreAudit.tsx")).toContain("not removed automatically");
  });
});

describe("G-TS_SIGN-14 — deployment hygiene and security headers", () => {
  const good = {
    settlement: "0x00000000000000000000000000000000005e771e",
    permit3: "0x000000000000000000000000000000000000aaaa",
  };

  it("test_audit_G_TS_SIGN_14_invalidAddressesAreRejected", () => {
    expect(parseDeployments(JSON.stringify({ 30: good }))[30]?.permit3).toBe(getAddress(good.permit3));
    expect(parseDeployments(JSON.stringify({ 30: { ...good, permit3: "0xnotanaddress" } }))[30]).toBeUndefined();
    expect(parseDeployments(JSON.stringify({ 30: { ...good, permit3: zeroAddress } }))[30]).toBeUndefined();
    expect(parseDeployments(JSON.stringify({ 30: { settlement: good.settlement } }))[30]).toBeUndefined();
    expect(parseDeployments(JSON.stringify({ 30: { ...good, solver: 42 } }))[30]).toBeUndefined();
    expect(parseDeployments("{oops")).toEqual({});
  });

  it("test_audit_G_TS_SIGN_14_permit3MismatchRefused", async () => {
    const reader = (wired: string): Reader => ({ readContract: async () => wired });
    await expect(verifyDeployment(reader(PERMIT3), { settlement: SETTLEMENT, permit3: PERMIT3 })).resolves.toBeUndefined();
    await expect(
      verifyDeployment(reader("0x0000000000000000000000000000000000000bad"), { settlement: SETTLEMENT, permit3: PERMIT3 }),
    ).rejects.toThrow(/deployment mismatch/);
  });

  it("test_audit_G_TS_SIGN_14_workerSetsFrameAncestorsAndCsp", async () => {
    // @ts-expect-error — plain JS worker module
    const worker = (await import("../public/_worker.js")).default;
    const env = { ASSETS: { fetch: async () => new Response("<html></html>", { status: 200, headers: { "content-type": "text/html" } }) } };
    const res: Response = await worker.fetch(new Request("https://app.example/"), env);
    const csp = res.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("script-src 'self'");
    expect(res.headers.get("x-frame-options")).toBe("DENY");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(await res.text()).toBe("<html></html>");
  });
});

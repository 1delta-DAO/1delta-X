import { describe, expect, it } from "vitest";
import { decodeFunctionData, erc20Abi, getAddress } from "viem";

import { pinnedToken, wrappedNativeSymbol } from "../src/config/markets";
import {
  WRAP_GAS_RESERVE_WEI,
  WRAPPED_NATIVE_ABI,
  fmtWei,
  fundingButtonLabel,
  fundingButtonParts,
  fundingCalls,
  fundingStepLabel,
  planFunding,
  unwrapCall,
  wrapCall,
} from "../src/lib/funding";
import { balanceState, exceedsBalance, maxSpendableWei, wrappableWei, wrapSpendableWei } from "../src/lib/ticketView";

const E = 10n ** 18n;
const milli = (n: number) => (BigInt(n) * E) / 1000n; // n × 0.001
const WRBTC = getAddress("0x542fda317318ebf1d3deaf76e0b632741a7e677d");
const PERMIT3 = getAddress("0x000000000000000000000000000000000000aaaa");
const SETTLEMENT = getAddress("0x00000000000000000000000000000000005e771e");
const T = { token: WRBTC, permit3: PERMIT3, settlement: SETTLEMENT };
const NOW = 1_700_000_000;
const UNFUNDED = { erc20Allowance: 0n, grantAmount: 0n, grantExpiration: 0, strict: true };
const LABEL = { amount: "0.010000", token: "WRBTC", nativeSymbol: "RBTC" };

describe("auto-wrap config", () => {
  it("wraps WRBTC on Rootstock only, and it is the pinned WRBTC", () => {
    expect(wrappedNativeSymbol(30)).toBe("WRBTC");
    expect(wrappedNativeSymbol(1)).toBeUndefined();
    expect(getAddress(pinnedToken(30, "WRBTC")!.address)).toBe(WRBTC);
  });

  it("the reserve is 0.00005 RBTC", () => {
    expect(WRAP_GAS_RESERVE_WEI).toBe(5n * 10n ** 13n);
  });
});

describe("planFunding with a wrap source", () => {
  it("no wrap when the WRBTC balance already covers the order", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: milli(10), nativeBalance: milli(50) });
    expect(plan.steps.map((s) => s.kind)).toEqual(["erc20-approve", "permit3-grant"]);
    expect(plan.blocked).toBeNull();
  });

  it("no wrap and covered when funding is set and WRBTC suffices", () => {
    const funded = { erc20Allowance: milli(10), grantAmount: milli(10), grantExpiration: NOW + 99_999, strict: true };
    const plan = planFunding(funded, milli(10), 300, NOW, { tokenBalance: milli(12), nativeBalance: 0n });
    expect(plan.covered).toBe(true);
  });

  it("wraps EXACTLY the shortfall, first, then approve + grant", () => {
    const required = milli(10);
    const tokenBalance = 3_141_592_653_589_793n; // 0.0031… WRBTC
    const plan = planFunding(UNFUNDED, required, 300, NOW, { tokenBalance, nativeBalance: milli(50) });
    expect(plan.steps[0]).toEqual({ kind: "wrap", amount: required - tokenBalance });
    expect(plan.steps.map((s) => s.kind)).toEqual(["wrap", "erc20-approve", "permit3-grant"]);
    // approve and grant are sized to the ORDER, not the wrap
    expect(plan.steps[1]).toEqual({ kind: "erc20-approve", amount: required });
    expect(plan.blocked).toBeNull();
    expect(plan.covered).toBe(false);
  });

  it("an otherwise-funded order still needs the wrap: not covered", () => {
    const funded = { erc20Allowance: milli(10), grantAmount: milli(10), grantExpiration: NOW + 99_999, strict: true };
    const plan = planFunding(funded, milli(10), 300, NOW, { tokenBalance: 0n, nativeBalance: milli(50) });
    expect(plan.steps).toEqual([{ kind: "wrap", amount: milli(10) }]);
    expect(plan.covered).toBe(false);
  });

  it("wrapping right up to the reserve is allowed; one wei past it is refused", () => {
    const required = milli(10);
    const exact = planFunding(UNFUNDED, required, 300, NOW, { tokenBalance: 0n, nativeBalance: required + WRAP_GAS_RESERVE_WEI });
    expect(exact.blocked).toBeNull();
    const short = planFunding(UNFUNDED, required, 300, NOW, {
      tokenBalance: 0n,
      nativeBalance: required + WRAP_GAS_RESERVE_WEI - 1n,
      nativeSymbol: "RBTC",
    });
    expect(short.blocked).toMatch(/leave less than 0\.00005 RBTC for gas/);
    expect(short.covered).toBe(false);
  });

  it("refuses with a plain message when the native balance cannot cover the shortfall at all", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: 0n, nativeBalance: milli(1), nativeSymbol: "RBTC" });
    expect(plan.blocked).toMatch(/^Not enough RBTC/);
  });

  it("a custom reserve is honoured", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: 0n, nativeBalance: milli(11), reserve: milli(2) });
    expect(plan.blocked).not.toBeNull();
  });

  it("no wrap source → unchanged behaviour (USD0 / USDRIF tickets)", () => {
    const plan = planFunding(UNFUNDED, 500n, 300, NOW);
    expect(plan.steps.map((s) => s.kind)).toEqual(["erc20-approve", "permit3-grant"]);
    expect(plan.blocked).toBeNull();
  });
});

describe("wrap / unwrap calldata", () => {
  it("fundingCalls: the wrap is WRBTC.deposit{value: shortfall}", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: milli(4), nativeBalance: milli(50) });
    const calls = fundingCalls(plan.steps, T);
    expect(calls).toHaveLength(3);
    expect(calls[0]!.to).toBe(WRBTC);
    expect(calls[0]!.value).toBe(milli(6));
    expect(decodeFunctionData({ abi: WRAPPED_NATIVE_ABI, data: calls[0]!.data }).functionName).toBe("deposit");
    expect(calls[0]!.data).toBe("0xd0e30db0");
    // approve and grant carry no value
    expect(calls[1]!.value).toBeUndefined();
    expect(decodeFunctionData({ abi: erc20Abi, data: calls[1]!.data }).args).toEqual([PERMIT3, milli(10)]);
    expect(calls[2]!.value).toBeUndefined();
  });

  it("wrapCall / unwrapCall", () => {
    expect(wrapCall(WRBTC, 7n)).toEqual({ to: WRBTC, data: "0xd0e30db0", value: 7n });
    const u = unwrapCall(WRBTC, milli(3));
    expect(u.to).toBe(WRBTC);
    expect(u.value).toBeUndefined();
    expect(u.data.slice(0, 10)).toBe("0x2e1a7d4d");
    expect(decodeFunctionData({ abi: WRAPPED_NATIVE_ABI, data: u.data }).args).toEqual([milli(3)]);
  });
});

describe("step labels", () => {
  it("names the wrap and counts all three steps", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: 0n, nativeBalance: milli(50) });
    expect(fundingStepLabel(plan.steps[0], LABEL)).toBe("Wrap 0.01 RBTC → WRBTC");
    expect(fundingButtonLabel(plan, LABEL)).toBe("Wrap 0.01 RBTC → WRBTC (1 of 3)");
    // The button's one-line form: the short label + a step badge (the info tooltip explains the wrap).
    expect(fundingButtonParts(plan, LABEL)).toEqual({ text: "Wrap 0.01 RBTC", step: "1/3" });
  });

  it("the wrap amount is the exact shortfall, rounded UP at 8 decimals", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: milli(10) - 12_300_000_000_000_001n, nativeBalance: milli(50) });
    expect(fundingButtonLabel(plan, LABEL)).toBe("Wrap 0.01230001 RBTC → WRBTC (1 of 3)");
  });

  it("without a wrap the labels are the old ones", () => {
    const plan = planFunding(UNFUNDED, milli(10), 300, NOW, { tokenBalance: milli(10), nativeBalance: 0n });
    expect(fundingButtonLabel(plan, LABEL)).toBe("Approve exactly 0.010000 WRBTC to Permit3 (1 of 2)");
    const grantOnly = planFunding({ erc20Allowance: milli(10), grantAmount: 0n, grantExpiration: 0, strict: true }, milli(10), 300, NOW);
    expect(fundingButtonLabel(grantOnly, LABEL)).toBe("Grant Settlement exactly 0.010000 WRBTC via Permit3");
  });

  it("a trim says Reduce, but never on a wrap step", () => {
    const big = { erc20Allowance: milli(99), grantAmount: 0n, grantExpiration: 0, strict: true };
    const trim = planFunding(big, milli(10), 300, NOW, { tokenBalance: milli(10), nativeBalance: 0n });
    expect(fundingButtonLabel(trim, LABEL)).toMatch(/^Reduce: Approve exactly/);
    const wrapFirst = planFunding(big, milli(10), 300, NOW, { tokenBalance: 0n, nativeBalance: milli(50) });
    expect(fundingButtonLabel(wrapFirst, LABEL)).toMatch(/^Wrap /);
  });

  it("fmtWei", () => {
    expect(fmtWei(milli(10))).toBe("0.01");
    expect(fmtWei(1n)).toBe("0.00000001");
    expect(fmtWei(0n)).toBe("0");
    expect(fmtWei(WRAP_GAS_RESERVE_WEI)).toBe("0.00005");
  });
});

describe("spendable / Max / insufficient with RBTC", () => {
  it("spendable = WRBTC + max(0, RBTC − reserve)", () => {
    expect(wrapSpendableWei(milli(10), milli(50))).toBe(milli(60) - WRAP_GAS_RESERVE_WEI);
    expect(wrapSpendableWei(milli(10), WRAP_GAS_RESERVE_WEI / 2n)).toBe(milli(10));
    expect(wrapSpendableWei(milli(10), undefined)).toBe(milli(10)); // unread native adds nothing
    expect(wrapSpendableWei(undefined, milli(50))).toBeUndefined(); // unread WRBTC stays unknown
    expect(wrappableWei(milli(50))).toBe(milli(50) - WRAP_GAS_RESERVE_WEI);
    expect(wrappableWei(0n)).toBe(0n);
  });

  it("0 WRBTC / 0.05 RBTC: selling 0.01 WRBTC is NOT insufficient, and Max leaves the reserve", () => {
    const spend = wrapSpendableWei(0n, milli(50))!;
    expect(exceedsBalance("0.01", 18, spend)).toBe(false);
    expect(exceedsBalance("0.05", 18, spend)).toBe(true); // the reserve is not spendable
    expect(maxSpendableWei(spend, false)).toBe(milli(50) - WRAP_GAS_RESERVE_WEI);
    // whatever Max fills, its wrap passes the reserve check
    const plan = planFunding(UNFUNDED, spend, 300, NOW, { tokenBalance: 0n, nativeBalance: milli(50) });
    expect(plan.blocked).toBeNull();
    // …and one wei more would not
    expect(exceedsBalance("0.04995000000000001", 18, spend)).toBe(true);
  });

  it("without RBTC, WRBTC alone is what counts (plain insufficient)", () => {
    const spend = wrapSpendableWei(milli(5), 0n)!;
    expect(exceedsBalance("0.01", 18, spend)).toBe(true);
  });

  it("the balance line shows the summed total, the auto-wrapped RBTC as a tag with the split in its tooltip", () => {
    const s = balanceState({ connected: true, onChain: true, value: 0.01, symbol: "WRBTC", wrappable: { value: 0.04995, symbol: "RBTC" } });
    expect(s).toEqual({
      kind: "ok",
      text: "0.05995 WRBTC",
      value: 0.01 + 0.04995,
      wrap: { tag: "+RBTC", note: "0.01 WRBTC + 0.04995 RBTC — the RBTC is wrapped to WRBTC when you sign (gas reserve kept)" },
    });
    // nothing wrappable → the plain line
    expect(balanceState({ connected: true, onChain: true, value: 0.01, symbol: "WRBTC", wrappable: { value: 0, symbol: "RBTC" } }).text).toBe(
      "0.01 WRBTC",
    );
    // disconnected / wrong network as before
    expect(balanceState({ connected: false, onChain: false, value: 1, symbol: "WRBTC", wrappable: { value: 1, symbol: "RBTC" } }).kind).toBe(
      "disconnected",
    );
    expect(balanceState({ connected: true, onChain: false, value: 1, symbol: "WRBTC", wrappable: { value: 1, symbol: "RBTC" } }).kind).toBe(
      "wrong-network",
    );
  });
});

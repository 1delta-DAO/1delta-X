import { encodeApproveToken, encodeRevokeToken } from "@1delta-x/sdk";
import { encodeFunctionData, erc20Abi, type Address, type Hex } from "viem";

/**
 * How a maker's input actually reaches a fill — and what this app must set up
 * before an order it signs can settle.
 *
 * Settlement pulls the maker's input with `Permit3.transferFrom(maker, …)`.
 * That spends the maker's PERMIT3 BOOK GRANT to Settlement
 * (`tokenAllowance[maker][Settlement][token]`), and Permit3 in turn moves the
 * tokens under the maker's ERC-20 allowance to PERMIT3. Both legs are required
 * (docs/account-onboarding.md). The app used to send only the ERC-20 approve,
 * so the Permit3 leg reverted `InsufficientAllowance`, the direct fallback had
 * no allowance to Settlement either, and every order it signed was unfillable
 * (audit A-IMMUT-1).
 *
 * Pre-audit policy is still EXACT: both legs are set to exactly the order's
 * input — trimmed down when a previous ticket left more — and the book grant
 * carries an expiry just past the order's own, so an unfilled order's grant
 * lapses on its own. The ERC-20 approval to Permit3 has no expiry; it stays
 * until a fill uses it or the maker revokes it, which the UI says plainly and
 * offers a one-click revoke for (G-TS_SIGN-5).
 */

/** What the chain says today, for one (maker, token). */
export interface FundingState {
  /** ERC-20 `allowance(maker, Permit3)`. */
  erc20Allowance: bigint;
  /** Permit3 `tokenAllowance(maker, Settlement, token).amount`. */
  grantAmount: bigint;
  /** Its expiry, unix seconds; `0` means NEVER expires in Permit3. */
  grantExpiration: number;
}

export type FundingStep =
  | { kind: "erc20-approve"; amount: bigint }
  | { kind: "permit3-grant"; amount: bigint; expiration: number };

export interface FundingPlan {
  /** Transactions still to send, in order. Empty means the order is fillable as far as funding goes. */
  steps: FundingStep[];
  covered: boolean;
  /** True when a standing allowance or grant exceeds this order and the plan trims it. */
  trims: boolean;
}

/** Slack between the order's expiry and its book grant's, so the grant never lapses first. */
export const GRANT_MARGIN_SECONDS = 3600;

/**
 * The transactions that make an order of `required` wei, live for
 * `ttlSeconds` from `now`, fillable — and no more than that.
 */
export function planFunding(state: FundingState, required: bigint, ttlSeconds: number, now: number): FundingPlan {
  if (required <= 0n) return { steps: [], covered: false, trims: false };
  const steps: FundingStep[] = [];
  let trims = false;

  if (state.erc20Allowance !== required) {
    trims ||= state.erc20Allowance > required;
    steps.push({ kind: "erc20-approve", amount: required });
  }

  const needUntil = now + ttlSeconds;
  const grantLive = state.grantExpiration === 0 || state.grantExpiration >= needUntil;
  // A never-expiring grant is a standing allowance even when the amount is right.
  const grantExact = state.grantAmount === required && state.grantExpiration !== 0;
  if (!(grantLive && grantExact)) {
    trims ||= state.grantAmount > required;
    steps.push({ kind: "permit3-grant", amount: required, expiration: needUntil + GRANT_MARGIN_SECONDS });
  }
  return { steps, covered: steps.length === 0, trims };
}

/** Whether anything is left standing that a revoke would clear. */
export function hasLeftover(state: FundingState, now: number): boolean {
  const grantLive = state.grantAmount > 0n && (state.grantExpiration === 0 || state.grantExpiration >= now);
  return state.erc20Allowance > 0n || grantLive;
}

export interface Call {
  to: Address;
  data: Hex;
}

export interface FundingTargets {
  token: Address;
  permit3: Address;
  settlement: Address;
}

const approveData = (spender: Address, amount: bigint): Hex =>
  encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, amount] });

/** The calldata for a plan. The book grant names SETTLEMENT as the spender — the contract that calls `transferFrom`. */
export function fundingCalls(steps: readonly FundingStep[], t: FundingTargets): Call[] {
  return steps.map((s) =>
    s.kind === "erc20-approve"
      ? { to: t.token, data: approveData(t.permit3, s.amount) }
      : { to: t.permit3, data: encodeApproveToken(t.settlement, t.token, s.amount, s.expiration) },
  );
}

/** Clear both legs: the ERC-20 approval to Permit3 and the book grant to Settlement. */
export function revokeCalls(state: FundingState, t: FundingTargets): Call[] {
  const calls: Call[] = [];
  if (state.grantAmount > 0n) calls.push({ to: t.permit3, data: encodeRevokeToken(t.settlement, t.token) });
  if (state.erc20Allowance > 0n) calls.push({ to: t.token, data: approveData(t.permit3, 0n) });
  return calls;
}

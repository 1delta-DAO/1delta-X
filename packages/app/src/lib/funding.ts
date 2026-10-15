import { encodeApproveToken, encodeRevokeToken } from "@1delta-x/sdk";
import { encodeFunctionData, erc20Abi, formatUnits, type Address, type Hex } from "viem";

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
 *
 * DIRECT funding (default since 2026-10-12): ONE transaction instead of two —
 * `token.approve(Settlement, exact)`. Settlement's pull tries the Permit3 leg and
 * falls back to the maker's direct ERC-20 allowance unless the maker is in Permit3
 * strict mode (`Base._pullViaPermit3`; the lens counts both). It is the surface a
 * gasless ERC-2612 permit already sets (spender = Settlement). It approves EXACTLY the
 * order's input when it must approve; what it gives up is the grant's auto-expiry: an
 * unfilled order's allowance stands until a fill or a revoke, and only a maker-signed
 * order can spend it. Makers in strict mode keep the two-leg Permit3 plan (the direct
 * surface is refused for them).
 *
 * COVERED AT ≥, NOT == (2026-10-15). A standing direct allowance at or above the order's
 * input funds it: no transaction. The direct path used to demand EQUALITY and "Reduce"
 * anything larger, so a re-sized ticket (a Max that moved by a few wei with the balance,
 * a new quote) re-prompted an approve each time — two approvals in a row for 0.000691 vs
 * 0.000689 WRBTC. The surplus is still only spendable by an order the maker signs; the
 * form shows the approved amount and a one-click revoke, so nothing standing is hidden
 * (G-TS_SIGN-5's point). Strict-mode Permit3 legs stay exact (their grant is time-bounded).
 */

/** What the chain says today, for one (maker, token). */
export interface FundingState {
  /** ERC-20 `allowance(maker, Permit3)`. */
  erc20Allowance: bigint;
  /** Permit3 `tokenAllowance(maker, Settlement, token).amount`. */
  grantAmount: bigint;
  /** Its expiry, unix seconds; `0` means NEVER expires in Permit3. */
  grantExpiration: number;
  /**
   * ERC-20 `allowance(maker, Settlement)` — the DIRECT surface a relayed ERC-2612
   * permit creates (lib/permit.ts). Optional: older readers (and tests) omit it.
   */
  directAllowance?: bigint;
  /** `Permit3.isStrict(maker, token)`: the direct surface is refused, so gasless funding is not offered. */
  strict?: boolean;
}

export type FundingStep =
  /** `WRAPPED.deposit{value: amount}()`: turn native coin into the wrapped token the order sells. */
  | { kind: "wrap"; amount: bigint }
  | { kind: "erc20-approve"; amount: bigint }
  /** `token.approve(Settlement, amount)`: the direct surface Settlement falls back to (one transaction). */
  | { kind: "direct-approve"; amount: bigint }
  | { kind: "permit3-grant"; amount: bigint; expiration: number };

export interface FundingPlan {
  /** Transactions still to send, in order. Empty means the order is fillable as far as funding goes. */
  steps: FundingStep[];
  covered: boolean;
  /** True when a standing allowance or grant exceeds this order and the plan trims it. */
  trims: boolean;
  /**
   * Why the plan must not be sent, or null. Set when the wrap it needs would
   * leave the wallet less native coin than `WRAP_GAS_RESERVE_WEI` for gas.
   */
  blocked: string | null;
}

/**
 * Native coin a wrap must leave behind for gas, wei: 0.00005 RBTC.
 *
 * Measured on Rootstock (2026-10-11, `cast estimate` against public-node.rsk.co):
 * WRBTC `deposit()` 43,010 gas, ERC-20 `approve` 44,016, Permit3 `approveToken`
 * 45,723 — ~133k for the whole wrap → approve → grant sequence. At the node's
 * gas price (~26 Mwei; `minimumGasPrice` 23.7 Mwei) that is ~0.0000035 RBTC, or
 * ~0.0000065 RBTC once a later hard cancel (~50k) and a two-tx revoke (~60k) are
 * added. 0.00005 RBTC buys ~1.9M gas at 26 Mwei: ~7× that whole budget, so it
 * survives a wallet padding its gas limits and a several-fold gas-price spike,
 * while costing a user about $5 of RBTC at most (≈ $100k/BTC) left unwrapped.
 */
export const WRAP_GAS_RESERVE_WEI = 50_000_000_000_000n;

/**
 * The wallet's side of an auto-wrap: present only when the order SELLS the
 * chain's wrapped native coin (WRBTC on Rootstock), which can be minted 1:1
 * from the native coin the wallet holds.
 */
export interface WrapSource {
  /** Wrapped-token balance (e.g. WRBTC), wei. */
  tokenBalance: bigint;
  /** Native coin balance (e.g. RBTC), wei. */
  nativeBalance: bigint;
  /** Native coin to keep for gas; defaults to `WRAP_GAS_RESERVE_WEI`. */
  reserve?: bigint;
  /** For the refusal message. */
  nativeSymbol?: string;
}

/** Up to 8 decimals, rounded UP (a stated wrap is never less than what is sent), trailing zeros trimmed. */
export function fmtWei(wei: bigint, decimals = 18, dp = 8): string {
  const unit = 10n ** BigInt(Math.max(0, decimals - dp));
  const up = decimals > dp ? ((wei + unit - 1n) / unit) * unit : wei;
  return formatUnits(up, decimals);
}

/** Slack between the order's expiry and its book grant's, so the grant never lapses first. */
export const GRANT_MARGIN_SECONDS = 3600;

/**
 * The transactions that make an order of `required` wei, live for
 * `ttlSeconds` from `now`, fillable — and no more than that.
 */
export function planFunding(
  state: FundingState,
  required: bigint,
  ttlSeconds: number,
  now: number,
  wrap?: WrapSource,
): FundingPlan {
  if (required <= 0n) return { steps: [], covered: false, trims: false, blocked: null };
  const steps: FundingStep[] = [];
  let trims = false;
  let blocked: string | null = null;

  // Auto-wrap: mint exactly the shortfall, never more — the wallet's native coin
  // stays native beyond what this order sells. First, because the approve and
  // grant are sized to the order, not to the balance, and need not wait on it.
  if (wrap && wrap.tokenBalance < required) {
    const shortfall = required - wrap.tokenBalance;
    const reserve = wrap.reserve ?? WRAP_GAS_RESERVE_WEI;
    const sym = wrap.nativeSymbol ?? "native coin";
    if (wrap.nativeBalance - shortfall < reserve) {
      blocked =
        wrap.nativeBalance < shortfall
          ? `Not enough ${sym}: wrapping ${fmtWei(shortfall)} needs more than the ${fmtWei(wrap.nativeBalance)} you hold`
          : `Wrapping ${fmtWei(shortfall)} ${sym} would leave less than ${fmtWei(reserve)} ${sym} for gas — lower the amount`;
    }
    steps.push({ kind: "wrap", amount: shortfall });
  }

  // Already funded through the legacy Permit3 legs (an exact live grant AND enough
  // approval behind it): nothing to send — Settlement's pull takes that leg first.
  const needUntilP3 = now + ttlSeconds;
  const permit3Covered =
    state.erc20Allowance >= required &&
    state.grantAmount === required &&
    state.grantExpiration !== 0 &&
    state.grantExpiration >= needUntilP3;

  if (!state.strict) {
    const direct = state.directAllowance ?? 0n;
    // Covered at ≥ (see the header): only a SHORT allowance costs a transaction, and then
    // exactly the order's input.
    if (direct < required && !permit3Covered) steps.push({ kind: "direct-approve", amount: required });
    return { steps, covered: steps.length === 0, trims, blocked };
  }

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
  return { steps, covered: steps.length === 0, trims, blocked };
}

/** What the button for a funding step says. Amounts in human units, already formatted. */
export function fundingStepLabel(
  step: FundingStep | undefined,
  a: { amount: string; token: string; nativeSymbol?: string },
): string {
  if (!step) return `Approve ${a.token}`;
  switch (step.kind) {
    case "wrap":
      return `Wrap ${fmtWei(step.amount)} ${a.nativeSymbol ?? "native"} → ${a.token}`;
    case "direct-approve":
      return `Approve exactly ${a.amount} ${a.token}`;
    case "erc20-approve":
      return `Approve exactly ${a.amount} ${a.token} to Permit3`;
    case "permit3-grant":
      return `Grant Settlement exactly ${a.amount} ${a.token} via Permit3`;
  }
}

/** The full button text: the next step, and where it sits when there are several ("(1 of 3)"). */
export function fundingButtonLabel(plan: Pick<FundingPlan, "steps" | "trims">, a: { amount: string; token: string; nativeSymbol?: string }): string {
  const head = fundingStepLabel(plan.steps[0], a);
  const reduce = plan.trims && plan.steps[0]?.kind !== "wrap" ? "Reduce: " : "";
  return `${reduce}${head}${plan.steps.length > 1 ? ` (1 of ${plan.steps.length})` : ""}`;
}

/**
 * The funding button in parts, so it fits ONE line: the step's short label, and the
 * "1/2" step counter as a separate badge. The wrap step drops "→ WRBTC" (the button's info
 * tooltip spells out the wrap). {@link fundingButtonLabel} stays the one-string form.
 */
export function fundingButtonParts(
  plan: Pick<FundingPlan, "steps" | "trims">,
  a: { amount: string; token: string; nativeSymbol?: string },
): { text: string; step: string | null } {
  const first = plan.steps[0];
  const head = first?.kind === "wrap" ? `Wrap ${fmtWei(first.amount)} ${a.nativeSymbol ?? "native"}` : fundingStepLabel(first, a);
  const reduce = plan.trims && first?.kind !== "wrap" ? "Reduce: " : "";
  return { text: `${reduce}${head}`, step: plan.steps.length > 1 ? `1/${plan.steps.length}` : null };
}

/** Whether anything is left standing that a revoke would clear. */
export function hasLeftover(state: FundingState, now: number): boolean {
  const grantLive = state.grantAmount > 0n && (state.grantExpiration === 0 || state.grantExpiration >= now);
  return state.erc20Allowance > 0n || grantLive || (state.directAllowance ?? 0n) > 0n;
}

/**
 * Whether this ticket may be funded GASLESSLY — an ERC-2612 permit to Settlement,
 * signed next to the order and relayed by the filler (lib/permit.ts) — instead of the
 * approve + grant transactions. `reason` says why not, for the form.
 */
export function planGasless(
  state: FundingState | undefined,
  a: { permitSupported: boolean; needsWrap: boolean; multiOrder: boolean; covered: boolean },
): { available: boolean; reason: string | null } {
  if (!a.permitSupported) return { available: false, reason: null };
  if (a.covered) return { available: false, reason: null }; // nothing to fund
  if (!state) return { available: false, reason: null };
  if (state.strict) return { available: false, reason: "Permit3 strict mode is on for this token: gasless funding uses a direct approval, which strict mode refuses" };
  if (a.needsWrap) return { available: false, reason: "needs a wrap first" };
  if (a.multiOrder) return { available: false, reason: "a TWAP signs one slice at a time; fund it with approvals" };
  return { available: true, reason: null };
}

export interface Call {
  to: Address;
  data: Hex;
  /** Native coin sent with the call (only a wrap carries any). */
  value?: bigint;
  /** What the transaction does, for the status line ("Approve to Permit3"). */
  label?: string;
}

/** The WETH9 surface of a wrapped native coin (WRBTC 0x542f…: verified WETH9 port, solc 0.5.17). */
export const WRAPPED_NATIVE_ABI = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "withdraw", stateMutability: "nonpayable", inputs: [{ name: "wad", type: "uint256" }], outputs: [] },
] as const;

/** `WRAPPED.deposit{value: amount}()`. */
export function wrapCall(wrapped: Address, amount: bigint): Call {
  return { to: wrapped, data: encodeFunctionData({ abi: WRAPPED_NATIVE_ABI, functionName: "deposit" }), value: amount };
}

/** `WRAPPED.withdraw(amount)` — back to the native coin. */
export function unwrapCall(wrapped: Address, amount: bigint): Call {
  return { to: wrapped, data: encodeFunctionData({ abi: WRAPPED_NATIVE_ABI, functionName: "withdraw", args: [amount] }) };
}

export interface FundingTargets {
  token: Address;
  permit3: Address;
  settlement: Address;
}

const approveData = (spender: Address, amount: bigint): Hex =>
  encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, amount] });

/**
 * The calldata for a plan. The book grant names SETTLEMENT as the spender — the
 * contract that calls `transferFrom`. A wrap deposits into `t.token` itself: the
 * plan only holds one when that token is the wrapped native coin.
 */
export function fundingCalls(steps: readonly FundingStep[], t: FundingTargets): Call[] {
  return steps.map((s) =>
    s.kind === "wrap"
      ? { ...wrapCall(t.token, s.amount), label: `Wrap ${fmtWei(s.amount)}` }
      : s.kind === "direct-approve"
        ? { to: t.token, data: approveData(t.settlement, s.amount), label: "Approve to Settlement" }
        : s.kind === "erc20-approve"
        ? { to: t.token, data: approveData(t.permit3, s.amount), label: "Approve to Permit3" }
        : { to: t.permit3, data: encodeApproveToken(t.settlement, t.token, s.amount, s.expiration), label: "Grant Settlement via Permit3" },
  );
}

/**
 * Clear every funding surface: the ERC-20 approval to Permit3, the book grant to
 * Settlement, and a direct approval to Settlement (what a relayed gasless permit leaves).
 */
export function revokeCalls(state: FundingState, t: FundingTargets): Call[] {
  const calls: Call[] = [];
  if (state.grantAmount > 0n) calls.push({ to: t.permit3, data: encodeRevokeToken(t.settlement, t.token), label: "Revoke the Permit3 grant" });
  if (state.erc20Allowance > 0n) calls.push({ to: t.token, data: approveData(t.permit3, 0n), label: "Revoke the approval" });
  if ((state.directAllowance ?? 0n) > 0n) calls.push({ to: t.token, data: approveData(t.settlement, 0n), label: "Revoke the direct approval to Settlement" });
  return calls;
}

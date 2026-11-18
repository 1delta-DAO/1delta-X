import { answersHash, feedbackTypedData, PARTICIPATION_QUESTIONS, type ParticipationAnswers, type Question } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import { msg, t } from "../i18n";

/**
 * The prize draw's client side. The draw itself is fixed copy (config/promotion.ts) and
 * is evaluated by hand; nothing on the orderbook configures it. The worker's `/raffle`
 * desk only keeps the optional feedback form, and this decides what the feedback
 * control shows. There is NO entry (TC §4.1): every wallet that trades is in.
 */

/** `GET /raffle/status/:address`. */
export interface RaffleStatus {
  /** The book keeps a feedback form (RAFFLE_ID set). */
  feedbackForm: boolean;
  promotion?: string;
  chainId?: number;
  address?: string;
  traded?: boolean;
  entered?: boolean;
  enteredAt?: number;
  updatedAt?: number;
}

/** What the feedback control shows. Feedback is optional and changes nothing about the draw. */
export type ParticipateView =
  /** No feedback form on this book (or no book in this build): no control at all. */
  | { kind: "hidden" }
  | { kind: "connect" }
  /** Connected, no fill as maker yet: ratings come from users, so the form waits. */
  | { kind: "locked" }
  | { kind: "open" }
  | { kind: "entered"; enteredAt: number };

export function participateView(status: RaffleStatus | null, address: string | null): ParticipateView {
  if (!status || !status.feedbackForm || !status.promotion) return { kind: "hidden" };
  if (!address) return { kind: "connect" };
  if (status.address && status.address.toLowerCase() !== address.toLowerCase()) return { kind: "hidden" };
  if (status.entered) return { kind: "entered", enteredAt: status.enteredAt ?? 0 };
  return status.traded ? { kind: "open" } : { kind: "locked" };
}

export async function fetchRaffleStatus(base: string, address: string, init?: RequestInit): Promise<RaffleStatus> {
  const res = await fetch(`${base}/raffle/status/${address.toLowerCase()}`, { ...init, headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(res.status === 429 ? "rate limited" : `the orderbook answered ${res.status}`);
  return (await res.json()) as RaffleStatus;
}

/** `GET /raffle` — the feedback count for the notice. */
export async function fetchRaffleSummary(base: string, init?: RequestInit): Promise<{ feedbackForm: boolean; promotion?: string; feedback?: number }> {
  const res = await fetch(`${base}/raffle`, { ...init, headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`the orderbook answered ${res.status}`);
  return (await res.json()) as { feedbackForm: boolean; promotion?: string; feedback?: number };
}

/**
 * The feedback form's copy, which lives in the SDK (the worker validates against the
 * same questions). Shown through `t()`; the English option stays the answer's value,
 * because it is what gets hashed, signed and posted.
 */
export const FEEDBACK_FORM_COPY: readonly string[] = [
  msg("Overall, how would you rate the app?"),
  msg("Poor"),
  msg("Excellent"),
  msg("How easy was placing your order?"),
  msg("Very hard"),
  msg("Very easy"),
  msg("How safe did you feel while your order was pending?"),
  msg("Very uneasy"),
  msg("Completely safe"),
  msg("Fill speed and price, compared with what you expected"),
  msg("Much worse"),
  msg("Much better"),
  msg("What did you trade for?"),
  msg("Exit USDRIF"),
  msg("Get RBTC"),
  msg("Buy or sell RIF"),
  msg("Try the app"),
  msg("Other"),
  msg("What confused you or nearly stopped you?"),
  msg("Which order types would you use next?"),
  msg("Limit orders"),
  msg("Scheduled / TWAP"),
  msg("Take-profit / stop-loss"),
  msg("Orders on lending positions"),
  msg("None of these"),
];

/** `validateAnswers`' problem as the form shows it. The SDK phrases it in English; an unrecognised one is shown as it came. */
export function problemText(problem: string, questions: readonly Question[] = PARTICIPATION_QUESTIONS): string {
  for (const q of questions) {
    const head = `"${q.label}"`;
    if (!problem.startsWith(head)) continue;
    const label = t(q.label);
    const rest = problem.slice(head.length);
    if (rest === " is required") return t('"{label}" is required', { label });
    if (rest === ": remove leading or trailing spaces") return t('"{label}": remove leading or trailing spaces', { label });
  }
  return problem;
}

export interface TypedDataSigner {
  signTypedData(parameters: never): Promise<Hex>;
}

/** Sign the feedback and post it. Throws the desk's own error message on a refusal. */
export async function submitParticipation(args: {
  base: string;
  signer: TypedDataSigner;
  chainId: number;
  participant: Address;
  promotion: string;
  answers: ParticipationAnswers;
  now?: () => number;
}): Promise<{ entered: true; updated: boolean; enteredAt: number }> {
  const issuedAt = BigInt(Math.floor((args.now ?? Date.now)() / 1000));
  const td = feedbackTypedData(args.chainId, { participant: args.participant, promotion: args.promotion, answers: answersHash(args.answers), issuedAt });
  const signature = await args.signer.signTypedData({ account: args.participant, ...td } as never);
  const res = await fetch(`${args.base}/raffle/entries`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ participant: args.participant, promotion: args.promotion, issuedAt: issuedAt.toString(), answers: args.answers, signature }),
  });
  const body = (await res.json().catch(() => ({}))) as { error?: string; updated?: boolean; enteredAt?: number };
  if (!res.ok) throw new Error(body.error ?? t("the orderbook answered {status}", { status: res.status }));
  return { entered: true, updated: !!body.updated, enteredAt: body.enteredAt ?? Number(issuedAt) };
}

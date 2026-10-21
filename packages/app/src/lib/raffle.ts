import { answersHash, feedbackTypedData, type ParticipationAnswers } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

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
  if (!res.ok) throw new Error(body.error ?? `the orderbook answered ${res.status}`);
  return { entered: true, updated: !!body.updated, enteredAt: body.enteredAt ?? Number(issuedAt) };
}

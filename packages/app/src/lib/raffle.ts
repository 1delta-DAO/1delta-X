import { answersHash, claimTypedData, feedbackTypedData, type ParticipationAnswers } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

/**
 * The prize draw's client side: the orderbook worker's `/raffle` desk (src/raffle.ts
 * there) and the decisions the notice makes from it — what the feedback control shows,
 * and whether the connected wallet has a prize to claim. There is NO entry (TC §4.1):
 * every wallet that trades is in. The worker enforces every rule again.
 */

/** The draw rules the desk publishes (orderbook-worker `RaffleConfig`). */
export interface RaffleRules {
  qualifierUsd: number;
  periodDays: number;
  minQualifiers: number;
  prizes: number[];
  prizeToken: string;
  onePrizePerAddress: boolean;
}

/** `GET /raffle/status/:address`. */
/** A draw the connected address won (`GET /raffle/status/:address` → `wins`). */
export interface Win {
  day: string;
  payout: number;
  token: string;
  drawnAt: number;
  /** Unix seconds: the claim window (TC §7.5, 14 days). */
  claimBy: number;
  claimed: boolean;
  claimedAt?: number;
}

export interface RaffleStatus {
  live: boolean;
  rules?: RaffleRules;
  wins?: Win[];
  promotion?: string;
  terms?: Hex;
  startsAt?: number;
  endsAt?: number | null;
  chainId?: number;
  address?: string;
  traded?: boolean;
  entered?: boolean;
  enteredAt?: number;
  updatedAt?: number;
}

/** What the feedback control shows. Feedback is optional and changes nothing about the draw. */
export type ParticipateView =
  /** No draw on the desk (or no desk in this build): no control at all. */
  | { kind: "hidden" }
  | { kind: "connect" }
  /** Connected, no fill as maker yet: ratings come from users, so the form waits. */
  | { kind: "locked" }
  | { kind: "open" }
  | { kind: "entered"; enteredAt: number };

export function participateView(status: RaffleStatus | null, address: string | null): ParticipateView {
  if (!status || !status.live || !status.promotion) return { kind: "hidden" };
  if (!address) return { kind: "connect" };
  if (status.address && status.address.toLowerCase() !== address.toLowerCase()) return { kind: "hidden" };
  if (status.entered) return { kind: "entered", enteredAt: status.enteredAt ?? 0 };
  return status.traded ? { kind: "open" } : { kind: "locked" };
}

/**
 * The prize the connected wallet should claim now, if any: unclaimed, inside its window.
 * `termsMismatch` when the desk's Terms are not this build's — the claim signs the
 * Terms by hash, so the user must reload to see the text they would accept.
 */
export function claimView(status: RaffleStatus | null, address: string | null, termsHash: Hex, now = Math.floor(Date.now() / 1000)): { win: Win; termsMismatch: boolean } | null {
  if (!status || !address || !status.promotion || !status.wins?.length) return null;
  if (status.address && status.address.toLowerCase() !== address.toLowerCase()) return null;
  const win = status.wins.find((w) => !w.claimed && now <= w.claimBy) ?? null;
  if (!win) return null;
  return { win, termsMismatch: (status.terms ?? "").toLowerCase() !== termsHash.toLowerCase() };
}

export async function fetchRaffleStatus(base: string, address: string, init?: RequestInit): Promise<RaffleStatus> {
  const res = await fetch(`${base}/raffle/status/${address.toLowerCase()}`, { ...init, headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(res.status === 429 ? "rate limited" : `the orderbook answered ${res.status}`);
  return (await res.json()) as RaffleStatus;
}

/** `GET /raffle` — the public entrant count for the notice. */
export async function fetchRaffleSummary(base: string, init?: RequestInit): Promise<{ live: boolean; entrants?: number; rules?: RaffleRules }> {
  const res = await fetch(`${base}/raffle`, { ...init, headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`the orderbook answered ${res.status}`);
  return (await res.json()) as { live: boolean; entrants?: number; rules?: RaffleRules };
}

const usd = (n: number) => `US$${Number.isInteger(n) ? n : n.toFixed(2)}`;
const every = (d: number) => (d === 1 ? "every day" : d === 7 ? "every week" : `every ${d} days`);

/**
 * The notice's sentences, from the published rules — so the app never states a
 * cadence or a prize the desk is not running. `null` without rules (an old worker):
 * the caller falls back to the compiled-in copy.
 */
export function describeRules(r: RaffleRules | undefined): { lead: string; fine: string } | null {
  if (!r || !r.prizes.length) return null;
  const winners = r.prizes.length === 1 ? `${r.prizes[0]} ${r.prizeToken} to one winner` : `${r.prizes.join(" / ")} ${r.prizeToken} to ${r.prizes.length} winners`;
  const lead = `There is a prize draw ${every(r.periodDays)}, and every wallet that trades is in it: no sign-up. Each day you trade at least ${usd(r.qualifierUsd)} on Rootstock is one ticket, and each draw pays ${winners} picked at random.`;
  const parts = [
    `A draw with fewer than ${r.minQualifiers} qualifying addresses is carried forward, so the next prize is bigger.`,
    ...(r.onePrizePerAddress ? ["One prize per address while others are still waiting to win."] : []),
    "A winner confirms eligibility here before the prize is paid to the winning address.",
  ];
  return { lead, fine: parts.join(" ") };
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

/** A drawn winner signs the eligibility confirmations (TC §3, §7.5) and posts the claim. */
export async function submitClaim(args: {
  base: string;
  signer: TypedDataSigner;
  chainId: number;
  participant: Address;
  promotion: string;
  draw: string;
  terms: Hex;
  now?: () => number;
}): Promise<{ claimed: true; payout?: number; token?: string }> {
  const issuedAt = BigInt(Math.floor((args.now ?? Date.now)() / 1000));
  const td = claimTypedData(args.chainId, { participant: args.participant, promotion: args.promotion, draw: args.draw, terms: args.terms, issuedAt });
  const signature = await args.signer.signTypedData({ account: args.participant, ...td } as never);
  const res = await fetch(`${args.base}/raffle/claims`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ participant: args.participant, promotion: args.promotion, draw: args.draw, terms: args.terms, issuedAt: issuedAt.toString(), signature }),
  });
  const body = (await res.json().catch(() => ({}))) as { error?: string; payout?: number; token?: string };
  if (!res.ok) throw new Error(body.error ?? `the orderbook answered ${res.status}`);
  return { claimed: true, ...(body.payout !== undefined ? { payout: body.payout, token: body.token } : {}) };
}

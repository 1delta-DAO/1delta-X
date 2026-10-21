import type { ParticipationAnswers, Question } from "@1delta-x/sdk";

import type { FillWire } from "@app/lib/dashboard";
import type { Snapshot } from "./draw";

/**
 * The admin page's client for the orderbook's `/raffle/admin/*` routes (through the
 * app's `/api/book` proxy, which forwards `authorization` for these routes only). The
 * token is the worker's `RAFFLE_ADMIN_TOKEN`; the page keeps it in sessionStorage.
 */

export interface RaffleConfig {
  id: string;
  terms: `0x${string}`;
  startsAt: number;
  endsAt: number;
  qualifierUsd: number;
  exclude: string[];
  testers: string[];
  periodDays: number;
  minQualifiers: number;
  prizes: number[];
  prizeToken: string;
  onePrizePerAddress: boolean;
}

export interface AdminConfig {
  source: "env" | "admin" | "disabled" | "none";
  effective: RaffleConfig | null;
  env: RaffleConfig | null;
  live: boolean;
  testMode: boolean;
  now: number;
  chainId: number;
  questions: Question[];
}

export interface AdminEntry {
  address: string;
  enteredAt: number;
  updatedAt: number;
  issuedAt: number;
  answers: ParticipationAnswers;
  signature: string;
  source: "signed" | "manual";
  note: string | null;
}

export interface PromotionRow {
  promotion: string;
  entries: number;
  firstEntry: number | null;
  lastUpdate: number | null;
  draws: number;
}

export interface SavedDraw extends Snapshot {
  updatedAt: number;
  /** Winners who have confirmed eligibility (signed in the app, or recorded by an admin). */
  claimed: string[];
}

export interface Win {
  day: string;
  payout: number;
  token: string;
  drawnAt: number;
  claimBy: number;
  claimed: boolean;
  claimedAt?: number;
}

export interface Claim {
  day: string;
  address: string;
  claimedAt: number;
  source: "signed" | "manual";
  note: string | null;
  signature: string;
}

export class AdminError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

/** "No end" on the worker is MAX_SAFE_INTEGER. */
export const NO_END = Number.MAX_SAFE_INTEGER;

export class AdminApi {
  constructor(
    private readonly base: string,
    private readonly token: string,
  ) {}

  private async req<T>(method: string, path: string, body?: unknown, promotion?: string): Promise<T> {
    const q = promotion ? `${path.includes("?") ? "&" : "?"}promotion=${encodeURIComponent(promotion)}` : "";
    const res = await fetch(`${this.base}${path}${q}`, {
      method,
      headers: {
        accept: "application/json",
        authorization: `Bearer ${this.token}`,
        ...(body !== undefined ? { "content-type": "application/json" } : {}),
      },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    const json = (await res.json().catch(() => ({}))) as { error?: string };
    if (!res.ok) throw new AdminError(json.error ?? `HTTP ${res.status}`, res.status);
    return json as T;
  }

  config = () => this.req<AdminConfig>("GET", "/raffle/admin/config");
  saveConfig = (c: RaffleConfig) => this.req<AdminConfig>("PUT", "/raffle/admin/config", { ...c, endsAt: c.endsAt === NO_END ? undefined : c.endsAt });
  disable = () => this.req<AdminConfig>("PUT", "/raffle/admin/config", { disabled: true });
  revertToEnv = () => this.req<AdminConfig>("DELETE", "/raffle/admin/config");
  promotions = () => this.req<{ promotions: PromotionRow[] }>("GET", "/raffle/admin/promotions");
  entries = (promotion?: string) => this.req<{ promotion: string; questions: Question[]; count: number; entries: AdminEntry[] }>("GET", "/raffle/admin/entries", undefined, promotion);
  removeEntry = (address: string, promotion?: string) => this.req<{ removed: boolean }>("DELETE", `/raffle/admin/entries/${address.toLowerCase()}`, undefined, promotion);
  claims = (promotion?: string) => this.req<{ promotion: string; claims: Claim[] }>("GET", "/raffle/admin/claims", undefined, promotion);
  confirmClaim = (c: { address: string; day: string; note: string }, promotion?: string) => this.req<{ claim: Claim }>("POST", "/raffle/admin/claims", c, promotion);
  removeClaim = (day: string, address: string, promotion?: string) => this.req<{ removed: boolean }>("DELETE", `/raffle/admin/claims/${day}/${address.toLowerCase()}`, undefined, promotion);
  lookup = (address: string, promotion?: string) =>
    this.req<{ address: string; promotion: string | null; fills: number; firstFillAt: number | null; entered: boolean; entry?: AdminEntry; wins: Win[]; claims: Claim[] }>(
      "GET",
      `/raffle/admin/status?address=${address.toLowerCase()}`,
      undefined,
      promotion,
    );
  reset = (promotion: string, confirm: string) => this.req<{ entriesRemoved: number; drawsRemoved: number }>("POST", "/raffle/admin/reset", { promotion, confirm });
  draws = (promotion?: string) => this.req<{ promotion: string; draws: SavedDraw[] }>("GET", "/raffle/admin/draws", undefined, promotion);
  saveDraw = (s: Snapshot) => this.req<{ saved: boolean }>("PUT", `/raffle/admin/draws/${s.day}`, s, s.promotion);
  removeDraw = (day: string, promotion?: string) => this.req<{ removed: boolean }>("DELETE", `/raffle/admin/draws/${day}`, undefined, promotion);

  /** Public routes, for the self-test (what a visitor / a tester sees). */
  publicSummary = () => fetch(`${this.base}/raffle`).then((r) => r.json() as Promise<{ live: boolean; promotion?: string; terms?: string; entrants?: number }>);
  publicStatus = (address: string) =>
    fetch(`${this.base}/raffle/status/${address.toLowerCase()}`).then((r) => r.json() as Promise<{ live: boolean; traded?: boolean; entered?: boolean; terms?: string }>);
}

/** Every indexed fill since `fromSec` (newest first, paged), for the draw. */
export async function fillsSince(base: string, fromSec: number): Promise<FillWire[]> {
  const out: FillWire[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 200; page++) {
    const q = new URLSearchParams({ limit: "500", ...(cursor ? { cursor } : {}) });
    const res = await fetch(`${base}/fills?${q}`, { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`fills: HTTP ${res.status}`);
    const body = (await res.json()) as { fills: FillWire[]; nextCursor?: string };
    out.push(...body.fills);
    const oldest = body.fills[body.fills.length - 1]?.at;
    if (!body.nextCursor || (typeof oldest === "number" && oldest < fromSec)) break;
    cursor = body.nextCursor;
  }
  return out;
}

/** Per-question tallies of the feedback: option counts, a 1–5 average, or the free-text answers. */
export type Tally =
  | { q: Question; kind: "counts"; answered: number; counts: Array<[string, number]> }
  | { q: Question; kind: "scale"; answered: number; average: number | null; counts: Array<[string, number]> }
  | { q: Question; kind: "texts"; answered: number; texts: Array<{ address: string; text: string }> };

export function tallyFeedback(questions: readonly Question[], entries: readonly AdminEntry[]): Tally[] {
  return questions
    .map((q): Tally => {
      const values = entries.map((e) => ({ address: e.address, v: e.answers[q.id] })).filter((x) => x.v !== undefined);
      if (q.kind === "choice" || q.kind === "multi") {
        const counts = new Map<string, number>(q.options.map((o) => [o, 0]));
        for (const { v } of values) for (const o of Array.isArray(v) ? v : [v as string]) counts.set(o, (counts.get(o) ?? 0) + 1);
        return { q, kind: "counts", answered: values.length, counts: [...counts.entries()] };
      }
      if (q.kind === "scale") {
        const nums = values.map((x) => Number(x.v)).filter((n) => Number.isFinite(n));
        const counts: Array<[string, number]> = [1, 2, 3, 4, 5].map((n) => [String(n), nums.filter((x) => x === n).length]);
        return { q, kind: "scale", answered: nums.length, average: nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : null, counts };
      }
      return { q, kind: "texts", answered: values.length, texts: values.map((x) => ({ address: x.address, text: String(x.v) })) };
    });
}

/** The entries as CSV (one column per question; multi-selects joined with " | "). */
export function entriesCsv(questions: readonly Question[], entries: readonly AdminEntry[]): string {
  const cell = (v: unknown) => {
    const s = v === undefined || v === null ? "" : Array.isArray(v) ? v.join(" | ") : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const head = ["address", "enteredAt", "updatedAt", "source", "note", ...questions.map((q) => q.id)];
  const rows = entries.map((e) =>
    [e.address, new Date(e.enteredAt * 1000).toISOString(), new Date(e.updatedAt * 1000).toISOString(), e.source, e.note, ...questions.map((q) => e.answers[q.id])].map(cell).join(","),
  );
  return [head.join(","), ...rows].join("\n") + "\n";
}

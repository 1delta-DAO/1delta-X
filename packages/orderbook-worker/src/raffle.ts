import { answersHash, canonicalAnswers, claimTypedData, feedbackTypedData, validateAnswers, PARTICIPATION_QUESTIONS, type ParticipationAnswers } from "@1delta-x/sdk";
import { hashTypedData, isAddress, recoverTypedDataAddress, type Address, type Hex } from "viem";

import { parseRaffleConfig, type RaffleConfig, type WorkerConfig } from "./config";
import type { CoreDeps } from "./core";
import { ROUTE_COST } from "./ratelimit";
import { count, getMeta, setMeta, type Sql } from "./store";

/**
 * THE PRIZE DRAW'S DESK (2026-10-21).
 *
 * The Promotion Terms (TC.md, reviewed and frozen) govern what this does:
 *
 *   • §4.1 — NO registration: every wallet that trades is considered automatically.
 *     Nothing here is an entry. The draw tool (packages/raffle-admin) lists qualifiers
 *     from the fill index alone; `raffle_entries` holds optional FEEDBACK forms.
 *   • §4.2/4.3, §6.2 — the qualifying criteria and the number, timing and amount of
 *     prizes are 1delta's to set and communicate: the published `rules` on GET /raffle
 *     (period length, qualifier, minimum qualifiers with carry-forward, prizes, one
 *     prize per address) are that communication, and the app notice repeats them.
 *   • §3, §7.5, §8 — a drawn winner CLAIMS the prize by signing the eligibility
 *     confirmations (`raffle_claims`); the operator pays claimed prizes only, and may
 *     forfeit one not confirmed within 14 days.
 *
 * Feedback: posted as EIP-712 typed data (`@1delta-x/sdk` participation.ts) by an
 * address with at least one indexed fill as maker since the start (so ratings come
 * from users), one row per (promotion, address), a newer signature replaces the
 * answers. Claims: typed data naming the promotion, the draw record and the Terms
 * hash, accepted only for an address the saved draw result names.
 *
 * CONFIGURATION: `RAFFLE_*` is the deploy-time default; an admin can override it from
 * the console (`PUT /raffle/admin/config`, stored in `meta`), switch it off, reset a
 * promotion's feedback, draws and claims, and confirm a claim by hand. Every
 * `/raffle/admin/*` route needs the `RAFFLE_ADMIN_TOKEN` bearer, checked by the entry
 * worker.
 *
 * No personal data: the forms ask none; a winner is the wallet address the draw picks.
 */

/** A signed form older or newer than this (vs the worker clock) is refused. */
export const ISSUED_AT_SKEW_SECONDS = 24 * 3600;
/** The desk stops taking NEW addresses past this many feedback forms (updates still land). */
export const MAX_ENTRIES = 50_000;
/** A winner may claim this long after the draw (TC §7.5: 14 days); later, an admin confirms by hand. */
export const CLAIM_WINDOW_SECONDS = 14 * 24 * 3600;
/** A saved draw record (the snapshot JSON) is at most this large. */
export const MAX_DRAW_BYTES = 200_000;
const CONFIG_KEY = "raffleConfig";

export interface RaffleContext {
  sql: Sql;
  cfg: WorkerConfig;
  deps: CoreDeps;
  /** Per-IP budget (the core's `gate`). */
  gate(ip: string, cost: number): Response | undefined;
  /** Per-key budget on the maker bucket (the core's `gateMaker`). */
  gateKey(key: string, cost: number): Response | undefined;
  readJsonBody(request: Request): Promise<unknown | Response>;
  json(body: unknown, status?: number, headers?: Record<string, string>): Response;
}

interface EntryRow {
  address: string;
  entered_at: number;
  updated_at: number;
  issued_at: number;
  answers: string;
  signature: string;
  source: string;
  note: string | null;
}

interface ClaimRow {
  day: string;
  address: string;
  claimed_at: number;
  signature: string;
  source: string;
  note: string | null;
}

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const SIG = /^0x[0-9a-fA-F]+$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

// ──────────────────── configuration ────────────────────

type Override = { disabled: true } | { config: RaffleConfig };

function override(sql: Sql): Override | undefined {
  const raw = getMeta(sql, CONFIG_KEY);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as Override;
  } catch {
    return undefined;
  }
}

/** The effective draw: the admin's saved one, else `RAFFLE_*`; undefined = none / switched off. */
export function effectiveRaffle(ctx: Pick<RaffleContext, "sql" | "cfg">): RaffleConfig | undefined {
  const o = override(ctx.sql);
  if (o && "disabled" in o) return undefined;
  if (o && "config" in o) return o.config;
  return ctx.cfg.raffle;
}

// ──────────────────── routing ────────────────────

/** Answer a `/raffle…` request; `undefined` for a path that is not one of the desk's. */
export async function handleRaffle(ctx: RaffleContext, path: string, method: string, request: Request, ip: string, admin: boolean): Promise<Response | undefined> {
  const { json } = ctx;
  const notAllowed = (allow: string) => json({ error: "method not allowed" }, 405, { allow });
  if (path.startsWith("/raffle/admin/") || path === "/raffle/admin") {
    if (!admin) return json({ error: "forbidden: needs the raffle admin token" }, 403);
    return adminRoute(ctx, path.slice("/raffle/admin".length), method, request);
  }
  const r = effectiveRaffle(ctx);
  if (path === "/raffle") return method === "GET" ? (ctx.gate(ip, ROUTE_COST.read) ?? summary(ctx, r)) : notAllowed("GET");
  const m = /^\/raffle\/status\/(0x[0-9a-fA-F]{40})$/.exec(path);
  if (m) return method === "GET" ? (ctx.gate(ip, ROUTE_COST.read) ?? status(ctx, r, m[1]!.toLowerCase())) : notAllowed("GET");
  if (path === "/raffle/entrants") return method === "GET" ? (ctx.gate(ip, ROUTE_COST.query) ?? entrants(ctx, r)) : notAllowed("GET");
  if (path === "/raffle/draws") return method === "GET" ? (ctx.gate(ip, ROUTE_COST.query) ?? publicDraws(ctx, r)) : notAllowed("GET");
  if (path === "/raffle/entries") return method === "POST" ? await postEntry(ctx, r, request, ip) : notAllowed("POST");
  if (path === "/raffle/claims") return method === "POST" ? await postClaim(ctx, r, request, ip) : notAllowed("POST");
  return undefined;
}

function window(ctx: RaffleContext, r: RaffleConfig): { open: boolean; reason?: string } {
  const now = ctx.deps.now();
  if (now < r.startsAt) return { open: false, reason: "the promotion has not started yet" };
  if (now >= r.endsAt) return { open: false, reason: "entries for this promotion are closed" };
  return { open: true };
}

/** Live for `address` (or for the public, when absent): open, and in test mode only for a tester. */
function liveFor(ctx: RaffleContext, r: RaffleConfig, address?: string): boolean {
  if (!window(ctx, r).open) return false;
  if (r.testers.length === 0) return true;
  return !!address && r.testers.includes(address);
}

function head(ctx: RaffleContext, r: RaffleConfig | undefined, address?: string): Record<string, unknown> {
  if (!r) return { live: false };
  return {
    live: liveFor(ctx, r, address),
    promotion: r.id,
    terms: r.terms,
    startsAt: r.startsAt,
    endsAt: r.endsAt === Number.MAX_SAFE_INTEGER ? null : r.endsAt,
    chainId: ctx.cfg.chain.chainId,
    // The published rules: what the app notice says and what the draw tool applies.
    rules: {
      qualifierUsd: r.qualifierUsd,
      periodDays: r.periodDays,
      minQualifiers: r.minQualifiers,
      prizes: r.prizes,
      prizeToken: r.prizeToken,
      onePrizePerAddress: r.onePrizePerAddress,
      pot: r.pot,
      // What the saved draws have paid out so far (claimed or not), so the notice can say what is left.
      paidOut: drawRecords(ctx, r.id).reduce((a, d) => a + (d.result?.winners.length ? (d.payouts ?? []).slice(0, d.result.winners.length).reduce((x, y) => x + y, 0) : 0), 0),
    },
    ...(r.testers.length ? { testMode: true } : {}),
  };
}

function summary(ctx: RaffleContext, r: RaffleConfig | undefined): Response {
  // In test mode the public sees nothing — not even the promotion id.
  if (r && r.testers.length) return ctx.json({ live: false });
  return ctx.json({ ...head(ctx, r), ...(r ? { entrants: count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, r.id) } : {}) });
}

/** The address's first fill as maker since `startsAt` (unix seconds; a row without a block time counts at 0). */
function firstFill(ctx: RaffleContext, address: string, startsAt: number): number | null {
  const row = ctx.sql
    .exec<{ at: number | null; n: number }>(`SELECT MIN(COALESCE(at, 0)) AS at, COUNT(*) AS n FROM fills WHERE maker = ? AND (at IS NULL OR at >= ?)`, address, startsAt)
    .toArray()[0];
  return row && Number(row.n) > 0 ? Number(row.at ?? 0) : null;
}

function entryOf(ctx: RaffleContext, promotion: string, address: string): EntryRow | undefined {
  return ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address).toArray()[0];
}

function status(ctx: RaffleContext, r: RaffleConfig | undefined, address: string): Response {
  if (!r) return ctx.json({ live: false, address });
  if (r.testers.length && !r.testers.includes(address)) return ctx.json({ live: false, address });
  const entry = entryOf(ctx, r.id, address);
  return ctx.json({
    ...head(ctx, r, address),
    address,
    traded: firstFill(ctx, address, r.startsAt) !== null,
    entered: !!entry,
    ...(entry ? { enteredAt: entry.entered_at, updatedAt: entry.updated_at } : {}),
    wins: winsOf(ctx, r.id, address),
  });
}

interface DrawRecord {
  day: string;
  skipped?: boolean;
  payouts?: number[];
  rules?: { prizeToken?: string };
  result?: { winners: string[]; drawnAt: number };
}

function drawRecords(ctx: RaffleContext, promotion: string): DrawRecord[] {
  return ctx.sql
    .exec<{ day: string; snapshot: string }>(`SELECT day, snapshot FROM raffle_draws WHERE promotion = ? ORDER BY day ASC`, promotion)
    .toArray()
    .map((d) => ({ ...(JSON.parse(d.snapshot) as DrawRecord), day: d.day }));
}

function claimOf(ctx: RaffleContext, promotion: string, day: string, address: string): ClaimRow | undefined {
  return ctx.sql.exec<ClaimRow>(`SELECT * FROM raffle_claims WHERE promotion = ? AND day = ? AND address = ?`, promotion, day, address).toArray()[0];
}

/** The draws `address` won: what it is owed, whether it has claimed, and until when it can. */
function winsOf(ctx: RaffleContext, promotion: string, address: string) {
  const out: Array<{ day: string; payout: number; token: string; drawnAt: number; claimBy: number; claimed: boolean; claimedAt?: number }> = [];
  for (const d of drawRecords(ctx, promotion)) {
    const i = d.result?.winners.map((w) => w.toLowerCase()).indexOf(address) ?? -1;
    if (i < 0 || !d.result) continue;
    const c = claimOf(ctx, promotion, d.day, address);
    out.push({ day: d.day, payout: d.payouts?.[i] ?? 0, token: d.rules?.prizeToken ?? "", drawnAt: d.result.drawnAt, claimBy: d.result.drawnAt + CLAIM_WINDOW_SECONDS, claimed: !!c, ...(c ? { claimedAt: c.claimed_at } : {}) });
  }
  return out;
}

function entrants(ctx: RaffleContext, r: RaffleConfig | undefined): Response {
  if (!r || r.testers.length) return ctx.json({ error: "no promotion is running" }, 404);
  const rows = ctx.sql
    .exec<{ address: string; entered_at: number }>(`SELECT address, entered_at FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, r.id)
    .toArray();
  return ctx.json({ promotion: r.id, count: rows.length, entrants: rows.map((e) => ({ address: e.address, enteredAt: e.entered_at })) });
}

function publicDraws(ctx: RaffleContext, r: RaffleConfig | undefined): Response {
  if (!r || r.testers.length) return ctx.json({ error: "no promotion is running" }, 404);
  return ctx.json({ promotion: r.id, draws: draws(ctx, r.id) });
}

function draws(ctx: RaffleContext, promotion: string): unknown[] {
  const claims = ctx.sql.exec<{ day: string; address: string }>(`SELECT day, address FROM raffle_claims WHERE promotion = ?`, promotion).toArray();
  return ctx.sql
    .exec<{ day: string; snapshot: string; updated_at: number }>(`SELECT day, snapshot, updated_at FROM raffle_draws WHERE promotion = ? ORDER BY day ASC`, promotion)
    .toArray()
    .map((d) => ({ day: d.day, updatedAt: d.updated_at, ...(JSON.parse(d.snapshot) as Record<string, unknown>), claimed: claims.filter((c) => c.day === d.day).map((c) => c.address).sort() }));
}

// ──────────────────── POST /raffle/entries (feedback) ────────────────────

interface EntryBody {
  participant: Address;
  promotion: string;
  issuedAt: bigint;
  answers: ParticipationAnswers;
  signature: Hex;
}

function parseEntry(body: unknown): EntryBody | string {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return "body must be a JSON object";
  const b = body as Record<string, unknown>;
  for (const k of Object.keys(b)) if (!["participant", "promotion", "issuedAt", "answers", "signature"].includes(k)) return `unknown field "${k}"`;
  if (typeof b.participant !== "string" || !ADDRESS.test(b.participant) || !isAddress(b.participant, { strict: false })) return "participant must be an address";
  if (typeof b.promotion !== "string") return "promotion must be a string";
  const issued = typeof b.issuedAt === "number" ? String(b.issuedAt) : b.issuedAt;
  if (typeof issued !== "string" || !/^\d{1,12}$/.test(issued)) return "issuedAt must be unix seconds";
  if (typeof b.signature !== "string" || !SIG.test(b.signature) || b.signature.length > 2 + 2 * 4096) return "signature must be hex";
  const bad = validateAnswers(b.answers);
  if (bad) return bad;
  return {
    participant: b.participant.toLowerCase() as Address,
    promotion: b.promotion,
    issuedAt: BigInt(issued),
    answers: b.answers as ParticipationAnswers,
    signature: b.signature as Hex,
  };
}

async function postEntry(ctx: RaffleContext, r: RaffleConfig | undefined, request: Request, ip: string): Promise<Response> {
  const { json } = ctx;
  if (!r) return json({ error: "no promotion is running" }, 404);
  const refused = ctx.gate(ip, ROUTE_COST.write);
  if (refused) return refused;
  const raw = await ctx.readJsonBody(request);
  if (raw instanceof Response) return raw;
  const e = parseEntry(raw);
  if (typeof e === "string") return json({ error: e }, 400);

  const w = window(ctx, r);
  if (!w.open) return json({ error: w.reason }, 403);
  if (r.testers.length && !r.testers.includes(e.participant)) return json({ error: "the promotion is in a closed test" }, 403);
  if (e.promotion !== r.id) return json({ error: "this form is for another promotion" }, 409);
  const now = ctx.deps.now();
  if (Math.abs(Number(e.issuedAt) - now) > ISSUED_AT_SKEW_SECONDS) return json({ error: "the signed form is stale — sign it again" }, 400);
  if (firstFill(ctx, e.participant, r.startsAt) === null) return json({ error: "make at least one swap with this address first" }, 403);

  const before = entryOf(ctx, r.id, e.participant);
  if (before && before.source === "signed" && Number(e.issuedAt) <= before.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  if (!before && count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, r.id) >= MAX_ENTRIES) {
    return json({ error: "the promotion is full" }, 503);
  }
  const billed = ctx.gateKey(`rf:${e.participant}`, ROUTE_COST.write);
  if (billed) return billed;

  const td = feedbackTypedData(ctx.cfg.chain.chainId, { participant: e.participant, promotion: e.promotion, answers: answersHash(e.answers), issuedAt: e.issuedAt });
  if (!(await signedBy(ctx, td, e.participant, e.signature))) return json({ error: "the signature does not match the participant and form" }, 401);

  // Synchronous from here: re-read the row the awaits may have raced.
  const current = entryOf(ctx, r.id, e.participant);
  if (current && current.source === "signed" && Number(e.issuedAt) <= current.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  // A signed form supersedes a manual entry (keeps its original entry time and note).
  ctx.sql.exec(
    `INSERT INTO raffle_entries (promotion, address, entered_at, updated_at, issued_at, answers, signature, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'signed')
     ON CONFLICT(promotion, address) DO UPDATE SET
       updated_at = excluded.updated_at, issued_at = excluded.issued_at,
       answers = excluded.answers, signature = excluded.signature, source = 'signed'`,
    r.id,
    e.participant,
    now,
    now,
    Number(e.issuedAt),
    canonicalAnswers(e.answers),
    e.signature,
  );
  const row = entryOf(ctx, r.id, e.participant)!;
  return json({ entered: true, updated: !!current, address: e.participant, enteredAt: row.entered_at, updatedAt: row.updated_at }, current ? 200 : 201);
}

// ──────────────────── POST /raffle/claims ────────────────────

/**
 * A drawn winner confirms eligibility (TC §3, §7.5) and accepts the Terms by hash. Only
 * an address the saved draw result names, only for the running promotion, only within
 * the claim window; a second claim of the same prize is a no-op.
 */
async function postClaim(ctx: RaffleContext, r: RaffleConfig | undefined, request: Request, ip: string): Promise<Response> {
  const { json } = ctx;
  if (!r) return json({ error: "no promotion is running" }, 404);
  const refused = ctx.gate(ip, ROUTE_COST.write);
  if (refused) return refused;
  const raw = await ctx.readJsonBody(request);
  if (raw instanceof Response) return raw;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return json({ error: "body must be a JSON object" }, 400);
  const b = raw as Record<string, unknown>;
  for (const k of Object.keys(b)) if (!["participant", "promotion", "draw", "terms", "issuedAt", "signature"].includes(k)) return json({ error: `unknown field "${k}"` }, 400);
  if (typeof b.participant !== "string" || !ADDRESS.test(b.participant)) return json({ error: "participant must be an address" }, 400);
  if (typeof b.promotion !== "string" || b.promotion !== r.id) return json({ error: "this claim is for another promotion" }, 409);
  if (typeof b.draw !== "string" || !DAY.test(b.draw)) return json({ error: "draw must be a record key (YYYY-MM-DD)" }, 400);
  if (typeof b.terms !== "string" || b.terms.toLowerCase() !== r.terms) return json({ error: "the Terms have changed since this page loaded — reload and review them" }, 409);
  const issued = typeof b.issuedAt === "number" ? String(b.issuedAt) : b.issuedAt;
  if (typeof issued !== "string" || !/^\d{1,12}$/.test(issued)) return json({ error: "issuedAt must be unix seconds" }, 400);
  if (typeof b.signature !== "string" || !SIG.test(b.signature) || b.signature.length > 2 + 2 * 4096) return json({ error: "signature must be hex" }, 400);
  const participant = b.participant.toLowerCase() as Address;
  const now = ctx.deps.now();
  if (Math.abs(Number(issued) - now) > ISSUED_AT_SKEW_SECONDS) return json({ error: "the signed claim is stale — sign it again" }, 400);

  const win = winsOf(ctx, r.id, participant).find((w) => w.day === b.draw);
  if (!win) return json({ error: "this address was not drawn in that draw" }, 403);
  if (win.claimed) return json({ claimed: true, already: true, day: win.day, claimedAt: win.claimedAt }, 200);
  if (now > win.claimBy) return json({ error: "the claim window for this draw has closed — contact 1delta through its official channels" }, 403);
  const billed = ctx.gateKey(`rc:${participant}`, ROUTE_COST.write);
  if (billed) return billed;

  const td = claimTypedData(ctx.cfg.chain.chainId, { participant, promotion: r.id, draw: b.draw, terms: r.terms, issuedAt: BigInt(issued) });
  if (!(await signedBy(ctx, td, participant, b.signature as Hex))) return json({ error: "the signature does not match the winner and claim" }, 401);
  ctx.sql.exec(
    `INSERT INTO raffle_claims (promotion, day, address, claimed_at, signature, source) VALUES (?, ?, ?, ?, ?, 'signed')
     ON CONFLICT(promotion, day, address) DO NOTHING`,
    r.id,
    b.draw,
    participant,
    now,
    b.signature as string,
  );
  return json({ claimed: true, day: b.draw, payout: win.payout, token: win.token, claimedAt: now }, 201);
}

async function signedBy(ctx: RaffleContext, td: ReturnType<typeof feedbackTypedData> | ReturnType<typeof claimTypedData>, signer: Address, signature: Hex): Promise<boolean> {
  // The two typed-data shapes are checked the same way; viem's generics want one shape, so widen.
  const any = td as unknown as Parameters<typeof hashTypedData>[0];
  try {
    const recovered = await recoverTypedDataAddress({ ...any, signature });
    if (recovered.toLowerCase() === signer) return true;
  } catch {
    // Not a 65-byte ECDSA signature: a contract wallet's, perhaps.
  }
  if (!ctx.deps.isValidSignature) return false;
  return ctx.deps.isValidSignature(signer, hashTypedData(any), signature);
}

// ──────────────────── /raffle/admin/* ────────────────────

async function body(ctx: RaffleContext, request: Request): Promise<Record<string, unknown> | Response> {
  const raw = await ctx.readJsonBody(request);
  if (raw instanceof Response) return raw;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return ctx.json({ error: "body must be a JSON object" }, 400);
  return raw as Record<string, unknown>;
}

/** `?promotion=` or the effective draw's id. */
function promotionOf(ctx: RaffleContext, url: URL): string | undefined {
  const q = url.searchParams.get("promotion");
  if (q !== null) return /^[a-z0-9][a-z0-9-]{0,63}$/.test(q) ? q : undefined;
  return effectiveRaffle(ctx)?.id;
}

async function adminRoute(ctx: RaffleContext, sub: string, method: string, request: Request): Promise<Response> {
  const { json } = ctx;
  const url = new URL(request.url);
  const notAllowed = (allow: string) => json({ error: "method not allowed" }, 405, { allow });

  if (sub === "/config") {
    if (method === "GET") return adminConfig(ctx);
    if (method === "PUT") {
      const b = await body(ctx, request);
      if (b instanceof Response) return b;
      if (b.disabled === true) {
        setMeta(ctx.sql, CONFIG_KEY, JSON.stringify({ disabled: true }));
        return adminConfig(ctx);
      }
      try {
        setMeta(ctx.sql, CONFIG_KEY, JSON.stringify({ config: parseRaffleConfig(b) }));
      } catch (err) {
        return json({ error: err instanceof Error ? err.message : "invalid config" }, 400);
      }
      return adminConfig(ctx);
    }
    if (method === "DELETE") {
      ctx.sql.exec(`DELETE FROM meta WHERE key = ?`, CONFIG_KEY);
      return adminConfig(ctx);
    }
    return notAllowed("GET, PUT, DELETE");
  }

  if (sub === "/promotions") {
    if (method !== "GET") return notAllowed("GET");
    const rows = ctx.sql
      .exec<{ promotion: string; n: number; first: number; last: number }>(
        `SELECT promotion, COUNT(*) AS n, MIN(entered_at) AS first, MAX(updated_at) AS last FROM raffle_entries GROUP BY promotion`,
      )
      .toArray();
    const drawRows = ctx.sql.exec<{ promotion: string; n: number }>(`SELECT promotion, COUNT(*) AS n FROM raffle_draws GROUP BY promotion`).toArray();
    const ids = new Set([...rows.map((r) => r.promotion), ...drawRows.map((d) => d.promotion)]);
    return json({
      promotions: [...ids].sort().map((id) => {
        const e = rows.find((r) => r.promotion === id);
        return { promotion: id, entries: e ? Number(e.n) : 0, firstEntry: e?.first ?? null, lastUpdate: e?.last ?? null, draws: Number(drawRows.find((d) => d.promotion === id)?.n ?? 0) };
      }),
    });
  }

  if (sub === "/entries") {
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    if (method === "GET") return exportEntries(ctx, promotion);
    return notAllowed("GET");
  }

  const one = /^\/entries\/(0x[0-9a-fA-F]{40})$/.exec(sub);
  if (one) {
    if (method !== "DELETE") return notAllowed("DELETE");
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    const address = one[1]!.toLowerCase();
    const had = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address);
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address);
    return json({ promotion, address, removed: had > 0 });
  }

  if (sub === "/status") {
    if (method !== "GET") return notAllowed("GET");
    const a = (url.searchParams.get("address") ?? "").toLowerCase();
    if (!ADDRESS.test(a)) return json({ error: "address is required" }, 400);
    const r = effectiveRaffle(ctx);
    const promotion = promotionOf(ctx, url);
    const first = firstFill(ctx, a, r?.startsAt ?? 0);
    const entry = promotion ? entryOf(ctx, promotion, a) : undefined;
    const fills = count(ctx.sql, `SELECT COUNT(*) AS n FROM fills WHERE maker = ?`, a);
    return json({
      address: a,
      promotion: promotion ?? null,
      fills,
      firstFillAt: first,
      entered: !!entry,
      ...(entry ? { entry: entryJson(entry) } : {}),
      wins: promotion ? winsOf(ctx, promotion, a) : [],
      claims: promotion ? ctx.sql.exec<ClaimRow>(`SELECT * FROM raffle_claims WHERE promotion = ? AND address = ?`, promotion, a).toArray().map(claimJson) : [],
    });
  }

  if (sub === "/claims") {
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    if (method === "GET") {
      return json({ promotion, claims: ctx.sql.exec<ClaimRow>(`SELECT * FROM raffle_claims WHERE promotion = ? ORDER BY day ASC, claimed_at ASC`, promotion).toArray().map(claimJson) });
    }
    if (method === "POST") {
      // A winner confirmed another way (a signed message in Telegram, a call): the admin
      // records it, with a note saying how. The payout review still happens.
      const b = await body(ctx, request);
      if (b instanceof Response) return b;
      const address = typeof b.address === "string" ? b.address.trim().toLowerCase() : "";
      const day = typeof b.day === "string" ? b.day : "";
      const note = typeof b.note === "string" ? b.note.trim() : "";
      if (!ADDRESS.test(address)) return json({ error: "address must be an address" }, 400);
      if (!DAY.test(day)) return json({ error: "day must be a draw record key (YYYY-MM-DD)" }, 400);
      if (!note || note.length > 500) return json({ error: "a note (how the winner confirmed, ≤ 500 chars) is required" }, 400);
      if (!winsOf(ctx, promotion, address).some((w) => w.day === day)) return json({ error: "this address was not drawn in that draw" }, 409);
      ctx.sql.exec(
        `INSERT INTO raffle_claims (promotion, day, address, claimed_at, signature, source, note) VALUES (?, ?, ?, ?, '', 'manual', ?)
         ON CONFLICT(promotion, day, address) DO UPDATE SET note = excluded.note`,
        promotion,
        day,
        address,
        ctx.deps.now(),
        note,
      );
      return json({ promotion, claim: claimJson(claimOf(ctx, promotion, day, address)!) }, 201);
    }
    return notAllowed("GET, POST");
  }

  const oneClaim = /^\/claims\/(\d{4}-\d{2}-\d{2})\/(0x[0-9a-fA-F]{40})$/.exec(sub);
  if (oneClaim) {
    if (method !== "DELETE") return notAllowed("DELETE");
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    ctx.sql.exec(`DELETE FROM raffle_claims WHERE promotion = ? AND day = ? AND address = ?`, promotion, oneClaim[1]!, oneClaim[2]!.toLowerCase());
    return json({ promotion, day: oneClaim[1], address: oneClaim[2]!.toLowerCase(), removed: true });
  }

  if (sub === "/reset") {
    if (method !== "POST") return notAllowed("POST");
    const b = await body(ctx, request);
    if (b instanceof Response) return b;
    const promotion = typeof b.promotion === "string" ? b.promotion : "";
    // Typed twice on purpose: a reset deletes every entry and draw of the promotion.
    if (!promotion || b.confirm !== promotion) return json({ error: "reset needs {promotion, confirm} with confirm equal to the promotion id" }, 400);
    const entries = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, promotion);
    const drawn = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_draws WHERE promotion = ?`, promotion);
    const claims = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_claims WHERE promotion = ?`, promotion);
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ?`, promotion);
    ctx.sql.exec(`DELETE FROM raffle_draws WHERE promotion = ?`, promotion);
    ctx.sql.exec(`DELETE FROM raffle_claims WHERE promotion = ?`, promotion);
    return json({ promotion, entriesRemoved: entries, drawsRemoved: drawn, claimsRemoved: claims });
  }

  if (sub === "/draws") {
    if (method !== "GET") return notAllowed("GET");
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    return json({ promotion, draws: draws(ctx, promotion) });
  }

  const d = /^\/draws\/(\d{4}-\d{2}-\d{2})$/.exec(sub);
  if (d && DAY.test(d[1]!)) {
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    if (method === "PUT") {
      const b = await body(ctx, request);
      if (b instanceof Response) return b;
      const text = JSON.stringify(b);
      if (text.length > MAX_DRAW_BYTES) return json({ error: `a draw record is at most ${MAX_DRAW_BYTES} bytes` }, 413);
      ctx.sql.exec(
        `INSERT INTO raffle_draws (promotion, day, snapshot, updated_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(promotion, day) DO UPDATE SET snapshot = excluded.snapshot, updated_at = excluded.updated_at`,
        promotion,
        d[1]!,
        text,
        ctx.deps.now(),
      );
      return json({ promotion, day: d[1], saved: true });
    }
    if (method === "DELETE") {
      ctx.sql.exec(`DELETE FROM raffle_draws WHERE promotion = ? AND day = ?`, promotion, d[1]!);
      ctx.sql.exec(`DELETE FROM raffle_claims WHERE promotion = ? AND day = ?`, promotion, d[1]!);
      return json({ promotion, day: d[1], removed: true });
    }
    return notAllowed("PUT, DELETE");
  }

  return json({ error: "not found" }, 404);
}

function adminConfig(ctx: RaffleContext): Response {
  const o = override(ctx.sql);
  const effective = effectiveRaffle(ctx);
  return ctx.json({
    source: o ? ("disabled" in o ? "disabled" : "admin") : ctx.cfg.raffle ? "env" : "none",
    effective: effective ?? null,
    env: ctx.cfg.raffle ?? null,
    live: effective ? window(ctx, effective).open : false,
    testMode: !!effective?.testers.length,
    now: ctx.deps.now(),
    chainId: ctx.cfg.chain.chainId,
    questions: PARTICIPATION_QUESTIONS,
  });
}

function entryJson(e: EntryRow) {
  return {
    address: e.address,
    enteredAt: e.entered_at,
    updatedAt: e.updated_at,
    issuedAt: e.issued_at,
    answers: JSON.parse(e.answers) as unknown,
    signature: e.signature,
    source: e.source,
    note: e.note,
  };
}

function exportEntries(ctx: RaffleContext, promotion: string): Response {
  const rows = ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, promotion).toArray();
  return ctx.json({ promotion, questions: PARTICIPATION_QUESTIONS, count: rows.length, entries: rows.map(entryJson) });
}

function claimJson(c: ClaimRow) {
  return { day: c.day, address: c.address, claimedAt: c.claimed_at, source: c.source, note: c.note, signature: c.signature };
}

import { answersHash, canonicalAnswers, feedbackTypedData, validateAnswers, PARTICIPATION_QUESTIONS, type ParticipationAnswers } from "@1delta-x/sdk";
import { hashTypedData, isAddress, recoverTypedDataAddress, type Address, type Hex } from "viem";

import type { WorkerConfig } from "./config";
import type { CoreDeps } from "./core";
import { ROUTE_COST } from "./ratelimit";
import { count, type Sql } from "./store";

/**
 * THE FEEDBACK DESK (2026-10-21). Nothing here configures or runs the prize draw: the
 * Terms (TC.md, reviewed and frozen) promise no registration (§4.1) and leave criteria,
 * timing and amounts to 1delta (§4.2, §6.2), so the app states the draw as fixed copy
 * and the operator evaluates each UTC day by hand off the fill index (the console's
 * Qualifiers tab reads `GET /fills`). This desk only keeps the optional FEEDBACK form:
 * EIP-712 typed data (`@1delta-x/sdk` participation.ts) from an address with at least
 * one indexed fill as maker, so ratings come from users; one row per (RAFFLE_ID,
 * address), a newer signature replaces the answers. Not an entry.
 *
 * Every `/raffle/admin/*` route needs the `RAFFLE_ADMIN_TOKEN` bearer, checked by the
 * entry worker. No personal data anywhere: the form asks none.
 */

/** A signed form older or newer than this (vs the worker clock) is refused. */
export const ISSUED_AT_SKEW_SECONDS = 24 * 3600;
/** The desk stops taking NEW addresses past this many feedback forms (updates still land). */
export const MAX_ENTRIES = 50_000;

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

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const SIG = /^0x[0-9a-fA-F]+$/;

// ──────────────────── routing ────────────────────

/** Answer a `/raffle…` request; `undefined` for a path that is not one of the desk's. */
export async function handleRaffle(ctx: RaffleContext, path: string, method: string, request: Request, ip: string, admin: boolean): Promise<Response | undefined> {
  const { json } = ctx;
  const notAllowed = (allow: string) => json({ error: "method not allowed" }, 405, { allow });
  if (path.startsWith("/raffle/admin/") || path === "/raffle/admin") {
    if (!admin) return json({ error: "forbidden: needs the raffle admin token" }, 403);
    return adminRoute(ctx, path.slice("/raffle/admin".length), method, request);
  }
  const id = ctx.cfg.raffleId;
  if (path === "/raffle") return method === "GET" ? (ctx.gate(ip, ROUTE_COST.read) ?? summary(ctx, id)) : notAllowed("GET");
  const m = /^\/raffle\/status\/(0x[0-9a-fA-F]{40})$/.exec(path);
  if (m) return method === "GET" ? (ctx.gate(ip, ROUTE_COST.read) ?? status(ctx, id, m[1]!.toLowerCase())) : notAllowed("GET");
  if (path === "/raffle/entries") return method === "POST" ? await postEntry(ctx, id, request, ip) : notAllowed("POST");
  return undefined;
}

function summary(ctx: RaffleContext, id: string | undefined): Response {
  if (!id) return ctx.json({ feedbackForm: false });
  return ctx.json({ feedbackForm: true, promotion: id, chainId: ctx.cfg.chain.chainId, feedback: count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, id) });
}

/** The address's first fill as maker (unix seconds; a row without a block time counts at 0). */
function firstFill(ctx: RaffleContext, address: string): number | null {
  const row = ctx.sql.exec<{ at: number | null; n: number }>(`SELECT MIN(COALESCE(at, 0)) AS at, COUNT(*) AS n FROM fills WHERE maker = ?`, address).toArray()[0];
  return row && Number(row.n) > 0 ? Number(row.at ?? 0) : null;
}

function entryOf(ctx: RaffleContext, promotion: string, address: string): EntryRow | undefined {
  return ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address).toArray()[0];
}

function status(ctx: RaffleContext, id: string | undefined, address: string): Response {
  if (!id) return ctx.json({ feedbackForm: false, address });
  const entry = entryOf(ctx, id, address);
  return ctx.json({
    feedbackForm: true,
    promotion: id,
    chainId: ctx.cfg.chain.chainId,
    address,
    traded: firstFill(ctx, address) !== null,
    entered: !!entry,
    ...(entry ? { enteredAt: entry.entered_at, updatedAt: entry.updated_at } : {}),
  });
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

async function postEntry(ctx: RaffleContext, id: string | undefined, request: Request, ip: string): Promise<Response> {
  const { json } = ctx;
  if (!id) return json({ error: "no feedback form on this book" }, 404);
  const refused = ctx.gate(ip, ROUTE_COST.write);
  if (refused) return refused;
  const raw = await ctx.readJsonBody(request);
  if (raw instanceof Response) return raw;
  const e = parseEntry(raw);
  if (typeof e === "string") return json({ error: e }, 400);

  if (e.promotion !== id) return json({ error: "this form is for another promotion" }, 409);
  const now = ctx.deps.now();
  if (Math.abs(Number(e.issuedAt) - now) > ISSUED_AT_SKEW_SECONDS) return json({ error: "the signed form is stale — sign it again" }, 400);
  if (firstFill(ctx, e.participant) === null) return json({ error: "make at least one swap with this address first" }, 403);

  const before = entryOf(ctx, id, e.participant);
  if (before && Number(e.issuedAt) <= before.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  if (!before && count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, id) >= MAX_ENTRIES) {
    return json({ error: "the form is full" }, 503);
  }
  const billed = ctx.gateKey(`rf:${e.participant}`, ROUTE_COST.write);
  if (billed) return billed;

  const td = feedbackTypedData(ctx.cfg.chain.chainId, { participant: e.participant, promotion: e.promotion, answers: answersHash(e.answers), issuedAt: e.issuedAt });
  if (!(await signedBy(ctx, td, e.participant, e.signature))) return json({ error: "the signature does not match the participant and form" }, 401);

  // Synchronous from here: re-read the row the awaits may have raced.
  const current = entryOf(ctx, id, e.participant);
  if (current && Number(e.issuedAt) <= current.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  ctx.sql.exec(
    `INSERT INTO raffle_entries (promotion, address, entered_at, updated_at, issued_at, answers, signature, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'signed')
     ON CONFLICT(promotion, address) DO UPDATE SET
       updated_at = excluded.updated_at, issued_at = excluded.issued_at,
       answers = excluded.answers, signature = excluded.signature, source = 'signed'`,
    id,
    e.participant,
    now,
    now,
    Number(e.issuedAt),
    canonicalAnswers(e.answers),
    e.signature,
  );
  const row = entryOf(ctx, id, e.participant)!;
  return json({ entered: true, updated: !!current, address: e.participant, enteredAt: row.entered_at, updatedAt: row.updated_at }, current ? 200 : 201);
}

async function signedBy(ctx: RaffleContext, td: ReturnType<typeof feedbackTypedData>, signer: Address, signature: Hex): Promise<boolean> {
  try {
    const recovered = await recoverTypedDataAddress({ ...td, signature });
    if (recovered.toLowerCase() === signer) return true;
  } catch {
    // Not a 65-byte ECDSA signature: a contract wallet's, perhaps.
  }
  if (!ctx.deps.isValidSignature) return false;
  return ctx.deps.isValidSignature(signer, hashTypedData(td), signature);
}

// ──────────────────── /raffle/admin/* ────────────────────

/** `?promotion=` or the configured key. */
function promotionOf(ctx: RaffleContext, url: URL): string | undefined {
  const q = url.searchParams.get("promotion");
  if (q !== null) return /^[a-z0-9][a-z0-9-]{0,63}$/.test(q) ? q : undefined;
  return ctx.cfg.raffleId;
}

async function adminRoute(ctx: RaffleContext, sub: string, method: string, request: Request): Promise<Response> {
  const { json } = ctx;
  const url = new URL(request.url);
  const notAllowed = (allow: string) => json({ error: "method not allowed" }, 405, { allow });
  const promotion = promotionOf(ctx, url);

  if (sub === "/entries") {
    if (method !== "GET") return notAllowed("GET");
    if (!promotion) return json({ error: "no feedback form: set RAFFLE_ID or pass ?promotion=" }, 400);
    const rows = ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, promotion).toArray();
    return json({ promotion, questions: PARTICIPATION_QUESTIONS, count: rows.length, entries: rows.map(entryJson) });
  }

  const one = /^\/entries\/(0x[0-9a-fA-F]{40})$/.exec(sub);
  if (one) {
    if (method !== "DELETE") return notAllowed("DELETE");
    if (!promotion) return json({ error: "no feedback form: set RAFFLE_ID or pass ?promotion=" }, 400);
    const address = one[1]!.toLowerCase();
    const had = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address);
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ? AND address = ?`, promotion, address);
    return json({ promotion, address, removed: had > 0 });
  }

  if (sub === "/status") {
    if (method !== "GET") return notAllowed("GET");
    const a = (url.searchParams.get("address") ?? "").toLowerCase();
    if (!ADDRESS.test(a)) return json({ error: "address is required" }, 400);
    const entry = promotion ? entryOf(ctx, promotion, a) : undefined;
    return json({
      address: a,
      promotion: promotion ?? null,
      fills: count(ctx.sql, `SELECT COUNT(*) AS n FROM fills WHERE maker = ?`, a),
      firstFillAt: firstFill(ctx, a),
      entered: !!entry,
      ...(entry ? { entry: entryJson(entry) } : {}),
    });
  }

  if (sub === "/reset") {
    if (method !== "POST") return notAllowed("POST");
    const raw = await ctx.readJsonBody(request);
    if (raw instanceof Response) return raw;
    const b = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
    const target = typeof b.promotion === "string" ? b.promotion : "";
    // Typed twice on purpose: a reset deletes every feedback form under the key.
    if (!target || b.confirm !== target) return json({ error: "reset needs {promotion, confirm} with confirm equal to the promotion id" }, 400);
    const entries = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, target);
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ?`, target);
    return json({ promotion: target, entriesRemoved: entries });
  }

  return json({ error: "not found" }, 404);
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

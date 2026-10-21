import { answersHash, canonicalAnswers, feedbackTypedData, validateAnswers, PARTICIPATION_QUESTIONS, type ParticipationAnswers } from "@1delta-x/sdk";
import { hashTypedData, isAddress, recoverTypedDataAddress, type Address, type Hex } from "viem";

import { parseRaffleConfig, type RaffleConfig, type WorkerConfig } from "./config";
import type { CoreDeps } from "./core";
import { ROUTE_COST } from "./ratelimit";
import { count, getMeta, setMeta, type Sql } from "./store";

/**
 * THE PRIZE DRAW'S DESK (2026-10-21) — deliberately small.
 *
 * The Promotion Terms (TC.md, reviewed and frozen) promise no registration (§4.1):
 * every wallet that trades is in the draw. So the desk holds no entries and no draw
 * records. The operator reads the day's qualifying addresses off the fill index (the
 * console's Qualifiers tab) and evaluates and pays by hand (§4.5, §6.2).
 *
 * What the desk does:
 *   • the LIVE SWITCH — `RAFFLE_ID` / the console's saved config say whether the app
 *     shows the notice at all, and between which times;
 *   • the optional FEEDBACK form — EIP-712 typed data (`@1delta-x/sdk` participation.ts)
 *     from an address with at least one indexed fill as maker since the start, so
 *     ratings come from users; one row per (promotion, address), a newer signature
 *     replaces the answers. It is not an entry and changes nothing about the draw.
 *
 * Every `/raffle/admin/*` route needs the `RAFFLE_ADMIN_TOKEN` bearer, checked by the
 * entry worker. No personal data anywhere: the form asks none.
 */

/** A signed form older or newer than this (vs the worker clock) is refused. */
export const ISSUED_AT_SKEW_SECONDS = 24 * 3600;
/** The desk stops taking NEW addresses past this many feedback forms (updates still land). */
export const MAX_ENTRIES = 50_000;
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

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const SIG = /^0x[0-9a-fA-F]+$/;

// ──────────────────── configuration ────────────────────

type Override = { disabled: true } | { config: RaffleConfig };

function override(sql: Sql): Override | undefined {
  const raw = getMeta(sql, CONFIG_KEY);
  if (!raw) return undefined;
  try {
    const o = JSON.parse(raw) as Override;
    // A config saved by an older console may carry fields that no longer exist: keep the known ones.
    if ("config" in o) return { config: parseRaffleConfig(pick(o.config as unknown as Record<string, unknown>, ["id", "startsAt", "endsAt", "qualifierUsd", "exclude"])) };
    return o;
  } catch {
    return undefined;
  }
}

function pick(o: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  return Object.fromEntries(keys.filter((k) => k in o).map((k) => [k, o[k]]));
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
  if (path === "/raffle/entries") return method === "POST" ? await postEntry(ctx, r, request, ip) : notAllowed("POST");
  return undefined;
}

function window(ctx: RaffleContext, r: RaffleConfig): { open: boolean; reason?: string } {
  const now = ctx.deps.now();
  if (now < r.startsAt) return { open: false, reason: "the promotion has not started yet" };
  if (now >= r.endsAt) return { open: false, reason: "the promotion has ended" };
  return { open: true };
}

function head(ctx: RaffleContext, r: RaffleConfig | undefined): Record<string, unknown> {
  if (!r) return { live: false };
  return {
    live: window(ctx, r).open,
    promotion: r.id,
    startsAt: r.startsAt,
    endsAt: r.endsAt === Number.MAX_SAFE_INTEGER ? null : r.endsAt,
    chainId: ctx.cfg.chain.chainId,
    qualifierUsd: r.qualifierUsd,
  };
}

function summary(ctx: RaffleContext, r: RaffleConfig | undefined): Response {
  return ctx.json({ ...head(ctx, r), ...(r ? { feedback: count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, r.id) } : {}) });
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
  const entry = entryOf(ctx, r.id, address);
  return ctx.json({
    ...head(ctx, r),
    address,
    traded: firstFill(ctx, address, r.startsAt) !== null,
    entered: !!entry,
    ...(entry ? { enteredAt: entry.entered_at, updatedAt: entry.updated_at } : {}),
  });
}

/** The addresses that gave feedback — NOT a draw list (every trader is in the draw). */
function entrants(ctx: RaffleContext, r: RaffleConfig | undefined): Response {
  if (!r) return ctx.json({ error: "no promotion is running" }, 404);
  const rows = ctx.sql
    .exec<{ address: string; entered_at: number }>(`SELECT address, entered_at FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, r.id)
    .toArray();
  return ctx.json({ promotion: r.id, count: rows.length, entrants: rows.map((e) => ({ address: e.address, enteredAt: e.entered_at })) });
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
  if (e.promotion !== r.id) return json({ error: "this form is for another promotion" }, 409);
  const now = ctx.deps.now();
  if (Math.abs(Number(e.issuedAt) - now) > ISSUED_AT_SKEW_SECONDS) return json({ error: "the signed form is stale — sign it again" }, 400);
  if (firstFill(ctx, e.participant, r.startsAt) === null) return json({ error: "make at least one swap with this address first" }, 403);

  const before = entryOf(ctx, r.id, e.participant);
  if (before && Number(e.issuedAt) <= before.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  if (!before && count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, r.id) >= MAX_ENTRIES) {
    return json({ error: "the promotion is full" }, 503);
  }
  const billed = ctx.gateKey(`rf:${e.participant}`, ROUTE_COST.write);
  if (billed) return billed;

  const td = feedbackTypedData(ctx.cfg.chain.chainId, { participant: e.participant, promotion: e.promotion, answers: answersHash(e.answers), issuedAt: e.issuedAt });
  if (!(await signedBy(ctx, td, e.participant, e.signature))) return json({ error: "the signature does not match the participant and form" }, 401);

  // Synchronous from here: re-read the row the awaits may have raced.
  const current = entryOf(ctx, r.id, e.participant);
  if (current && Number(e.issuedAt) <= current.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
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
        `SELECT promotion, COUNT(*) AS n, MIN(entered_at) AS first, MAX(updated_at) AS last FROM raffle_entries GROUP BY promotion ORDER BY promotion`,
      )
      .toArray();
    return json({ promotions: rows.map((e) => ({ promotion: e.promotion, entries: Number(e.n), firstEntry: e.first, lastUpdate: e.last })) });
  }

  if (sub === "/entries") {
    if (method !== "GET") return notAllowed("GET");
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    const rows = ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, promotion).toArray();
    return json({ promotion, questions: PARTICIPATION_QUESTIONS, count: rows.length, entries: rows.map(entryJson) });
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
    const entry = promotion ? entryOf(ctx, promotion, a) : undefined;
    return json({
      address: a,
      promotion: promotion ?? null,
      fills: count(ctx.sql, `SELECT COUNT(*) AS n FROM fills WHERE maker = ?`, a),
      firstFillAt: firstFill(ctx, a, r?.startsAt ?? 0),
      entered: !!entry,
      ...(entry ? { entry: entryJson(entry) } : {}),
    });
  }

  if (sub === "/reset") {
    if (method !== "POST") return notAllowed("POST");
    const b = await body(ctx, request);
    if (b instanceof Response) return b;
    const promotion = typeof b.promotion === "string" ? b.promotion : "";
    // Typed twice on purpose: a reset deletes every feedback form of the promotion.
    if (!promotion || b.confirm !== promotion) return json({ error: "reset needs {promotion, confirm} with confirm equal to the promotion id" }, 400);
    const entries = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ?`, promotion);
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ?`, promotion);
    return json({ promotion, entriesRemoved: entries });
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

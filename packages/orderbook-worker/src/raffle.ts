import {
  answersHash,
  canonicalAnswers,
  participationTypedData,
  validateAnswers,
  withoutPersonal,
  PARTICIPATION_QUESTIONS,
  type ParticipationAnswers,
} from "@1delta-x/sdk";
import { hashTypedData, isAddress, recoverTypedDataAddress, type Address, type Hex } from "viem";

import { parseRaffleConfig, type RaffleConfig, type WorkerConfig } from "./config";
import type { CoreDeps } from "./core";
import { ROUTE_COST } from "./ratelimit";
import { count, getMeta, setMeta, type Sql } from "./store";

/**
 * THE PRIZE DRAW'S ENTRY DESK (2026-10-20).
 *
 * An address enters by posting the participation form signed as EIP-712 typed data
 * (`@1delta-x/sdk` participation.ts). The desk takes it only when:
 *
 *   • a draw is configured and open (`startsAt ≤ now < endsAt`) — and, in TEST MODE
 *     (`testers` non-empty), only from a listed tester;
 *   • it names this draw and the Terms version configured (`terms`);
 *   • the answers fit the form and hash to the signed `answers`;
 *   • the address has at least one indexed fill AS MAKER since the start — the
 *     "Participate after your first swap" gate is enforced here, not trusted to the app;
 *   • the signature recovers to the address (or its ERC-1271 `isValidSignature` accepts it).
 *
 * One row per (promotion, address); a later signature (higher `issuedAt`) replaces the
 * answers, an older or equal one is refused, so a replayed form cannot roll an update back.
 *
 * CONFIGURATION: `RAFFLE_*` is the deploy-time default; an admin can override it from
 * the operator console, packages/raffle-admin (`PUT /raffle/admin/config`, stored in `meta`), switch it off, run it in
 * test mode, reset a promotion's entries and draws, and add or remove an entry by hand
 * (a support case: "I signed up but I'm not listed"). Every `/raffle/admin/*` route needs
 * the `RAFFLE_ADMIN_TOKEN` bearer, checked by the entry worker.
 *
 * Whether an entrant QUALIFIES for a day (volume, exclusions) is decided by the draw
 * tool (the admin page / scripts/raffle-draw.ts), which saves its record here.
 *
 * Personal data: `contact` (optional) is stored in its own column, never served by a
 * public route, and `POST /raffle/admin/purge-contacts` blanks it after payout.
 */

/** A signed form older or newer than this (vs the worker clock) is refused. */
export const ISSUED_AT_SKEW_SECONDS = 24 * 3600;
/** The desk stops taking NEW addresses past this many entries (updates still land). */
export const MAX_ENTRIES = 50_000;
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
  contact: string | null;
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
  });
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
  return ctx.sql
    .exec<{ day: string; snapshot: string; updated_at: number }>(`SELECT day, snapshot, updated_at FROM raffle_draws WHERE promotion = ? ORDER BY day ASC`, promotion)
    .toArray()
    .map((d) => ({ day: d.day, updatedAt: d.updated_at, ...(JSON.parse(d.snapshot) as Record<string, unknown>) }));
}

// ──────────────────── POST /raffle/entries ────────────────────

interface EntryBody {
  participant: Address;
  promotion: string;
  terms: Hex;
  issuedAt: bigint;
  answers: ParticipationAnswers;
  signature: Hex;
}

function parseEntry(body: unknown): EntryBody | string {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return "body must be a JSON object";
  const b = body as Record<string, unknown>;
  for (const k of Object.keys(b)) if (!["participant", "promotion", "terms", "issuedAt", "answers", "signature"].includes(k)) return `unknown field "${k}"`;
  if (typeof b.participant !== "string" || !ADDRESS.test(b.participant) || !isAddress(b.participant, { strict: false })) return "participant must be an address";
  if (typeof b.promotion !== "string") return "promotion must be a string";
  if (typeof b.terms !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(b.terms)) return "terms must be a 32-byte hash";
  const issued = typeof b.issuedAt === "number" ? String(b.issuedAt) : b.issuedAt;
  if (typeof issued !== "string" || !/^\d{1,12}$/.test(issued)) return "issuedAt must be unix seconds";
  if (typeof b.signature !== "string" || !SIG.test(b.signature) || b.signature.length > 2 + 2 * 4096) return "signature must be hex";
  const bad = validateAnswers(b.answers);
  if (bad) return bad;
  return {
    participant: b.participant.toLowerCase() as Address,
    promotion: b.promotion,
    terms: b.terms.toLowerCase() as Hex,
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
  // The Terms the user was shown are not the ones running: they must re-read and re-sign.
  if (e.terms !== r.terms) return json({ error: "the Terms have changed since this page loaded — reload and review them" }, 409);
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

  const td = participationTypedData(ctx.cfg.chain.chainId, {
    participant: e.participant,
    promotion: e.promotion,
    terms: e.terms,
    answers: answersHash(e.answers),
    issuedAt: e.issuedAt,
  });
  if (!(await signedBy(ctx, td, e.participant, e.signature))) return json({ error: "the signature does not match the participant and form" }, 401);

  // Synchronous from here: re-read the row the awaits may have raced.
  const current = entryOf(ctx, r.id, e.participant);
  if (current && current.source === "signed" && Number(e.issuedAt) <= current.issued_at) return json({ error: "a newer form from this address is already on file" }, 409);
  const contact = typeof e.answers.contact === "string" && e.answers.contact !== "" ? e.answers.contact : null;
  // A signed form supersedes a manual entry (keeps its original entry time and note).
  ctx.sql.exec(
    `INSERT INTO raffle_entries (promotion, address, entered_at, updated_at, issued_at, answers, contact, signature, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'signed')
     ON CONFLICT(promotion, address) DO UPDATE SET
       updated_at = excluded.updated_at, issued_at = excluded.issued_at,
       answers = excluded.answers, contact = excluded.contact, signature = excluded.signature, source = 'signed'`,
    r.id,
    e.participant,
    now,
    now,
    Number(e.issuedAt),
    canonicalAnswers(withoutPersonal(e.answers)),
    contact,
    e.signature,
  );
  const row = entryOf(ctx, r.id, e.participant)!;
  return json({ entered: true, updated: !!current, address: e.participant, enteredAt: row.entered_at, updatedAt: row.updated_at }, current ? 200 : 201);
}

async function signedBy(ctx: RaffleContext, td: ReturnType<typeof participationTypedData>, signer: Address, signature: Hex): Promise<boolean> {
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
    if (method === "POST") return manualEntry(ctx, promotion, request);
    return notAllowed("GET, POST");
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
    return json({ address: a, promotion: promotion ?? null, fills, firstFillAt: first, entered: !!entry, ...(entry ? { entry: entryJson(entry) } : {}) });
  }

  if (sub === "/purge-contacts") {
    if (method !== "POST") return notAllowed("POST");
    const promotion = promotionOf(ctx, url);
    if (!promotion) return json({ error: "no promotion: pass ?promotion=" }, 400);
    const n = count(ctx.sql, `SELECT COUNT(*) AS n FROM raffle_entries WHERE promotion = ? AND contact IS NOT NULL`, promotion);
    ctx.sql.exec(`UPDATE raffle_entries SET contact = NULL WHERE promotion = ?`, promotion);
    return json({ promotion, purged: n });
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
    ctx.sql.exec(`DELETE FROM raffle_entries WHERE promotion = ?`, promotion);
    ctx.sql.exec(`DELETE FROM raffle_draws WHERE promotion = ?`, promotion);
    return json({ promotion, entriesRemoved: entries, drawsRemoved: drawn });
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
    contact: e.contact,
    signature: e.signature,
    source: e.source,
    note: e.note,
  };
}

function exportEntries(ctx: RaffleContext, promotion: string): Response {
  const rows = ctx.sql.exec<EntryRow>(`SELECT * FROM raffle_entries WHERE promotion = ? ORDER BY entered_at ASC, address ASC`, promotion).toArray();
  return ctx.json({ promotion, questions: PARTICIPATION_QUESTIONS, count: rows.length, entries: rows.map(entryJson) });
}

/**
 * A support case: add (or annotate) an entry by hand. No signature and no fill check
 * — the admin vouches for it and says why in `note`; the row is marked `manual` so the
 * draw tool and the export show it. A later signed form from the address replaces it.
 */
async function manualEntry(ctx: RaffleContext, promotion: string, request: Request): Promise<Response> {
  const { json } = ctx;
  const b = await body(ctx, request);
  if (b instanceof Response) return b;
  const address = typeof b.address === "string" ? b.address.trim().toLowerCase() : "";
  if (!ADDRESS.test(address)) return json({ error: "address must be an address" }, 400);
  const note = typeof b.note === "string" ? b.note.trim() : "";
  if (!note || note.length > 500) return json({ error: "a note (why it is added by hand, ≤ 500 chars) is required" }, 400);
  const answers = (b.answers ?? {}) as ParticipationAnswers;
  if (Object.keys(answers).length) {
    const bad = validateAnswers(answers);
    if (bad) return json({ error: bad }, 400);
  }
  const contact = typeof answers.contact === "string" && answers.contact !== "" ? answers.contact : null;
  const now = ctx.deps.now();
  const enteredAt = b.enteredAt === undefined ? now : Number(b.enteredAt);
  if (!Number.isSafeInteger(enteredAt) || enteredAt < 0) return json({ error: "enteredAt must be unix seconds" }, 400);
  const existing = entryOf(ctx, promotion, address);
  if (existing && existing.source === "signed" && !b.overwrite) {
    return json({ error: "this address has a signed entry; pass overwrite: true to replace its answers by hand" }, 409);
  }
  ctx.sql.exec(
    `INSERT INTO raffle_entries (promotion, address, entered_at, updated_at, issued_at, answers, contact, signature, source, note)
     VALUES (?, ?, ?, ?, 0, ?, ?, '', 'manual', ?)
     ON CONFLICT(promotion, address) DO UPDATE SET
       entered_at = excluded.entered_at, updated_at = excluded.updated_at, answers = excluded.answers,
       contact = excluded.contact, signature = '', issued_at = 0, source = 'manual', note = excluded.note`,
    promotion,
    address,
    enteredAt,
    now,
    canonicalAnswers(withoutPersonal(answers)),
    contact,
    note,
  );
  return json({ promotion, entry: entryJson(entryOf(ctx, promotion, address)!) }, existing ? 200 : 201);
}

import type { Resolution } from "@1delta-x/beta-filler/core";

/** The subset of `SqlStorage` the log uses. */
export type SqlValue = string | number | null;
export interface Sql {
  exec<T = Record<string, SqlValue>>(query: string, ...bindings: SqlValue[]): { toArray(): T[] };
}

/**
 * Every resolved transaction: fills (with their P&L estimate) and the
 * rebalancer's approvals / redemptions / sales. Amounts are decimal TEXT.
 */
export const FILLS_SCHEMA = `CREATE TABLE IF NOT EXISTS fills (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  order_hash TEXT,
  strategy TEXT NOT NULL,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  tx TEXT NOT NULL,
  pay_token TEXT,
  paid TEXT,
  recv_token TEXT,
  received TEXT,
  gas_used TEXT,
  gas_cost_wei TEXT,
  profit_est TEXT,
  profit_token TEXT,
  note TEXT
)`;

export interface FillRow {
  id: number;
  at: number;
  order_hash: string | null;
  strategy: string;
  kind: string;
  status: string;
  tx: string;
  pay_token: string | null;
  paid: string | null;
  recv_token: string | null;
  received: string | null;
  gas_used: string | null;
  gas_cost_wei: string | null;
  profit_est: string | null;
  profit_token: string | null;
  note: string | null;
}

export const FILL_COLUMNS = ["id", "at", "order_hash", "strategy", "kind", "status", "tx", "pay_token", "paid", "recv_token", "received", "gas_used", "gas_cost_wei", "profit_est", "profit_token", "note"] as const;

export function migrateFills(sql: Sql): void {
  sql.exec(FILLS_SCHEMA);
  sql.exec(`CREATE INDEX IF NOT EXISTS fills_at ON fills(at)`);
}

/** Record one resolved tx (success / reverted / dropped). Keeps at most `maxRows`. */
export function recordResolution(sql: Sql, r: Resolution, at: number, maxRows: number): void {
  if (r.status === "waiting" || r.status === "timeout") return;
  const p = r.pending;
  const i = p.info ?? {};
  const ok = r.status === "success";
  sql.exec(
    `INSERT INTO fills (at, order_hash, strategy, kind, status, tx, pay_token, paid, recv_token, received, gas_used, gas_cost_wei, profit_est, profit_token, note)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    at,
    p.orderHash ?? null,
    p.strategy,
    p.kind,
    r.status === "success" ? (p.kind === "fill" ? "filled" : "mined") : r.status,
    p.hash,
    ok ? (i.payToken ?? null) : null,
    ok ? (i.paid ?? null) : null,
    ok ? (i.recvToken ?? null) : null,
    ok ? (i.received ?? null) : null,
    r.gasUsed?.toString() ?? null,
    r.gasCostWei?.toString() ?? null,
    ok ? (i.profitEst ?? null) : null,
    ok ? (i.profitToken ?? null) : null,
    i.note ?? (i.tag ? i.tag.slice(0, 300) : null),
  );
  sql.exec(`DELETE FROM fills WHERE id <= (SELECT MAX(id) FROM fills) - ?`, maxRows);
}

export function listFills(sql: Sql, o: { limit: number; since?: number; kind?: string; status?: string }): FillRow[] {
  const where: string[] = [];
  const args: SqlValue[] = [];
  if (o.since !== undefined) {
    where.push("at >= ?");
    args.push(o.since);
  }
  if (o.kind) {
    where.push("kind = ?");
    args.push(o.kind);
  }
  if (o.status) {
    where.push("status = ?");
    args.push(o.status);
  }
  return sql
    .exec<FillRow>(`SELECT * FROM fills ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY id DESC LIMIT ?`, ...args, o.limit)
    .toArray();
}

export function countSince(sql: Sql, status: string, since: number): number {
  const r = sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM fills WHERE status = ? AND at >= ?`, status, since).toArray()[0];
  return Number(r?.n ?? 0);
}

/** RFC 4180 CSV, with spreadsheet-formula cells neutralised (`=`, `+`, `@`, tab, CR; `-` unless numeric). */
export function toCsv(rows: readonly FillRow[]): string {
  const cell = (v: unknown): string => {
    if (v === null || v === undefined) return "";
    let s = String(v);
    if (/^[=+@\t\r]/.test(s) || (s.startsWith("-") && !/^-\d+(\.\d+)?$/.test(s))) s = `'${s}`;
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [FILL_COLUMNS.join(",")];
  for (const r of rows) lines.push(FILL_COLUMNS.map((c) => cell(c === "at" ? new Date(r.at).toISOString() : r[c])).join(","));
  return lines.join("\n") + "\n";
}

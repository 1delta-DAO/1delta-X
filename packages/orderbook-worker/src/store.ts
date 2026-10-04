/**
 * The subset of the Durable Object `SqlStorage` API the book uses, so the core
 * does not depend on the runtime types beyond it.
 */
export type SqlValue = string | number | null;
export interface SqlCursor<T> {
  toArray(): T[];
}
export interface Sql {
  exec<T = Record<string, SqlValue>>(query: string, ...bindings: SqlValue[]): SqlCursor<T>;
}

/**
 * The durable layout. One Durable Object instance per chain owns one of these.
 *
 *   orders        live orders: the canonical JSON announce + last lens state + fill progress
 *   graves        evicted orders (filled / cancelled / expired / evicted / displaced), with a TTL
 *   soft_cancels  maker-bound soft-cancel tombstones, keyed (hash, maker) as in the Book
 *   fills         the fill index, keyed (txHash, logIndex)
 *   meta          the log cursor and alarm bookkeeping
 *   buckets       rate-limit token buckets (per IP, per maker)
 *   billed        orders / cancels already charged to their maker
 *
 * Amounts are decimal TEXT (uint256 does not fit a SQLite integer); block numbers
 * and unix seconds are INTEGER.
 */
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS orders (
    hash TEXT PRIMARY KEY,
    maker TEXT NOT NULL,
    nonce TEXT NOT NULL,
    side INTEGER NOT NULL,
    expiry INTEGER NOT NULL,
    added_at INTEGER NOT NULL,
    tokens_in TEXT NOT NULL,
    tokens_out TEXT NOT NULL,
    announce TEXT NOT NULL,
    state TEXT,
    ok INTEGER NOT NULL DEFAULT 0,
    status INTEGER NOT NULL DEFAULT -1,
    strikes INTEGER NOT NULL DEFAULT 0,
    filled TEXT,
    checked_at INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 0
  )`,
  `CREATE INDEX IF NOT EXISTS orders_maker ON orders(maker)`,
  `CREATE INDEX IF NOT EXISTS orders_added ON orders(added_at, hash)`,
  `CREATE INDEX IF NOT EXISTS orders_expiry ON orders(expiry)`,
  `CREATE INDEX IF NOT EXISTS orders_check ON orders(dirty, checked_at)`,
  `CREATE TABLE IF NOT EXISTS graves (
    hash TEXT PRIMARY KEY,
    maker TEXT NOT NULL,
    reason TEXT NOT NULL,
    removed_at INTEGER NOT NULL,
    summary TEXT NOT NULL,
    announce TEXT NOT NULL,
    tx_hash TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS graves_removed ON graves(removed_at)`,
  `CREATE TABLE IF NOT EXISTS soft_cancels (
    hash TEXT NOT NULL,
    maker TEXT NOT NULL,
    until INTEGER NOT NULL,
    pending INTEGER NOT NULL,
    PRIMARY KEY (hash, maker)
  )`,
  `CREATE TABLE IF NOT EXISTS fills (
    tx_hash TEXT NOT NULL,
    log_index INTEGER NOT NULL,
    order_hash TEXT NOT NULL,
    maker TEXT NOT NULL,
    solver TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    at INTEGER,
    cumulative TEXT,
    amount TEXT,
    PRIMARY KEY (tx_hash, log_index)
  )`,
  `CREATE INDEX IF NOT EXISTS fills_maker ON fills(maker, block_number, log_index)`,
  `CREATE INDEX IF NOT EXISTS fills_order ON fills(order_hash, block_number, log_index)`,
  `CREATE INDEX IF NOT EXISTS fills_block ON fills(block_number, log_index)`,
  `CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS buckets (key TEXT PRIMARY KEY, tokens REAL NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS billed (key TEXT PRIMARY KEY, at INTEGER NOT NULL)`,
];

export function migrate(sql: Sql): void {
  for (const s of SCHEMA) sql.exec(s);
}

export function getMeta(sql: Sql, key: string): string | undefined {
  return sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = ?`, key).toArray()[0]?.value;
}

export function setMeta(sql: Sql, key: string, value: string): void {
  sql.exec(`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value);
}

export function count(sql: Sql, query: string, ...bindings: SqlValue[]): number {
  const row = sql.exec<{ n: number }>(query, ...bindings).toArray()[0];
  return Number(row?.n ?? 0);
}

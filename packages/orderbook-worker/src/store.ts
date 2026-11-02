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
 *   fills         the fill index, keyed (txHash, logIndex); `order_json` is the filled
 *                 order's JSON, copied at index time so the row outlives the order's
 *                 tombstone (graves are pruned after TOMBSTONE_TTL_SECONDS; a fill is not)
 *   pending_fills fill txs a trusted filler reported as BROADCAST, not yet mined
 *                 (`POST /fills/report` status "pending"); short-lived markers
 *   meta          the log cursor and alarm bookkeeping
 *   buckets       rate-limit token buckets (per IP, per maker)
 *   billed        orders / cancels already charged to their maker
 *   raffle_entries prize-draw FEEDBACK forms (src/raffle.ts; optional, not an entry), one per
 *                 (promotion, address); `answers` holds the canonical JSON the
 *                 signature commits to. `contact` is a retired column (the form
 *                 dropped its contact field 2026-10-20): always NULL, scrubbed on start
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
  // No index on (dirty, checked_at): every lens re-check rewrites `checked_at`, and
  // each index entry is one more billed row written per re-check, while the re-check
  // query's scan of ≤ MAX_ORDERS rows is cheap reads. Objects created before this
  // change carry the index: dropped (idempotent).
  `DROP INDEX IF EXISTS orders_check`,
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
  `CREATE TABLE IF NOT EXISTS pending_fills (
    order_hash TEXT NOT NULL,
    tx_hash TEXT NOT NULL,
    sent_at INTEGER NOT NULL,
    PRIMARY KEY (order_hash, tx_hash)
  )`,
  `CREATE INDEX IF NOT EXISTS pending_fills_tx ON pending_fills(tx_hash)`,
  `CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS buckets (key TEXT PRIMARY KEY, tokens REAL NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS billed (key TEXT PRIMARY KEY, at INTEGER NOT NULL)`,
  // The bills prune keeps the newest `maxBilled` by `at`: walk an index, not a sort.
  `CREATE INDEX IF NOT EXISTS billed_at ON billed(at)`,
  `CREATE TABLE IF NOT EXISTS raffle_entries (
    promotion TEXT NOT NULL,
    address TEXT NOT NULL,
    entered_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    issued_at INTEGER NOT NULL,
    answers TEXT NOT NULL,
    contact TEXT,
    signature TEXT NOT NULL,
    -- 'signed' (the participation form) or 'manual' (added by an admin, e.g. a support case)
    source TEXT NOT NULL DEFAULT 'signed',
    note TEXT,
    PRIMARY KEY (promotion, address)
  )`,
  // The contact field was dropped (2026-10-20): erase any value a rehearsal stored.
  `UPDATE raffle_entries SET contact = NULL WHERE contact IS NOT NULL`,
  // Retired (2026-10-21): the draw is evaluated by hand from the fill index now.
  `DROP TABLE IF EXISTS raffle_draws`,
  `DROP TABLE IF EXISTS raffle_claims`,
];

export function migrate(sql: Sql): void {
  for (const s of SCHEMA) sql.exec(s);
  // `fills.order_json` (2026-11-02). `/fills` used to join the order from `orders` /
  // `graves` at read time, so a fill lost its order (pair, size) once the order's
  // tombstone aged out (14 days): the dashboard showed it as "? → ?". The column is
  // filled at index time; an object created before it gets the column and a one-time
  // copy from whatever orders and graves it still holds.
  const cols = sql.exec<{ name: string }>(`PRAGMA table_info(fills)`).toArray();
  if (!cols.some((c) => c.name === "order_json")) {
    sql.exec(`ALTER TABLE fills ADD COLUMN order_json TEXT`);
    const rows = sql
      .exec<{ rowid: number; announce: string }>(
        `SELECT f.rowid AS rowid, COALESCE(o.announce, g.announce) AS announce
           FROM fills f
           LEFT JOIN orders o ON o.hash = f.order_hash
           LEFT JOIN graves g ON g.hash = f.order_hash
          WHERE o.announce IS NOT NULL OR g.announce IS NOT NULL`,
      )
      .toArray();
    for (const r of rows) sql.exec(`UPDATE fills SET order_json = ? WHERE rowid = ?`, orderJsonOf(r.announce), r.rowid);
  }
}

/** The `order` member of a stored announce, as JSON text (the wire form `/fills` serves). */
export function orderJsonOf(announce: string): string {
  return JSON.stringify((JSON.parse(announce) as { order: unknown }).order);
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

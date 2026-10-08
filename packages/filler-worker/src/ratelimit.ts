import type { Sql } from "./fills";

/**
 * Per-IP (and global) token buckets for the PUBLIC `POST /quote`, kept in the Durable
 * Object's SQLite so an eviction does not hand every caller a fresh burst — the
 * orderbook worker's `SqlRateLimiter` approach (packages/orderbook-worker/src/ratelimit.ts),
 * copied rather than imported (the two workers share no package).
 *
 * A refusal writes nothing: the stored `(tokens, updated_at)` already determines the
 * balance at any later time, so refreshing it would only cost a billed row write —
 * and refusals are exactly what an abusive client generates.
 */
export interface Bucket {
  capacity: number;
  refillPerSecond: number;
}

export function migrateBuckets(sql: Sql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS quote_buckets (key TEXT PRIMARY KEY, tokens REAL NOT NULL, updated_at INTEGER NOT NULL)`);
}

export class SqlRateLimiter {
  private takes = 0;

  constructor(
    private readonly sql: Sql,
    private readonly nowMs: () => number,
  ) {}

  /** Spend `cost`; the seconds to wait when refused. */
  take(key: string, bucket: Bucket, cost = 1): { ok: true } | { ok: false; retryAfter: number } {
    if (cost <= 0) return { ok: true };
    const at = this.nowMs();
    const row = this.sql.exec<{ tokens: number; updated_at: number }>(`SELECT tokens, updated_at FROM quote_buckets WHERE key = ?`, key).toArray()[0];
    let tokens = row ? row.tokens : bucket.capacity;
    if (row) tokens = Math.min(bucket.capacity, tokens + (Math.max(0, at - row.updated_at) / 1000) * bucket.refillPerSecond);
    if (tokens < cost) {
      const rate = bucket.refillPerSecond > 0 ? bucket.refillPerSecond : 1;
      return { ok: false, retryAfter: Math.max(1, Math.ceil((cost - tokens) / rate)) };
    }
    this.sql.exec(
      `INSERT INTO quote_buckets (key, tokens, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET tokens = excluded.tokens, updated_at = excluded.updated_at`,
      key,
      tokens - cost,
      at,
    );
    if (++this.takes % 200 === 0) this.prune(bucket);
    return { ok: true };
  }

  /** Drop buckets idle for an hour (refilled to capacity by then for any sane bucket), then cap the table. */
  prune(_b: Bucket, idleMs = 3_600_000, maxKeys = 50_000): void {
    this.sql.exec(`DELETE FROM quote_buckets WHERE updated_at < ?`, this.nowMs() - idleMs);
    this.sql.exec(`DELETE FROM quote_buckets WHERE key IN (SELECT key FROM quote_buckets ORDER BY updated_at DESC LIMIT -1 OFFSET ?)`, maxKeys);
  }
}

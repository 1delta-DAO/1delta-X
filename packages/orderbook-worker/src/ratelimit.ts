import type { Sql } from "./store";

/**
 * What each route spends — the same table as `orderbook-server`'s `ROUTE_COST`
 * (copied, not imported: that module pulls in Fastify types).
 */
export const ROUTE_COST = {
  read: 1,
  query: 2,
  write: 10,
  cancel: 5,
  free: 0,
} as const;

export interface Bucket {
  capacity: number;
  refillPerSecond: number;
}

/**
 * Cost-weighted token buckets kept in the Durable Object's SQLite, so a restart
 * (or an eviction of the object) does not hand every caller a fresh burst.
 *
 * Keys are `ip:<address>` and `mk:<maker>`. The IP is the one the entry worker
 * resolved (see `clientIp` in `clientIp.ts`); `x-forwarded-for` is never read.
 */
export class SqlRateLimiter {
  constructor(
    private readonly sql: Sql,
    private readonly nowMs: () => number,
  ) {}

  /**
   * Spend `cost`; returns the seconds to wait when refused.
   *
   * A REFUSAL WRITES NOTHING. The stored `(tokens, updated_at)` already determines
   * the balance at any later time — `min(capacity, tokens + elapsed × refill)` — and
   * refilling it to "now" first and storing that is the same function of time
   * (`min(c, min(c, a + x) + y) = min(c, a + x + y)` for x, y ≥ 0). Writing it was
   * pure cost: every SQLite write is a billed row, and refusals are exactly what an
   * abusive client generates (thousands per minute).
   */
  take(key: string, bucket: Bucket, cost: number): { ok: true } | { ok: false; retryAfter: number } {
    if (cost <= 0) return { ok: true };
    const at = this.nowMs();
    const row = this.sql.exec<{ tokens: number; updated_at: number }>(`SELECT tokens, updated_at FROM buckets WHERE key = ?`, key).toArray()[0];
    let tokens = row ? row.tokens : bucket.capacity;
    if (row) tokens = Math.min(bucket.capacity, tokens + (Math.max(0, at - row.updated_at) / 1000) * bucket.refillPerSecond);
    if (tokens < cost) {
      const shortfall = cost - tokens;
      const rate = bucket.refillPerSecond > 0 ? bucket.refillPerSecond : 1;
      return { ok: false, retryAfter: Math.max(1, Math.ceil(shortfall / rate)) };
    }
    this.write(key, tokens - cost, at);
    return { ok: true };
  }

  private write(key: string, tokens: number, at: number): void {
    this.sql.exec(
      `INSERT INTO buckets (key, tokens, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET tokens = excluded.tokens, updated_at = excluded.updated_at`,
      key,
      tokens,
      at,
    );
  }

  /**
   * Drop idle buckets that have refilled to capacity — a FULL bucket is
   * indistinguishable from none, any other one is not (dropping it would hand its
   * owner a fresh burst) — then cap the table. A refused request no longer touches
   * `updated_at`, so "idle" alone (the old rule) could have dropped a bucket an
   * abuser keeps hammering before it refilled; the fullness test keeps the math
   * exact for any capacity / refill pair.
   */
  prune(kinds: ReadonlyArray<{ prefix: string; bucket: Bucket }>, idleSeconds: number, maxKeys: number): void {
    const now = this.nowMs();
    for (const { prefix, bucket } of kinds) {
      // Key range on the primary key: `prefix` ≤ key < `prefix` with its last char + 1.
      const hi = prefix.slice(0, -1) + String.fromCharCode(prefix.charCodeAt(prefix.length - 1) + 1);
      this.sql.exec(
        `DELETE FROM buckets WHERE key >= ? AND key < ? AND updated_at < ? AND tokens + ((? - updated_at) / 1000.0) * ? >= ?`,
        prefix,
        hi,
        now - idleSeconds * 1000,
        now,
        bucket.refillPerSecond,
        bucket.capacity,
      );
    }
    this.sql.exec(
      `DELETE FROM buckets WHERE key IN (SELECT key FROM buckets ORDER BY updated_at DESC LIMIT -1 OFFSET ?)`,
      maxKeys,
    );
  }
}

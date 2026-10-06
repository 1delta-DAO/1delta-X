import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { SqlRateLimiter, type Bucket } from "../src/ratelimit";
import { migrate, type Sql } from "../src/store";
import { freshBook } from "./helpers";

/** The pre-2026-10 limiter, verbatim in behaviour: it WROTE the refilled balance on a refusal. */
class ReferenceLimiter {
  private readonly rows = new Map<string, { tokens: number; at: number }>();
  constructor(private readonly nowMs: () => number) {}
  take(key: string, b: Bucket, cost: number): { ok: true } | { ok: false; retryAfter: number } {
    if (cost <= 0) return { ok: true };
    const at = this.nowMs();
    const row = this.rows.get(key);
    let tokens = row ? row.tokens : b.capacity;
    if (row) tokens = Math.min(b.capacity, tokens + (Math.max(0, at - row.at) / 1000) * b.refillPerSecond);
    if (tokens < cost) {
      this.rows.set(key, { tokens, at });
      return { ok: false, retryAfter: Math.max(1, Math.ceil((cost - tokens) / (b.refillPerSecond > 0 ? b.refillPerSecond : 1))) };
    }
    this.rows.set(key, { tokens: tokens - cost, at });
    return { ok: true };
  }
}

/** Seeded PRNG: the schedule is the same on every run. */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const withSql = <T>(fn: (sql: Sql) => T): Promise<T> =>
  runInDurableObject(freshBook(), (_i, state) => {
    const sql = state.storage.sql as unknown as Sql;
    migrate(sql);
    return fn(sql);
  });

describe("SqlRateLimiter (no write on a refusal)", () => {
  it("answers exactly like the old write-on-refusal limiter over a long random schedule", async () => {
    await withSql((sql) => {
      // Steps of 250 ms and a refill of 2/s keep every balance a multiple of 0.5:
      // exact in floating point, so "the same math" can be asserted as equality.
      const buckets: Record<string, Bucket> = { "ip:a": { capacity: 12, refillPerSecond: 2 }, "mk:b": { capacity: 30, refillPerSecond: 0.5 } };
      let now = 1_000_000;
      const next = new SqlRateLimiter(sql, () => now);
      const ref = new ReferenceLimiter(() => now);
      const r = rng(42);
      let refusals = 0;
      for (let i = 0; i < 2_000; i++) {
        now += 250 * Math.floor(r() * 9); // 0 … 2 s
        const key = r() < 0.5 ? "ip:a" : "mk:b";
        const cost = [1, 2, 5, 10][Math.floor(r() * 4)]!;
        const a = next.take(key, buckets[key]!, cost);
        const b = ref.take(key, buckets[key]!, cost);
        expect(a).toEqual(b);
        if (!a.ok) refusals++;
      }
      expect(refusals).toBeGreaterThan(200); // the schedule exercises refusals heavily
    });
  });

  it("a refusal leaves the stored row untouched (no billed write)", async () => {
    await withSql((sql) => {
      let now = 5_000;
      const lim = new SqlRateLimiter(sql, () => now);
      const b = { capacity: 10, refillPerSecond: 1 };
      expect(lim.take("ip:x", b, 10).ok).toBe(true);
      const row = () => sql.exec<{ tokens: number; updated_at: number }>(`SELECT tokens, updated_at FROM buckets WHERE key = 'ip:x'`).toArray()[0];
      const before = row();
      for (let i = 0; i < 5; i++) {
        now += 1_000;
        expect(lim.take("ip:x", b, 10)).toMatchObject({ ok: false });
      }
      expect(row()).toEqual(before);
      now += 5_000; // 10 s after the spend: full again
      expect(lim.take("ip:x", b, 10).ok).toBe(true);
    });
  });

  it("the idle prune drops a bucket only once it has refilled to capacity (else it would grant a fresh burst)", async () => {
    await withSql((sql) => {
      let now = 0;
      const lim = new SqlRateLimiter(sql, () => now);
      const slow = { capacity: 10, refillPerSecond: 0.01 }; // 1000 s to refill
      const kinds = [{ prefix: "ip:", bucket: slow }];
      expect(lim.take("ip:slow", slow, 10).ok).toBe(true);
      const has = () => sql.exec(`SELECT key FROM buckets WHERE key = 'ip:slow'`).toArray().length === 1;
      now = 700_000; // idle 700 s > 600 s, but only 7 tokens back
      lim.prune(kinds, 600, 1_000);
      expect(has()).toBe(true);
      expect(lim.take("ip:slow", slow, 10)).toMatchObject({ ok: false }); // still short: no free burst
      now = 1_000_000; // refilled
      lim.prune(kinds, 600, 1_000);
      expect(has()).toBe(false);
      // An `mk:` bucket is judged by its own kind (not pruned by the ip: rule).
      expect(lim.take("mk:m", { capacity: 1, refillPerSecond: 0.001 }, 1).ok).toBe(true);
      now = 2_000_000;
      lim.prune(kinds, 600, 1_000);
      expect(sql.exec(`SELECT key FROM buckets WHERE key = 'mk:m'`).toArray().length).toBe(1);
    });
  });
});

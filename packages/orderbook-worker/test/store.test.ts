import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { migrate, type Sql } from "../src/store";
import { freshBook } from "./helpers";

describe("schema migration", () => {
  it("drops the old orders_check index on an existing object, adds billed(at); idempotent", async () => {
    await runInDurableObject(freshBook(), (_i, state) => {
      const sql = state.storage.sql as unknown as Sql;
      const indexes = () =>
        sql
          .exec<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
          .toArray()
          .map((r) => r.name);
      // An object created before the change: the old layout, with the old index.
      migrate(sql);
      sql.exec(`CREATE INDEX IF NOT EXISTS orders_check ON orders(dirty, checked_at)`);
      sql.exec(`DROP INDEX IF EXISTS billed_at`);
      expect(indexes()).toContain("orders_check");
      for (let i = 0; i < 3; i++) migrate(sql); // every Durable Object start runs it
      expect(indexes()).not.toContain("orders_check");
      expect(indexes()).toContain("billed_at");
      // The bills prune uses it (no temp B-tree sort over `billed`).
      const plan = sql
        .exec<{ detail: string }>(`EXPLAIN QUERY PLAN SELECT key FROM billed ORDER BY at DESC LIMIT -1 OFFSET 10`)
        .toArray()
        .map((r) => r.detail)
        .join(" | ");
      expect(plan).toMatch(/billed_at/);
    });
  });
});

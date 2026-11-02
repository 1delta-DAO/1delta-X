import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { hashOrderStruct, orderFromJson, orderToJson } from "@1delta-x/sdk";
import { beforeEach, describe, expect, it } from "vitest";

import { migrate, type Sql } from "../src/store";
import { alice, call, fillLog, freshBook, resetWorld, signed, world } from "./helpers";

const DAY = 86_400;

const fillsOf = async (book: DurableObjectStub) => (await call(book, "GET", "/fills")).body.fills as Record<string, unknown>[];
const graves = (book: DurableObjectStub) =>
  runInDurableObject(book, (_i, state) => Number((state.storage.sql as unknown as Sql).exec<{ n: number }>(`SELECT COUNT(*) AS n FROM graves`).toArray()[0]!.n));

describe("a fill keeps its order after the tombstone is pruned (fills.order_json)", () => {
  beforeEach(() => resetWorld());

  it("the order is copied onto the row at index time and still served after TOMBSTONE_TTL", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 10n)];
    world.filled.set(`${o.hash}@10`, 1_000n);
    await runDurableObjectAlarm(book);
    expect(await graves(book)).toBe(1);

    // Past the 14-day tombstone TTL: the grave is pruned, the fill row is not.
    world.offset = 15 * DAY;
    await runDurableObjectAlarm(book);
    expect(await graves(book)).toBe(0);

    const [row] = await fillsOf(book);
    expect(row).toMatchObject({ orderHash: o.hash, amount: "1000" });
    expect(hashOrderStruct(orderFromJson(row!.order)).toLowerCase()).toBe(o.hash);
  });

  it("migrate adds the column to an older object and copies what it still holds; idempotent", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 10n)];
    world.filled.set(`${o.hash}@10`, 1_000n);
    await runDurableObjectAlarm(book);
    await runInDurableObject(book, (_i, state) => {
      const sql = state.storage.sql as unknown as Sql;
      // The layout before the column: drop it (and its copy).
      sql.exec(`ALTER TABLE fills DROP COLUMN order_json`);
      for (let i = 0; i < 3; i++) migrate(sql);
      const rows = sql.exec<{ order_json: string | null }>(`SELECT order_json FROM fills`).toArray();
      expect(rows).toHaveLength(1);
      expect(hashOrderStruct(orderFromJson(JSON.parse(rows[0]!.order_json!))).toLowerCase()).toBe(o.hash);
    });
  });
});

describe("POST /fills/orders — restore an order a fill row lost", () => {
  beforeEach(() => resetWorld());

  /** A fill whose order this book never held: the row has no order. */
  async function orphanFill() {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "GET", "/health"); // first request arms the alarm
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 10n)];
    world.filled.set(`${o.hash}@10`, 1_000n);
    expect(await runDurableObjectAlarm(book)).toBe(true);
    const [row] = await fillsOf(book);
    expect(row!.order).toBeUndefined();
    return { book, o };
  }

  it("attaches an order that hashes to the row; then reports it known", async () => {
    const { book, o } = await orphanFill();
    const body = JSON.stringify([orderToJson(o.order)]);
    const res = await call(book, "POST", "/fills/orders", body, undefined, true);
    expect(res.status).toBe(200);
    expect(res.body.results).toEqual([{ orderHash: o.hash, result: "attached", rows: 1 }]);
    const [row] = await fillsOf(book);
    expect(hashOrderStruct(orderFromJson(row!.order)).toLowerCase()).toBe(o.hash);
    const again = await call(book, "POST", "/fills/orders", body, undefined, true);
    expect(again.body.results).toEqual([{ orderHash: o.hash, result: "known", rows: 0 }]);
  });

  it("writes nothing for an order no fill row hashes to, nor for a malformed one", async () => {
    const { book } = await orphanFill();
    const other = await signed(alice);
    const res = await call(book, "POST", "/fills/orders", JSON.stringify([orderToJson(other.order), { nope: 1 }]), undefined, true);
    expect(res.body.results).toMatchObject([{ orderHash: other.hash, result: "no-fill", rows: 0 }, { result: "invalid" }]);
    expect((await fillsOf(book))[0]!.order).toBeUndefined();
  });

  it("is refused without the binding key or the admin token", async () => {
    const { book, o } = await orphanFill();
    const res = await call(book, "POST", "/fills/orders", JSON.stringify(orderToJson(o.order)));
    expect(res.status).toBe(403);
    expect((await fillsOf(book))[0]!.order).toBeUndefined();
  });
});

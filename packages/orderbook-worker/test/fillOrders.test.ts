import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { AGGREGATOR_FILL_SOLVER_ABI, hashOrderStruct, orderFromJson, orderToJson, packOrder, SETTLEMENT_ABI } from "@1delta-x/sdk";
import { encodeFunctionData, zeroAddress, type Hex } from "viem";
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

describe("the alarm decodes a lost order from the fill tx's calldata", () => {
  beforeEach(() => resetWorld());

  /** A fill of an order this book never held, in tx `tx`. */
  async function orphan(tx: Hex) {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "GET", "/health");
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 10n, 0, tx)];
    world.filled.set(`${o.hash}@10`, 1_000n);
    return { book, o };
  }
  const TX = `0x${"ab".repeat(32)}` as Hex;
  const settlementFill = (order: Parameters<typeof packOrder>[0]) =>
    encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "fill", args: [packOrder(order), "0x", 1_000n] });

  it("a direct Settlement fill: attached on the pass that indexes it, never re-read", async () => {
    const { book, o } = await orphan(TX);
    world.txInputs.set(TX, settlementFill(o.order));
    await runDurableObjectAlarm(book);
    const [row] = await fillsOf(book);
    expect(hashOrderStruct(orderFromJson(row!.order)).toLowerCase()).toBe(o.hash);
    expect((await call(book, "GET", "/fills")).body.coverage).toMatchObject({ withoutOrder: 0 });
    const calls = world.txInputCalls;
    await runDurableObjectAlarm(book);
    expect(world.txInputCalls).toBe(calls);
  });

  it("an AggregatorFillSolver executeFill", async () => {
    const { book, o } = await orphan(TX);
    const plan = {
      router: zeroAddress, minOut: 0n, maxPay: 0n, amountInOffset: 0n, amountOutOffset: 0n, minBumpBps: 0n,
      profitRecipient: zeroAddress, originator: zeroAddress, originatorPpm: 0, data: "0x" as Hex,
    };
    const input = encodeFunctionData({
      abi: AGGREGATOR_FILL_SOLVER_ABI,
      functionName: "executeFill",
      args: [packOrder(o.order), "0x", 1_000n, plan, "0x", []],
    } as never);
    world.txInputs.set(TX, input);
    await runDurableObjectAlarm(book);
    expect(hashOrderStruct(orderFromJson((await fillsOf(book))[0]!.order)).toLowerCase()).toBe(o.hash);
  });

  it("calldata whose orders do not hash to the fill: given up at once, nothing written", async () => {
    const { book } = await orphan(TX);
    const other = await signed(alice);
    world.txInputs.set(TX, settlementFill(other.order));
    await runDurableObjectAlarm(book);
    const calls = world.txInputCalls;
    await runDurableObjectAlarm(book);
    expect(world.txInputCalls).toBe(calls);
    expect((await fillsOf(book))[0]!.order).toBeUndefined();
  });

  it("an RPC error or an unknown tx is retried, at most ORDER_RECOVERY_TRIES times", async () => {
    const { book, o } = await orphan(TX);
    world.txInputs.set(TX, "throw");
    await runDurableObjectAlarm(book); // indexes, try 1 fails
    world.txInputs.delete(TX); // unknown tx: try 2
    await runDurableObjectAlarm(book);
    world.txInputs.set(TX, settlementFill(o.order)); // try 3 succeeds
    await runDurableObjectAlarm(book);
    expect(world.txInputCalls).toBe(3);
    expect(hashOrderStruct(orderFromJson((await fillsOf(book))[0]!.order)).toLowerCase()).toBe(o.hash);

    const b = await orphan(`0x${"cd".repeat(32)}` as Hex);
    world.txInputCalls = 0;
    for (let i = 0; i < 5; i++) await runDurableObjectAlarm(b.book);
    expect(world.txInputCalls).toBe(3);
  });
});

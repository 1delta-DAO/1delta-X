import { runDurableObjectAlarm } from "cloudflare:test";
import { OrderStatus } from "@1delta-x/orderbook/pure";
import { beforeEach, describe, expect, it } from "vitest";

import { alice, bob, call, fillLog, freshBook, resetWorld, signed, world } from "./helpers";

beforeEach(() => resetWorld());

const health = async (book: DurableObjectStub) => (await call(book, "GET", "/health")).body as Record<string, any>;
const unfunded = { ok: false, status: OrderStatus.Fillable, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true };
/** What viem throws when a node answers JSON-RPC -32601 (Rootstock's public node, for eth_getLogs). */
const methodNotFound = () => Object.assign(new Error('The method "eth_getLogs" does not exist / is not available.'), { code: -32601 });

describe("an RPC without eth_getLogs (B3)", () => {
  it("is loud on /health, keeps the alarm alive, and falls back to a 60 s lens re-check", async () => {
    const book = freshBook();
    const o = await signed(alice);
    expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    world.head = 50n;
    world.logsError = methodNotFound();
    expect(await runDurableObjectAlarm(book)).toBe(true);

    const h = await health(book);
    expect(h.logsUnsupported).toBe(true);
    expect(h.logs).toMatchObject({ ok: false, unsupported: true, span: "100" }); // not a range problem: no shrink
    expect(String(h.lastError)).toMatch(/does not serve eth_getLogs.*RPC_URL_SECRET/);
    expect(h.revalidateSeconds).toBe(60);
    expect(h.fills.toBlock).toBeNull(); // the cursor did not move
    expect(h.lastAlarm).not.toBeNull();

    // The re-check is now the only way an order leaves: 70 s later it runs (300 s otherwise).
    world.lens.set(o.hash, unfunded);
    world.offset = 70;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, reason: "evicted" });

    // A provider that serves logs again clears the flag and the cadence.
    world.logsError = undefined;
    await runDurableObjectAlarm(book);
    const after = await health(book);
    expect(after.logsUnsupported).toBe(false);
    expect(after.logs.ok).toBe(true);
    expect(after.revalidateSeconds).toBe(300);
    expect(after.fills.toBlock).toBe("50");
  });

  it("control: with logs served, the same order is NOT re-checked after 70 s", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 50n;
    world.lens.set(o.hash, unfunded);
    world.offset = 70;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body.live).toBe(true);
    expect((await health(book)).logsUnsupported).toBe(false);
  });

  it("an RPC error (not -32601) is a logs error, not 'unsupported'", async () => {
    const book = freshBook();
    await call(book, "GET", "/health"); // arms the alarm
    world.head = 50n;
    world.logsError = new Error("HTTP request failed. Status: 503");
    await runDurableObjectAlarm(book);
    const h = await health(book);
    expect(h.logsUnsupported).toBe(false);
    expect(h.logs).toMatchObject({ ok: false, unsupported: false });
    expect(h.logs.lastError).toMatch(/503/);
  });
});

describe("adaptive eth_getLogs span (B3c)", () => {
  it("a provider range cap halves the span until a read fits; the cursor advances; the span grows back after the cool-down", async () => {
    const book = freshBook();
    await call(book, "GET", "/health"); // arms the alarm
    world.head = 1_000n; // CONFIRMATIONS 0, MAX_LOG_RANGE 100 in the test env; a fresh object starts at 0
    world.logsMaxRange = 30n;
    for (let i = 0; i < 4; i++) await runDurableObjectAlarm(book);
    expect(world.logsCalls).toEqual([
      [0n, 99n],
      [0n, 49n],
      [0n, 24n], // fits: the cursor moves
      [25n, 49n], // within the cool-down the span holds at 25
    ]);
    let h = await health(book);
    expect(h.logs.span).toBe("25");
    expect(h.fills.toBlock).toBe("49");

    // The cap is lifted and the cool-down (600 s) passed: each success doubles the span.
    world.logsMaxRange = undefined;
    world.offset = 700;
    world.logsCalls = [];
    for (let i = 0; i < 3; i++) await runDurableObjectAlarm(book);
    expect(world.logsCalls).toEqual([
      [50n, 74n],
      [75n, 124n],
      [125n, 224n],
    ]);
    h = await health(book);
    expect(h.logs.span).toBe("100");
    expect(h.logs.ok).toBe(true);
  });
});

describe("the alarm's wall-clock budget (B3e)", () => {
  it("a slow RPC stops fill sizing at the deadline; the next pass resumes at the first log not applied — nothing lost, nothing doubled", async () => {
    const book = freshBook();
    const orders = [await signed(alice), await signed(alice), await signed(bob), await signed(bob)];
    for (const o of orders) expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    world.head = 50n;
    world.logs = orders.map((o, i) => fillLog(o.hash, i < 2 ? alice.address : bob.address, BigInt(10 + i)));
    orders.forEach((o, i) => world.filled.set(`${o.hash}@${10 + i}`, 1_000n));
    // Each `filled(hash)` read takes 100 s on the clock; sizing one fill reads twice.
    // ALARM_BUDGET_SECONDS = 240: two fills fit, the third would start past the deadline.
    world.filledCostS = 100;
    await runDurableObjectAlarm(book);
    let h = await health(book);
    expect(h.fills.records).toBe(2);
    expect(h.fills.toBlock).toBe("11"); // cursor at block 12, the first log not applied
    expect((await call(book, "GET", `/orders/${orders[2]!.hash}/status`)).body.live).toBe(true);

    await runDurableObjectAlarm(book);
    h = await health(book);
    expect(h.fills.records).toBe(4);
    expect(h.fills.toBlock).toBe("50");
    const fills = (await call(book, "GET", "/fills?limit=10")).body.fills as Array<Record<string, unknown>>;
    expect(fills.map((f) => f.amount)).toEqual(["1000", "1000", "1000", "1000"]);
    for (const o of orders) expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, reason: "filled" });
  });
});

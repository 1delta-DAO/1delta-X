import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { OrderStatus } from "@1delta-x/orderbook/pure";
import { hashOrderStruct, ocoNonceGroup, orderFromJson, orderToJson, signOrder, withFillOnce } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import {
  alice,
  bob,
  call,
  cancelBody,
  deployment,
  fillLog,
  freshBook,
  mallory,
  now,
  orderFor,
  rawFillLog,
  resetWorld,
  signed,
  USDRIF,
  USDT0,
  world,
} from "./helpers";

beforeEach(() => resetWorld());

describe("POST /orders — admission", () => {
  it("admits a verified order and serves it back as JSON", async () => {
    const book = freshBook();
    const o = await signed(alice);
    const res = await call(book, "POST", "/orders", o.body);
    expect(res.status).toBe(202);
    expect(res.body).toEqual({ orderHash: o.hash });

    const list = await call(book, "GET", "/orders");
    expect(list.status).toBe(200);
    expect(list.body.total).toBe(1);
    const [row] = list.body.orders as Record<string, unknown>[];
    expect(row!.orderHash).toBe(o.hash);
    expect(row!.sig).toBe(o.sig);
    // The served order parses strictly and hashes to the same id.
    expect(hashOrderStruct(orderFromJson(row!.order)).toLowerCase()).toBe(o.hash);
    expect((row!.state as Record<string, unknown>).fillableAmount).toBe("1000");

    const status = await call(book, "GET", `/orders/${o.hash}/status`);
    expect(status.body).toMatchObject({ live: true, orderHash: o.hash, status: "Fillable", filledAmount: "0" });
  });

  it("dedupes a re-post without a lens call or a maker charge", async () => {
    const book = freshBook();
    const o = await signed(alice);
    expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    const calls = world.lensCalls;
    const again = await call(book, "POST", "/orders", o.body);
    expect(again.status).toBe(202);
    expect(again.body).toEqual({ orderHash: o.hash, duplicate: true });
    expect(world.lensCalls).toBe(calls);
    expect((await call(book, "GET", "/orders")).body.total).toBe(1);
  });

  it("422s what the lens or Layer 1 rejects, and what admission refuses locally", async () => {
    const book = freshBook();
    const unfunded = await signed(alice);
    world.lens.set(unfunded.hash, { ok: false, status: OrderStatus.Fillable, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true });
    const r1 = await call(book, "POST", "/orders", unfunded.body);
    expect(r1.status).toBe(422);
    expect(r1.body.error).toMatch(/allowance\/balance/);

    // Expires too soon: refused before any lens call.
    const calls = world.lensCalls;
    const soon = await signed(alice, { expiry: BigInt(now() + 5) });
    const r2 = await call(book, "POST", "/orders", soon.body);
    expect(r2.status).toBe(422);
    expect(r2.body.error).toMatch(/min 120s/);
    expect(world.lensCalls).toBe(calls);

    // Layer 1: a garbage 65-byte signature does not recover.
    const bad = await signed(alice);
    const r3 = await call(book, "POST", "/orders", bad.body.replace(bad.sig, `0x${"00".repeat(65)}`));
    expect(r3.status).toBe(422);

    expect((await call(book, "GET", "/orders")).body.total).toBe(0);
  });

  it("400s on a non-strict JSON body and 415s on anything but JSON", async () => {
    const book = freshBook();
    const o = await signed(alice);
    const extra = JSON.stringify({ ...JSON.parse(o.body), extra: 1 });
    expect((await call(book, "POST", "/orders", extra)).status).toBe(400);
    expect((await call(book, "POST", "/orders", "{not json")).status).toBe(400);
    const numeric = o.body.replace(/"nonce":"(\d+)"/, '"nonce":$1');
    const r = await call(book, "POST", "/orders", numeric);
    expect(r.status).toBe(400);
    expect(r.body.error).toMatch(/order\.nonce/);
    const proto = await book.fetch("https://book.test/orders", {
      method: "POST",
      headers: { "content-type": "application/x-protobuf", "x-ob-client-ip": "1.1.1.1" },
      body: new Uint8Array([1, 2, 3]),
    });
    expect(proto.status).toBe(415);
  });

  it("503s when verification is unavailable or the book is at capacity", async () => {
    const book = freshBook();
    world.lensDown = true;
    const o = await signed(alice);
    const down = await call(book, "POST", "/orders", o.body);
    expect(down.status).toBe(503);
    expect(down.body.error).toMatch(/verification unavailable/);
    world.lensDown = false;

    // MAX_ORDERS_PER_MAKER = 3 in the test env.
    for (let i = 0; i < 3; i++) expect((await call(book, "POST", "/orders", (await signed(alice)).body)).status).toBe(202);
    const fourth = await call(book, "POST", "/orders", (await signed(alice)).body);
    expect(fourth.status).toBe(503);
    expect(fourth.body.error).toMatch(/order limit/);
  });

  it("a full book displaces the largest maker's furthest-dated order for a smaller maker", async () => {
    const book = freshBook();
    // MAX_ORDERS = 4: alice holds 3, bob 1 — full.
    const far = await signed(alice, { expiry: BigInt(now() + 7200) });
    for (const o of [await signed(alice), far, await signed(alice), await signed(bob)]) {
      expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    }
    const newcomer = await signed(mallory);
    expect((await call(book, "POST", "/orders", newcomer.body)).status).toBe(202);
    const gone = await call(book, "GET", `/orders/${far.hash}/status`);
    expect(gone.body).toMatchObject({ live: false, reason: "displaced" });
  });
});

describe("POST /cancels", () => {
  it("refuses a stranger: a forged maker is 403, a valid stranger signature evicts nothing", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);

    // Mallory signs a cancel claiming to be alice.
    const forged = await call(book, "POST", "/cancels", await cancelBody(mallory, alice.address, [o.hash]));
    expect(forged.status).toBe(403);

    // Mallory signs as herself, naming alice's order: accepted, retracts nothing.
    const own = await call(book, "POST", "/cancels", await cancelBody(mallory, mallory.address, [o.hash]));
    expect(own.status).toBe(202);
    expect(own.body).toEqual({ evicted: [], requested: 1 });
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body.live).toBe(true);
  });

  it("evicts the maker's named orders and keeps a tombstone that blocks a re-post", async () => {
    const book = freshBook();
    const o = await signed(alice);
    const keep = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    await call(book, "POST", "/orders", keep.body);
    const res = await call(book, "POST", "/cancels", await cancelBody(alice, alice.address, [o.hash]));
    expect(res.status).toBe(202);
    expect(res.body).toEqual({ evicted: [o.hash], requested: 1 });

    const status = await call(book, "GET", `/orders/${o.hash}/status`);
    expect(status.body).toMatchObject({ live: false, reason: "soft-cancelled" });
    expect((await call(book, "GET", `/orders/${keep.hash}/status`)).body.live).toBe(true);

    const repost = await call(book, "POST", "/orders", o.body);
    expect(repost.status).toBe(422);
    expect(repost.body.error).toMatch(/soft-cancelled/);
  });

  it("a cancel that arrives before its order blocks that order later (maker-bound)", async () => {
    const book = freshBook();
    const o = await signed(alice);
    expect((await call(book, "POST", "/cancels", await cancelBody(alice, alice.address, [o.hash]))).status).toBe(202);
    expect((await call(book, "POST", "/orders", o.body)).status).toBe(422);
  });
});

describe("persistence", () => {
  it("a fresh Durable Object instance reads the stored book, tombstones and buckets", async () => {
    const book = freshBook();
    const live = await signed(alice);
    const cancelled = await signed(alice);
    await call(book, "POST", "/orders", live.body);
    await call(book, "POST", "/orders", cancelled.body);
    await call(book, "POST", "/cancels", await cancelBody(alice, alice.address, [cancelled.hash]));
    const before = await runInDurableObject(book, (_i, state) =>
      state.storage.sql.exec(`SELECT tokens FROM buckets WHERE key = 'ip:198.51.100.7'`).one().tokens as number,
    );

    await evictDurableObject(book);

    const list = await call(book, "GET", "/orders");
    expect(list.body.total).toBe(1);
    expect(((list.body.orders as Record<string, unknown>[])[0]!).orderHash).toBe(live.hash);
    expect((await call(book, "GET", `/orders/${cancelled.hash}/status`)).body).toMatchObject({ live: false, reason: "soft-cancelled" });
    expect((await call(book, "POST", "/orders", cancelled.body)).status).toBe(422);
    const after = await runInDurableObject(book, (_i, state) =>
      state.storage.sql.exec(`SELECT tokens FROM buckets WHERE key = 'ip:198.51.100.7'`).one().tokens as number,
    );
    // The bucket was NOT reset to full capacity by the restart (100); the reads since spent more.
    expect(before).toBeLessThan(100);
    expect(after).toBeLessThan(before);
  });
});

describe("the maintenance alarm", () => {
  it("indexes fills from logs: a full fill tombstones the order with its tx, a partial updates filledAmount", async () => {
    const book = freshBook();
    const full = await signed(alice);
    const partial = await signed(alice);
    await call(book, "POST", "/orders", full.body);
    await call(book, "POST", "/orders", partial.body);

    world.head = 50n;
    const fullLog = fillLog(full.hash, alice.address, 10n, 3);
    const partLog = fillLog(partial.hash, alice.address, 12n, 1);
    world.logs = [fullLog, partLog];
    world.filled.set(`${full.hash}@10`, 1_000n);
    world.filled.set(`${partial.hash}@12`, 400n);
    world.lens.set(partial.hash, { ok: true, status: OrderStatus.Fillable, fillableAmount: 600n, isSignatureValid: true, validatorsPass: true });

    expect(await runDurableObjectAlarm(book)).toBe(true);

    const s1 = await call(book, "GET", `/orders/${full.hash}/status`);
    expect(s1.body).toMatchObject({ live: false, status: "Filled", reason: "filled", filledAmount: "1000", txHash: fullLog.txHash });
    const s2 = await call(book, "GET", `/orders/${partial.hash}/status`);
    expect(s2.body).toMatchObject({ live: true, filledAmount: "400", fillableAmount: "600" });

    const fills = await call(book, "GET", `/fills?maker=${alice.address}`);
    expect(fills.body.total).toBe(2);
    const rows = fills.body.fills as Record<string, unknown>[];
    // Newest first.
    expect(rows[0]).toMatchObject({ orderHash: partial.hash, txHash: partLog.txHash, blockNumber: "12", amount: "400", cumulative: "400" });
    expect(rows[1]).toMatchObject({ orderHash: full.hash, txHash: fullLog.txHash, blockNumber: "10", amount: "1000", logIndex: 3 });
    // The signed order rides along, so a client can place the fill in its market.
    expect(hashOrderStruct(orderFromJson(rows[1]!.order)).toLowerCase()).toBe(full.hash);
    expect(fills.body.coverage).toMatchObject({ fromBlock: "0", toBlock: "50", records: 2 });

    // Re-running over the same range (cursor moved on) adds nothing.
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", "/fills")).body.total).toBe(2);
  });

  it("a second partial fill differences against the first", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 5n)];
    world.filled.set(`${o.hash}@5`, 300n);
    await runDurableObjectAlarm(book);
    world.head = 40n;
    world.logs.push(fillLog(o.hash, alice.address, 30n));
    world.filled.set(`${o.hash}@30`, 750n);
    await runDurableObjectAlarm(book);
    const rows = (await call(book, "GET", `/fills?orderHash=${o.hash}`)).body.fills as Record<string, unknown>[];
    expect(rows.map((r) => r.amount)).toEqual(["450", "300"]);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: true, filledAmount: "750" });
  });

  it("evicts expired orders into tombstones", async () => {
    const book = freshBook();
    const o = await signed(alice, { expiry: BigInt(now() + 150) }); // MIN_TTL_SECONDS = 120
    expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    world.offset = 200;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, status: "Expired", reason: "expired" });
    expect((await call(book, "GET", "/orders")).body.total).toBe(0);
  });

  it("evicts on on-chain nonce cancellations, maker-checked, with no lens call", async () => {
    const book = freshBook();
    const a = await signed(alice, { nonce: 77n });
    const b = await signed(bob, { nonce: 77n });
    await call(book, "POST", "/orders", a.body);
    await call(book, "POST", "/orders", b.body);
    world.head = 10n;
    world.logs = [{ event: { kind: "cancelledNonces", maker: alice.address, nonces: [77n] }, blockNumber: 3n, logIndex: 0, txHash: `0x${"cd".repeat(32)}` }];
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${a.hash}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled" });
    expect((await call(book, "GET", `/orders/${b.hash}/status`)).body.live).toBe(true);
  });

  it("re-checks stale orders on the lens and drops what went unfunded; an RPC outage evicts nothing", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.offset = 360; // past REVALIDATE_SECONDS (300)
    world.lensDown = true;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body.live).toBe(true);
    world.lensDown = false;
    world.lens.set(o.hash, { ok: false, status: OrderStatus.Fillable, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true });
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, reason: "evicted" });
  });

  it("bounds the log range per alarm and catches up across alarms", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 250n; // MAX_LOG_RANGE = 100
    world.logs = [fillLog(o.hash, alice.address, 220n)];
    world.filled.set(`${o.hash}@220`, 1_000n);
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", "/fills")).body.total).toBe(0);
    expect(((await call(book, "GET", "/health")).body.fills as Record<string, unknown>).toBlock).toBe("99");
    await runDurableObjectAlarm(book);
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", "/fills")).body.total).toBe(1);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body.status).toBe("Filled");
  });
});

describe("rate limits", () => {
  it("charges the IP bucket per route cost and answers 429 with retry-after", async () => {
    const book = freshBook();
    const o = await signed(alice);
    // IP capacity 100, a write costs 10: ten writes, then refused.
    for (let i = 0; i < 10; i++) await call(book, "POST", "/orders", o.body, "203.0.113.9");
    const refused = await call(book, "POST", "/orders", o.body, "203.0.113.9");
    expect(refused.status).toBe(429);
    expect(Number(refused.headers.get("retry-after"))).toBeGreaterThan(0);
    // Another address is unaffected.
    expect((await call(book, "POST", "/orders", o.body, "203.0.113.10")).status).toBe(202);
  });

  it("charges the maker bucket once per admitted order / cancel, not per replay", async () => {
    const book = freshBook();
    const orders = [await signed(alice), await signed(alice), await signed(alice)];
    // Maker capacity 30: three admitted orders spend it all.
    for (const o of orders) expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    // Replays are free for the maker (dedupe answers first).
    expect((await call(book, "POST", "/orders", orders[0]!.body, "192.0.2.1")).status).toBe(202);
    const cancel = await call(book, "POST", "/cancels", await cancelBody(alice, alice.address, [orders[0]!.hash]));
    expect(cancel.status).toBe(429);
    expect(cancel.body.error).toMatch(/maker rate limit/);
  });
});

describe("GET /orders filters and paging", () => {
  it("filters by maker / tokenIn / tokenOut and pages with a keyset cursor", async () => {
    const book = freshBook();
    const a1 = await signed(alice);
    const a2 = await signed(alice, {
      legsIn: [{ token: USDT0, start: 500n, end: 0n }],
      legsOut: [{ token: USDRIF, start: 499n, end: 0n, recipient: "0x0000000000000000000000000000000000000000" }],
    });
    const b1 = await signed(bob);
    for (const o of [a1, a2, b1]) await call(book, "POST", "/orders", o.body);

    expect((await call(book, "GET", `/orders?maker=${alice.address}`)).body.total).toBe(2);
    const byIn = await call(book, "GET", `/orders?tokenIn=${USDT0}`);
    expect((byIn.body.orders as Record<string, unknown>[]).map((r) => r.orderHash)).toEqual([a2.hash]);
    expect((await call(book, "GET", `/orders?tokenOut=${USDT0}`)).body.total).toBe(2);
    expect((await call(book, "GET", `/orders?maker=nope`)).status).toBe(400);
    expect((await call(book, "GET", `/orders?pair=x`)).status).toBe(400);

    const seen: unknown[] = [];
    let cursor: string | undefined;
    do {
      const page = await call(book, "GET", `/orders?limit=1${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
      seen.push(...(page.body.orders as Record<string, unknown>[]).map((r) => r.orderHash));
      cursor = page.body.nextCursor as string | undefined;
    } while (cursor);
    expect(new Set(seen).size).toBe(3);
  });
});

describe("fill-once fills (no size in `filled`; the lens says Cancelled)", () => {
  // What the REAL SettlementLens answers for a completed fill-once order: its fill set
  // the nonce bit and left `filled` at 0 — the same state a nonce cancel leaves.
  const consumed = { ok: false, status: OrderStatus.Cancelled, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true } as const;
  const once = { timing: withFillOnce(0n) };

  it("an indexed OrderFilled tombstones it as Filled — full size, with the tx, no lens call", async () => {
    const book = freshBook();
    const o = await signed(alice, once);
    await call(book, "POST", "/orders", o.body);
    world.head = 20n;
    const log = fillLog(o.hash, alice.address, 7n);
    world.logs = [log];
    world.lens.set(o.hash, consumed);
    const lensBefore = world.lensCalls;
    await runDurableObjectAlarm(book);
    const fill = ((await call(book, "GET", "/fills")).body.fills as Record<string, unknown>[])[0]!;
    // The one fill a fill-once order can take is the whole order.
    expect(fill).toMatchObject({ orderHash: o.hash, amount: "1000", cumulative: "1000", txHash: log.txHash });
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({
      live: false,
      status: "Filled",
      reason: "filled",
      filledAmount: "1000",
      txHash: log.txHash,
    });
    expect(world.lensCalls).toBe(lensBefore);
  });

  it("a confirmed /fills/report does the same", async () => {
    const book = freshBook();
    const o = await signed(alice, once);
    await call(book, "POST", "/orders", o.body);
    world.lens.set(o.hash, consumed);
    const T = `0x${"e1".repeat(32)}` as Hex;
    world.receipts.set(T, { status: "success", blockNumber: 9n, transactionHash: T, logs: [rawFillLog(o.hash, alice.address, 9n, 0, T)] });
    const res = await call(book, "POST", "/fills/report", JSON.stringify({ txHash: T }), undefined, true);
    expect((res.body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "indexed", indexed: 1 });
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({
      live: false,
      status: "Filled",
      reason: "filled",
      filledAmount: "1000",
      txHash: T,
    });
    // The next alarm's lens re-check has nothing left to (mis)label.
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ status: "Filled", reason: "filled", txHash: T });
  });

  it("a lens re-check that ran BEFORE the log was indexed is upgraded from cancelled to Filled", async () => {
    const book = freshBook();
    const o = await signed(alice, once);
    await call(book, "POST", "/orders", o.body);
    world.lens.set(o.hash, consumed);
    world.head = 5n; // the log scan has read up to block 5: the fill (block 12) is not in it yet
    world.offset = 360; // past REVALIDATE_SECONDS: the re-check runs, no log yet
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled" });
    world.head = 20n;
    const log = fillLog(o.hash, alice.address, 12n);
    world.logs = [log];
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({
      live: false,
      status: "Filled",
      reason: "filled",
      filledAmount: "1000",
      txHash: log.txHash,
    });
  });

  it("a lens re-check that sees Cancelled for a fill-once order WITH an indexed fill row maps it to Filled", async () => {
    const book = freshBook();
    const o = await signed(alice, once);
    // The fill is indexed before this node holds the order (a lagging admission RPC
    // still answered fillable), so the log alone could not tombstone it.
    world.head = 20n;
    const log = fillLog(o.hash, alice.address, 7n);
    world.logs = [log];
    await runDurableObjectAlarm(book);
    expect((await call(book, "POST", "/orders", o.body)).status).toBe(202);
    world.lens.set(o.hash, consumed);
    world.offset = 360;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({
      live: false,
      status: "Filled",
      reason: "filled",
      filledAmount: "1000",
      txHash: log.txHash,
    });
  });

  it("a genuine nonce cancel of a fill-once order with no fill stays Cancelled (event and lens paths)", async () => {
    const byEvent = freshBook();
    const a = await signed(alice, { ...once, nonce: 4242n });
    await call(byEvent, "POST", "/orders", a.body);
    world.head = 10n;
    world.logs = [{ event: { kind: "cancelledNonces", maker: alice.address, nonces: [4242n] }, blockNumber: 3n, logIndex: 0, txHash: `0x${"cd".repeat(32)}` }];
    await runDurableObjectAlarm(byEvent);
    expect((await call(byEvent, "GET", `/orders/${a.hash}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled" });
    expect((await call(byEvent, "GET", `/orders/${a.hash}/status`)).body.txHash).toBeUndefined();

    // No log at all (an RPC without eth_getLogs): only the lens re-check sees it.
    world.logs = [];
    const byLens = freshBook();
    const b = await signed(alice, once);
    await call(byLens, "POST", "/orders", b.body);
    world.lens.set(b.hash, consumed);
    world.offset = 360;
    await runDurableObjectAlarm(byLens);
    expect((await call(byLens, "GET", `/orders/${b.hash}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled" });
  });

  it("a shared-nonce OCO bracket: the filled leg is Filled, its sibling Cancelled at once; another maker's same nonce untouched", async () => {
    const book = freshBook();
    const [tp, sl] = ocoNonceGroup([orderFor(alice.address), orderFor(alice.address, { legsOut: [{ token: USDT0, start: 950n, end: 0n, recipient: zeroAddress }] })], 9001n);
    const legs: Hex[] = [];
    for (const leg of [tp!, sl!]) {
      const sig = await signOrder(alice, leg, deployment);
      const hash = hashOrderStruct(leg).toLowerCase() as Hex;
      expect((await call(book, "POST", "/orders", JSON.stringify({ order: orderToJson(leg), sig }))).status).toBe(202);
      legs.push(hash);
    }
    const stranger = await signed(bob, { ...once, nonce: 9001n });
    await call(book, "POST", "/orders", stranger.body);
    world.head = 30n;
    const log = fillLog(legs[0]!, alice.address, 15n);
    world.logs = [log];
    const lensBefore = world.lensCalls;
    await runDurableObjectAlarm(book);
    expect((await call(book, "GET", `/orders/${legs[0]}/status`)).body).toMatchObject({ live: false, status: "Filled", reason: "filled", txHash: log.txHash });
    expect((await call(book, "GET", `/orders/${legs[1]}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled" });
    expect((await call(book, "GET", `/orders/${stranger.hash}/status`)).body.live).toBe(true);
    expect(world.lensCalls).toBe(lensBefore);
  });

  it("an ordinary (not fill-once) order the lens calls Cancelled is still cancelled, even with a fill row", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 7n)];
    world.filled.set(`${o.hash}@7`, 400n);
    world.lens.set(o.hash, { ...consumed });
    await runDurableObjectAlarm(book); // partial fill indexed → dirty → lens says Cancelled
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body).toMatchObject({ live: false, status: "Cancelled", reason: "cancelled", filledAmount: "400" });
  });
});

describe("POST /orders — gasless ERC-2612 funding permit", () => {
  async function withPermit(over: { spender?: `0x${string}`; deadlineDelta?: bigint } = {}) {
    const { erc2612PermitToJson, erc2612TypedData, splitPermitSignature, orderToJson } = await import("@1delta-x/sdk");
    const { deployment } = await import("./helpers");
    const o = await signed(alice, { legsIn: [{ token: USDT0, start: 5_000_000n, end: 0n }], legsOut: [{ token: USDRIF, start: 4_900_000_000_000_000_000n, end: 0n, recipient: "0x0000000000000000000000000000000000000000" }] });
    const m = { owner: alice.address, spender: over.spender ?? deployment.settlement, value: 5_000_000n, nonce: 0n, deadline: o.order.expiry + (over.deadlineDelta ?? 0n) };
    const sig = await alice.signTypedData(erc2612TypedData({ name: "USD₮0", version: "1", chainId: deployment.chainId, verifyingContract: USDT0 }, m));
    const permit = { token: USDT0, spender: m.spender, value: m.value, nonce: m.nonce, deadline: m.deadline, ...splitPermitSignature(sig) };
    return { ...o, permit, body: JSON.stringify({ order: orderToJson(o.order), sig: o.sig, erc2612Permit: erc2612PermitToJson(permit) }) };
  }

  it("admits it on the verifier's live-permit verdict and serves the permit to fillers", async () => {
    const book = freshBook();
    const o = await withPermit();
    world.lens.set(o.hash, { ok: true, status: OrderStatus.Fillable, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true, erc2612Live: true });
    const res = await call(book, "POST", "/orders", o.body);
    expect(res.status).toBe(202);
    const [row] = (await call(book, "GET", "/orders")).body.orders as Record<string, unknown>[];
    const served = row!.erc2612Permit as Record<string, unknown>;
    expect(served).toEqual(JSON.parse(o.body).erc2612Permit);
    expect((row!.state as Record<string, unknown>).erc2612Live).toBe(true);
    expect((row!.state as Record<string, unknown>).fillableAmount).toBe("0");
    // An ordinary order serves no permit field at all.
    const plain = await signed(bob);
    await call(book, "POST", "/orders", plain.body);
    const rows = (await call(book, "GET", "/orders")).body.orders as Record<string, unknown>[];
    expect(rows.find((r) => r.orderHash === plain.hash)).not.toHaveProperty("erc2612Permit");
  });

  it("422s a permit to another spender or one that lapses before the order", async () => {
    const book = freshBook();
    const wrongSpender = await withPermit({ spender: bob.address });
    expect((await call(book, "POST", "/orders", wrongSpender.body)).status).toBe(422);
    const early = await withPermit({ deadlineDelta: -1n });
    const res = await call(book, "POST", "/orders", early.body);
    expect(res.status).toBe(422);
    expect(String(res.body.error)).toMatch(/deadline/);
  });
});

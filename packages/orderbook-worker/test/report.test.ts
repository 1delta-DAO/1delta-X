import { runDurableObjectAlarm } from "cloudflare:test";
import { OrderStatus } from "@1delta-x/orderbook/pure";
import type { Hex } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import { decodeReceiptLogs, type RawLog } from "../src/chain";
import worker from "../src/index";
import { alice, call, deployment, fillLog, freshBook, rawFillLog, rawNoiseLog, resetWorld, signed, testEnv, world } from "./helpers";

beforeEach(() => resetWorld());

const tx = (n: number): Hex => `0x${n.toString(16).padStart(64, "a")}` as Hex;
const receipt = (hash: Hex, block: bigint, logs: RawLog[], status: "success" | "reverted" = "success") =>
  world.receipts.set(hash.toLowerCase(), { status, blockNumber: block, transactionHash: hash, logs });
const report = (book: DurableObjectStub, body: unknown) => call(book, "POST", "/fills/report", JSON.stringify(body), undefined, true);
const fillsOf = async (book: DurableObjectStub, q = "") => (await call(book, "GET", `/fills${q}`)).body.fills as Record<string, unknown>[];
const status = async (book: DurableObjectStub, hash: Hex) => {
  const { removedAt: _r, ...rest } = (await call(book, "GET", `/orders/${hash}/status`)).body;
  return rest;
};

describe("POST /fills/report — receipt-based fill indexing", () => {
  it("stores exactly the record the eth_getLogs path stores, with the same side effects", async () => {
    const T1 = tx(1);
    const T2 = tx(2);
    const full = await signed(alice);
    const partial = await signed(alice);
    world.filled.set(`${full.hash}@10`, 1_000n);
    world.filled.set(`${partial.hash}@12`, 400n);
    world.lens.set(partial.hash, { ok: true, status: OrderStatus.Fillable, fillableAmount: 600n, isSignatureValid: true, validatorsPass: true });

    // Book A: the log scan.
    const viaLogs = freshBook();
    await call(viaLogs, "POST", "/orders", full.body);
    await call(viaLogs, "POST", "/orders", partial.body);
    world.head = 50n;
    world.logs = [fillLog(full.hash, alice.address, 10n, 3, T1), fillLog(partial.hash, alice.address, 12n, 1, T2)];
    await runDurableObjectAlarm(viaLogs);
    world.logs = [];

    // Book B: the same two txs, reported (receipts carry token-transfer noise around the event).
    const viaReport = freshBook();
    await call(viaReport, "POST", "/orders", full.body);
    await call(viaReport, "POST", "/orders", partial.body);
    receipt(T1, 10n, [rawNoiseLog(10n, 2, T1), rawFillLog(full.hash, alice.address, 10n, 3, T1), rawNoiseLog(10n, 4, T1)]);
    receipt(T2, 12n, [rawFillLog(partial.hash, alice.address, 12n, 1, T2)]);
    const res = await report(viaReport, [T1, { txHash: T2 }]);
    expect(res.status).toBe(200);
    expect(res.body.results).toEqual([
      { txHash: T1, result: "indexed", blockNumber: "10", fills: [{ orderHash: full.hash, logIndex: 3 }], indexed: 1 },
      { txHash: T2, result: "indexed", blockNumber: "12", fills: [{ orderHash: partial.hash, logIndex: 1 }], indexed: 1 },
    ]);

    // The served fill rows, per maker (the app's `?maker=` query) — identical.
    const a = await fillsOf(viaLogs, `?maker=${alice.address}`);
    const b = await fillsOf(viaReport, `?maker=${alice.address}`);
    expect(b).toEqual(a);
    expect(b[1]).toMatchObject({ orderHash: full.hash, txHash: T1, blockNumber: "10", logIndex: 3, amount: "1000", cumulative: "1000", at: 1_700_000_300 });
    // Side effects: full fill tombstoned with its tx, partial progress updated.
    expect(await status(viaReport, full.hash)).toEqual(await status(viaLogs, full.hash));
    expect(await status(viaReport, full.hash)).toMatchObject({ live: false, status: "Filled", reason: "filled", filledAmount: "1000", txHash: T1 });
    expect(await status(viaReport, partial.hash)).toMatchObject({ live: true, filledAmount: "400" });
    // The partial is re-checked on the lens at the next alarm (dirty), as on the log path.
    await runDurableObjectAlarm(viaReport);
    expect(await status(viaReport, partial.hash)).toMatchObject({ live: true, filledAmount: "400", fillableAmount: "600" });
  });

  it("is idempotent on (txHash, logIndex) — across re-reports and the log scan", async () => {
    const T = tx(3);
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.filled.set(`${o.hash}@7`, 300n);
    receipt(T, 7n, [rawFillLog(o.hash, alice.address, 7n, 0, T)]);
    expect(((await report(book, { txHash: T })).body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "indexed", indexed: 1 });
    expect(((await report(book, T)).body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "known", indexed: 0 });
    // The log scan later reads the same block (a provider with eth_getLogs): still one row.
    world.head = 20n;
    world.logs = [fillLog(o.hash, alice.address, 7n, 0, T)];
    await runDurableObjectAlarm(book);
    const rows = await fillsOf(book);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ txHash: T, amount: "300" });
  });

  it("two fills of one order in one block by different txs: the block's delta is counted once", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.filled.set(`${o.hash}@9`, 700n);
    receipt(tx(4), 9n, [rawFillLog(o.hash, alice.address, 9n, 0, tx(4))]);
    receipt(tx(5), 9n, [rawFillLog(o.hash, alice.address, 9n, 5, tx(5))]);
    await report(book, [tx(4), tx(5)]);
    const amounts = (await fillsOf(book)).map((r) => r.amount);
    expect(amounts.sort()).toEqual(["700", null].sort());
  });

  it("refuses a reverted receipt, an unknown hash and an RPC error without writing anything", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.filled.set(`${o.hash}@8`, 1_000n);
    receipt(tx(6), 8n, [rawFillLog(o.hash, alice.address, 8n, 0, tx(6))], "reverted");
    world.receipts.set(tx(8), "throw");
    const res = await report(book, [tx(6), tx(7), tx(8)]);
    expect((res.body.results as Record<string, unknown>[]).map((r) => r.result)).toEqual(["reverted", "no-receipt", "rpc-error"]);
    expect(await fillsOf(book)).toEqual([]);
    expect(await status(book, o.hash)).toMatchObject({ live: true });
  });

  it("ignores an OrderFilled emitted by any contract but the Settlement", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.filled.set(`${o.hash}@8`, 1_000n);
    const forged = rawFillLog(o.hash, alice.address, 8n, 0, tx(9), "0x9999999999999999999999999999999999999999");
    receipt(tx(9), 8n, [forged, rawNoiseLog(8n, 1, tx(9))]);
    const res = await report(book, tx(9));
    expect((res.body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "no-fills", events: 0 });
    expect(await fillsOf(book)).toEqual([]);
    expect(await status(book, o.hash)).toMatchObject({ live: true });
    // The pure decoder, directly: only the Settlement's log survives.
    const own = rawFillLog(o.hash, alice.address, 8n, 2, tx(9));
    expect(decodeReceiptLogs([forged, own], deployment.settlement, []).map((l) => l.logIndex)).toEqual([2]);
  });

  it("validates the body: a 20-report cap, hashes, statuses", async () => {
    const book = freshBook();
    const many = Array.from({ length: 21 }, (_, i) => tx(100 + i));
    expect((await report(book, many)).status).toBe(413);
    const twenty = await report(book, many.slice(0, 20));
    expect(twenty.status).toBe(200);
    expect((twenty.body.results as unknown[]).length).toBe(20);
    expect((await report(book, [])).status).toBe(400);
    expect((await report(book, { txHash: "0x1234" })).status).toBe(400);
    expect((await report(book, { txHash: tx(1), status: "maybe" })).status).toBe(400);
    expect((await report(book, { txHash: tx(1), status: "pending" })).status).toBe(400); // needs orderHash
    expect((await call(book, "GET", "/fills/report", undefined, undefined, true)).status).toBe(405);
  });
});

describe("pending fill markers (status: pending / failed)", () => {
  it("are served on the live order until the fill is indexed", async () => {
    const T = tx(20);
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    const res = await report(book, { txHash: T, orderHash: o.hash, status: "pending" });
    expect((res.body.results as Record<string, unknown>[])[0]).toEqual({ txHash: T, orderHash: o.hash, result: "pending" });

    const row = ((await call(book, "GET", "/orders")).body.orders as Record<string, unknown>[])[0]!;
    expect(row.pendingFill).toEqual({ txHash: T, sentAt: expect.any(Number) });
    expect((await call(book, "GET", `/orders/${o.hash}`)).body.pendingFill).toMatchObject({ txHash: T });
    expect((await call(book, "GET", `/orders/${o.hash}/status`)).body.pendingFill).toMatchObject({ txHash: T });
    // Not a fill yet: /fills serves only mined, indexed fills.
    expect(await fillsOf(book)).toEqual([]);

    // Confirmed (partial): the marker is replaced by the indexed record.
    world.filled.set(`${o.hash}@11`, 250n);
    receipt(T, 11n, [rawFillLog(o.hash, alice.address, 11n, 0, T)]);
    await report(book, { txHash: T });
    expect((await call(book, "GET", `/orders/${o.hash}`)).body.pendingFill).toBeNull();
    expect(await fillsOf(book)).toHaveLength(1);
  });

  it("are cleared by a failed report or a reverted receipt, and expire after 10 min", async () => {
    const book = freshBook();
    const a = await signed(alice);
    const b = await signed(alice);
    await call(book, "POST", "/orders", a.body);
    await call(book, "POST", "/orders", b.body);
    const pf = async (h: Hex) => (await call(book, "GET", `/orders/${h}`)).body.pendingFill;

    await report(book, { txHash: tx(21), orderHash: a.hash, status: "pending" });
    expect(((await report(book, { txHash: tx(21), status: "failed" })).body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "cleared" });
    expect(await pf(a.hash)).toBeNull();

    await report(book, { txHash: tx(22), orderHash: a.hash, status: "pending" });
    receipt(tx(22), 5n, [rawFillLog(a.hash, alice.address, 5n, 0, tx(22))], "reverted");
    await report(book, tx(22));
    expect(await pf(a.hash)).toBeNull();

    await report(book, { txHash: tx(23), orderHash: b.hash, status: "pending" });
    expect(await pf(b.hash)).toMatchObject({ txHash: tx(23) });
    world.offset += 601;
    expect(await pf(b.hash)).toBeNull();

    // A marker for an order the book does not hold is refused.
    const res = await report(book, { txHash: tx(24), orderHash: tx(999), status: "pending" });
    expect((res.body.results as Record<string, unknown>[])[0]).toMatchObject({ result: "unknown-order" });
  });
});

describe("fills nobody reported (lens-only detection)", () => {
  it("tombstone as Filled with the anchor as filledAmount and no txHash; /fills stays tx-backed only", async () => {
    const book = freshBook();
    const o = await signed(alice);
    await call(book, "POST", "/orders", o.body);
    world.offset += 400; // past the 300 s re-check cadence
    world.lens.set(o.hash, { ok: false, status: OrderStatus.Filled, fillableAmount: 0n, isSignatureValid: true, validatorsPass: true });
    await runDurableObjectAlarm(book);
    const s = (await call(book, "GET", `/orders/${o.hash}/status`)).body;
    expect(s).toMatchObject({ live: false, status: "Filled", reason: "filled", filledAmount: "1000", removedAt: expect.any(Number) });
    expect(s.txHash).toBeUndefined();
    expect(await fillsOf(book)).toEqual([]);
  });
});

describe("POST /fills/report through the entry worker — binding-key gate", () => {
  const post = (headers: Record<string, string>) =>
    worker.fetch(
      new Request("https://book.test/fills/report", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.150", ...headers },
        body: JSON.stringify({ txHash: tx(30) }),
      }),
      testEnv,
    );

  it("403 without the key, with a wrong key, or with a forged internal header; 200 with the key", async () => {
    expect((await post({})).status).toBe(403);
    expect((await post({ "x-orderbook-binding-key": "guess" })).status).toBe(403);
    expect((await post({ "x-ob-trusted": "1" })).status).toBe(403);
    const ok = await post({ "x-orderbook-binding-key": testEnv.BINDING_KEY! });
    expect(ok.status).toBe(200);
    expect(((await ok.json()) as { results: Array<{ result: string }> }).results[0]!.result).toBe("no-receipt");
  });
});

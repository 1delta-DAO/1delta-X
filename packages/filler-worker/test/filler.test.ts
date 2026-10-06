import { createScheduledController, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { parseTransaction, recoverTransactionAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { beforeEach, describe, expect, it } from "vitest";

import { alertBody } from "../src/alerts";
import { isAdmin, safeEqual } from "../src/auth";
import { setDeps } from "../src/do";
import worker from "../src/index";
import { ADMIN, doCall, freshFiller, GAS_PRICE, resetWorld, seedBook, testDeps, testEnv, tick, world } from "./helpers";

beforeEach(() => resetWorld());

const status = async (stub: ReturnType<typeof freshFiller>) => (await doCall(stub, "GET", "/status")).body as Record<string, any>;
const fills = async (stub: ReturnType<typeof freshFiller>, q = "") => ((await doCall(stub, "GET", `/fills${q}`)).body.fills ?? []) as Array<Record<string, any>>;

describe("signing in workerd", () => {
  it("viem privateKeyToAccount signs an explicit legacy tx that recovers to the key's address", async () => {
    const account = privateKeyToAccount(testEnv.PRIVATE_KEY as Hex);
    const raw = await account.signTransaction({ type: "legacy", chainId: 30, nonce: 7, to: "0x00000000000000000000000000000000000050a1", data: "0x1234", value: 0n, gas: 300_000n, gasPrice: GAS_PRICE });
    const t = parseTransaction(raw);
    expect(t).toMatchObject({ type: "legacy", chainId: 30, nonce: 7, gas: 300_000n, gasPrice: GAS_PRICE });
    expect(await recoverTransactionAddress({ serializedTransaction: raw as never })).toBe(account.address);
  });
});

describe("the tick state machine", () => {
  it("a tick sends ONE tx and records it pending", async () => {
    const stub = freshFiller();
    seedBook(3);
    const s = await tick(stub);
    expect(s.sent).toMatchObject({ kind: "fill", strategy: "route" });
    expect(s.pending).toBe(true);
    expect(world.sent).toHaveLength(1);
    expect(world.sent[0]).toMatchObject({ type: "legacy", gasPrice: GAS_PRICE, nonce: 0 });
    expect(s.sent!.tx).toBe(world.sent[0]!.hash);
    const st = await status(stub);
    expect(st.pending).toMatchObject({ hash: world.sent[0]!.hash, kind: "fill", strategy: "route", nonce: 0 });
  });

  it("the next tick resolves the receipt, charges the real gas and logs the fill", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    const charged = (await status(stub)).budgets.gasRbtcLeft as string;
    world.receipt = "success";
    const s = await tick(stub);
    expect(s.resolution).toMatchObject({ status: "success", kind: "fill" });
    const st = await status(stub);
    expect(st.pending).toBeNull();
    // At send: limit × price reserved; after the receipt: 280k × price charged.
    expect(Number(st.budgets.gasRbtcLeft)).toBeGreaterThan(Number(charged));
    expect(Number(st.budgets.gasRbtcLeft)).toBeCloseTo(0.002 - (280_000 * Number(GAS_PRICE)) / 1e18, 12);
    const rows = await fills(stub);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: "filled", strategy: "route", kind: "fill", tx: world.sent[0]!.hash, gas_used: "280000", gas_cost_wei: String(280_000n * GAS_PRICE) });
    expect(BigInt(rows[0]!.profit_est)).toBeGreaterThan(0n);
  });

  it("a revert applies the per-order backoff (no resend) and is logged", async () => {
    const stub = freshFiller();
    const [h] = seedBook(1);
    await tick(stub);
    world.receipt = "reverted";
    const s = await tick(stub);
    expect(s.resolution?.status).toBe("reverted");
    expect(s.sent).toBeUndefined();
    expect(s.outcomes?.[0]).toMatchObject({ status: "skipped", reason: expect.stringMatching(/backoff after 1 on-chain revert/) });
    const st = await status(stub);
    expect(st.backoff).toEqual(expect.arrayContaining([expect.objectContaining({ key: h, strikes: 1, scope: "all" })]));
    expect((await fills(stub, "?status=reverted"))[0]).toMatchObject({ status: "reverted", tx: world.sent[0]!.hash });
    expect(world.sent).toHaveLength(1);
  });

  it("no second send while a tx is pending", async () => {
    const stub = freshFiller();
    seedBook(3);
    for (let i = 0; i < 4; i++) {
      const s = await tick(stub);
      expect(s.pending).toBe(true);
    }
    expect(world.sent).toHaveLength(1);
    expect(world.bookFetches).toBe(1); // a pending tick does not even fetch the book
  });

  it("a dropped tx (not mined, not in the mempool after 15 min) is cleared and logged", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.offset = 3 * 60_000;
    expect((await tick(stub)).resolution?.status).toBe("timeout");
    world.offset = 16 * 60_000;
    world.known = false;
    const s = await tick(stub);
    expect(s.resolution?.status).toBe("dropped");
    expect((await status(stub)).pending).toBeNull();
    expect((await fills(stub))[0]).toMatchObject({ status: "dropped" });
  });

  it("a receipt after RECEIPT_TIMEOUT_MS: the fills row and the gas budget both carry the receipt's cost", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.offset = 3 * 60_000;
    expect((await tick(stub)).resolution?.status).toBe("timeout");
    world.receipt = "success";
    expect((await tick(stub)).resolution?.status).toBe("success");
    // The e2e verifier (e2e/load.ts) checks gas_cost_wei = gasUsed × price per row.
    expect((await fills(stub))[0]).toMatchObject({ status: "filled", gas_used: "280000", gas_cost_wei: String(280_000n * GAS_PRICE) });
    expect(Number((await status(stub)).budgets.gasRbtcLeft)).toBeCloseTo(0.002 - (280_000 * Number(GAS_PRICE)) / 1e18, 12);
  });

  it("a nonce mined by another tx (a hand-replacement) resolves at the first overdue tick, not after 15 min", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.offset = 30_000;
    expect((await tick(stub)).resolution).toBeUndefined(); // waiting: not overdue, the nonce is not read
    world.mined = 1; // the replacement mined; ours never will
    world.known = false;
    world.offset = 61_000;
    const s = await tick(stub);
    expect(s.resolution?.status).toBe("dropped");
    expect((await status(stub)).pending).toBeNull();
    expect(world.sent).toHaveLength(1); // no re-broadcast of the dead bytes
    expect((await fills(stub))[0]).toMatchObject({ status: "dropped" });
  });

  it("alarms re-arm faster while a tx is pending", async () => {
    const stub = freshFiller();
    seedBook(1);
    await runInDurableObject(stub, (instance) => instance.alarm());
    const next = await runInDurableObject(stub, (_i, state) => state.storage.getAlarm());
    expect(world.sent).toHaveLength(1);
    expect(next! - Date.now()).toBeLessThanOrEqual(3_500); // PENDING_TICK_SECONDS = 3
    world.receipt = "success";
    await runInDurableObject(stub, (instance) => instance.alarm());
    const idle = await runInDurableObject(stub, (_i, state) => state.storage.getAlarm());
    expect(idle! - Date.now()).toBeGreaterThan(60_000); // back to TICK_SECONDS
    await runInDurableObject(stub, (_i, state) => state.storage.deleteAlarm());
  });
});

describe("pause, resume, dry run", () => {
  it("paused: resolves the outstanding tx but sends nothing; resume sends again", async () => {
    const stub = freshFiller();
    seedBook(2);
    await tick(stub);
    expect((await doCall(stub, "POST", "/pause")).body).toEqual({ paused: true });
    world.receipt = "success";
    const s = await tick(stub);
    expect(s).toMatchObject({ paused: true, pending: false });
    expect(s.resolution?.status).toBe("success");
    expect(world.sent).toHaveLength(1);
    expect((await doCall(stub, "POST", "/resume")).body).toEqual({ paused: false });
    expect((await tick(stub)).sent).toBeDefined();
    expect(world.sent).toHaveLength(2);
  });

  it("POST /dry-run {on:true} stops broadcasting; {on:false} goes live again", async () => {
    const stub = freshFiller();
    seedBook(2);
    expect((await doCall(stub, "POST", "/dry-run", { on: true })).body).toEqual({ dryRun: true });
    const s = await tick(stub);
    expect(s.outcomes?.map((o) => o.status)).toEqual(["dry-run", "dry-run"]);
    expect(world.sent).toHaveLength(0);
    expect((await status(stub)).dryRun).toBe(true);
    expect((await doCall(stub, "POST", "/dry-run", { on: "no" })).status).toBe(400);
    await doCall(stub, "POST", "/dry-run", { on: false });
    expect((await tick(stub)).sent).toBeDefined();
    expect(world.sent).toHaveLength(1);
  });
});

describe("admin API", () => {
  const req = (path: string, init: RequestInit & { token?: string; host?: string } = {}) =>
    new Request(`https://${init.host ?? "filler.example.com"}${path}`, {
      method: init.method ?? "GET",
      headers: init.token !== undefined ? { authorization: `Bearer ${init.token}` } : {},
      ...(init.body ? { body: init.body } : {}),
    });

  it("every admin route is 401 without the right bearer token", async () => {
    for (const [path, method] of [["/status", "GET"], ["/fills", "GET"], ["/pause", "POST"], ["/resume", "POST"], ["/dry-run", "POST"], ["/tick", "POST"]] as const) {
      expect((await worker.fetch(req(path, { method }), testEnv)).status).toBe(401);
      expect((await worker.fetch(req(path, { method, token: "wrong" }), testEnv)).status).toBe(401);
      expect((await worker.fetch(req(path, { method, token: ADMIN.slice(0, -1) }), testEnv)).status).toBe(401);
      expect((await worker.fetch(req(path, { method, token: ADMIN + "x" }), testEnv)).status).toBe(401);
    }
    const ok = await worker.fetch(req("/status", { token: ADMIN }), testEnv);
    expect(ok.status).toBe(200);
    const body = await ok.text();
    // The private key never leaves the worker, in any form.
    const key = (testEnv.PRIVATE_KEY as string).toLowerCase();
    expect(body.toLowerCase()).not.toContain(key.slice(2));
    expect(body).not.toContain(ADMIN);
    expect(body).not.toContain("hooks.test");
    expect(JSON.parse(body)).toMatchObject({ address: privateKeyToAccount(key as Hex).address, chainId: 30 });
  });

  it("no ADMIN_TOKEN configured = everything refused", async () => {
    const r = req("/status", { token: "" });
    expect(await isAdmin(r, undefined)).toBe(false);
    expect(await isAdmin(r, "")).toBe(false);
    expect(await isAdmin(req("/status", { token: "abc" }), "abc")).toBe(true);
    expect(await isAdmin(new Request("https://x/status", { headers: { authorization: "Basic abc" } }), "abc")).toBe(false);
  });

  it("the compare is constant-time over SHA-256 digests (length-independent)", async () => {
    expect(await safeEqual("a", "a")).toBe(true);
    expect(await safeEqual("a", "b")).toBe(false);
    expect(await safeEqual("", "a")).toBe(false);
    expect(await safeEqual("a".repeat(1000), "a")).toBe(false);
  });

  it("the admin routes do not answer on *.workers.dev; /health does, unauthenticated, with ok + age only", async () => {
    expect((await worker.fetch(req("/status", { token: ADMIN, host: "filler-1delta-rsk.acct.workers.dev" }), testEnv)).status).toBe(404);
    const h = await worker.fetch(req("/health", { host: "filler-1delta-rsk.acct.workers.dev" }), testEnv);
    expect(h.status).toBe(200);
    const body = (await h.json()) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["lastTickAgeSeconds", "ok"]);
  });

  it("POST /tick runs a tick; wrong methods are 405; unknown paths 404", async () => {
    world.book = [];
    const t = await worker.fetch(req("/tick", { method: "POST", token: ADMIN }), testEnv);
    expect(t.status).toBe(200);
    expect(await t.json()).toMatchObject({ source: "manual" });
    expect((await worker.fetch(req("/tick", { token: ADMIN }), testEnv)).status).toBe(405);
    expect((await worker.fetch(req("/nope", { token: ADMIN }), testEnv)).status).toBe(404);
  });

  it("GET /fills?format=csv", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.receipt = "success";
    await tick(stub);
    const res = await stub.fetch("https://filler/fills?format=csv");
    expect(res.headers.get("content-type")).toMatch(/text\/csv/);
    const [header, row] = (await res.text()).trim().split("\n");
    expect(header).toBe("id,at,order_hash,strategy,kind,status,tx,pay_token,paid,recv_token,received,gas_used,gas_cost_wei,profit_est,profit_token,note");
    expect(row).toContain(world.sent[0]!.hash);
    expect(row).toContain(",filled,");
  });
});

describe("alerts", () => {
  it("a revert alerts once; the same condition does not re-alert within the cooldown", async () => {
    const stub = freshFiller();
    seedBook(2);
    await tick(stub);
    world.receipt = "reverted";
    await tick(stub); // resolves the revert, sends the second order
    const reverts = () => world.alerts.filter((a) => String(a.body.text).includes("reverted transaction"));
    expect(reverts()).toHaveLength(1);
    expect(world.alerts[world.alerts.length - 1]!.url).toBe("https://hooks.test/alert");
    await tick(stub); // the second order reverts too: still within the cooldown
    expect(reverts()).toHaveLength(1);
    const st = await status(stub);
    expect(st.alerts.some((a: { key: string }) => a.key === "reverts")).toBe(true);
  });

  it("low RBTC, a long-pending tx and an RPC error streak each alert (once)", async () => {
    const stub = freshFiller();
    world.rbtc = 10n ** 17n; // 0.1 < ALERT_MIN_RBTC 0.5
    seedBook(1);
    await tick(stub);
    expect(world.alerts.filter((a) => String(a.body.text).includes("low RBTC"))).toHaveLength(1);
    world.offset = 11 * 60_000;
    await tick(stub);
    await tick(stub);
    expect(world.alerts.filter((a) => String(a.body.text).includes("pending for"))).toHaveLength(1);
    world.rpcDown = true;
    for (let i = 0; i < 5; i++) await tick(stub);
    expect(world.alerts.filter((a) => String(a.body.text).includes("RPC failing"))).toHaveLength(1);
    expect(JSON.stringify(world.alerts)).not.toContain("rpc.invalid");
  });

  it("Slack and Telegram bodies", () => {
    expect(alertBody({ format: "slack", name: "f" }, "hi")).toEqual({ text: "[f] hi" });
    expect(alertBody({ format: "telegram", telegramChatId: "-100", name: "f" }, "hi")).toEqual({ chat_id: "-100", text: "[f] hi", disable_web_page_preview: true });
  });
});

describe("durability", () => {
  it("state survives eviction: the pending tx, budgets and cursor are reloaded from storage", async () => {
    const stub = freshFiller();
    seedBook(2);
    const s1 = await tick(stub);
    const before = await status(stub);
    await evictDurableObject(stub);
    const after = await status(stub);
    expect(after.pending.hash).toBe(s1.sent!.tx);
    expect(after.budgets).toEqual(before.budgets);
    world.receipt = "success";
    const s2 = await tick(stub);
    expect(s2.resolution).toMatchObject({ status: "success", tx: s1.sent!.tx });
    // The next send is the OTHER order, at the next nonce.
    expect(s2.sent!.orderHash).not.toBe(s1.sent!.orderHash);
    expect(world.sent[1]!.nonce).toBe(1);
  });
});

describe("per-tick work bound", () => {
  it("at most MAX_ORDERS_PER_TICK orders per tick, round-robin across ticks (cursor in the DO)", async () => {
    const stub = freshFiller();
    await doCall(stub, "POST", "/dry-run", { on: true });
    const hashes = seedBook(5).sort();
    const seen: string[] = [];
    for (let i = 0; i < 3; i++) {
      const s = await tick(stub);
      expect(s.evaluated).toBeLessThanOrEqual(2);
      seen.push(...(s.outcomes ?? []).map((o) => o.orderHash.toLowerCase()));
    }
    expect(seen).toEqual(hashes);
    await evictDurableObject(stub);
    // After eviction the cursor is reloaded: the walk wraps to the start, not to a random place.
    world.offset = 120_000; // past the dry-run recheck window
    const s = await tick(stub);
    expect(s.outcomes!.map((o) => o.orderHash.toLowerCase())).toEqual(hashes.slice(0, 2));
  });

  it("the subrequest budget stops the sweep before the next order", async () => {
    const stub = freshFiller();
    await doCall(stub, "POST", "/dry-run", { on: true });
    seedBook(3);
    world.rpcCost = 10; // every RPC call bills 10 subrequests: one order ≈ 60–130 of the 200
    const s = await tick(stub);
    // A new order is started only while ≥ SUBREQUESTS_PER_ORDER (40) remain of 200.
    expect(s.entries).toBe(3);
    expect(s.evaluated).toBeLessThan(3);
    expect(s.bounded).toBe(true);
    expect(s.subrequests).toBeLessThanOrEqual(200 + 100);
    // Without the multiplier the same tick evaluates every order (MAX_ORDERS_PER_TICK = 2 permitting).
    world.rpcCost = 1;
    world.offset = 120_000;
    expect((await tick(stub)).evaluated).toBe(2);
  });
});

describe("cron and intake", () => {
  it("the cron re-arms the alarm", async () => {
    const stub = testEnv.FILLER.get(testEnv.FILLER.idFromName("filler"));
    await runInDurableObject(stub, (_i, state) => state.storage.deleteAlarm());
    expect(await runInDurableObject(stub, (_i, state) => state.storage.getAlarm())).toBeNull();
    await worker.scheduled(createScheduledController({ cron: "* * * * *", scheduledTime: Date.now() }), testEnv);
    expect(await runInDurableObject(stub, (_i, state) => state.storage.getAlarm())).toBeGreaterThan(Date.now() - 1000);
  });

  it("without an injected book, the ORDERBOOK service binding serves the orders", async () => {
    const { fetchBook: _book, ...withoutBook } = testDeps;
    void _book;
    setDeps(withoutBook);
    try {
      const stub = freshFiller();
      const s = await tick(stub);
      expect(s.errors).toEqual([]);
      expect(s.entries).toBe(0);
      expect((await status(stub)).config.orderbook).toBe("service binding ORDERBOOK");
    } finally {
      setDeps(testDeps);
    }
  });
});

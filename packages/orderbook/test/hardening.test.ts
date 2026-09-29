import { describe, expect, it, vi } from "vitest";

import { amendOrder, hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";

import { checkAdmission, DEFAULT_ADMISSION } from "../src/admission";
import { Book } from "../src/book";
import { CancelVerifier } from "../src/cancels";
import { HttpTransport, OrderbookClient, signSoftCancel } from "../src/client";
import type { OrderAnnounce } from "../src/messages";
import { encodeOrderAnnounce, encodeOrderList, encodeStreamMessage } from "../src/proto/codec";
import { StreamKind } from "../src/proto/schema";
import { cancelTopic, orderTopic, replaceTopic } from "../src/topics";
import { InMemoryTransport } from "../src/transport";
import { OrderStatus, Verifier } from "../src/verify";

/**
 * Regressions for the 2026-09 order-book audit (F1–F12). Each block names the
 * finding it pins.
 */

const config = { chainId: 31, settlement: "0x0000000000000000000000000000000000000001" as const, permit3: zeroAddress, lens: zeroAddress, rpcUrl: "" };
const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const stranger = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
const TOKEN_A = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_B = "0x2222222222222222222222222222222222222222" as Address;
const POISON = 666n;
const HEAVY = 777n;

const inADay = () => BigInt(Math.floor(Date.now() / 1000) + 86_400);

function orderFor(maker: Address, nonce = 1n, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce,
    expiry: inADay(),
    legsIn: [{ token: TOKEN_A, start: 1000n, end: 0n }],
    legsOut: [{ token: TOKEN_B, start: 900n, end: 800n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

const entry = (o: Order) => ({ order: o, sig: "0x" as Hex });

type Mode = "revert-chunk" | "old-lens" | "new-lens";

/**
 * A lens stub that models the poison order in each of its shapes: the whole call
 * reverting, an old lens starving every later row to `Invalid`, and the new lens
 * reporting `Inconclusive`. Nonce 777 is an honest order too heavy for the batch
 * budget that the uncapped single-order view does classify.
 */
function lensClient(mode: Mode, log: { batches: number[]; singles: number } = { batches: [], singles: 0 }, singleThrows = true) {
  return {
    log,
    client: {
      readContract: async (args: { functionName: string; args: unknown[] }) => {
        if (args.functionName === "getOrderRelevantState") {
          log.singles++;
          const nonce = (args.args[0] as { nonce: bigint }).nonce;
          if (nonce === POISON && singleThrows) throw new Error("execution reverted: out of gas");
          return [OrderStatus.Fillable, 1000n, true, true];
        }
        const orders = args.args[0] as { nonce: bigint }[];
        log.batches.push(orders.length);
        const poisonAt = orders.findIndex((o) => o.nonce === POISON);
        if (mode === "revert-chunk" && poisonAt >= 0) throw new Error("execution reverted");
        const statuses = orders.map((o, i) => {
          if (mode === "old-lens" && poisonAt >= 0 && i >= poisonAt) return OrderStatus.Invalid;
          if (mode === "new-lens" && (o.nonce === POISON || o.nonce === HEAVY)) return OrderStatus.Inconclusive;
          return OrderStatus.Fillable;
        });
        return [statuses, statuses.map((s) => (s === OrderStatus.Fillable ? 1000n : 0n)), statuses.map(() => true), statuses.map(() => true)];
      },
    } as unknown as PublicClient,
  };
}

// ──────────────────── F1 — one poison order evicts its chunk ────────────────────

describe("F1 — a poison order cannot take its chunk (or the sweep) down with it", () => {
  const honest = (n: number) => Array.from({ length: n }, (_, i) => orderFor(account.address, BigInt(i + 1)));

  it("bisects a chunk whose lens call reverts, and still answers every later chunk", async () => {
    const { client, log } = lensClient("revert-chunk");
    const v = new Verifier(client, config, { batchSize: 4 });
    const orders = honest(12);
    orders[1] = orderFor(account.address, POISON);
    const res = await v.verifyLayer2(orders.map(entry));

    expect(res).toHaveLength(12);
    res.forEach((r, i) => expect(r.status).toBe(i === 1 ? OrderStatus.Inconclusive : OrderStatus.Fillable));
    // chunks 2 and 3 were each asked once, untouched by chunk 1's failure
    expect(log.batches.filter((n) => n === 4).length).toBeGreaterThanOrEqual(3);
  });

  it("re-checks an old lens's run of Invalid rows in isolation", async () => {
    const { client } = lensClient("old-lens");
    const v = new Verifier(client, config, { batchSize: 10 });
    const orders = honest(6);
    orders[2] = orderFor(account.address, POISON);
    const res = await v.verifyLayer2(orders.map(entry));
    res.forEach((r, i) => {
      if (i === 2) expect(r.status).toBe(OrderStatus.Invalid); // alone, it really is
      else expect(r.ok).toBe(true);
    });
  });

  it("takes Inconclusive for what it is, and settles a heavy honest order with the uncapped view", async () => {
    const { client, log } = lensClient("new-lens");
    const v = new Verifier(client, config);
    const orders = [orderFor(account.address, 1n), orderFor(account.address, POISON), orderFor(account.address, HEAVY), orderFor(account.address, 4n)];
    const res = await v.verifyLayer2(orders.map(entry));
    expect(res.map((r) => r.status)).toEqual([OrderStatus.Fillable, OrderStatus.Inconclusive, OrderStatus.Fillable, OrderStatus.Fillable]);
    expect(res[1]!.isolated).toBe(true);
    expect(res[2]!.ok).toBe(true);
    expect(log.singles).toBe(2);
  });

  it("marks what the re-check budget does not reach Inconclusive, never Invalid", async () => {
    const { client } = lensClient("old-lens");
    const v = new Verifier(client, config, { maxRecheckCalls: 0 });
    const orders = honest(5);
    orders[0] = orderFor(account.address, POISON);
    const res = await v.verifyLayer2(orders.map(entry));
    for (const r of res) expect(r.status).toBe(OrderStatus.Inconclusive);
  });

  it("throws when NO call succeeds — an RPC outage is not a book's worth of verdicts", async () => {
    const dead = { readContract: async () => Promise.reject(new Error("fetch failed")) } as unknown as PublicClient;
    const v = new Verifier(dead, config, { batchSize: 2 });
    await expect(v.verifyLayer2(honest(4).map(entry))).rejects.toThrow("fetch failed");
  });

  it("the book keeps an Inconclusive order, and evicts it only after repeated isolated failures", async () => {
    const { client } = lensClient("new-lens");
    const verifier = new Verifier(client, config);
    const book = new Book({ transport: new InMemoryTransport(), config, verifier, cancelVerifier: new CancelVerifier(client, config), revalidateMs: 0 });
    const good = orderFor(account.address, 1n);
    const poison = orderFor(account.address, POISON);
    book.admit(hashOrderStruct(good), entry(good));
    book.admit(hashOrderStruct(poison), entry(poison));

    await book.revalidate();
    await book.revalidate();
    expect(book.size).toBe(2); // two strikes: kept
    await book.revalidate();
    expect(book.get(hashOrderStruct(poison))).toBeUndefined();
    expect(book.get(hashOrderStruct(good))?.state?.ok).toBe(true);
  });

  it("an RPC outage during a sweep evicts nothing", async () => {
    const dead = { readContract: async () => Promise.reject(new Error("fetch failed")) } as unknown as PublicClient;
    const book = new Book({ transport: new InMemoryTransport(), config, verifier: new Verifier(dead, config), cancelVerifier: new CancelVerifier(dead, config), revalidateMs: 0 });
    const o = orderFor(account.address, 1n);
    book.admit(hashOrderStruct(o), entry(o));
    for (let i = 0; i < 5; i++) await expect(book.revalidate()).rejects.toThrow();
    expect(book.size).toBe(1);
  });
});

// ──────────────────── F2 — transport-path admission + bounded verification ────────────────────

describe("F2 — the transport path is gated and its lens calls are batched", () => {
  it("applies the admission policy before any lens call", async () => {
    const verifyAnnounce = vi.fn(async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }));
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: { verifyAnnounce, refreshStates: async () => new Map() } as unknown as Verifier,
      cancelVerifier: new CancelVerifier({} as PublicClient, config),
      revalidateMs: 0,
      admission: { maxLegsIn: 1 },
    });
    const twoLegs = orderFor(account.address, 1n, { legsIn: [{ token: TOKEN_A, start: 1n, end: 0n }, { token: TOKEN_B, start: 1n, end: 0n }] });
    const forever = orderFor(account.address, 2n, { expiry: 4_000_000_000n });
    expect((await book.ingestAnnounceBytes(encodeOrderAnnounce(entry(twoLegs)))).reason).toMatch(/input legs/);
    expect((await book.ingestAnnounceBytes(encodeOrderAnnounce(entry(forever)))).reason).toMatch(/max/);
    expect(verifyAnnounce).not.toHaveBeenCalled();
  });

  it("coalesces concurrent ingests into one lens call and dedupes the same announce in flight", async () => {
    const log = { batches: [] as number[], singles: 0 };
    const { client } = lensClient("new-lens", log);
    const v = new Verifier(client, config, { batchWindowMs: 5 });
    const orders = Array.from({ length: 10 }, (_, i) => orderFor(account.address, BigInt(i + 1)));
    const results = await Promise.all([...orders, orders[0]!, orders[0]!].map((o) => v.verifyAnnounce(entry(o))));
    expect(results.every((r) => r.ok)).toBe(true);
    expect(log.batches).toEqual([10]);
  });

  it("fails fast past the queue bound instead of piling up promises", async () => {
    const { client } = lensClient("new-lens");
    const v = new Verifier(client, config, { maxQueued: 2, batchWindowMs: 50 });
    const p = [1n, 2n].map((n) => v.verifyAnnounce(entry(orderFor(account.address, n))));
    await expect(v.verifyAnnounce(entry(orderFor(account.address, 3n)))).rejects.toThrow("queue full");
    await Promise.all(p);
  });

  it("never has more than maxConcurrentCalls lens calls in flight", async () => {
    let active = 0;
    let peak = 0;
    const client = {
      readContract: async (args: { args: unknown[] }) => {
        active++;
        peak = Math.max(peak, active);
        await new Promise((r) => setTimeout(r, 10));
        active--;
        const n = (args.args[0] as unknown[]).length;
        return [new Array(n).fill(OrderStatus.Fillable), new Array(n).fill(1n), new Array(n).fill(true), new Array(n).fill(true)];
      },
    } as unknown as PublicClient;
    const v = new Verifier(client, config, { batchSize: 1, maxConcurrentCalls: 2, batchWindowMs: 0 });
    await Promise.all(Array.from({ length: 8 }, (_, i) => v.verifyAnnounce(entry(orderFor(account.address, BigInt(i + 1))))));
    expect(peak).toBe(2);
  });
});

// ──────────────────── F3 — the verdict cache is bounded ────────────────────

describe("F3 — verdict cache: size bound and TTL eviction", () => {
  it("never holds more than maxCacheEntries", async () => {
    const { client } = lensClient("new-lens");
    const v = new Verifier(client, config, { maxCacheEntries: 3, batchWindowMs: 0 });
    for (let i = 1; i <= 10; i++) await v.verifyAnnounce(entry(orderFor(account.address, BigInt(i))));
    expect(v.cacheSize).toBe(3);
  });

  it("drops expired entries as new ones arrive", async () => {
    let t = 0;
    const { client } = lensClient("new-lens");
    const v = new Verifier(client, config, { cacheTtlMs: 1_000, nowMs: () => t, batchWindowMs: 0 });
    for (let i = 1; i <= 5; i++) await v.verifyAnnounce(entry(orderFor(account.address, BigInt(i))));
    t = 5_000;
    await v.verifyAnnounce(entry(orderFor(account.address, 99n)));
    expect(v.cacheSize).toBe(1);
  });

  it("does not cache an Inconclusive answer", async () => {
    const { client, log } = lensClient("new-lens");
    const v = new Verifier(client, config, { batchWindowMs: 0 });
    await v.verifyAnnounce(entry(orderFor(account.address, POISON)));
    await v.verifyAnnounce(entry(orderFor(account.address, POISON)));
    expect(log.batches.length).toBe(2);
    expect(v.cacheSize).toBe(0);
  });
});

// ──────────────────── F4 — capacity squatting ────────────────────

describe("F4 — capacity: token allowlist, tighter bounds, displacement", () => {
  const ctx = { size: 0, makerCount: () => 0, now: Math.floor(Date.now() / 1000) };

  it("rejects a leg token off the allowlist, on either side", () => {
    const policy = { ...DEFAULT_ADMISSION, allowedTokens: [TOKEN_A] };
    expect(checkAdmission(orderFor(account.address), ctx, policy).reason).toMatch(/not listed/);
    expect(checkAdmission(orderFor(account.address), ctx, { ...policy, allowedTokens: [TOKEN_A, TOKEN_B] }).ok).toBe(true);
  });

  it("caps encoded size and curve points; per-maker default is tighter", () => {
    expect(checkAdmission(orderFor(account.address), { ...ctx, encodedBytes: 20_000 }).reason).toMatch(/bytes/);
    const curve = Array.from({ length: 40 }, (_, i) => ({ timeDelta: BigInt(i + 1), bumpBps: 1n }));
    expect(checkAdmission(orderFor(account.address, 1n, { curve } as never), ctx).reason).toMatch(/curve/);
    expect(DEFAULT_ADMISSION.maxOrdersPerMaker).toBeLessThanOrEqual(100);
  });

  it("a full book displaces the largest maker's furthest-dated order for a smaller maker", () => {
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: {} as Verifier,
      cancelVerifier: new CancelVerifier({} as PublicClient, config),
      revalidateMs: 0,
      admission: { maxOrders: 4, maxOrdersPerMaker: 10 },
    });
    const squat = [1n, 2n, 3n, 4n].map((n) => orderFor(stranger.address, n, { expiry: inADay() + n }));
    for (const o of squat) expect(book.admit(hashOrderStruct(o), entry(o)).ok).toBe(true);

    // The squatter cannot displace itself…
    const more = orderFor(stranger.address, 5n);
    expect(book.precheck(more, hashOrderStruct(more)).capacity).toBe(true);
    // …but an honest newcomer takes the slot of its furthest-dated order.
    const honest = orderFor(account.address, 1n);
    expect(book.precheck(honest, hashOrderStruct(honest)).ok).toBe(true);
    expect(book.admit(hashOrderStruct(honest), entry(honest)).ok).toBe(true);
    expect(book.size).toBe(4);
    expect(book.get(hashOrderStruct(squat[3]!))).toBeUndefined();
    expect(book.makerCount(stranger.address)).toBe(3);
    expect(book.makerCount(account.address)).toBe(1);
  });
});

// ──────────────────── F6 — soft cancels stick ────────────────────

describe("F6 — soft cancels are remembered and honoured on every path", () => {
  const stubVerifier = {
    verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }),
    refreshStates: async () => new Map(),
  } as unknown as Verifier;
  const noChain = { readContract: async () => Promise.reject(new Error("no chain")), verifyTypedData: async () => Promise.reject(new Error("no chain")) } as unknown as PublicClient;
  const mkBook = () => new Book({ transport: new InMemoryTransport(), config, verifier: stubVerifier, cancelVerifier: new CancelVerifier(noChain, config), revalidateMs: 0 });

  it("a re-announce of a soft-cancelled order is not re-listed", async () => {
    const book = mkBook();
    const o = orderFor(account.address);
    expect((await book.ingestAnnounce(entry(o))).ok).toBe(true);
    await book.ingestCancel(await signSoftCancel(account, account.address, [hashOrderStruct(o)], config));
    expect(book.size).toBe(0);

    const again = await book.ingestAnnounce(entry(o));
    expect(again.ok).toBe(false);
    expect(again.reason).toMatch(/soft-cancelled/);
    expect(book.admit(hashOrderStruct(o), entry(o)).ok).toBe(false); // the fast path too
  });

  it("a cancel that arrives BEFORE its order still applies", async () => {
    const book = mkBook();
    const o = orderFor(account.address);
    await book.ingestCancel(await signSoftCancel(account, account.address, [hashOrderStruct(o)], config));
    expect((await book.ingestAnnounce(entry(o))).ok).toBe(false);
    expect(book.size).toBe(0);
  });

  it("a stranger's cancel over someone else's unseen hash blocks nothing", async () => {
    const book = mkBook();
    const o = orderFor(account.address);
    await book.ingestCancel(await signSoftCancel(stranger, stranger.address, [hashOrderStruct(o)], config));
    expect((await book.ingestAnnounce(entry(o))).ok).toBe(true);
  });

  it("the predecessor of a replace cannot be re-listed", async () => {
    const book = mkBook();
    const prev = orderFor(account.address, 1n);
    await book.ingestAnnounce(entry(prev));
    const amended = await amendOrder(account, prev, 2n, { minFillAnchor: 5n }, config);
    const res = await book.ingestReplace({
      cancel: { cancel: amended.cancel, sig: amended.cancelSig },
      announce: { order: amended.order, sig: amended.sig },
      replaces: amended.replaces,
    });
    expect(res.ok).toBe(true);
    expect((await book.ingestAnnounce(entry(prev))).ok).toBe(false);
  });

  it("tombstones are pruned once their order can no longer matter, and bounded", async () => {
    let now = Math.floor(Date.now() / 1000);
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: stubVerifier,
      cancelVerifier: new CancelVerifier(noChain, config),
      revalidateMs: 0,
      now: () => now,
      maxPendingTombstonesPerMaker: 3,
    });
    const hashes = Array.from({ length: 10 }, (_, i) => hashOrderStruct(orderFor(account.address, BigInt(i + 1))));
    await book.ingestCancel(await signSoftCancel(account, account.address, hashes, config));
    expect(book.tombstoneCount).toBe(3);
    now += 10 * 86_400;
    book.pruneTombstones();
    expect(book.tombstoneCount).toBe(0);
  });
});

// ──────────────────── F10 — eviction invalidates the verdict cache ────────────────────

describe("F10 — a chain-event eviction drops the cached verdict", () => {
  it("a re-announce after an on-chain cancel is re-verified, not served the stale ok", async () => {
    let status = OrderStatus.Fillable;
    let calls = 0;
    const client = {
      readContract: async (args: { args: unknown[] }) => {
        calls++;
        const n = (args.args[0] as unknown[]).length;
        return [new Array(n).fill(status), new Array(n).fill(status === OrderStatus.Fillable ? 1n : 0n), new Array(n).fill(true), new Array(n).fill(true)];
      },
    } as unknown as PublicClient;
    const verifier = new Verifier(client, config, { batchWindowMs: 0 });
    const book = new Book({ transport: new InMemoryTransport(), config, verifier, cancelVerifier: new CancelVerifier(client, config), revalidateMs: 0 });
    const o = orderFor(account.address);
    expect((await book.ingestAnnounce(entry(o))).ok).toBe(true);

    status = OrderStatus.Cancelled;
    book.applyChainEvent({ kind: "cancelledByHash", maker: account.address, orderHash: hashOrderStruct(o) });
    const again = await book.ingestAnnounce(entry(o));
    expect(again.ok).toBe(false);
    expect(calls).toBe(2);
  });
});

// ──────────────────── F11 — replace atomicity; first-seen announce ────────────────────

describe("F11 — replaces stay whole; a re-announce cannot rewrite the stored announce", () => {
  it("keeps the first-seen announce (permitBatch included) on a re-announce", () => {
    const book = new Book({ transport: new InMemoryTransport(), config, verifier: {} as Verifier, cancelVerifier: new CancelVerifier({} as PublicClient, config), revalidateMs: 0 });
    const o = orderFor(account.address);
    const permitBatch = { details: [], spender: zeroAddress, sigDeadline: 1n, signature: "0x01" } as unknown as OrderAnnounce["permitBatch"];
    book.admit(hashOrderStruct(o), { order: o, sig: "0xaa", permitBatch });
    book.admit(hashOrderStruct(o), { order: o, sig: "0xbb" });
    expect(book.get(hashOrderStruct(o))?.announce.permitBatch).toBe(permitBatch);
    expect(book.get(hashOrderStruct(o))?.announce.sig).toBe("0xaa");
  });

  it("HttpTransport delivers a REPLACE only on the replace topic — never a lone cancel half", async () => {
    let onMessage: ((ev: { data: unknown }) => void) | undefined;
    const t = new HttpTransport({
      baseUrl: "http://x",
      config,
      webSocket: () => ({ binaryType: "", addEventListener: (_t, cb) => (onMessage = cb), close: () => undefined }),
      fetch: (async () => new Response()) as typeof fetch,
    });
    const seen: string[] = [];
    await t.subscribe(cancelTopic(config.chainId, config.settlement), () => seen.push("cancel"));
    await t.subscribe(orderTopic(config.chainId, config.settlement), () => seen.push("order"));
    await t.subscribe(replaceTopic(config.chainId, config.settlement), () => seen.push("replace"));

    const prev = orderFor(account.address, 1n);
    const amended = await amendOrder(account, prev, 2n, { minFillAnchor: 5n }, config);
    const replace = { cancel: { cancel: amended.cancel, sig: amended.cancelSig }, announce: { order: amended.order, sig: amended.sig }, replaces: amended.replaces };
    onMessage!({ data: encodeStreamMessage({ kind: StreamKind.REPLACE, replace }) });
    expect(seen).toEqual(["replace"]);

    // …while the ergonomic client still hands halves to half-subscribers.
    const halves: string[] = [];
    const client = new OrderbookClient(t, config);
    await client.subscribeCancels(() => halves.push("cancel"));
    await client.subscribeOrders(() => halves.push("order"));
    onMessage!({ data: encodeStreamMessage({ kind: StreamKind.REPLACE, replace }) });
    expect(halves.sort()).toEqual(["cancel", "order"]);
  });

  it("a replace whose cancel does not verify admits nothing and evicts nothing", async () => {
    const stubVerifier = { verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }), refreshStates: async () => new Map() } as unknown as Verifier;
    const noChain = { readContract: async () => Promise.reject(new Error("no chain")), verifyTypedData: async () => Promise.reject(new Error("no chain")) } as unknown as PublicClient;
    const book = new Book({ transport: new InMemoryTransport(), config, verifier: stubVerifier, cancelVerifier: new CancelVerifier(noChain, config), revalidateMs: 0 });
    const prev = orderFor(account.address, 1n);
    await book.ingestAnnounce(entry(prev));
    const amended = await amendOrder(account, prev, 2n, { minFillAnchor: 5n }, config);
    const forged = await signSoftCancel(stranger, account.address, [amended.replaces], config);
    const res = await book.ingestReplace({ cancel: forged, announce: { order: amended.order, sig: amended.sig }, replaces: amended.replaces });
    expect(res.ok).toBe(false);
    expect(book.get(amended.replaces)).toBeDefined();
    expect(book.get(amended.orderHash)).toBeUndefined();
  });
});

// ──────────────────── F12 — history is paged ────────────────────

describe("F12 — HttpTransport.queryHistory walks every page", () => {
  it("follows x-next-cursor until the server stops sending one", async () => {
    const all = Array.from({ length: 5 }, (_, i) => entry(orderFor(account.address, BigInt(i + 1))));
    const urls: string[] = [];
    const fetchStub = (async (url: string) => {
      urls.push(url);
      const page = urls.length - 1;
      const slice = all.slice(page * 2, page * 2 + 2);
      const headers = new Headers(page < 2 ? { "x-next-cursor": `c${page}` } : {});
      return new Response(encodeOrderList(slice), { status: 200, headers });
    }) as unknown as typeof fetch;
    const t = new HttpTransport({ baseUrl: "http://x", config, webSocket: () => ({ binaryType: "", addEventListener: () => undefined, close: () => undefined }), fetch: fetchStub });
    const got = await t.queryHistory(orderTopic(config.chainId, config.settlement));
    expect(got).toHaveLength(5);
    expect(urls[0]).toContain("limit=");
    expect(urls[1]).toContain("cursor=c0");
  });
});

// ──────────────────── Low — O(1) per-maker count stays exact ────────────────────

describe("per-maker counter", () => {
  it("tracks admits and every kind of eviction", () => {
    const book = new Book({ transport: new InMemoryTransport(), config, verifier: {} as Verifier, cancelVerifier: new CancelVerifier({} as PublicClient, config), revalidateMs: 0 });
    const a = orderFor(account.address, 1n);
    const b = orderFor(account.address, 2n);
    book.admit(hashOrderStruct(a), entry(a));
    book.admit(hashOrderStruct(b), entry(b));
    book.admit(hashOrderStruct(b), entry(b)); // re-announce: no double count
    expect(book.makerCount(account.address.toLowerCase())).toBe(2);
    book.applyChainEvent({ kind: "cancelledByHash", maker: account.address, orderHash: hashOrderStruct(a) });
    expect(book.makerCount(account.address)).toBe(1);
  });
});

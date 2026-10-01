import { describe, expect, it, vi } from "vitest";

import {
  amendOrder,
  encodeProportional,
  hashOrderStruct,
  OrderSide,
  permit3Nonce,
  Permit3MessageKind,
  permitBatch,
  signPermitWitness,
  softCancelTypedData,
  tokenPermit,
  type Order,
} from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import {
  compactSignatureToHex,
  encodeAbiParameters,
  hashTypedData,
  parseSignature,
  signatureToCompactSignature,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

import { Book } from "../src/book";
import { CancelVerifier } from "../src/cancels";
import { OrderbookClient, signSoftCancel } from "../src/client";
import { FillIndex } from "../src/fills";
import type { OrderAnnounce } from "../src/messages";
import { encodeOrderAnnounce, encodeOrderReplace, encodeSoftCancel } from "../src/proto/codec";
import { orderPrice, queryOrders, summarize } from "../src/query";
import { cancelTopic, orderTopic, replaceTopic } from "../src/topics";
import { InMemoryTransport } from "../src/transport";
import { OrderStatus, Verifier, type Layer2Result } from "../src/verify";
import { ChainWatcher } from "../src/watcher";
import type { BookEntry } from "../src/book";

/**
 * Regressions for the 2026-09-30 whole-tree audit, group B-offchain (orderbook
 * library). Each test is named `test_audit_<ID>_<what>` after the finding it pins,
 * and asserts the SAFE end state — every one fails on the pre-fix source.
 */

const config = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001" as Address,
  permit3: "0x0000000000000000000000000000000000000003" as Address,
  lens: zeroAddress as Address,
  rpcUrl: "",
};
const maker = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const stranger = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
const TOKEN_A = "0x1111111111111111111111111111111111111111" as Address;
const TOKEN_B = "0x2222222222222222222222222222222222222222" as Address;
const inADay = () => BigInt(Math.floor(Date.now() / 1000) + 86_400);

function orderFor(who: Address, nonce = 1n, over: Partial<Order> = {}): Order {
  return {
    maker: who,
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

const announce = (o: Order): OrderAnnounce => ({ order: o, sig: "0x" as Hex });

/** A chain that answers nothing — every EOA soft-cancel path must stay RPC-free. */
const noChain = {
  readContract: async () => Promise.reject(new Error("no chain")),
  getCode: async () => Promise.reject(new Error("no chain")),
  verifyTypedData: async () => Promise.reject(new Error("no chain")),
} as unknown as PublicClient;

function stubVerifier(delayMs = 0) {
  return {
    verifyAnnounce: async (a: OrderAnnounce) => {
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
      return { ok: true, orderHash: hashOrderStruct(a.order) };
    },
    refreshStates: async () => new Map(),
  } as unknown as Verifier;
}

function mkBook(over: Partial<ConstructorParameters<typeof Book>[0]> = {}): Book {
  return new Book({
    transport: new InMemoryTransport(),
    config,
    verifier: stubVerifier(),
    cancelVerifier: new CancelVerifier(noChain, config),
    revalidateMs: 0,
    ...over,
  });
}

// ──────────────────── G-TS_FILLER-2 ────────────────────

describe("G-TS_FILLER-2 — a stranger cannot make a maker's soft cancel not stick", () => {
  it("test_audit_G_TS_FILLER_2_squatted_hash_still_takes_the_makers_cancel", async () => {
    const book = mkBook();
    const o = orderFor(maker.address);
    const h = hashOrderStruct(o);
    // The stranger plants a (pending) tombstone on H before H reaches this node.
    await book.ingestCancel(await signSoftCancel(stranger, stranger.address, [h], config));
    // H arrives — the stranger's tombstone does not block someone else's order.
    expect((await book.ingestAnnounce(announce(o))).ok).toBe(true);
    // The real maker cancels H: evicted AND remembered.
    const res = await book.ingestCancel(await signSoftCancel(maker, maker.address, [h], config));
    expect(res.evicted).toEqual([h]);
    expect(book.isSoftCancelled(h, maker.address)).toBe(true);
    const again = await book.ingestAnnounce(announce(o));
    expect(again.ok).toBe(false);
    expect(again.reason).toMatch(/soft-cancelled/);
  });

  it("test_audit_G_TS_FILLER_2_pending_flood_never_flushes_a_real_tombstone", async () => {
    const book = mkBook({ maxTombstones: 4, maxPendingTombstonesPerMaker: 1_000 });
    const o = orderFor(maker.address);
    const h = hashOrderStruct(o);
    await book.ingestAnnounce(announce(o));
    await book.ingestCancel(await signSoftCancel(maker, maker.address, [h], config));
    // Free keys mint pending tombstones on hashes that were never here.
    const junk = Array.from({ length: 20 }, (_, i) => hashOrderStruct(orderFor(stranger.address, BigInt(100 + i))));
    await book.ingestCancel(await signSoftCancel(stranger, stranger.address, junk, config));
    expect(book.tombstoneCount).toBeLessThanOrEqual(4);
    expect(book.isSoftCancelled(h, maker.address)).toBe(true);
    expect((await book.ingestAnnounce(announce(o))).ok).toBe(false);
  });

  it("test_audit_G_TS_FILLER_2_pending_tombstone_lifetime_is_bounded", async () => {
    let now = Math.floor(Date.now() / 1000);
    const book = mkBook({ now: () => now, admission: { maxTtlSeconds: 3_600 } });
    const unseen = hashOrderStruct(orderFor(maker.address, 9n));
    // A cancel that names an expiry ten years out.
    await book.ingestCancel(
      await signSoftCancel(maker, maker.address, [unseen], config, { now: BigInt(now), ttlSeconds: 10n * 365n * 86_400n }),
    );
    expect(book.tombstoneCount).toBe(1);
    now += 3_601; // past any deadline an order admitted now could carry
    book.pruneTombstones();
    expect(book.tombstoneCount).toBe(0);
  });
});

// ──────────────────── G-TS_FILLER-3 ────────────────────

describe("G-TS_FILLER-3 — backfill replays cancels and replaces, not only orders", () => {
  it("test_audit_G_TS_FILLER_3_restarted_node_does_not_relist_cancelled_or_replaced", async () => {
    const transport = new InMemoryTransport();
    const cancelled = orderFor(maker.address, 1n);
    const prev = orderFor(maker.address, 2n);
    // Store history as a long-running network would hold it.
    await transport.publish(orderTopic(config.chainId, config.settlement), encodeOrderAnnounce(announce(cancelled)));
    await transport.publish(orderTopic(config.chainId, config.settlement), encodeOrderAnnounce(announce(prev)));
    await transport.publish(
      cancelTopic(config.chainId, config.settlement),
      encodeSoftCancel(await signSoftCancel(maker, maker.address, [hashOrderStruct(cancelled)], config)),
    );
    const amended = await amendOrder(maker, prev, 3n, { minFillAnchor: 5n }, config);
    await transport.publish(
      replaceTopic(config.chainId, config.settlement),
      encodeOrderReplace({
        cancel: { cancel: amended.cancel, sig: amended.cancelSig },
        announce: { order: amended.order, sig: amended.sig },
        replaces: amended.replaces,
      }),
    );

    // A fresh node boots against that history.
    const book = mkBook({ transport });
    await book.start();
    expect(book.get(hashOrderStruct(cancelled))).toBeUndefined();
    expect(book.get(hashOrderStruct(prev))).toBeUndefined();
    expect(book.get(hashOrderStruct(amended.order))).toBeDefined();
    expect(book.size).toBe(1);
    await book.stop();
  });
});

// ──────────────────── G-TS_FILLER-4 ────────────────────

describe("G-TS_FILLER-4 — the replace exemption is re-derived after the awaits", () => {
  it("test_audit_G_TS_FILLER_4_concurrent_replaces_cannot_bypass_the_maker_cap", async () => {
    const book = mkBook({ verifier: stubVerifier(5), admission: { maxOrdersPerMaker: 1 } });
    const prev = orderFor(maker.address, 1n);
    expect(book.admit(hashOrderStruct(prev), announce(prev)).ok).toBe(true);
    expect(book.makerCount(maker.address)).toBe(1);

    const replaces = await Promise.all(
      [10n, 11n, 12n].map(async (n) => {
        const a = await amendOrder(maker, prev, n, { minFillAnchor: n }, config);
        return {
          cancel: { cancel: a.cancel, sig: a.cancelSig },
          announce: { order: a.order, sig: a.sig },
          replaces: a.replaces,
        };
      }),
    );
    // All three pass the pre-filter while the predecessor is live, then race.
    const results = await Promise.all(replaces.map((r) => book.ingestReplace(r)));
    expect(results.filter((r) => r.ok)).toHaveLength(1);
    expect(book.makerCount(maker.address)).toBe(1);
    expect(book.size).toBe(1);
  });

  it("test_audit_G_TS_FILLER_4_admit_cannot_be_told_to_skip_the_caps", () => {
    const book = mkBook({ admission: { maxOrdersPerMaker: 1 } });
    const a = orderFor(maker.address, 1n);
    const b = orderFor(maker.address, 2n);
    book.admit(hashOrderStruct(a), announce(a));
    // A caller-asserted exemption (the old `{ exempt: true }`) grants nothing.
    const res = book.admit(hashOrderStruct(b), announce(b), undefined, { exempt: true } as never);
    expect(res.ok).toBe(false);
    expect(book.makerCount(maker.address)).toBe(1);
  });
});

// ──────────────────── G-TS_FILLER-9 ────────────────────

describe("G-TS_FILLER-9 — the cancel verifier accepts the settler's signer set, no more", () => {
  const cancelFor = async (signerMaker: Address) => {
    const signed = await signSoftCancel(maker, signerMaker, [hashOrderStruct(orderFor(signerMaker))], config);
    return signed;
  };

  it("test_audit_G_TS_FILLER_9_accepts_an_eip2098_compact_signature", async () => {
    const signed = await cancelFor(maker.address);
    const compact = compactSignatureToHex(signatureToCompactSignature(parseSignature(signed.sig)));
    expect((compact.length - 2) / 2).toBe(64);
    // RPC-free: the settler recovers 64-byte signatures with plain ecrecover.
    const v = await new CancelVerifier(noChain, config).verify({ ...signed, sig: compact });
    expect(v.ok).toBe(true);
    expect(v.maker).toBe(maker.address);
  });

  it("test_audit_G_TS_FILLER_9_accepts_a_contract_delegate_envelope_for_a_codeless_maker", async () => {
    const codeless = "0x00000000000000000000000000000000000c0de1" as Address;
    const safe = "0x0000000000000000000000000000000000005afe" as Address;
    const cancel = (await signSoftCancel(maker, codeless, [hashOrderStruct(orderFor(codeless))], config)).cancel;
    const digest = hashTypedData(softCancelTypedData(cancel, config) as never);
    const inner = `0x${"ab".repeat(100)}` as Hex; // a Safe-style non-ECDSA payload
    const envelope = `0x${safe.slice(2)}${inner.slice(2)}` as Hex;
    const client = {
      getCode: async ({ address }: { address: Address }) => (address.toLowerCase() === safe.toLowerCase() ? "0x6080" : "0x"),
      readContract: async ({ functionName, args }: { functionName: string; args: readonly unknown[] }) => {
        if (functionName === "orderSignerExpiry") return (args[1] as string).toLowerCase() === safe.toLowerCase() ? 4_000_000_000n : 0n;
        if (functionName === "isValidSignature") return args[0] === digest && args[1] === inner ? "0x1626ba7e" : "0xffffffff";
        throw new Error(`unexpected ${functionName}`);
      },
      // The pre-fix code asked viem's verifyTypedData about the MAKER, which for a
      // codeless maker and a non-ECDSA payload is simply false.
      verifyTypedData: async () => false,
    } as unknown as PublicClient;
    const v = await new CancelVerifier(client, config).verify({ cancel, sig: envelope });
    expect(v.ok).toBe(true);
    expect(v.maker).toBe(codeless);
  });

  it("test_audit_G_TS_FILLER_9_rejects_an_erc6492_wrapper", async () => {
    // viem's verifyTypedData unwraps ERC-6492 (and would simulate the deploy); the
    // settler never does. Model the old path's acceptance with a stub that says yes.
    const signed = await cancelFor(stranger.address);
    const wrapped = (encodeAbiParameters(
      [{ type: "address" }, { type: "bytes" }, { type: "bytes" }],
      ["0x00000000000000000000000000000000000fac70", "0x1234", signed.sig],
    ) + "6492649264926492649264926492649264926492649264926492649264926492") as Hex;
    const client = {
      getCode: async () => "0x",
      readContract: async () => 0n,
      verifyTypedData: async () => true,
    } as unknown as PublicClient;
    const v = await new CancelVerifier(client, config).verify({ cancel: signed.cancel, sig: wrapped });
    expect(v.ok).toBe(false);
  });
});

// ──────────────────── G-TS_FILLER-10 ────────────────────

describe("G-TS_FILLER-10 — subscribers can ask for verified messages only", () => {
  it("test_audit_G_TS_FILLER_10_verified_cancel_subscription_drops_forgeries", async () => {
    const transport = new InMemoryTransport();
    const client = new OrderbookClient(transport, config);
    const got: Hex[] = [];
    await client.subscribeCancels((c) => got.push(c.sig), { cancelVerifier: new CancelVerifier(noChain, config) } as never);
    // A stranger "cancels" the maker's order with its own key.
    const forged = await signSoftCancel(stranger, maker.address, [hashOrderStruct(orderFor(maker.address))], config);
    const genuine = await signSoftCancel(maker, maker.address, [hashOrderStruct(orderFor(maker.address))], config);
    await client.cancelOrder(forged);
    await client.cancelOrder(genuine);
    await vi.waitFor(() => expect(got).toContain(genuine.sig));
    expect(got).not.toContain(forged.sig);
  });

  it("test_audit_G_TS_FILLER_10_verified_order_subscription_drops_rejected_announces", async () => {
    const transport = new InMemoryTransport();
    const client = new OrderbookClient(transport, config);
    const got: bigint[] = [];
    const verifier = { verifyAnnounce: async (a: OrderAnnounce) => ({ ok: a.order.nonce !== 666n }) };
    await client.subscribeOrders((a) => got.push(a.order.nonce), { verifier } as never);
    await client.publishAnnounce(announce(orderFor(maker.address, 666n)));
    await client.publishAnnounce(announce(orderFor(maker.address, 1n)));
    await vi.waitFor(() => expect(got).toContain(1n));
    expect(got).not.toContain(666n);
  });
});

// ──────────────────── A-FLEX-2 ────────────────────

describe("A-FLEX-2 — single-signature fillWithPermit announces verify", () => {
  const lens = (sigValid: boolean) =>
    ({
      // What a real lens says about a permit order before its fill: the order is
      // live, the permit's allowance does not exist yet, and the witness sig is not
      // an order signature.
      readContract: async () => [[OrderStatus.Fillable], [0n], [sigValid], [true]],
    }) as unknown as PublicClient;
  const batchFor = () => permitBatch([tokenPermit(config.settlement, TOKEN_A, 1000n, 4_000_000_000)], [], permit3Nonce(Permit3MessageKind.Batch, 1n), inADay());

  it("test_audit_A_FLEX_2_permit_witness_signed_announce_is_admitted", async () => {
    const order = orderFor(maker.address);
    const batch = batchFor();
    const sig = await signPermitWitness(maker, batch, order, config);
    const res = await new Verifier(lens(false), config, { batchWindowMs: 0 }).verifyAnnounce({ order, sig, permitBatch: batch });
    expect(res.ok).toBe(true);
    expect(res.state?.isSignatureValid).toBe(true);
  });

  it("test_audit_A_FLEX_2_permit_signed_by_someone_else_is_rejected", async () => {
    const order = orderFor(maker.address);
    const batch = batchFor();
    const sig = await signPermitWitness(stranger, batch, order, config);
    const res = await new Verifier(lens(true), config, { batchWindowMs: 0 }).verifyAnnounce({ order, sig, permitBatch: batch });
    expect(res.ok).toBe(false);
  });
});

// ──────────────────── G-TS_FILLER-8 ────────────────────

describe("G-TS_FILLER-8 — the fill index never reports negative amounts and honours reorgs", () => {
  const H = `0x${"11".repeat(32)}` as Hex;
  const SOLVER = "0x00000000000000000000000000000000000005a1" as Address;
  const lg = (block: bigint, removed = false) => ({
    args: { orderHash: H, maker: maker.address, solver: SOLVER },
    blockNumber: block,
    transactionHash: `0x${block.toString(16).padStart(64, "0")}` as Hex,
    logIndex: 0,
    ...(removed ? { removed: true } : {}),
  });

  function liveIndex(filledAt: (block: bigint | undefined) => bigint, delayAt: (block: bigint | undefined) => number = () => 0) {
    let onLogs: ((logs: unknown[]) => void) | undefined;
    const client = {
      getBlockNumber: async () => 100n,
      getContractEvents: async () => [],
      readContract: async ({ blockNumber }: { blockNumber?: bigint }) => {
        const d = delayAt(blockNumber);
        if (d) await new Promise((r) => setTimeout(r, d));
        return filledAt(blockNumber);
      },
      getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: 1_700_000_000n + blockNumber }),
      watchContractEvent: (args: { onLogs: (logs: unknown[]) => void }) => {
        onLogs = args.onLogs;
        return () => undefined;
      },
    } as unknown as PublicClient;
    const index = new FillIndex({ client, config });
    index.watch();
    return { index, emit: (logs: unknown[]) => onLogs!(logs) };
  }

  it("test_audit_G_TS_FILLER_8_out_of_order_batches_never_go_negative", async () => {
    const totals: Record<string, bigint> = { "5": 100n, "10": 300n, "11": 600n };
    const { index, emit } = liveIndex(
      (b) => totals[String(b)] ?? 0n,
      (b) => (b === 10n ? 30 : 0), // block 10's read is slow, block 11's fast
    );
    emit([lg(5n)]);
    await vi.waitFor(() => expect(index.query().total).toBe(1));
    emit([lg(10n)]);
    emit([lg(11n)]);
    await vi.waitFor(() => expect(index.query().total).toBe(3), { timeout: 2_000 });
    const byBlock = new Map(index.query().items.map((r) => [r.blockNumber, r.amount]));
    for (const amount of byBlock.values()) if (amount !== null) expect(amount > 0n).toBe(true);
    expect(byBlock.get(10n)).toBe(200n);
    expect(byBlock.get(11n)).toBe(300n);
  });

  it("test_audit_G_TS_FILLER_8_removed_log_is_retracted_not_recorded", async () => {
    const { index, emit } = liveIndex(() => 500n);
    emit([lg(7n)]);
    await vi.waitFor(() => expect(index.query().total).toBe(1));
    emit([lg(7n, true)]);
    await new Promise((r) => setTimeout(r, 30));
    expect(index.query().total).toBe(0);
  });

  it("test_audit_G_TS_FILLER_8_backfill_head_read_does_not_clobber_live_state", async () => {
    // Live row at block 60 (filled 700) arrives after a concurrent backfill read
    // the counter at head 100 (filled 900): it must not difference to -200.
    const totals: Record<string, bigint> = { "50": 500n, "60": 700n, "100": 900n, undefined: 900n };
    let onLogs: ((logs: unknown[]) => void) | undefined;
    const client = {
      getBlockNumber: async () => 100n,
      getContractEvents: async ({ fromBlock }: { fromBlock: bigint }) => (fromBlock === 0n ? [lg(50n)] : []),
      readContract: async ({ blockNumber }: { blockNumber?: bigint }) => totals[String(blockNumber)] ?? 0n,
      getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: 1_700_000_000n + blockNumber }),
      watchContractEvent: (args: { onLogs: (logs: unknown[]) => void }) => {
        onLogs = args.onLogs;
        return () => undefined;
      },
    } as unknown as PublicClient;
    const index = new FillIndex({ client, config, chunkBlocks: 1_000n });
    index.watch();
    await index.backfill(0n);
    onLogs!([lg(60n)]);
    await vi.waitFor(() => expect(index.query().total).toBe(2));
    const live = index.query().items.find((r) => r.blockNumber === 60n)!;
    expect(live.amount === null || live.amount > 0n).toBe(true);
  });

  it("test_audit_G_TS_FILLER_8_watcher_ignores_a_removed_cancel_log", async () => {
    const handlers: Record<string, (logs: unknown[]) => void> = {};
    const client = {
      watchContractEvent: (args: { eventName: string; onLogs: (logs: unknown[]) => void }) => {
        handlers[args.eventName] = args.onLogs;
        return () => undefined;
      },
    } as unknown as PublicClient;
    const watcher = new ChainWatcher({ client, config });
    const seen: string[] = [];
    watcher.on((e) => seen.push(e.kind));
    await watcher.start();
    handlers.OrdersCancelled!([{ args: { maker: maker.address, nonces: [1n] }, removed: true }]);
    expect(seen).toEqual([]);
    handlers.OrdersCancelled!([{ args: { maker: maker.address, nonces: [1n] } }]);
    expect(seen).toEqual(["cancelledNonces"]);
  });
});

// ──────────────────── X-ARITH-1.v5 ────────────────────

describe("X-ARITH-1.v5 — summaries do not read a proportional marker or a capacity cap as amounts", () => {
  const st = (over: Partial<Layer2Result> = {}): Layer2Result => ({
    ok: true,
    status: OrderStatus.Fillable,
    fillableAmount: 1000n,
    isSignatureValid: true,
    validatorsPass: true,
    ...over,
  });
  let seq = 0;
  const entry = (o: Order, state?: Layer2Result): BookEntry => ({
    orderHash: `0x${(++seq).toString(16).padStart(64, "0")}` as Hex,
    announce: announce(o),
    addedAt: seq,
    ...(state ? { state } : {}),
  });
  const proportionalOrder = () =>
    orderFor(maker.address, 1n, { legsIn: [{ token: TOKEN_A, start: encodeProportional(5_000n), end: 10n ** 30n }] });

  it("test_audit_X_ARITH_1_v5_proportional_order_has_no_raw_price_or_filled", () => {
    const s = summarize(entry(proportionalOrder(), st({ fillableAmount: 400n })));
    expect(s.amountIn).toBeNull();
    expect(s.proportionalBps).toBe(5_000);
    expect(s.price).toBeNull();
    expect(s.filledAmount).toBeNull();
    expect(orderPrice(proportionalOrder())).toBeNull();
  });

  it("test_audit_X_ARITH_1_v5_underfunded_order_is_not_reported_as_filled", () => {
    // Nothing filled; the maker can fund only 300 of 1000.
    const s = summarize(entry(orderFor(maker.address), st({ fillableAmount: 300n })));
    expect(s.filledAmount).not.toBe("700");
    expect(s.filledAmount).toBeNull();
    expect(summarize(entry(orderFor(maker.address), st({ fillableAmount: 300n })), 0n).filledAmount).toBe("0");
  });

  it("test_audit_X_ARITH_1_v5_unpriced_orders_sort_last_both_ways", () => {
    const priced = [orderFor(maker.address, 2n), orderFor(maker.address, 3n, { legsOut: [{ token: TOKEN_B, start: 1800n, end: 0n, recipient: zeroAddress }] })];
    const entries = [entry(proportionalOrder()), ...priced.map((o) => entry(o))];
    for (const direction of ["asc", "desc"] as const) {
      const items = queryOrders(entries, { sort: "price", direction }).items;
      expect(items[items.length - 1]!.announce.order.legsIn[0]!.start > 10n ** 70n).toBe(true);
      // Paging through with a cursor still visits every row exactly once.
      const first = queryOrders(entries, { sort: "price", direction, limit: 2 });
      const rest = queryOrders(entries, { sort: "price", direction, limit: 2, cursor: first.nextCursor! });
      expect([...first.items, ...rest.items].map((e) => e.orderHash).sort()).toEqual(entries.map((e) => e.orderHash).sort());
    }
  });
});

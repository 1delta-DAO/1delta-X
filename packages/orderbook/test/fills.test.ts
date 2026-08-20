import { describe, expect, it, vi } from "vitest";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";

import { adviseBand, bumpDistribution, OrderSide, type Order } from "@1delta-x/sdk";

import { FillIndex } from "../src/fills";
import type { OrderbookConfig } from "../src/config";

const config: OrderbookConfig = {
  chainId: 1,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};

const ALICE = "0x00000000000000000000000000000000000000a1" as Address;
const BOB = "0x00000000000000000000000000000000000000b0" as Address;
const SOLVER = "0x00000000000000000000000000000000000005a1" as Address;
const H1 = `0x${"11".repeat(32)}` as Hex;
const H2 = `0x${"22".repeat(32)}` as Hex;
/** `stubClient` reports block N at BASE_TS + N. */
const BASE_TS = 1_700_000_000;

function log(orderHash: Hex, maker: Address, blockNumber: bigint, logIndex: number) {
  return {
    args: { orderHash, maker, solver: SOLVER },
    blockNumber,
    transactionHash: `0x${blockNumber.toString(16).padStart(64, "0")}` as Hex,
    logIndex,
  };
}

function stubClient(logs: ReturnType<typeof log>[], filled: Record<string, bigint> = {}) {
  return {
    getBlockNumber: vi.fn(async () => 100n),
    getContractEvents: vi.fn(async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) =>
      logs.filter((l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock),
    ),
    readContract: vi.fn(async ({ args }: { args: readonly unknown[] }) => filled[args[0] as string] ?? 0n),
    getBlock: vi.fn(async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: 1_700_000_000n + blockNumber })),
    watchContractEvent: vi.fn(() => () => undefined),
  } as unknown as PublicClient;
}

describe("FillIndex", () => {
  it("backfills logs and reports the range it actually scanned", async () => {
    const client = stubClient([log(H1, ALICE, 10n, 0), log(H2, BOB, 20n, 1)], { [H1]: 500n, [H2]: 700n });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n });

    const found = await index.backfill();
    expect(found).toBe(2);

    const coverage = index.coverage;
    expect(coverage.records).toBe(2);
    expect(coverage.fromBlock).toBe("0");
    expect(coverage.toBlock).toBe("100");
    // Not live until something subscribes — a caller must be able to tell.
    expect(coverage.live).toBe(false);
  });

  it("attaches a cumulative to each order's newest row, and leaves per-fill amounts unknown", async () => {
    const client = stubClient([log(H1, ALICE, 10n, 0), log(H1, ALICE, 12n, 0)], { [H1]: 900n });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n });
    await index.backfill();

    const rows = index.query({ orderHash: H1 }).items;
    expect(rows).toHaveLength(2);
    // Newest first.
    expect(rows[0]!.blockNumber).toBe(12n);
    expect(rows[0]!.cumulative).toBe(900n);
    // The settlement stores only a running total, so a historical per-fill delta
    // is not recoverable. `null`, never a fabricated 0.
    expect(rows[0]!.amount).toBeNull();
    expect(rows[1]!.cumulative).toBeNull();
  });

  it("filters by maker and by solver", async () => {
    const client = stubClient([log(H1, ALICE, 10n, 0), log(H2, BOB, 11n, 0)]);
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n });
    await index.backfill();

    expect(index.query({ maker: ALICE }).items).toHaveLength(1);
    expect(index.query({ maker: ALICE }).items[0]!.orderHash).toBe(H1);
    expect(index.query({ solver: SOLVER }).items).toHaveLength(2);
    expect(index.query({ maker: "0x000000000000000000000000000000000000dead" as Address }).items).toHaveLength(0);
  });

  it("pages newest-first with a stable cursor", async () => {
    const client = stubClient([
      log(H1, ALICE, 10n, 0),
      log(H1, ALICE, 11n, 0),
      log(H1, ALICE, 12n, 0),
    ]);
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n });
    await index.backfill();

    const first = index.query({ limit: 2 });
    expect(first.items.map((f) => f.blockNumber)).toEqual([12n, 11n]);
    expect(first.total).toBe(3);

    const second = index.query({ limit: 2, cursor: first.nextCursor });
    expect(second.items.map((f) => f.blockNumber)).toEqual([10n]);
    expect(second.nextCursor).toBeUndefined();
  });

  it("bounds memory and admits that coverage is no longer contiguous", async () => {
    const logs = Array.from({ length: 10 }, (_, i) => log(H1, ALICE, BigInt(i + 1), 0));
    const client = stubClient(logs);
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, maxRecords: 4 });
    await index.backfill();

    expect(index.coverage.records).toBe(4);
    expect(index.coverage.dropped).toBe(6);
    // The window now starts at the oldest surviving record, not at the scan start.
    expect(index.coverage.fromBlock).toBe("7");
  });

  it("survives a provider that fails one chunk", async () => {
    const client = stubClient([log(H1, ALICE, 10n, 0)]);
    (client.getContractEvents as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error("range too wide"));
    const errors: unknown[] = [];
    const index = new FillIndex({
      client,
      config,
      defaultLookbackBlocks: 100n,
      chunkBlocks: 25n,
      onError: (e) => errors.push(e),
    });

    await expect(index.backfill()).resolves.toBeGreaterThanOrEqual(0);
    expect(errors).toHaveLength(1);
  });
});

// ──────────────────── realized clearing depth (bump replay) ────────────────────

/** A decaying SELL: 1000 in, output 2000 → 1000 over a 100-second window opening
 *  at the timestamp `stubClient` reports for block 0. */
function decayingOrder(over: Partial<Order> = {}): Order {
  return {
    maker: ALICE,
    side: OrderSide.SELL,
    nonce: 1n,
    expiry: 4_000_000_000n,
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1_000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 2_000n, end: 1_000n, recipient: zeroAddress }],
    // decayStartTime = the block-0 timestamp, decayDuration = 100.
    timing: BigInt(BASE_TS) | (100n << 32n),
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    priorityScale: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

describe("FillIndex realized bump", () => {
  it("replays the clock bump from the fill block, with no new chain data", async () => {
    // Block 50 ⇒ 50s into a 100s window ⇒ the midpoint of the band.
    const client = stubClient([log(H1, ALICE, 50n, 0)], { [H1]: 1_000n });
    const order = decayingOrder();
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });

    await index.backfill();
    await index.resolveBumps();

    const row = index.query({ orderHash: H1 }).items[0]!;
    expect(row.bumpSource).toBe("clock");
    expect(row.realizedBump).toBe(5_000);
  });

  it("clamps at the end of the window", async () => {
    const client = stubClient([log(H1, ALICE, 90n, 0)], { [H1]: 1_000n });
    const order = decayingOrder({ timing: BigInt(BASE_TS) | (10n << 32n) });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });
    await index.backfill();
    await index.resolveBumps();
    expect(index.query({ orderHash: H1 }).items[0]!.realizedBump).toBe(10_000);
  });

  it("reads a block-clock order's window in BLOCKS, not seconds", async () => {
    // decayStart = block 40, duration = 20 blocks; the fill lands at block 50 ⇒ half.
    const client = stubClient([log(H1, ALICE, 50n, 0)], { [H1]: 1_000n });
    const order = decayingOrder({ timing: 40n | (20n << 32n) | (1n << 102n) });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });
    await index.backfill();
    await index.resolveBumps();
    const row = index.query({ orderHash: H1 }).items[0]!;
    expect(row.bumpSource).toBe("clock");
    expect(row.realizedBump).toBe(5_000);
  });

  it("marks an IPriceModule order as a blind spot rather than guessing", async () => {
    // The bump depends on the filler's `takerData`, which is in the fill tx's
    // calldata and opaque behind a solver's own contract. `null`, never 0.
    const client = stubClient([log(H1, ALICE, 50n, 0)], { [H1]: 1_000n });
    const order = decayingOrder({ pricingModule: "0x00000000000000000000000000000000000000ff" as Address });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });
    await index.backfill();
    await index.resolveBumps();
    const row = index.query({ orderHash: H1 }).items[0]!;
    expect(row.bumpSource).toBe("module");
    expect(row.realizedBump).toBeNull();
  });

  it("reports unknown — not zero — when the order is not available", async () => {
    const client = stubClient([log(H1, ALICE, 50n, 0)], { [H1]: 1_000n });
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => undefined });
    await index.backfill();
    await index.resolveBumps();
    const row = index.query({ orderHash: H1 }).items[0]!;
    expect(row.bumpSource).toBe("unknown");
    expect(row.realizedBump).toBeNull();
  });

  it("leaves backfilled rows unresolved until asked — backfill does no per-event RPC", async () => {
    const client = stubClient([log(H1, ALICE, 50n, 0)], { [H1]: 1_000n });
    const order = decayingOrder();
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });
    await index.backfill();
    expect(index.query({ orderHash: H1 }).items[0]!.bumpSource).toBe("unresolved");
    expect(await index.resolveBumps()).toBe(1);
    expect(index.query({ orderHash: H1 }).items[0]!.bumpSource).toBe("clock");
    // Idempotent: a second pass has nothing left to do.
    expect(await index.resolveBumps()).toBe(0);
  });

  it("feeds bumpSamples straight into the SDK band advisor", async () => {
    const logs = [log(H1, ALICE, 25n, 0), log(H1, ALICE, 50n, 1), log(H1, ALICE, 75n, 2)];
    const client = stubClient(logs, { [H1]: 1_000n });
    const order = decayingOrder();
    const index = new FillIndex({ client, config, defaultLookbackBlocks: 100n, orderFor: () => order });
    await index.backfill();
    await index.resolveBumps();

    const d = bumpDistribution(index.bumpSamples({ orderHash: H1 }));
    expect(d.sorted).toEqual([2_500, 5_000, 7_500]);

    const advice = adviseBand({ start: 2_000n, end: 1_000n }, d, { coverage: 1 })!;
    // Nothing ever reached the floor: 2500 bps of the band is dead weight.
    expect(advice.maxBumpBps).toBe(7_500);
    expect(advice.unusedBandBps).toBe(2_500);
    expect(advice.suggestedEnd).toBe(1_250n);
    expect(advice.floorGain).toBe(250n);
    expect(advice.missedFraction).toBe(0);
  });
});

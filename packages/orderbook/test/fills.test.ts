import { describe, expect, it, vi } from "vitest";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";

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

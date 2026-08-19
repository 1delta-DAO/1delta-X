import { SETTLEMENT_ABI } from "@1delta-x/sdk";
import type { Address, Hex, PublicClient } from "viem";

import type { OrderbookConfig } from "./config";
import type { Unsubscribe } from "./transport";

/**
 * One `OrderFilled` log, enriched.
 *
 * ⚠ `OrderFilled(orderHash, maker, solver)` carries no amount — the settlement
 * deliberately does not pay ~256 gas per fill to publish one. The amount here is
 * therefore RECONSTRUCTED by reading the settlement's cumulative `filled(hash)`
 * and differencing it, which is exact for events this index saw live and
 * unavailable for most backfilled ones. `null` means "not known", never zero.
 */
export interface FillRecord {
  orderHash: Hex;
  maker: Address;
  solver: Address;
  blockNumber: bigint;
  txHash: Hex;
  logIndex: number;
  /** Unix seconds of the block, when the timestamp was resolvable. */
  at: number | null;
  /** Cumulative anchor amount filled on this order after this event. */
  cumulative: bigint | null;
  /** This fill's own delta. Known only when the previous cumulative was known. */
  amount: bigint | null;
}

export interface FillIndexOptions {
  client: PublicClient;
  config: OrderbookConfig;
  /**
   * Ring-buffer bound. An unbounded index is a memory leak with a public write
   * path in front of it — anyone can cause fills. Default 50k records.
   */
  maxRecords?: number;
  /** How many blocks `backfill()` reaches back when no explicit start is given. */
  defaultLookbackBlocks?: bigint;
  /** Log-range chunk for backfill; providers cap `eth_getLogs` spans. Default 10k. */
  chunkBlocks?: bigint;
  onError?: (err: unknown) => void;
}

export interface FillQuery {
  maker?: Address;
  solver?: Address;
  orderHash?: Hex;
  /** Records at or after this block. */
  fromBlock?: bigint;
  limit?: number;
  /** Opaque cursor from a previous page. */
  cursor?: string;
}

export interface FillQueryResult {
  items: FillRecord[];
  total: number;
  nextCursor?: string;
}

/** What the index can actually answer for — served alongside every fills response. */
export interface FillCoverage {
  /** Lowest block the index has scanned, or null if it has scanned nothing. */
  fromBlock: string | null;
  /** Highest block seen. */
  toBlock: string | null;
  records: number;
  /** True once a live subscription is attached; historical-only until then. */
  live: boolean;
  /** Records dropped by the ring buffer — coverage is no longer contiguous. */
  dropped: number;
}

function eq(a: string | undefined, b: string | undefined): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

/**
 * An in-memory index of settlement fills.
 *
 * This is the honest minimum for "which of my orders were filled". It is NOT a
 * durable indexer: it holds a bounded window in one process's memory and starts
 * empty on restart. Every response carries its {@link FillCoverage} so a caller
 * can tell "no fills" from "not indexed that far back" — the distinction a
 * silent empty array destroys.
 */
export class FillIndex {
  private readonly records: FillRecord[] = [];
  private readonly byHash = new Map<Hex, FillRecord[]>();
  /** Last known cumulative per order, so a live event can be differenced. */
  private readonly cumulative = new Map<Hex, bigint>();
  private readonly timestamps = new Map<string, number>();
  private readonly maxRecords: number;
  private readonly lookback: bigint;
  private readonly chunk: bigint;
  private scannedFrom: bigint | null = null;
  private scannedTo: bigint | null = null;
  private dropped = 0;
  private live = false;
  private unwatch: Unsubscribe | undefined;

  constructor(private readonly opts: FillIndexOptions) {
    this.maxRecords = Math.max(1, opts.maxRecords ?? 50_000);
    this.lookback = opts.defaultLookbackBlocks ?? 50_000n;
    this.chunk = opts.chunkBlocks ?? 10_000n;
  }

  get coverage(): FillCoverage {
    // Once the ring buffer has evicted anything, the window no longer starts
    // where the scan did — it starts at the oldest record still held. Reporting
    // the scan start would claim coverage that was dropped.
    const oldest = this.dropped > 0 ? (this.records[0]?.blockNumber ?? this.scannedFrom) : this.scannedFrom;
    return {
      fromBlock: oldest?.toString() ?? null,
      toBlock: this.scannedTo?.toString() ?? null,
      records: this.records.length,
      live: this.live,
      dropped: this.dropped,
    };
  }

  /**
   * Scan historical `OrderFilled` logs.
   *
   * Amounts are resolved once per DISTINCT order at head rather than per event:
   * the settlement stores only the running total, so the per-event deltas of a
   * backfill are not recoverable without replaying every call. One read per
   * order gives the cumulative honestly; the individual rows say `null`.
   */
  async backfill(fromBlock?: bigint): Promise<number> {
    const { client, config } = this.opts;
    const head = await client.getBlockNumber();
    const start = fromBlock ?? (head > this.lookback ? head - this.lookback : 0n);

    let found = 0;
    for (let from = start; from <= head; from += this.chunk) {
      const to = from + this.chunk - 1n > head ? head : from + this.chunk - 1n;
      let logs;
      try {
        logs = await client.getContractEvents({
          address: config.settlement,
          abi: SETTLEMENT_ABI,
          eventName: "OrderFilled",
          fromBlock: from,
          toBlock: to,
        });
      } catch (err) {
        this.opts.onError?.(err);
        continue;
      }
      for (const log of logs) {
        const args = log.args as { orderHash?: Hex; maker?: Address; solver?: Address };
        if (!args.orderHash || !args.maker || !args.solver) continue;
        this.push({
          orderHash: args.orderHash,
          maker: args.maker,
          solver: args.solver,
          blockNumber: log.blockNumber ?? 0n,
          txHash: log.transactionHash ?? ("0x" as Hex),
          logIndex: log.logIndex ?? 0,
          at: null,
          cumulative: null,
          amount: null,
        });
        found++;
      }
    }

    this.scannedFrom = this.scannedFrom === null ? start : start < this.scannedFrom ? start : this.scannedFrom;
    this.scannedTo = this.scannedTo === null || head > this.scannedTo ? head : this.scannedTo;
    await this.resolveHeadCumulatives();
    return found;
  }

  /** Subscribe to live `OrderFilled` logs. Returns an unsubscribe. */
  watch(): Unsubscribe {
    if (this.unwatch) return this.unwatch;
    const { client, config } = this.opts;
    const stop = client.watchContractEvent({
      address: config.settlement,
      abi: SETTLEMENT_ABI,
      eventName: "OrderFilled",
      onError: (err) => this.opts.onError?.(err),
      onLogs: (logs) => {
        void (async () => {
          for (const log of logs) {
            const args = log.args as { orderHash?: Hex; maker?: Address; solver?: Address };
            if (!args.orderHash || !args.maker || !args.solver) continue;
            const record: FillRecord = {
              orderHash: args.orderHash,
              maker: args.maker,
              solver: args.solver,
              blockNumber: log.blockNumber ?? 0n,
              txHash: log.transactionHash ?? ("0x" as Hex),
              logIndex: log.logIndex ?? 0,
              at: await this.timestampOf(log.blockNumber),
              cumulative: null,
              amount: null,
            };
            await this.resolveAmount(record);
            this.push(record);
            if (this.scannedTo === null || record.blockNumber > this.scannedTo) this.scannedTo = record.blockNumber;
          }
        })().catch((err) => this.opts.onError?.(err));
      },
    });
    this.live = true;
    this.unwatch = () => {
      stop();
      this.live = false;
      this.unwatch = undefined;
    };
    return this.unwatch;
  }

  stop(): void {
    this.unwatch?.();
  }

  query(q: FillQuery = {}): FillQueryResult {
    let items = this.records;
    if (q.orderHash) items = this.byHash.get(q.orderHash) ?? [];
    if (q.maker) items = items.filter((r) => eq(r.maker, q.maker));
    if (q.solver) items = items.filter((r) => eq(r.solver, q.solver));
    if (q.fromBlock !== undefined) items = items.filter((r) => r.blockNumber >= q.fromBlock!);

    // Newest first: the only ordering "my recent fills" ever wants.
    const sorted = [...items].sort((a, b) =>
      a.blockNumber === b.blockNumber ? b.logIndex - a.logIndex : a.blockNumber > b.blockNumber ? -1 : 1,
    );

    let start = 0;
    if (q.cursor) {
      const after = decodeFillCursor(q.cursor);
      if (after) {
        start = sorted.findIndex(
          (r) => r.blockNumber < after.block || (r.blockNumber === after.block && r.logIndex < after.logIndex),
        );
        if (start < 0) start = sorted.length;
      }
    }
    const limit = q.limit && q.limit > 0 ? q.limit : sorted.length;
    const page = sorted.slice(start, start + limit);
    const last = page[page.length - 1];
    const more = start + page.length < sorted.length;
    return {
      items: page,
      total: sorted.length,
      ...(more && last ? { nextCursor: encodeFillCursor(last.blockNumber, last.logIndex) } : {}),
    };
  }

  // ──────────────────── internals ────────────────────

  private push(record: FillRecord): void {
    this.records.push(record);
    const forHash = this.byHash.get(record.orderHash);
    if (forHash) forHash.push(record);
    else this.byHash.set(record.orderHash, [record]);

    while (this.records.length > this.maxRecords) {
      const evicted = this.records.shift();
      if (!evicted) break;
      this.dropped++;
      const list = this.byHash.get(evicted.orderHash);
      if (list) {
        const at = list.indexOf(evicted);
        if (at >= 0) list.splice(at, 1);
        if (list.length === 0) this.byHash.delete(evicted.orderHash);
      }
    }
  }

  private async resolveAmount(record: FillRecord): Promise<void> {
    try {
      const total = (await this.opts.client.readContract({
        address: this.opts.config.settlement,
        abi: SETTLEMENT_ABI,
        functionName: "filled",
        args: [record.orderHash],
      })) as bigint;
      const previous = this.cumulative.get(record.orderHash);
      record.cumulative = total;
      record.amount = previous === undefined ? null : total - previous;
      this.cumulative.set(record.orderHash, total);
    } catch (err) {
      this.opts.onError?.(err);
    }
  }

  /** One `filled()` read per distinct order touched, attached to its newest row. */
  private async resolveHeadCumulatives(): Promise<void> {
    for (const [hash, rows] of this.byHash) {
      const newest = rows[rows.length - 1];
      if (!newest || newest.cumulative !== null) continue;
      try {
        const total = (await this.opts.client.readContract({
          address: this.opts.config.settlement,
          abi: SETTLEMENT_ABI,
          functionName: "filled",
          args: [hash],
        })) as bigint;
        newest.cumulative = total;
        this.cumulative.set(hash, total);
      } catch (err) {
        this.opts.onError?.(err);
      }
    }
  }

  private async timestampOf(blockNumber: bigint | null | undefined): Promise<number | null> {
    if (blockNumber == null) return null;
    const key = blockNumber.toString();
    const hit = this.timestamps.get(key);
    if (hit !== undefined) return hit;
    try {
      const block = await this.opts.client.getBlock({ blockNumber });
      const seconds = Number(block.timestamp);
      this.timestamps.set(key, seconds);
      // Bounded: one entry per block seen, and blocks only ever move forward.
      if (this.timestamps.size > 4096) {
        const oldest = this.timestamps.keys().next().value;
        if (oldest !== undefined) this.timestamps.delete(oldest);
      }
      return seconds;
    } catch {
      return null;
    }
  }
}

/** Plain text — this library also runs where `Buffer` does not exist. */
function encodeFillCursor(block: bigint, logIndex: number): string {
  return `${block}~${logIndex}`;
}

function decodeFillCursor(cursor: string): { block: bigint; logIndex: number } | undefined {
  const at = cursor.indexOf("~");
  if (at < 0) return undefined;
  try {
    return { block: BigInt(cursor.slice(0, at)), logIndex: Number(cursor.slice(at + 1)) };
  } catch {
    return undefined;
  }
}

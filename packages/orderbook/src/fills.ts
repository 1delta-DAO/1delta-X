import {
  BLOCK_CLOCK_BIT,
  PRIORITY_AUCTION_BIT,
  bumpBps,
  priorityBid,
  SETTLEMENT_ABI,
  type Order,
} from "@1delta-x/sdk";
import type { Address, Hex, PublicClient } from "viem";

import type { OrderbookConfig } from "./config";
import type { Unsubscribe } from "./transport";

/**
 * Where a fill priced within the maker's band, and how confidently we know it.
 *
 *   • `clock`      — replayed from the order's decay clock at the fill block. Exact.
 *   • `priority`   — replayed from the fill's effective gas price. Exact.
 *   • `module`     — the order is priced by an {IPriceModule}; the answer depends on
 *                    the filler's `takerData`, which lives in the fill transaction's
 *                    calldata and is opaque when the filler routes through its own
 *                    contract. Genuinely not recoverable here.
 *   • `unresolved` — not attempted yet (backfilled rows, until {FillIndex.resolveBumps}).
 *   • `unknown`    — attempted and failed: no order available, or an RPC error.
 *
 * Only `clock` and `priority` carry a non-null `realizedBump`.
 */
export type BumpSource = "clock" | "priority" | "module" | "unresolved" | "unknown";

/**
 * One `OrderFilled` log, enriched.
 *
 * ⚠ `OrderFilled(orderHash, maker, solver)` carries no amount — the settlement
 * deliberately does not pay ~256 gas per fill to publish one. The amount here is
 * therefore RECONSTRUCTED by reading the settlement's cumulative `filled(hash)`
 * and differencing it, which is exact for events this index saw live and
 * unavailable for most backfilled ones. `null` means "not known", never zero.
 *
 * ⚠ The PRICE is not on chain either, and is not in `filled` — that counter tracks
 * the ANCHORED side, which is precisely the side that does not decay. The bump is
 * resolved once per fill into memory (`DutchAuction.resolveBump` → `FillCtx.bump`),
 * used, and discarded. But for the two on-chain pricing modes it is a deterministic
 * function of block context, so `realizedBump` REPLAYS it rather than observing it —
 * no new event, no gas on the hot path, no archive node. See {BumpSource} for the
 * modes where that replay does not work.
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
  /**
   * Where in the maker's signed band this fill cleared, in bps: `0` = `start`
   * (the maker's ambition), `10000` = `end` (its floor). `null` when it could not
   * be replayed — check {@link bumpSource} to tell a blind spot from a real 0.
   */
  realizedBump: number | null;
  bumpSource: BumpSource;
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
  /**
   * Resolve an order by hash, for {@link FillRecord.realizedBump}. Wire this to the
   * {@link Book}. Without it every row reports `bumpSource: "unknown"` — the index
   * holds only the event, and the band lives in the order.
   */
  orderFor?: (orderHash: Hex) => Order | undefined | Promise<Order | undefined>;
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
  /** Per-block context both the timestamp and the bump replay need. */
  private readonly blocks = new Map<string, BlockCtx>();
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
          realizedBump: null,
          bumpSource: "unresolved",
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
              realizedBump: null,
              bumpSource: "unresolved",
            };
            await this.resolveAmount(record);
            await this.resolveBump(record);
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

  /**
   * Resolve {@link FillRecord.realizedBump} for every row not yet attempted.
   *
   * Separate from `backfill()` on purpose: that path deliberately does NO per-event
   * RPC (it resolves cumulatives once per distinct order at head), and a bump replay
   * costs a `getBlock` per distinct block — cheap and cached, but not free. Call this
   * when you want the price data; skip it when you only want "was it filled".
   *
   * @returns how many rows gained a non-null bump.
   */
  async resolveBumps(): Promise<number> {
    let resolved = 0;
    for (const record of this.records) {
      if (record.bumpSource !== "unresolved") continue;
      await this.resolveBump(record);
      if (record.realizedBump !== null) resolved++;
    }
    return resolved;
  }

  /**
   * Realized clearing depths for a query, in the shape the SDK's `bumpDistribution`
   * consumes. Nulls are preserved rather than dropped — the distribution builder
   * discards them, and a null is an unobservable fill, never a fill at `start`.
   *
   * ⚠ Filter by pair before treating this as a band statistic. A fixed-price order
   * (no decay window) contributes an honest but meaningless `0`: it had no band to
   * clear inside.
   */
  bumpSamples(q: FillQuery = {}): (number | null)[] {
    return this.query(q).items.map((r) => r.realizedBump);
  }

  /**
   * Replay one fill's bump from block context.
   *
   * This is a REPLAY, not an observation: for the two on-chain pricing modes the
   * bump is a pure function of the order plus the fill's block (and, for a priority
   * auction, its effective gas price), so the same arithmetic the settler ran can be
   * re-run off-chain. That is why `OrderFilled` does not need to carry it — paying
   * ~256 gas on every fill forever to publish a derivable number would hand back a
   * tenth of the 2026-08 core gas pass.
   */
  private async resolveBump(record: FillRecord): Promise<void> {
    const lookup = this.opts.orderFor;
    if (!lookup) {
      record.bumpSource = "unknown";
      return;
    }
    try {
      const order = await lookup(record.orderHash);
      if (!order) {
        record.bumpSource = "unknown";
        return;
      }
      // An {IPriceModule} order prices off the filler's `takerData`, which is in the
      // fill transaction's calldata and opaque whenever the filler routes through its
      // own contract. Not recoverable here; say so rather than guessing.
      if (BigInt(order.pricingModule) !== 0n) {
        record.bumpSource = "module";
        return;
      }
      const ctx = await this.blockOf(record.blockNumber);
      if (!ctx) {
        record.bumpSource = "unknown";
        return;
      }

      const priority = ((order.timing >> PRIORITY_AUCTION_BIT) & 1n) === 1n;
      let bid = 0n;
      if (priority) {
        // The receipt's `effectiveGasPrice` IS the EVM's `tx.gasprice`; `maxFeePerGas`
        // is only a ceiling and would read as a much larger bid than was paid.
        const receipt = await this.opts.client.getTransactionReceipt({ hash: record.txHash });
        bid = priorityBid(receipt.effectiveGasPrice ?? 0n, ctx.baseFee, order.baselinePriorityFeeWei ?? 0n);
      }
      // The order's OWN clock: block numbers under `timing` bit 102, else seconds.
      const now = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n ? record.blockNumber : BigInt(ctx.timestamp);

      record.realizedBump = Number(bumpBps(order, now, ctx.baseFee, bid));
      record.bumpSource = priority ? "priority" : "clock";
    } catch (err) {
      // A malformed order, an auction that had not started, an RPC failure — all
      // reach here. `unknown` keeps them distinguishable from a real zero.
      record.bumpSource = "unknown";
      this.opts.onError?.(err);
    }
  }

  private async timestampOf(blockNumber: bigint | null | undefined): Promise<number | null> {
    const ctx = await this.blockOf(blockNumber);
    return ctx ? ctx.timestamp : null;
  }

  /** Block timestamp + basefee, cached. Both are inputs to the bump replay: the
   *  timestamp drives the decay clock, the basefee the gas bump and the priority bid. */
  private async blockOf(blockNumber: bigint | null | undefined): Promise<BlockCtx | null> {
    if (blockNumber == null) return null;
    const key = blockNumber.toString();
    const hit = this.blocks.get(key);
    if (hit !== undefined) return hit;
    try {
      const block = await this.opts.client.getBlock({ blockNumber });
      const ctx: BlockCtx = {
        timestamp: Number(block.timestamp),
        baseFee: block.baseFeePerGas ?? 0n,
      };
      this.blocks.set(key, ctx);
      // Bounded: one entry per block seen, and blocks only ever move forward.
      if (this.blocks.size > 4096) {
        const oldest = this.blocks.keys().next().value;
        if (oldest !== undefined) this.blocks.delete(oldest);
      }
      return ctx;
    } catch {
      return null;
    }
  }
}

interface BlockCtx {
  timestamp: number;
  baseFee: bigint;
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

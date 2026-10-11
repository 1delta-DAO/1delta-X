import { OCO_GROUP_MODULE_ABI, SETTLEMENT_ABI } from "@1delta-x/sdk";
import { parseEventLogs, type Address, type Hex, type PublicClient } from "viem";

/**
 * A Settlement (or OcoGroupModule) log, decoded. The same facts as the
 * orderbook library's `ChainEvent`, plus what an index needs: the `solver` of a
 * fill and the log's position.
 */
export type WorkerChainEvent =
  | { kind: "filled"; orderHash: Hex; maker: Address; solver: Address }
  | { kind: "cancelledByHash"; maker: Address; orderHash: Hex }
  | { kind: "cancelledNonces"; maker: Address; nonces: readonly bigint[] }
  | { kind: "rolledBack"; maker: Address; minValidNonce: bigint }
  | { kind: "wordInvalidated"; maker: Address; wordIndex: bigint }
  | { kind: "groupClaimed"; maker: Address; module: Address; groupId: bigint; nonce: bigint };

export interface ChainLog {
  event: WorkerChainEvent;
  blockNumber: bigint;
  logIndex: number;
  txHash: Hex;
}

/**
 * Everything the maintenance alarm reads from the chain. Injected so the tests
 * drive it with mocked logs; production uses {@link viemChainReader}.
 */
export interface ChainReader {
  blockNumber(): Promise<bigint>;
  /** Settlement + OCO logs in `[from, to]`, sorted by (block, logIndex). */
  logs(from: bigint, to: bigint): Promise<ChainLog[]>;
  /** `Settlement.filled(hash)` at `block` (latest when omitted). */
  filledAt(orderHash: Hex, block?: bigint): Promise<bigint>;
  /** Unix seconds of a block, or null. */
  blockTime(block: bigint): Promise<number | null>;
  /**
   * `eth_getTransactionReceipt`: the tx's status, block and RAW logs (every
   * contract's — {@link decodeReceiptLogs} keeps only the book's own), or `null`
   * when the node knows no receipt (not mined yet, or an unknown hash).
   */
  receipt(txHash: Hex): Promise<ChainReceipt | null>;
}

/** One raw log as `eth_getTransactionReceipt` returns it (viem's shape). */
export interface RawLog {
  address: Address;
  topics: readonly Hex[];
  data: Hex;
  blockNumber: bigint | null;
  logIndex: number | null;
  transactionHash: Hex | null;
  removed?: boolean;
}

export interface ChainReceipt {
  status: "success" | "reverted";
  blockNumber: bigint;
  transactionHash: Hex;
  logs: readonly RawLog[];
}

/** The event names the alarm asks `eth_getLogs` for — the same five `ChainWatcher` watches. */
const SETTLEMENT_EVENTS = ["OrderFilled", "OrderCancelledByHash", "OrdersCancelled", "NoncesRolledBack", "NonceWordInvalidated"] as const;

function eventAbi(abi: readonly unknown[], name: string): unknown {
  const e = abi.find((x) => (x as { type?: string; name?: string }).type === "event" && (x as { name?: string }).name === name);
  if (!e) throw new Error(`event ${name} missing from the SDK ABI`);
  return e;
}

/** Decode one viem log into a {@link WorkerChainEvent}; `undefined` for anything unusable. */
export function toChainEvent(eventName: string, args: Record<string, unknown>, address: Address): WorkerChainEvent | undefined {
  const a = args as Record<string, never>;
  switch (eventName) {
    case "OrderFilled":
      return a.orderHash && a.maker && a.solver ? { kind: "filled", orderHash: a.orderHash, maker: a.maker, solver: a.solver } : undefined;
    case "OrderCancelledByHash":
      return a.maker && a.orderHash ? { kind: "cancelledByHash", maker: a.maker, orderHash: a.orderHash } : undefined;
    case "OrdersCancelled":
      return a.maker && a.nonces ? { kind: "cancelledNonces", maker: a.maker, nonces: a.nonces } : undefined;
    case "NoncesRolledBack":
      return a.maker && a.minValidNonce != null ? { kind: "rolledBack", maker: a.maker, minValidNonce: a.minValidNonce } : undefined;
    case "NonceWordInvalidated":
      return a.maker && a.wordIndex != null ? { kind: "wordInvalidated", maker: a.maker, wordIndex: a.wordIndex } : undefined;
    case "GroupClaimed":
      return a.maker && a.groupId != null
        ? { kind: "groupClaimed", maker: a.maker, module: address, groupId: a.groupId, nonce: a.nonce ?? 0n }
        : undefined;
    default:
      return undefined;
  }
}

const SETTLEMENT_EVENT_ABIS = SETTLEMENT_EVENTS.map((n) => eventAbi(SETTLEMENT_ABI, n));
const GROUP_CLAIMED_ABI = eventAbi(OCO_GROUP_MODULE_ABI, "GroupClaimed");

/** A viem-decoded log (`getLogs` with `events`, or `parseEventLogs`). */
interface DecodedLog {
  eventName?: string;
  args?: Record<string, unknown>;
  address: Address;
  blockNumber: bigint | null;
  logIndex: number | null;
  transactionHash: Hex | null;
  removed?: boolean;
}

/** Decoded viem logs → {@link ChainLog}s: the ONE conversion both the log scan and the receipt path use. */
function collectChainLogs(logs: readonly unknown[], out: ChainLog[]): void {
  for (const raw of logs) {
    const log = raw as DecodedLog;
    if (log.removed || !log.eventName || log.blockNumber == null || log.logIndex == null || !log.transactionHash) continue;
    const event = toChainEvent(log.eventName, log.args ?? {}, log.address);
    if (event) out.push({ event, blockNumber: log.blockNumber, logIndex: log.logIndex, txHash: log.transactionHash });
  }
}

function byPosition(x: ChainLog, y: ChainLog): number {
  return x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : x.blockNumber < y.blockNumber ? -1 : 1;
}

/**
 * A receipt's raw logs → the {@link ChainLog}s `eth_getLogs` would have returned
 * for the same tx: the five Settlement events emitted BY `settlement`, and
 * `GroupClaimed` emitted by a configured OCO module. Anything else — including a
 * foreign contract emitting a look-alike `OrderFilled` topic — is dropped, as
 * the address filter of the `eth_getLogs` query drops it.
 */
export function decodeReceiptLogs(logs: readonly RawLog[], settlement: Address, ocoModules: readonly Address[]): ChainLog[] {
  const s = settlement.toLowerCase();
  const oco = new Set(ocoModules.map((a) => a.toLowerCase()));
  const own = logs.filter((l) => l.address.toLowerCase() === s);
  const groups = logs.filter((l) => oco.has(l.address.toLowerCase()));
  const out: ChainLog[] = [];
  collectChainLogs(parseEventLogs({ abi: SETTLEMENT_EVENT_ABIS as never, logs: own as never }), out);
  if (groups.length) collectChainLogs(parseEventLogs({ abi: [GROUP_CLAIMED_ABI] as never, logs: groups as never }), out);
  return out.sort(byPosition);
}

export function viemChainReader(client: PublicClient, settlement: Address, ocoModules: readonly Address[]): ChainReader {
  return {
    blockNumber: () => client.getBlockNumber({ cacheTime: 0 }),
    async logs(from, to) {
      const out: ChainLog[] = [];
      collectChainLogs(await client.getLogs({ address: settlement, events: SETTLEMENT_EVENT_ABIS as never, fromBlock: from, toBlock: to }), out);
      if (ocoModules.length) {
        collectChainLogs(await client.getLogs({ address: [...ocoModules], event: GROUP_CLAIMED_ABI as never, fromBlock: from, toBlock: to }), out);
      }
      return out.sort(byPosition);
    },
    async receipt(txHash) {
      let r;
      try {
        r = await client.getTransactionReceipt({ hash: txHash });
      } catch (err) {
        // viem throws TransactionReceiptNotFoundError for `null`: not mined (yet).
        if ((err as { name?: string }).name === "TransactionReceiptNotFoundError") return null;
        throw err;
      }
      return { status: r.status, blockNumber: r.blockNumber, transactionHash: r.transactionHash, logs: r.logs as readonly RawLog[] };
    },
    async filledAt(orderHash, block) {
      return (await client.readContract({
        address: settlement,
        abi: SETTLEMENT_ABI,
        functionName: "filled",
        args: [orderHash],
        ...(block !== undefined ? { blockNumber: block } : {}),
      })) as bigint;
    },
    async blockTime(block) {
      try {
        return Number((await client.getBlock({ blockNumber: block })).timestamp);
      } catch {
        return null;
      }
    },
  };
}

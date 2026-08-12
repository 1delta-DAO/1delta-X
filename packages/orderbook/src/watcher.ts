import { OCO_GROUP_MODULE_ABI, SETTLEMENT_ABI } from "@1delta-x/sdk";
import { decodeAbiParameters, type Address, type Hex, type PublicClient } from "viem";

import type { OrderbookConfig } from "./config";
import type { Unsubscribe } from "./transport";

/**
 * A normalized on-chain fact that changes an order's fate, decoded out of a log.
 *
 * The point of this type is that FOUR of the five carry everything a book needs
 * to evict — maker plus which hash or nonces died — so acting on them costs
 * **zero RPC**. Only `filled` is incomplete: `OrderFilled` says an order moved
 * but not how far, so it can only mark the order dirty for a targeted re-check.
 * (Putting the new cumulative `filled` in the event would close that too, at
 * ~256 gas per fill for the extra data word — the same band as optimizations
 * this codebase has previously rejected, so it is not proposed here.)
 */
export type ChainEvent =
  | { kind: "cancelledByHash"; maker: Address; orderHash: Hex }
  | { kind: "cancelledNonces"; maker: Address; nonces: readonly bigint[] }
  | { kind: "rolledBack"; maker: Address; minValidNonce: bigint }
  | { kind: "wordInvalidated"; maker: Address; wordIndex: bigint }
  | { kind: "groupClaimed"; maker: Address; module: Address; groupId: bigint; nonce: bigint }
  | { kind: "filled"; orderHash: Hex; maker: Address };

export type ChainEventHandler = (e: ChainEvent) => void;

export interface ChainWatcherOptions {
  client: PublicClient;
  config: OrderbookConfig;
  /**
   * {OcoGroupModule} deployments to watch `GroupClaimed` on. Optional, and worth
   * setting: one `GroupClaimed` retires every OTHER leg of a bracket, so it is
   * the only event here that evicts N−1 orders at once. Without it a retired
   * sibling looks fillable to the book right up until a solver burns gas
   * discovering otherwise — the book records `validatorsPass: false` for it and
   * deliberately does not act on that (a filler-conditional order is still
   * book-worthy for its target filler), so nothing else notices.
   */
  ocoModules?: readonly Address[];
  /** Surfaced rather than swallowed — a watcher that has silently died is worse than none. */
  onError?: (err: unknown) => void;
}

/**
 * Turns Settlement (and OcoGroupModule) logs into {@link ChainEvent}s.
 *
 * This exists because the book was polling for facts the chain already
 * broadcasts: a periodic `getOrderRelevantStates` over the WHOLE book, every
 * tick, regardless of what changed — O(n) work and up to a full period of
 * staleness to learn something the chain emitted in a log. Watching instead
 * makes eviction O(changed) and roughly one block late, and for the four
 * cancellation events it needs no view call at all.
 *
 * The timer does not go away. It stays as the safety net for everything a log
 * cannot tell you — a maker's balance or allowance falling away underneath a
 * still-valid order — and now runs against a book that events have already
 * pruned.
 */
export class ChainWatcher {
  private readonly unsubs: Unsubscribe[] = [];
  private readonly handlers = new Set<ChainEventHandler>();

  constructor(private readonly opts: ChainWatcherOptions) {}

  on(handler: ChainEventHandler): Unsubscribe {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  async start(): Promise<void> {
    const { client, config } = this.opts;
    const onError = (err: unknown): void => this.opts.onError?.(err);

    const watch = (eventName: string, address: Address, abi: unknown, map: (a: never) => ChainEvent | undefined): void => {
      this.unsubs.push(
        client.watchContractEvent({
          address,
          abi: abi as never,
          eventName: eventName as never,
          onLogs: (logs: readonly { args?: unknown }[]) => {
            for (const log of logs) {
              try {
                const e = map(log.args as never);
                if (e) this.emit(e);
              } catch (err) {
                onError(err);
              }
            }
          },
          onError,
        } as never),
      );
    };

    const s = config.settlement;
    watch("OrderCancelledByHash", s, SETTLEMENT_ABI, (a: { maker: Address; orderHash: Hex }) =>
      a.maker && a.orderHash ? { kind: "cancelledByHash", maker: a.maker, orderHash: a.orderHash } : undefined,
    );
    watch("OrdersCancelled", s, SETTLEMENT_ABI, (a: { maker: Address; nonces: readonly bigint[] }) =>
      a.maker && a.nonces ? { kind: "cancelledNonces", maker: a.maker, nonces: a.nonces } : undefined,
    );
    watch("NoncesRolledBack", s, SETTLEMENT_ABI, (a: { maker: Address; minValidNonce: bigint }) =>
      a.maker != null && a.minValidNonce != null
        ? { kind: "rolledBack", maker: a.maker, minValidNonce: a.minValidNonce }
        : undefined,
    );
    watch("NonceWordInvalidated", s, SETTLEMENT_ABI, (a: { maker: Address; wordIndex: bigint }) =>
      a.maker != null && a.wordIndex != null
        ? { kind: "wordInvalidated", maker: a.maker, wordIndex: a.wordIndex }
        : undefined,
    );
    watch("OrderFilled", s, SETTLEMENT_ABI, (a: { orderHash: Hex; maker: Address }) =>
      a.orderHash ? { kind: "filled", orderHash: a.orderHash, maker: a.maker } : undefined,
    );

    for (const mod of this.opts.ocoModules ?? []) {
      watch("GroupClaimed", mod, OCO_GROUP_MODULE_ABI, (a: { maker: Address; groupId: bigint; nonce: bigint }) =>
        a.maker != null && a.groupId != null
          ? { kind: "groupClaimed", maker: a.maker, module: mod, groupId: a.groupId, nonce: a.nonce }
          : undefined,
      );
    }
  }

  stop(): void {
    for (const u of this.unsubs.splice(0)) {
      try {
        u();
      } catch {
        /* already torn down */
      }
    }
  }

  private emit(e: ChainEvent): void {
    for (const h of [...this.handlers]) {
      try {
        h(e);
      } catch (err) {
        this.opts.onError?.(err);
      }
    }
  }
}

/**
 * Does this order carry a claim on `(module, groupId)` — i.e. is it a leg of that
 * bracket? Reads the order's own signed validators, so it needs no chain access
 * and cannot be spoofed by the announcer: the validator entry is inside the
 * EIP-712 hash.
 */
export function isOcoGroupLeg(
  validators: readonly { target: Address; data: Hex }[],
  module: Address,
  groupId: bigint,
): boolean {
  const m = module.toLowerCase();
  for (const v of validators) {
    if (v.target.toLowerCase() !== m) continue;
    try {
      const [g] = decodeAbiParameters([{ type: "uint256" }], v.data);
      if (g === groupId) return true;
    } catch {
      /* not a group validator on this module — some other validator sharing the address */
    }
  }
  return false;
}

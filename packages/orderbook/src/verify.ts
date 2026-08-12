import { hashOrderStruct, orderTypedData, OrderSide, SETTLEMENT_LENS_ABI, type Order } from "@1delta-x/sdk";
import { recoverTypedDataAddress, type Hex, type PublicClient } from "viem";

import { fillerOf, toDeployment, type OrderbookConfig } from "./config";
import type { OrderAnnounce } from "./messages";

/** Mirrors {SettlementLens.OrderStatus}. `Fillable` (1) is the admit gate. */
export enum OrderStatus {
  Invalid = 0,
  Fillable = 1,
  Filled = 2,
  Cancelled = 3,
  Expired = 4,
}

/** The full on-chain relevant-state for one order (one row of `getOrderRelevantStates`). */
export interface Layer2Result {
  /** Admit into the book? `Fillable && sig valid && fillable > 0`. Note: NOT gated on
   *  `validatorsPass` — a filler-conditional order is still book-worthy for the
   *  filler it targets, which runs its own per-filler preflight before filling. */
  ok: boolean;
  status: OrderStatus;
  /** Live fillable amount in anchor units, capped by the maker's Permit3 allowance + balance. */
  fillableAmount: bigint;
  /** ECDSA / EIP-1271 / EIP-7702 signature validity, as the lens attests it. */
  isSignatureValid: boolean;
  validatorsPass: boolean;
}

export interface VerifyResult {
  ok: boolean;
  reason?: string;
  orderHash: Hex;
  state?: Layer2Result;
}

interface CacheEntry {
  res: Layer2Result;
  at: number;
}

/**
 * The self-authenticating ingest pipeline (design doc §"verification pipeline").
 *
 * - **Layer 1** (local, zero RPC): recompute the order hash, structural sanity,
 *   deadline, and a cheap ECDSA recover for 65-byte sigs. Non-EOA sigs defer.
 * - **Layer 2** (one lens `readContract`): {SettlementLens.getOrderRelevantStates}
 *   returns status + live-fillable + signature validity (incl. EIP-1271/7702) +
 *   validators for a whole batch in a single view call — collapsing the design
 *   doc's "batched multicall" into one call. A short-TTL cache keyed by
 *   `orderHash` means a POST-then-ingest round-trip costs one eth_call, not two.
 *
 * The per-maker negative cache + `Transfer`/`Approval` event invalidation from
 * the design doc are a further optimization, deferred: at testnet volume a
 * per-ingest lens call is fine.
 */
export class Verifier {
  private readonly cache = new Map<Hex, CacheEntry>();
  private readonly cacheTtlMs: number;
  private readonly now: () => number;
  private readonly batchSize: number;

  constructor(
    private readonly client: PublicClient,
    private readonly config: OrderbookConfig,
    opts?: { cacheTtlMs?: number; now?: () => number; batchSize?: number },
  ) {
    this.cacheTtlMs = opts?.cacheTtlMs ?? 15_000;
    this.now = opts?.now ?? (() => Math.floor(Date.now() / 1000));
    this.batchSize = Math.max(1, opts?.batchSize ?? 100);
  }

  /** Layer 1 — local, no RPC. `deferSig` means the sig can only be judged by Layer 2. */
  async verifyLayer1(a: OrderAnnounce): Promise<{ ok: boolean; reason?: string; orderHash: Hex; deferSig: boolean }> {
    const { order, sig } = a;
    const orderHash = hashOrderStruct(order);

    const hasDenominator =
      order.fillTotal > 0n ||
      (order.side === OrderSide.SELL && order.legsIn.length > 0) ||
      (order.side === OrderSide.BUY && order.legsOut.length > 0);
    if (!hasDenominator) return { ok: false, reason: "no fill denominator (empty anchor leg)", orderHash, deferSig: false };

    if (order.deadline <= BigInt(this.now())) return { ok: false, reason: "order expired", orderHash, deferSig: false };

    // sigless = on-chain approveOrder path; confirmed on-chain, never by recover.
    if (a.sigless) return { ok: true, orderHash, deferSig: true };

    // 65-byte ECDSA sig (0x + 130 hex): recover here and require the maker. A
    // non-65-byte sig is a contract wallet (EIP-1271) or 7702 account — un-
    // recoverable locally, so defer the verdict to the lens.
    if (sig.length === 132) {
      let recovered: Hex;
      try {
        recovered = await recoverTypedDataAddress({
          ...orderTypedData(order, toDeployment(this.config)),
          signature: sig,
        } as unknown as Parameters<typeof recoverTypedDataAddress>[0]);
      } catch {
        return { ok: false, reason: "signature does not recover", orderHash, deferSig: false };
      }
      if (recovered.toLowerCase() !== order.maker.toLowerCase()) {
        return { ok: false, reason: "signature not by maker", orderHash, deferSig: false };
      }
      return { ok: true, orderHash, deferSig: false };
    }
    return { ok: true, orderHash, deferSig: true };
  }

  /**
   * Layer 2 — `getOrderRelevantStates` over the batch, CHUNKED. No cache.
   *
   * The chunking is not a micro-optimization, it is a correctness bound. Each
   * order in the call costs an external call, an order hash, cold
   * balance/allowance reads and one staticcall per validator — roughly 25–60k of
   * view gas. An unchunked call over a growing book therefore walks into the
   * provider's `eth_call` gas cap (30–50M, so somewhere past a few hundred to a
   * couple of thousand orders) and starts reverting WHOLESALE. Every order in
   * the book would then read as un-fillable at once, which is the worst possible
   * failure: a periodic re-check that evicts the entire book. Chunks keep one
   * bad or oversized order's blast radius to its own chunk.
   */
  async verifyLayer2(entries: readonly { order: Order; sig: Hex; sigless?: boolean }[]): Promise<Layer2Result[]> {
    if (entries.length === 0) return [];
    if (entries.length > this.batchSize) {
      const out: Layer2Result[] = [];
      for (let i = 0; i < entries.length; i += this.batchSize) {
        out.push(...(await this.verifyLayer2(entries.slice(i, i + this.batchSize))));
      }
      return out;
    }
    const orders = entries.map((e) => e.order);
    const sigs = entries.map((e) => e.sig);
    const takerDatas = entries.map(() => "0x" as Hex);

    const result = (await this.client.readContract({
      address: this.config.lens,
      abi: SETTLEMENT_LENS_ABI,
      functionName: "getOrderRelevantStates",
      args: [orders as never, sigs, fillerOf(this.config), takerDatas],
    })) as readonly [readonly number[], readonly bigint[], readonly boolean[], readonly boolean[]];

    const [statuses, fillableAmounts, sigValids, validatorsPass] = result;
    return entries.map((e, i): Layer2Result => {
      const status = (statuses[i] ?? OrderStatus.Invalid) as OrderStatus;
      const fillableAmount = fillableAmounts[i] ?? 0n;
      const isSignatureValid = sigValids[i] ?? false;
      const vp = validatorsPass[i] ?? false;
      // No sigless special case: the lens reads the settler's own `orderApproved`
      // record for an empty sig, so an on-chain-authorized order is attested here
      // on exactly the terms the settler applies. Previously this branch trusted
      // the announcer's own `sigless` claim, which is not evidence of anything.
      // NOTE: requires a lens deployed at or after that change — an older one
      // reports every sigless order invalid.
      const ok = status === OrderStatus.Fillable && isSignatureValid && fillableAmount > 0n;
      return { ok, status, fillableAmount, isSignatureValid, validatorsPass: vp };
    });
  }

  /** Full ingest verdict for one announce: Layer 1, then a cached Layer 2. */
  async verifyAnnounce(a: OrderAnnounce): Promise<VerifyResult> {
    const l1 = await this.verifyLayer1(a);
    if (!l1.ok) return { ok: false, reason: l1.reason, orderHash: l1.orderHash };
    const state = await this.layer2Cached(l1.orderHash, a);
    return { ok: state.ok, reason: state.ok ? undefined : reasonFor(state), orderHash: l1.orderHash, state };
  }

  /** Fresh Layer-2 states for orders already in the book (periodic re-check); refreshes the cache. */
  async refreshStates(entries: readonly { orderHash: Hex; announce: OrderAnnounce }[]): Promise<Map<Hex, Layer2Result>> {
    const states = await this.verifyLayer2(entries.map((e) => ({ order: e.announce.order, sig: e.announce.sig, sigless: e.announce.sigless })));
    const out = new Map<Hex, Layer2Result>();
    entries.forEach((e, i) => {
      const s = states[i];
      if (s) {
        this.cache.set(e.orderHash, { res: s, at: Date.now() });
        out.set(e.orderHash, s);
      }
    });
    return out;
  }

  private async layer2Cached(orderHash: Hex, a: OrderAnnounce): Promise<Layer2Result> {
    const hit = this.cache.get(orderHash);
    if (hit && Date.now() - hit.at < this.cacheTtlMs) return hit.res;
    const [res] = await this.verifyLayer2([{ order: a.order, sig: a.sig, sigless: a.sigless }]);
    const r: Layer2Result = res ?? { ok: false, status: OrderStatus.Invalid, fillableAmount: 0n, isSignatureValid: false, validatorsPass: false };
    this.cache.set(orderHash, { res: r, at: Date.now() });
    return r;
  }
}

function reasonFor(s: Layer2Result): string {
  switch (s.status) {
    case OrderStatus.Expired:
      return "order expired (on-chain)";
    case OrderStatus.Cancelled:
      return "nonce cancelled";
    case OrderStatus.Filled:
      return "order fully filled";
    case OrderStatus.Invalid:
      return "malformed order";
    default:
      if (!s.isSignatureValid) return "invalid signature";
      if (s.fillableAmount === 0n) return "maker has no allowance/balance for this order";
      return "not fillable";
  }
}

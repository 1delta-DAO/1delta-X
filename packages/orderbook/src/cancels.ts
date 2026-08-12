import { SETTLEMENT_ABI, softCancelTypedData, type SoftCancel } from "@1delta-x/sdk";
import { recoverTypedDataAddress, type Address, type Hex, type PublicClient } from "viem";

import { toDeployment, type OrderbookConfig } from "./config";
import type { SignedSoftCancel } from "./messages";

/** Verdict for one soft cancel. `maker` is set only when the signature verified. */
export interface CancelVerdict {
  ok: boolean;
  reason?: string;
  /** The authenticated maker — the ONLY account whose orders this cancel may evict. */
  maker?: Address;
}

export interface CancelVerifierOptions {
  /** Injectable clock (unix seconds). */
  now?: () => number;
  /**
   * How far into the future an `issuedAt` may sit before the message is
   * rejected as clock-skewed or hoarded-for-later. Default 60s.
   */
  maxSkewSeconds?: number;
  /**
   * Cap on `orderHashes` per message. A cancel is cheap to produce and forces a
   * map lookup per hash, so the batch that makes one signature efficient is also
   * the batch that makes one message a DoS vector. Default 256.
   */
  maxHashes?: number;
}

/**
 * Verifies maker-signed soft cancels, accepting exactly the signer set the
 * settlement accepts for an ORDER — no more, no less:
 *
 *   1. **EOA maker** — local ECDSA recover, zero RPC. The overwhelmingly common
 *      case, and the one that must stay free: a market maker re-pricing a book
 *      cancels far more often than it signs.
 *   2. **Maker-nominated delegate** — the recovered address is not the maker, so
 *      ask the settlement whether the maker nominated it (`orderSignerExpiry`)
 *      and whether that nomination is still live. A session key that can sign
 *      the maker's orders can obviously retract them; the reverse — a key that
 *      can create but not cancel — would be a strictly worse position for the
 *      maker to be in.
 *   3. **Contract maker (EIP-1271 / EIP-7702)** — the signature does not recover
 *      to anything meaningful, so defer to the chain via `verifyTypedData`,
 *      which viem resolves through the account's `isValidSignature`.
 *
 * Cases 2 and 3 cost one `eth_call`. Case 1 costs nothing, so the fast path
 * stays fast and only the unusual maker pays.
 *
 * ⚠ A verified cancel proves only WHO signed it. It does not prove the signer
 * owns the orders it names — that check belongs to the book, which evicts a hash
 * only when the order it holds names this maker. See `Book.ingestCancel`.
 */
export class CancelVerifier {
  private readonly now: () => number;
  private readonly maxSkew: number;
  private readonly maxHashes: number;
  /**
   * Resolved on first use, never at construction. The EOA path needs no chain at
   * all, so a caller with no RPC configured must be able to build a verifier and
   * still serve every ordinary cancel — the thunk keeps that true.
   */
  private readonly getClient: () => PublicClient;

  constructor(
    client: PublicClient | (() => PublicClient),
    private readonly config: OrderbookConfig,
    opts?: CancelVerifierOptions,
  ) {
    this.getClient = typeof client === "function" ? client : () => client;
    this.now = opts?.now ?? (() => Math.floor(Date.now() / 1000));
    this.maxSkew = opts?.maxSkewSeconds ?? 60;
    this.maxHashes = opts?.maxHashes ?? 256;
  }

  /** Shape + freshness only — no signature work, no RPC. Cheap enough to run first. */
  checkShape(c: SoftCancel): { ok: boolean; reason?: string } {
    if (c.orderHashes.length === 0) return { ok: false, reason: "cancel names no orders" };
    if (c.orderHashes.length > this.maxHashes) {
      return { ok: false, reason: `cancel names ${c.orderHashes.length} orders (max ${this.maxHashes})` };
    }
    const now = BigInt(this.now());
    if (c.expiry <= now) return { ok: false, reason: "cancel expired" };
    if (c.issuedAt > now + BigInt(this.maxSkew)) return { ok: false, reason: "cancel issued in the future" };
    if (c.expiry < c.issuedAt) return { ok: false, reason: "cancel expires before it was issued" };
    return { ok: true };
  }

  /** Full verdict: shape, then the three-step signer resolution. */
  async verify(signed: SignedSoftCancel): Promise<CancelVerdict> {
    const shape = this.checkShape(signed.cancel);
    if (!shape.ok) return shape;

    const typed = softCancelTypedData(signed.cancel, toDeployment(this.config));
    const maker = signed.cancel.maker;

    // 1 — EOA maker. A 65-byte sig is the only shape that can recover locally;
    //     anything else is a contract account and goes straight to the chain.
    if (signed.sig.length === 132) {
      let recovered: Address;
      try {
        recovered = await recoverTypedDataAddress({ ...typed, signature: signed.sig } as never);
      } catch {
        return { ok: false, reason: "cancel signature does not recover" };
      }
      if (recovered.toLowerCase() === maker.toLowerCase()) return { ok: true, maker };

      // 2 — a delegate the maker nominated on-chain.
      const delegated = await this.isLiveDelegate(maker, recovered);
      if (delegated) return { ok: true, maker };
      // Fall through: a 7702-delegated EOA can produce a 65-byte signature that
      // recovers to neither the maker nor a delegate, yet still validates through
      // the account's own `isValidSignature`. Only the chain can say.
    }

    // 3 — contract maker (EIP-1271 / EIP-7702), asked on-chain.
    try {
      const valid = await this.getClient().verifyTypedData({ ...typed, address: maker, signature: signed.sig } as never);
      return valid ? { ok: true, maker } : { ok: false, reason: "cancel not signed by the maker" };
    } catch {
      return { ok: false, reason: "cancel signature check failed (RPC?)" };
    }
  }

  private async isLiveDelegate(maker: Address, signer: Address): Promise<boolean> {
    try {
      const expiry = (await this.getClient().readContract({
        address: this.config.settlement,
        abi: SETTLEMENT_ABI,
        functionName: "orderSignerExpiry",
        args: [maker, signer],
      })) as bigint;
      // `0` is "not a signer" (an unset mapping), never "never expires" — the
      // settlement's own convention, mirrored here so the two cannot diverge.
      return expiry !== 0n && expiry > BigInt(this.now());
    } catch {
      return false;
    }
  }
}

/**
 * Which of a cancel's hashes this cancel is actually entitled to retract, given
 * what the book knows about each order's maker. Separated from signature
 * verification because they answer different questions — *who signed this* vs.
 * *what may they retract* — and conflating them is how a valid signature over
 * someone else's order hash turns into an eviction.
 */
export function evictableHashes(
  cancel: SoftCancel,
  makerOf: (orderHash: Hex) => Address | undefined,
): Hex[] {
  const maker = cancel.maker.toLowerCase();
  return cancel.orderHashes.filter((h) => makerOf(h)?.toLowerCase() === maker);
}

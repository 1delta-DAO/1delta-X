import { SETTLEMENT_ABI, softCancelTypedData, type SoftCancel } from "@1delta-x/sdk";
import { hashTypedData, type Address, type Hex, type PublicClient } from "viem";

import { toDeployment, type OrderbookConfig } from "./config";
import { recoverEcdsa } from "./ecdsa";
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
 * Verifies maker-signed soft cancels, accepting the signer set the settlement's
 * `Signatures._verifySignature` accepts for a SINGLE order signature, branch for
 * branch (audit 2026-09-30 G-TS_FILLER-9 — this used to say "no more, no less"
 * while accepting fewer shapes than the settler and more wrappers than it):
 *
 *   1. **EOA maker** — local ECDSA recover of a 65-byte OR 64-byte (EIP-2098
 *      compact) signature, zero RPC. The overwhelmingly common case, and the one
 *      that must stay free: a market maker re-pricing a book cancels far more
 *      often than it signs. A 65-byte `v` must be 27/28, as `ecrecover` demands.
 *   2. **Maker-nominated ECDSA delegate** — the recovered address is not the
 *      maker, so ask the settlement whether the maker nominated it
 *      (`orderSignerExpiry`) and whether that nomination is still live.
 *   3. **Maker-nominated CONTRACT delegate** — a codeless maker whose signature is
 *      not 64/65 bytes may carry the envelope `delegate(20) ‖ innerSig`; the
 *      delegate must be live in the registry and `innerSig` must verify for it
 *      (ECDSA, else its own EIP-1271 `isValidSignature`).
 *   4. **Contract maker (EIP-1271 / EIP-7702)** — the maker's own
 *      `isValidSignature(digest, sig)`, called DIRECTLY. Not viem's
 *      `verifyTypedData`: that also unwraps ERC-6492 (counterfactual deploy) and
 *      ERC-8010 envelopes, which the settler never accepts.
 *
 * NOT mirrored: the settler's bulk (Merkle-root) order signature — a soft cancel
 * is signed over its own `SoftCancel` struct, which has no root form.
 *
 * Cases 2–4 cost an `eth_call` or two. Case 1 costs nothing, so the fast path
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

  /** Full verdict: shape, then the settler's signer resolution (see the class doc). */
  async verify(signed: SignedSoftCancel): Promise<CancelVerdict> {
    const shape = this.checkShape(signed.cancel);
    if (!shape.ok) return shape;
    if (!/^0x([0-9a-fA-F]{2})*$/.test(signed.sig)) return { ok: false, reason: "cancel signature is not hex" };

    const digest = hashTypedData(softCancelTypedData(signed.cancel, toDeployment(this.config)) as never);
    const maker = signed.cancel.maker;
    const ok: CancelVerdict = { ok: true, maker };

    // 1/2 — ECDSA: the maker itself, else a delegate it nominated.
    const ecdsa = await recoverEcdsa(digest, signed.sig);
    if (ecdsa.standardLength && ecdsa.signer) {
      if (ecdsa.signer.toLowerCase() === maker.toLowerCase()) return ok;
      try {
        if (await this.isLiveDelegate(maker, ecdsa.signer)) return ok;
      } catch {
        return { ok: false, reason: "cancel signature check failed (RPC?)" };
      }
    }

    try {
      const makerHasCode = await this.hasCode(maker);
      // 3 — a contract delegate named in an envelope, for a codeless maker only.
      const bytes = (signed.sig.length - 2) / 2;
      if (!ecdsa.standardLength && bytes > 20 && !makerHasCode) {
        const delegate = `0x${signed.sig.slice(2, 42)}` as Address;
        const inner = `0x${signed.sig.slice(42)}` as Hex;
        if (await this.isLiveDelegate(maker, delegate)) {
          return (await this.verifyFor(delegate, digest, inner)) ? ok : { ok: false, reason: "cancel not signed by the maker" };
        }
      }
      // 4 — the maker's own EIP-1271 (a contract or 7702-delegated account). An EOA
      //     has none, so a signature that reached here from an EOA maker is final.
      if (!makerHasCode) return { ok: false, reason: "cancel not signed by the maker" };
      return (await this.isValid1271(maker, digest, signed.sig)) ? ok : { ok: false, reason: "cancel not signed by the maker" };
    } catch {
      return { ok: false, reason: "cancel signature check failed (RPC?)" };
    }
  }

  /** `SignatureVerification.verify` for one claimed signer: ECDSA, else its 1271. */
  private async verifyFor(signer: Address, digest: Hex, sig: Hex): Promise<boolean> {
    const ecdsa = await recoverEcdsa(digest, sig);
    if (ecdsa.standardLength && ecdsa.signer?.toLowerCase() === signer.toLowerCase()) return true;
    if (!(await this.hasCode(signer))) return false;
    return this.isValid1271(signer, digest, sig);
  }

  private async hasCode(account: Address): Promise<boolean> {
    const code = await this.getClient().getCode({ address: account });
    return code !== undefined && code !== "0x";
  }

  /** `isValidSignature(digest, sig) == 0x1626ba7e`; a revert or any other answer is `false`. */
  private async isValid1271(account: Address, digest: Hex, sig: Hex): Promise<boolean> {
    try {
      const magic = (await this.getClient().readContract({
        address: account,
        abi: ERC1271_ABI,
        functionName: "isValidSignature",
        args: [digest, sig],
      })) as Hex;
      return magic.toLowerCase() === ERC1271_MAGIC;
    } catch {
      return false;
    }
  }

  private async isLiveDelegate(maker: Address, signer: Address): Promise<boolean> {
    const expiry = (await this.getClient().readContract({
      address: this.config.settlement,
      abi: SETTLEMENT_ABI,
      functionName: "orderSignerExpiry",
      args: [maker, signer],
    })) as bigint;
    // `0` is "not a signer" (an unset mapping), never "never expires" — the
    // settlement's own convention (`block.timestamp <= expiry`), mirrored here so
    // the two cannot diverge.
    return expiry !== 0n && expiry >= BigInt(this.now());
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

const ERC1271_MAGIC = "0x1626ba7e";
const ERC1271_ABI = [
  {
    type: "function",
    name: "isValidSignature",
    stateMutability: "view",
    inputs: [
      { name: "hash", type: "bytes32" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "magicValue", type: "bytes4" }],
  },
] as const;

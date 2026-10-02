import { type QuoteBinding, type QuoteSigner, type SignedBid } from "@1delta-x/sdk";
import { encodeAbiParameters, keccak256, recoverAddress, toHex, type Address, type Hex } from "viem";

/**
 * EXECUTOR DECLARATIONS — binding a won quote to the contract that will fill.
 *
 * A bid names its filler, and the filler must be the bid's ECDSA signer (the SDK's
 * `signBid`/`verifyBid`), so a bid can only ever name an EOA. The quote modules,
 * however, compare the quote's `filler` with the address SETTLEMENT sees — and the
 * execution path this package recommends for a zero-inventory solver,
 * `AggregatorFillSolver`, fills AS ITSELF. Every quote the auctioneer bound to the
 * winning EOA therefore reverted `QuoteNotForFiller` on exactly that path (audit
 * 2026-09-30 CORE-FILLER-1.v3 / A-FLEX-1.v4 / PERIPH-2.v1); the only workaround was
 * an OPEN quote anyone could take.
 *
 * The bidder now signs a second, separate statement — "if I win this round, bind
 * the quote to `executor`" — with the SAME key, over the same round binding. The
 * round verifies it next to the bid, publishes it with the bid set (so
 * `checkRound` can re-verify it), and the auctioneer binds the quote to the
 * declared executor instead of the EOA.
 *
 * ⚠ DECLARE ONLY AN EXECUTOR THAT ONLY YOU CAN DRIVE. The quote is then bound to
 * that contract, so anyone able to make it fill can spend your quote: an
 * `AggregatorFillSolver` whose operator set is you (or a contract that checks its
 * caller) is fine; an open, permissionless router is equivalent to an open quote.
 * The maker is unaffected either way — the settlement still bounds the price by
 * the maker's band (and, under `ClockFlooredQuoteModule`, by the dutch clock).
 *
 * Its own type string, so it can never be replayed as a bid, a quote or an order.
 */

/** `keccak256("BidExecutor(bytes32 orderHash,address filler,address executor,uint256 closesAt)")` */
export const BID_EXECUTOR_TYPEHASH = keccak256(
  toHex("BidExecutor(bytes32 orderHash,address filler,address executor,uint256 closesAt)"),
);

export interface ExecutorDeclaration {
  orderHash: Hex;
  /** The bidding EOA — the declaration's signer. */
  filler: Address;
  /** The contract the quote is bound to if `filler` wins. */
  executor: Address;
  closesAt: number;
}

/** A signed bid, optionally carrying its executor declaration. */
export interface RoundBid extends SignedBid {
  executor?: Address;
  /** The filler's signature over {@link executorDigest}. Required with `executor`. */
  executorSignature?: Hex;
}

export function executorDigest(d: ExecutorDeclaration, binding: QuoteBinding): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "address" },
      ],
      [
        BID_EXECUTOR_TYPEHASH,
        d.orderHash,
        d.filler,
        d.executor,
        BigInt(d.closesAt),
        BigInt(binding.chainId),
        binding.module,
      ],
    ),
  );
}

/** Sign an executor declaration. The signer must be the filler that bids. */
export async function signExecutor(signer: QuoteSigner, d: ExecutorDeclaration, binding: QuoteBinding): Promise<Hex> {
  if (signer.address.toLowerCase() !== d.filler.toLowerCase()) {
    throw new Error("an executor declaration must be signed by the filler it names");
  }
  return signer.sign({ hash: executorDigest(d, binding) });
}

/** Attach a signed executor declaration to a signed bid. */
export async function withExecutor(
  signer: QuoteSigner,
  bid: SignedBid,
  executor: Address,
  binding: QuoteBinding,
): Promise<RoundBid> {
  const executorSignature = await signExecutor(
    signer,
    { orderHash: bid.orderHash, filler: bid.filler, executor, closesAt: bid.closesAt },
    binding,
  );
  return { ...bid, executor, executorSignature };
}

/** `ok` when the bid declares no executor, or declares one its filler signed for. */
export async function verifyExecutor(bid: RoundBid, binding: QuoteBinding): Promise<{ ok: boolean; reason?: string }> {
  if (bid.executor === undefined && bid.executorSignature === undefined) return { ok: true };
  if (bid.executor === undefined || bid.executorSignature === undefined) {
    return { ok: false, reason: "executor declaration is incomplete" };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(bid.executor)) return { ok: false, reason: "executor is not an address" };
  let signer: Address;
  try {
    signer = await recoverAddress({
      hash: executorDigest(
        { orderHash: bid.orderHash, filler: bid.filler, executor: bid.executor, closesAt: bid.closesAt },
        binding,
      ),
      signature: bid.executorSignature,
    });
  } catch {
    return { ok: false, reason: "executor declaration signature is not standard ECDSA" };
  }
  if (signer.toLowerCase() !== bid.filler.toLowerCase()) {
    return { ok: false, reason: "executor declaration not signed by the bidding filler" };
  }
  return { ok: true };
}

/**
 * The signed fields of a bid and nothing else. A submitted object can carry any
 * extra property — notably `commitment`, which the SDK's selection rule USED as
 * its tie-break key although no signature covers it, so a submitter could pick a
 * value that won every tie (audit 2026-09-30 G-TS_FILLER-1; the SDK now breaks
 * ties on the signed filler only). Rounds store and score only this projection.
 */
export function signedProjection(bid: RoundBid): RoundBid {
  return {
    orderHash: bid.orderHash,
    filler: bid.filler,
    bumpBps: bid.bumpBps,
    closesAt: bid.closesAt,
    signature: bid.signature,
    ...(bid.executor !== undefined ? { executor: bid.executor } : {}),
    ...(bid.executorSignature !== undefined ? { executorSignature: bid.executorSignature } : {}),
  };
}

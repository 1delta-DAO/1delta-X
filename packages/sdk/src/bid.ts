import { encodeAbiParameters, keccak256, recoverAddress, toHex, type Address, type Hex } from "viem";

import type { QuoteBinding, QuoteSigner } from "./quote";

/**
 * A SIGNED bid into a quote auction.
 *
 * ⚠ WHY BIDS MUST BE SIGNED — an unsigned bid set is forgeable from two sides:
 *
 *  1. BY A RIVAL. Anyone can bid *as* solver B with an aggressive bump. B wins,
 *     B never fills (it never bid), the genuine best bidder was displaced, and
 *     the maker ends up at the clock price instead of a real improvement. Free
 *     to mount, and it costs the attacker nothing.
 *  2. BY THE OPERATOR — the classic Vickrey attack, and the reason the mechanism
 *     is rare in the wild. An operator that publishes its bid set for audit can
 *     FABRICATE a losing bid just under the winner's to justify charging a worse
 *     second price, and an outcome check over that set still passes. Signatures
 *     make the published set unforgeable, which is what turns "the arithmetic is
 *     right" into "these bids are real AND the arithmetic is right".
 *
 * What signatures do NOT fix: an operator OMITTING a bid it received. Censorship
 * needs a public commitment log, not a bigger receipt. See
 * `docs/quote-auctions.md`.
 *
 * The digest binds the round as well as the bid — `orderHash` pins the order and
 * `closesAt` pins the round instance — so a bid cannot be lifted into a later
 * round for the same order, where it would price against a different field.
 * Never verified on-chain: this is an off-chain authenticity proof, so it uses
 * its own type string and can never be replayed as an order or a quote.
 */

const BPS = 10_000;

/** `keccak256("QuoteBid(bytes32 orderHash,address filler,uint256 bumpBps,uint256 closesAt)")` */
export const BID_TYPEHASH = keccak256(
  toHex("QuoteBid(bytes32 orderHash,address filler,uint256 bumpBps,uint256 closesAt)"),
);

export interface BidPayload {
  orderHash: Hex;
  /** Who will fill if this bid wins. MUST be the signer — enforced on recovery. */
  filler: Address;
  /** The concession asked for: 0 = the maker's `start`, 10000 = its `end`. */
  bumpBps: number;
  /** The round's close time, unix seconds. Pins the bid to one round. */
  closesAt: number;
}

export interface SignedBid extends BidPayload {
  signature: Hex;
}

function assertBid(bid: BidPayload): void {
  if (!Number.isInteger(bid.bumpBps) || bid.bumpBps < 0 || bid.bumpBps > BPS) {
    throw new Error(`bumpBps must be an integer in [0, ${BPS}], got ${bid.bumpBps}`);
  }
  if (!Number.isInteger(bid.closesAt) || bid.closesAt < 0) throw new Error("closesAt must be a unix timestamp");
}

/** The digest a bidder signs. Bound to the round, the chain and the quote module
 *  instance, so no bid is portable to another round, chain or deployment. */
export function bidDigest(bid: BidPayload, binding: QuoteBinding): Hex {
  assertBid(bid);
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "address" },
      ],
      [
        BID_TYPEHASH,
        bid.orderHash,
        bid.filler,
        BigInt(bid.bumpBps),
        BigInt(bid.closesAt),
        BigInt(binding.chainId),
        binding.module,
      ],
    ),
  );
}

/**
 * Sign a bid. The signer MUST be the `filler` the bid names — a bid is a
 * commitment to fill, so a signature from anyone else is meaningless and is
 * rejected here rather than at the round.
 *
 * ⚠ Signs the RAW digest (`sign({ hash })`), matching {@link signQuote}. Do not
 * use `signMessage`.
 */
export async function signBid(signer: QuoteSigner, bid: BidPayload, binding: QuoteBinding): Promise<SignedBid> {
  if (signer.address.toLowerCase() !== bid.filler.toLowerCase()) {
    throw new Error("a bid must be signed by the filler it names");
  }
  return { ...bid, signature: await signer.sign({ hash: bidDigest(bid, binding) }) };
}

/** Recover the address that signed a bid. Throws on a non-standard signature. */
export function recoverBidder(bid: SignedBid, binding: QuoteBinding): Promise<Address> {
  return recoverAddress({ hash: bidDigest(bid, binding), signature: bid.signature });
}

export interface BidCheck {
  ok: boolean;
  reason?: string;
}

/**
 * Authenticate one bid: well-formed, and signed by the filler it names.
 *
 * ECDSA only. A contract bidder (Safe, EIP-1271) cannot be authenticated
 * without a chain read and is reported as unverifiable rather than accepted —
 * an auction that wants contract bidders needs an on-chain check at the round.
 */
export async function verifyBid(bid: SignedBid, binding: QuoteBinding): Promise<BidCheck> {
  if (!Number.isInteger(bid.bumpBps) || bid.bumpBps < 0 || bid.bumpBps > BPS) {
    return { ok: false, reason: "bumpBps out of range" };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(bid.filler)) return { ok: false, reason: "filler is not an address" };
  let signer: Address;
  try {
    signer = await recoverBidder(bid, binding);
  } catch {
    return { ok: false, reason: "unverifiable-signer: signature is not standard-length ECDSA" };
  }
  if (signer.toLowerCase() !== bid.filler.toLowerCase()) {
    return { ok: false, reason: "forged: signature does not recover to the named filler" };
  }
  return { ok: true };
}

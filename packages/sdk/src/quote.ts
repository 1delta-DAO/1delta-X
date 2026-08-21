import {
  concatHex,
  encodeAbiParameters,
  keccak256,
  pad,
  recoverAddress,
  toHex,
  type Address,
  type Hex,
} from "viem";

/**
 * The cosigned PRICE QUOTE — the wire format that carries an off-chain auction
 * result onto the chain.
 *
 * `CosignedQuotePriceModule` and `ClockFlooredQuoteModule` both verify a quote
 * the filler presents in the shared `takerData` blob. Everything here mirrors
 * their on-chain checks exactly, so an auction operator, a filler and a book all
 * compute the same digest and the same bytes.
 *
 *   digest    = keccak256(abi.encode(
 *                 QUOTE_TYPEHASH, orderHash, filler, bumpBps, deadline,
 *                 chainId, module))
 *   takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig
 *
 * ⚠ NOT an EIP-712 envelope. The module hashes the chain id and its own address
 * into the digest directly (binding the same three things — contract, chain,
 * type — with less code) and hands the result to the settlement's shared
 * `SignatureVerification.verify`, which ECDSA-recovers the RAW hash. So a
 * cosigner signs the digest with a raw `sign`, NEVER `signMessage` — the
 * EIP-191 prefix the latter adds would recover to a different address and the
 * fill would revert.
 *
 * ⚠ A quote is a filler-carried, adversarial blob: it is not signed by the
 * maker and the settlement does not trust it. It can only move the price INSIDE
 * the maker's signed band, and under the clock-floored module no further than
 * the dutch clock. Nothing here can widen those bounds.
 */

const BPS = 10_000;

/** `keccak256("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline)")` —
 *  the same type string in both modules; the module ADDRESS in the digest is
 *  what keeps two instances (and the two module kinds) apart. */
export const QUOTE_TYPEHASH = keccak256(
  toHex("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline)"),
);

/** The open-to-any-filler sentinel. A quote naming a filler is exclusive to it;
 *  `address(0)` lets whoever holds the quote present it. */
export const ANY_FILLER = "0x0000000000000000000000000000000000000000" as Address;

export interface PriceQuote {
  orderHash: Hex;
  /** Who may present this quote; {@link ANY_FILLER} for an open one. */
  filler: Address;
  /** Where in the maker's band this prices: 0 = `start`, 10000 = `end`. */
  bumpBps: number;
  /** Unix seconds. The module rejects `block.timestamp > deadline`. */
  deadline: bigint;
}

/** Which module instance a quote is bound to. Both fields are hashed into the
 *  digest, so a quote cannot be replayed onto another deployment or chain. */
export interface QuoteBinding {
  module: Address;
  chainId: number;
}

function assertQuote(q: PriceQuote): void {
  if (!Number.isInteger(q.bumpBps) || q.bumpBps < 0 || q.bumpBps > BPS) {
    throw new Error(`bumpBps must be an integer in [0, ${BPS}], got ${q.bumpBps}`);
  }
  if (q.deadline < 0n) throw new Error("deadline must be non-negative");
}

/**
 * The digest a cosigner signs. Mirrors `quoteDigest(...)` on both modules —
 * they expose it on-chain for exactly this reason, so off-chain quoting code
 * cannot drift from the check that will run.
 */
export function quoteDigest(quote: PriceQuote, binding: QuoteBinding): Hex {
  assertQuote(quote);
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
        QUOTE_TYPEHASH,
        quote.orderHash,
        quote.filler,
        BigInt(quote.bumpBps),
        quote.deadline,
        BigInt(binding.chainId),
        binding.module,
      ],
    ),
  );
}

/**
 * Anything that can sign a raw 32-byte digest — a viem `Account` (`sign`), a
 * Safe/EIP-1271 wallet adapter, or an HSM shim.
 *
 * ⚠ Must sign the digest RAW. `signMessage` applies the EIP-191 prefix and
 * produces a signature the module will reject; viem accounts expose `sign({
 * hash })` for this.
 */
export interface QuoteSigner {
  address: Address;
  sign(args: { hash: Hex }): Promise<Hex>;
}

export interface SignedQuote extends PriceQuote {
  binding: QuoteBinding;
  digest: Hex;
  signature: Hex;
  /** The exact bytes a filler passes as `takerData`. */
  takerData: Hex;
}

/** Sign a quote and package the `takerData` a filler submits with its fill. */
export async function signQuote(
  signer: QuoteSigner,
  quote: PriceQuote,
  binding: QuoteBinding,
): Promise<SignedQuote> {
  const digest = quoteDigest(quote, binding);
  const signature = await signer.sign({ hash: digest });
  return { ...quote, binding, digest, signature, takerData: encodeQuoteTakerData(quote, signature) };
}

/**
 * `takerData = filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig` — packed, not
 * `abi.encode`d, so the module can hand an EIP-1271 cosigner the exact bytes it
 * was given and the signature stays a calldata slice.
 */
export function encodeQuoteTakerData(quote: PriceQuote, signature: Hex): Hex {
  assertQuote(quote);
  return concatHex([
    quote.filler,
    pad(toHex(BigInt(quote.bumpBps)), { size: 32 }),
    pad(toHex(quote.deadline), { size: 32 }),
    signature,
  ]);
}

/** Inverse of {@link encodeQuoteTakerData}, for a book or filler inspecting a
 *  blob it did not build. Throws on anything the module would reject as
 *  `MalformedQuote` (under 84 bytes). */
export function decodeQuoteTakerData(takerData: Hex): { quote: Omit<PriceQuote, "orderHash">; signature: Hex } {
  const body = takerData.startsWith("0x") ? takerData.slice(2) : takerData;
  if (body.length < 84 * 2) throw new Error("MalformedQuote: takerData shorter than 84 bytes");
  return {
    quote: {
      filler: `0x${body.slice(0, 40)}` as Address,
      bumpBps: Number(BigInt(`0x${body.slice(40, 104)}`)),
      deadline: BigInt(`0x${body.slice(104, 168)}`),
    },
    signature: `0x${body.slice(168)}` as Hex,
  };
}

export interface QuoteCheck {
  ok: boolean;
  reason?: string;
}

/**
 * Check a quote the way the module will, before relying on it — for a filler
 * that did not mint the quote, or a book publishing one.
 *
 * ECDSA only: a contract cosigner (Safe, EIP-1271) cannot be verified without a
 * chain read, and is reported as `unverifiable-signer` rather than as a
 * failure. Everything else — expiry, filler binding, range — is checked locally.
 */
export async function verifyQuote(
  signed: PriceQuote & { binding: QuoteBinding; signature: Hex },
  expected: { cosigner: Address; filler?: Address; now?: bigint },
): Promise<QuoteCheck> {
  const { binding, signature, ...quote } = signed;
  const now = expected.now ?? BigInt(Math.floor(Date.now() / 1000));
  if (quote.bumpBps < 0 || quote.bumpBps > BPS) return { ok: false, reason: "bumpBps out of range" };
  if (now > quote.deadline) return { ok: false, reason: "QuoteExpired" };
  // `address(0)` is the open quote; a named filler must match the one filling.
  if (
    expected.filler !== undefined &&
    quote.filler !== ANY_FILLER &&
    quote.filler.toLowerCase() !== expected.filler.toLowerCase()
  ) {
    return { ok: false, reason: "QuoteNotForFiller" };
  }
  try {
    const signer = await recoverAddress({ hash: quoteDigest(quote, binding), signature });
    if (signer.toLowerCase() !== expected.cosigner.toLowerCase()) {
      return { ok: false, reason: "unverifiable-signer: not the configured cosigner (or an EIP-1271 signer)" };
    }
  } catch {
    return { ok: false, reason: "unverifiable-signer: signature is not standard-length ECDSA" };
  }
  return { ok: true };
}

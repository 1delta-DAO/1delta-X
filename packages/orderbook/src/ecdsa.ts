import { recoverAddress, type Address, type Hex } from "viem";

/**
 * The one ECDSA primitive every local signature check in this package shares
 * (soft cancels, Layer 1 order and permit announces), so none of them can drift
 * from the settler's `ecrecover` semantics on its own.
 */

const UPPER_BIT_MASK = (1n << 255n) - 1n;

/**
 * `SignatureVerification.tryRecoverSigner`, off-chain: recover a 65-byte or
 * 64-byte (EIP-2098) ECDSA signature exactly as the settler's `ecrecover` would.
 * `standardLength` says whether recovery was attempted at all; `signer` is
 * `undefined` where `ecrecover` would return `address(0)` (a bad `v`, an
 * unrecoverable point).
 */
export async function recoverEcdsa(digest: Hex, sig: Hex): Promise<{ standardLength: boolean; signer?: Address }> {
  const bytes = (sig.length - 2) / 2;
  if (bytes !== 65 && bytes !== 64) return { standardLength: false };
  const r = `0x${sig.slice(2, 66)}` as Hex;
  let s: Hex;
  let v: number;
  if (bytes === 65) {
    s = `0x${sig.slice(66, 130)}` as Hex;
    v = parseInt(sig.slice(130, 132), 16);
  } else {
    const vs = BigInt(`0x${sig.slice(66, 130)}`);
    s = `0x${(vs & UPPER_BIT_MASK).toString(16).padStart(64, "0")}` as Hex;
    v = Number(vs >> 255n) + 27;
  }
  // `ecrecover` accepts only 27/28; viem would also take 0/1 — the settler would not.
  if (v !== 27 && v !== 28) return { standardLength: true };
  try {
    return { standardLength: true, signer: await recoverAddress({ hash: digest, signature: { r, s, v: BigInt(v) } }) };
  } catch {
    return { standardLength: true };
  }
}

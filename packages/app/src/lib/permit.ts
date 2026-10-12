import {
  ERC2612_ABI,
  erc2612DomainOf,
  erc2612DomainSeparator,
  erc2612TypedData,
  splitPermitSignature,
  type Erc2612Domain,
  type Erc2612Permit,
  type Order,
} from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import type { Reader } from "./chain";

/**
 * GASLESS FUNDING — an ERC-2612 permit instead of the approve + grant transactions.
 *
 * For a pay token that implements EIP-2612 (USD₮0 on Rootstock), the maker signs a
 * `Permit(owner, spender = Settlement, value = the order's input, nonce, deadline =
 * the order's expiry)` right after the order and both go to the book together. The
 * filler that takes the order submits `token.permit(...)` first (anyone may), which
 * creates a DIRECT allowance to Settlement; Settlement's pull falls back to it when
 * there is no Permit3 grant (`Base._pullViaPermit3`). The maker sends no transaction
 * and needs no RBTC. Nothing on-chain changed for this.
 *
 * The same exact-size policy as the approve path: `value` is this order's input, and a
 * permit SETS the allowance (it does not add), so a newer gasless ticket in the same
 * token replaces whatever an older unfilled one had left. Not offered in Permit3
 * strict mode (it refuses the direct surface) or for a TWAP (one slice is signed at a
 * time, and they would share the token nonce).
 */

/** The pinned 2612 domain for the pay token, or undefined when gasless funding is not offered for it. */
export function gaslessDomain(chainId: number, token: Address | null | undefined): Erc2612Domain | undefined {
  return token ? erc2612DomainOf(chainId, token) : undefined;
}

/** The allowance an order needs from its input token: the larger of its legs' start/end for that token. */
export function permitValue(order: Order, token: Address): bigint {
  let v = 0n;
  for (const l of order.legsIn) {
    if (l.token.toLowerCase() !== token.toLowerCase()) continue;
    const m = l.start > l.end ? l.start : l.end;
    if (m > v) v = m;
  }
  return v;
}

export interface PermitSigner {
  signTypedData(parameters: never): Promise<Hex>;
}

/**
 * Read the token's live domain and nonce, refuse to sign if the domain is not the
 * pinned one (a token upgrade or rename would otherwise get a signature the token
 * rejects — or, worse, one valid under a domain nobody reviewed), and sign.
 */
export async function signGaslessPermit(
  signer: PermitSigner,
  reader: Reader,
  a: { chainId: number; token: Address; owner: Address; settlement: Address; order: Order },
): Promise<Erc2612Permit> {
  const domain = erc2612DomainOf(a.chainId, a.token);
  if (!domain) throw new Error("this token has no supported EIP-2612 permit");
  const [onChain, nonce] = await Promise.all([
    reader.readContract({ address: a.token, abi: ERC2612_ABI, functionName: "DOMAIN_SEPARATOR" }) as Promise<Hex>,
    reader.readContract({ address: a.token, abi: ERC2612_ABI, functionName: "nonces", args: [a.owner] }) as Promise<bigint>,
  ]);
  if (onChain.toLowerCase() !== erc2612DomainSeparator(domain).toLowerCase()) {
    throw new Error("the token's permit domain is not the one this app was built for — use approvals instead");
  }
  const value = permitValue(a.order, a.token);
  if (value === 0n) throw new Error("the order spends none of this token");
  const deadline = a.order.expiry;
  const sig = await signer.signTypedData(
    erc2612TypedData(domain, { owner: a.owner, spender: a.settlement, value, nonce, deadline }) as never,
  );
  return { token: a.token, spender: a.settlement, value, nonce, deadline, ...splitPermitSignature(sig) };
}

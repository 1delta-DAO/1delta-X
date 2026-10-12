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

/** The pinned 2612 domain for the pay token, or undefined when it is not pinned (see {@link detectPermitDomain}). */
export function gaslessDomain(chainId: number, token: Address | null | undefined): Erc2612Domain | undefined {
  return token ? erc2612DomainOf(chainId, token) : undefined;
}

const DETECT_ABI = [
  { type: "function", name: "DOMAIN_SEPARATOR", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "nonces", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "version", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "eip712Domain",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "bytes1" },
      { type: "string" },
      { type: "string" },
      { type: "uint256" },
      { type: "address" },
      { type: "bytes32" },
      { type: "uint256[]" },
    ],
  },
] as const;

const detected = new Map<string, { at: number; run: Promise<Erc2612Domain | undefined> }>();
/** A NEGATIVE answer is re-checked after this long: it may have been an RPC failure (a read error looks like "no permit"). */
const NEGATIVE_TTL_MS = 5 * 60_000;

/**
 * ANY token's EIP-2612 domain, proven against the chain (2026-10-12): the pinned one
 * (`ERC2612_TOKENS`) when there is one, else RECONSTRUCTED — ERC-5267
 * `eip712Domain()`, or `name()` with `version()` / "1" / "2" — and accepted only when
 * its separator equals the token's own `DOMAIN_SEPARATOR()` and `nonces()` answers.
 *
 * That equality is the whole safety argument: a token whose fallback answers any call
 * (WRBTC, DOC) returns no bytes32, and a wrong name/version cannot hash to the live
 * separator, so a signature is only ever made under the domain the token verifies.
 * Cached per (chain, token): a found domain for the tab's life; "none" only for
 * {@link NEGATIVE_TTL_MS}, because an RPC timeout reads the same as a token without a
 * permit — the safe default meanwhile is approvals (no gasless offer), never a guess.
 */
export function detectPermitDomain(reader: Reader, chainId: number, token: Address): Promise<Erc2612Domain | undefined> {
  const pinned = erc2612DomainOf(chainId, token);
  if (pinned) return Promise.resolve(pinned);
  const key = `${chainId}:${token.toLowerCase()}`;
  const hit = detected.get(key);
  if (hit) {
    const stale = Date.now() - hit.at > NEGATIVE_TTL_MS;
    if (!stale) return hit.run;
    // Stale: reuse a positive answer, re-check a negative one.
    return hit.run.then((d) => (d ? d : (detected.delete(key), detectPermitDomain(reader, chainId, token))));
  }
  const read = <T>(functionName: string, args?: readonly unknown[]) =>
    (reader.readContract({ address: token, abi: DETECT_ABI, functionName, ...(args ? { args } : {}) }) as Promise<T>).then(
      (v) => v,
      () => undefined,
    );
  const run = (async (): Promise<Erc2612Domain | undefined> => {
    const [sep, nonce] = await Promise.all([read<Hex>("DOMAIN_SEPARATOR"), read<bigint>("nonces", [token])]);
    if (typeof sep !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(sep) || typeof nonce !== "bigint") return undefined;
    const candidates: { name: string; version: string }[] = [];
    const d5267 = await read<readonly unknown[]>("eip712Domain");
    if (Array.isArray(d5267) && typeof d5267[1] === "string" && typeof d5267[2] === "string") candidates.push({ name: d5267[1], version: d5267[2] });
    const [name, version] = await Promise.all([read<string>("name"), read<string>("version")]);
    if (typeof name === "string") for (const v of [version, "1", "2"]) if (typeof v === "string") candidates.push({ name, version: v });
    for (const c of candidates) {
      const domain: Erc2612Domain = { name: c.name, version: c.version, chainId, verifyingContract: token };
      if (erc2612DomainSeparator(domain).toLowerCase() === sep.toLowerCase()) return domain;
    }
    return undefined;
  })();
  detected.set(key, { at: Date.now(), run });
  run.catch(() => detected.delete(key));
  return run;
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
  const domain = await detectPermitDomain(reader, a.chainId, a.token);
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

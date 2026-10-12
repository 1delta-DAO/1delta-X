import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  concatHex,
  parseSignature,
  toHex,
  type Address,
  type Hex,
} from "viem";

/**
 * GASLESS FUNDING WITH AN ERC-2612 `permit` — no contract change.
 *
 * Settlement pulls a maker's input with `Permit3.transferFrom` and, when that leg
 * fails and the maker is NOT in Permit3 strict mode, falls back to a plain
 * `token.transferFrom(maker, …)` against a DIRECT ERC-20 allowance to Settlement
 * ({Base._pullViaPermit3}; docs/account-onboarding.md "two funding surfaces"). An
 * EIP-2612 permit with `spender = Settlement` creates exactly that allowance from a
 * signature: the maker signs it next to the order, it travels with the announce
 * (`erc2612Permit`), and the FILLER submits `token.permit(...)` — anyone may — right
 * before it fills. The maker sends no transaction and needs no native coin.
 *
 * Why Settlement and not Permit3 as the spender: a permit to Permit3 is only half
 * of Permit3's funding (the book grant to Settlement is the other half), so it would
 * need a second, Permit3 `permitBatch` signature and a second relayed call — or the
 * single-signature `fillWithPermit` entry, which `AggregatorFillSolver` cannot use
 * (it fills through `fillWithCallback`). The direct allowance is one signature, one
 * relayed call, and it is just as bounded: Settlement only ever pulls from a maker
 * against an order that maker signed. It does NOT work for a maker in strict mode
 * (`Permit3.isStrict(maker, token)`), by design — check before offering it.
 *
 * The permit is NOT covered by the order signature. A relay can strip it (the order
 * is then simply unfunded) but cannot forge one: it must recover to the maker under
 * the token's own domain.
 */

/** `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)`. */
export const ERC2612_PERMIT_SELECTOR = "0xd505accf" as const;

export const ERC2612_ABI = [
  {
    type: "function",
    name: "permit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "v", type: "uint8" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ],
    outputs: [],
  },
  { type: "function", name: "nonces", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "DOMAIN_SEPARATOR", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

/**
 * A maker's signed ERC-2612 permit as it travels with an order announce. `nonce` is
 * the token's `nonces(maker)` the maker signed over: it is implicit on-chain (the
 * token reads its own counter), carried here so a book or filler can tell a live
 * permit (`nonce == nonces(maker)`) from a spent or superseded one without guessing.
 */
export interface Erc2612Permit {
  token: Address;
  spender: Address;
  value: bigint;
  nonce: bigint;
  deadline: bigint;
  v: number;
  r: Hex;
  s: Hex;
}

/** The EIP-712 domain a 2612 token signs under — `name`/`version` are the TOKEN's, not ours. */
export interface Erc2612Domain {
  name: string;
  version: string;
  chainId: number;
  verifyingContract: Address;
}

export const ERC2612_PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const ERC2612_PERMIT_TYPEHASH = keccak256(
  toHex("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
);

const DOMAIN_TYPEHASH = keccak256(
  toHex("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
);

/** The domain separator `name`/`version` produce — compare it with the token's `DOMAIN_SEPARATOR()` before signing. */
export function erc2612DomainSeparator(d: Erc2612Domain): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "address" }],
      [DOMAIN_TYPEHASH, keccak256(toHex(d.name)), keccak256(toHex(d.version)), BigInt(d.chainId), d.verifyingContract],
    ),
  );
}

/** The struct a wallet signs (`eth_signTypedData_v4`), ready for viem's `signTypedData`. */
export function erc2612TypedData(
  d: Erc2612Domain,
  m: { owner: Address; spender: Address; value: bigint; nonce: bigint; deadline: bigint },
) {
  return {
    domain: { name: d.name, version: d.version, chainId: d.chainId, verifyingContract: d.verifyingContract },
    types: ERC2612_PERMIT_TYPES,
    primaryType: "Permit" as const,
    message: { owner: m.owner, spender: m.spender, value: m.value, nonce: m.nonce, deadline: m.deadline },
  };
}

/**
 * The digest the token checks, from its ON-CHAIN `DOMAIN_SEPARATOR()` — so a verifier
 * needs neither the token's name nor its version string, and a token whose name was
 * changed after deployment (USDT0's `updateNameAndSymbol` re-derives its domain from
 * the live name) is still judged against the domain it enforces today.
 */
export function erc2612Digest(
  domainSeparator: Hex,
  owner: Address,
  p: Pick<Erc2612Permit, "spender" | "value" | "nonce" | "deadline">,
): Hex {
  const structHash = keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [ERC2612_PERMIT_TYPEHASH, owner, p.spender, p.value, p.nonce, p.deadline],
    ),
  );
  return keccak256(concatHex(["0x1901", domainSeparator, structHash]));
}

/** A 65-byte (or 64-byte EIP-2098) signature → `{v, r, s}` with `v ∈ {27, 28}`, as `permit` takes it. */
export function splitPermitSignature(sig: Hex): { v: number; r: Hex; s: Hex } {
  const p = parseSignature(sig);
  const v = p.v !== undefined ? Number(p.v) : 27 + (p.yParity ?? 0);
  return { v: v < 27 ? v + 27 : v, r: p.r, s: p.s };
}

/** `{v, r, s}` → the 65-byte `r ‖ s ‖ v` signature. */
export function joinPermitSignature(p: Pick<Erc2612Permit, "v" | "r" | "s">): Hex {
  return concatHex([p.r, p.s, toHex(p.v, { size: 1 })]);
}

/** Calldata for `token.permit(owner, spender, value, deadline, v, r, s)`. */
export function encodeErc2612Permit(owner: Address, p: Erc2612Permit): Hex {
  return encodeFunctionData({
    abi: ERC2612_ABI,
    functionName: "permit",
    args: [owner, p.spender, p.value, p.deadline, p.v, p.r, p.s],
  });
}

/** `permit` with a `v` outside {27, 28} or an upper-half `s` is refused by `ecrecover`-based tokens. */
export function isCanonicalPermitSig(p: Pick<Erc2612Permit, "v" | "s">): boolean {
  const HALF_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n;
  return (p.v === 27 || p.v === 28) && BigInt(p.s) <= HALF_N;
}

/**
 * Tokens known to implement EIP-2612 `permit` with the standard `(owner, spender,
 * value, deadline, v, r, s)` shape, and the domain they sign under — by chain id and
 * LOWERCASE address. Verified on-chain (docs/gasless-permit-relay.md, 2026-10-12):
 * the `DOMAIN_SEPARATOR()` each returns equals {@link erc2612DomainSeparator} of the
 * name/version here. Everything else on Rootstock that the app lists (USDRIF, WRBTC,
 * WETH, RIF, DOC, rUSDT) has no permit at all.
 */
export const ERC2612_TOKENS: Record<number, Record<string, { name: string; version: string }>> = {
  30: {
    // USD₮0 — TransparentUpgradeableProxy → TetherTokenOFTExtension (impl 0x1ec7…b6a3):
    // OZ ERC20PermitUpgradeable + EIP-3009; the domain name is the live `name()`.
    "0x779ded0c9e1022225f8e0630b35a9b54be713736": { name: "USD₮0", version: "1" },
  },
};

/** The pinned 2612 domain for a token, or `undefined` when it is not known to support `permit`. */
export function erc2612DomainOf(chainId: number, token: Address): Erc2612Domain | undefined {
  const k = ERC2612_TOKENS[chainId]?.[token.toLowerCase()];
  return k ? { name: k.name, version: k.version, chainId, verifyingContract: token } : undefined;
}

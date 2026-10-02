import { encodeAbiParameters, encodeFunctionData, hexToSignature, zeroAddress, type Address, type Hex } from "viem";

/**
 * Venue-native signed authorizations the lending modules replay in-fill
 * (`DelegationHelper.replayCometAllow` / `replayMorphoAuth` / `replayEvcPermit`),
 * and the NONCE-CONSUMING revokes that retire them.
 *
 * ⚠ A PLAIN VENUE REVOKE DOES NOT RETIRE A PUBLISHED SIGNATURE (audit 2026-09-30
 * L-CMT-3 / L-ML-9). `comet.allow(module, false)` and Morpho/Moolah
 * `setAuthorization(module, false)` clear the flag but leave the venue nonce where
 * it was, so an `allowBySig` / `setAuthorizationWithSig` grant sitting in a public
 * order's data can be landed by ANYONE until its own expiry and re-grants the
 * module. The durable revoke CONSUMES the nonce: sign the `isAllowed/isAuthorized =
 * false` form at the CURRENT nonce ({@link cometAuthorizationTypedData},
 * {@link morphoAuthorizationTypedData}) and send it ({@link encodeCometAllowBySig},
 * {@link encodeMorphoSetAuthorizationWithSig}, or `buildRevokeAll`'s
 * `signedVenueRevokes`). `Permit3.lockdownAll` is the other durable switch: the
 * modules only act inside a fill, which the taker book gates.
 *
 * Grants embedded in order data should also expire no later than the order: the
 * tail builders below refuse an `expiry`/`deadline` past `orderExpiry`.
 */

/** The 65-byte signature split into Comet / Morpho's `(v, r, s)`. */
function vrs(sig: Hex): { v: number; r: Hex; s: Hex } {
  const { v, r, s, yParity } = hexToSignature(sig);
  return { v: v !== undefined ? Number(v) : 27 + (yParity ?? 0), r, s };
}

// ──────────────────── Compound v3 (Comet) ────────────────────

/** EIP-712 payload for Comet `allowBySig(owner, manager, isAllowed, nonce, expiry, v, r, s)`. */
export function cometAuthorizationTypedData(p: {
  comet: Address;
  /** `comet.name()` and `comet.version()` — the domain Comet signs under. */
  name: string;
  version: string;
  chainId: number;
  owner: Address;
  manager: Address;
  isAllowed: boolean;
  /** `comet.userNonce(owner)` — the CURRENT nonce for a revoke. */
  nonce: bigint;
  expiry: bigint;
}) {
  return {
    domain: { name: p.name, version: p.version, chainId: p.chainId, verifyingContract: p.comet },
    types: {
      Authorization: [
        { name: "owner", type: "address" },
        { name: "manager", type: "address" },
        { name: "isAllowed", type: "bool" },
        { name: "nonce", type: "uint256" },
        { name: "expiry", type: "uint256" },
      ],
    },
    primaryType: "Authorization" as const,
    message: { owner: p.owner, manager: p.manager, isAllowed: p.isAllowed, nonce: p.nonce, expiry: p.expiry },
  };
}

const COMET_ALLOW_BY_SIG_ABI = [
  {
    type: "function",
    name: "allowBySig",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "manager", type: "address" },
      { name: "isAllowed", type: "bool" },
      { name: "nonce", type: "uint256" },
      { name: "expiry", type: "uint256" },
      { name: "v", type: "uint8" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ],
    outputs: [],
  },
] as const;

export function encodeCometAllowBySig(p: {
  owner: Address;
  manager: Address;
  isAllowed: boolean;
  nonce: bigint;
  expiry: bigint;
  sig: Hex;
}): Hex {
  const { v, r, s } = vrs(p.sig);
  return encodeFunctionData({
    abi: COMET_ALLOW_BY_SIG_ABI,
    functionName: "allowBySig",
    args: [p.owner, p.manager, p.isAllowed, p.nonce, p.expiry, v, r, s],
  });
}

/**
 * The 160-byte in-data Comet grant block `abi.encode(nonce, expiry, v, r, s)` that
 * `DelegationHelper.replayCometAllow` lands. Refuses an `expiry` past the order's.
 */
export function cometAllowTail(p: { nonce: bigint; expiry: bigint; sig: Hex; orderExpiry: bigint }): Hex {
  if (p.expiry > p.orderExpiry) {
    throw new Error("cometAllowTail: the allowBySig expiry must not exceed the order expiry (L-CMT-3)");
  }
  const { v, r, s } = vrs(p.sig);
  return encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }],
    [p.nonce, p.expiry, v, r, s],
  );
}

// ──────────────────── Morpho Blue / Lista Moolah ────────────────────

/** EIP-712 payload for Morpho Blue (and Lista Moolah) `setAuthorizationWithSig`. */
export function morphoAuthorizationTypedData(p: {
  morpho: Address;
  chainId: number;
  authorizer: Address;
  authorized: Address;
  isAuthorized: boolean;
  /** `morpho.nonce(authorizer)` — the CURRENT nonce for a revoke. */
  nonce: bigint;
  deadline: bigint;
}) {
  return {
    domain: { chainId: p.chainId, verifyingContract: p.morpho },
    types: {
      Authorization: [
        { name: "authorizer", type: "address" },
        { name: "authorized", type: "address" },
        { name: "isAuthorized", type: "bool" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Authorization" as const,
    message: {
      authorizer: p.authorizer,
      authorized: p.authorized,
      isAuthorized: p.isAuthorized,
      nonce: p.nonce,
      deadline: p.deadline,
    },
  };
}

const MORPHO_SET_AUTH_WITH_SIG_ABI = [
  {
    type: "function",
    name: "setAuthorizationWithSig",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "authorization",
        type: "tuple",
        components: [
          { name: "authorizer", type: "address" },
          { name: "authorized", type: "address" },
          { name: "isAuthorized", type: "bool" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        name: "signature",
        type: "tuple",
        components: [
          { name: "v", type: "uint8" },
          { name: "r", type: "bytes32" },
          { name: "s", type: "bytes32" },
        ],
      },
    ],
    outputs: [],
  },
] as const;

export function encodeMorphoSetAuthorizationWithSig(p: {
  authorizer: Address;
  authorized: Address;
  isAuthorized: boolean;
  nonce: bigint;
  deadline: bigint;
  sig: Hex;
}): Hex {
  return encodeFunctionData({
    abi: MORPHO_SET_AUTH_WITH_SIG_ABI,
    functionName: "setAuthorizationWithSig",
    args: [
      { authorizer: p.authorizer, authorized: p.authorized, isAuthorized: p.isAuthorized, nonce: p.nonce, deadline: p.deadline },
      vrs(p.sig),
    ],
  });
}

/**
 * The 160-byte in-data Morpho/Moolah grant block `abi.encode(nonce, deadline, v, r,
 * s)` that `DelegationHelper.replayMorphoAuth` lands. Refuses a `deadline` past the
 * order's expiry.
 */
export function morphoAuthTail(p: { nonce: bigint; deadline: bigint; sig: Hex; orderExpiry: bigint }): Hex {
  if (p.deadline > p.orderExpiry) {
    throw new Error("morphoAuthTail: the setAuthorizationWithSig deadline must not exceed the order expiry (L-CMT-3)");
  }
  const { v, r, s } = vrs(p.sig);
  return encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }],
    [p.nonce, p.deadline, v, r, s],
  );
}

// ──────────────────── Euler v2 (EVC permit) ────────────────────

/** One `DelegationHelper.EvcPermit` of the Euler open-op tail. */
export interface EvcPermit {
  nonceNamespace: bigint;
  nonce: bigint;
  deadline: bigint;
  /** The signed EVC self-call (`abi.encodeCall(IEVC.batch, items)` etc.). */
  evcData: Hex;
  /** The maker's 65-byte signature (`r ‖ s ‖ v`, as the EVC reads it). */
  sig: Hex;
}

/**
 * EIP-712 payload for an EVC `Permit` the Euler operator module replays
 * (audit 2026-09-30 L-ED-1). `sender` MUST be the `EulerV2OperatorModule`
 * address — the module submits the permit itself, so a permit bound to it can be
 * landed only by a fill of the maker's own order. `address(0)` (any sender) is
 * refused: such a permit, published with the order, could be landed by anyone.
 */
export function evcPermitTypedData(p: {
  evc: Address;
  chainId: number;
  signer: Address;
  /** The `EulerV2OperatorModule` address — never zero. */
  sender: Address;
  nonceNamespace: bigint;
  nonce: bigint;
  deadline: bigint;
  data: Hex;
}) {
  if (p.sender.toLowerCase() === zeroAddress) {
    throw new Error("evcPermitTypedData: sender must be the EulerV2OperatorModule, never address(0) (L-ED-1)");
  }
  return {
    domain: { name: "Ethereum Vault Connector", chainId: p.chainId, verifyingContract: p.evc },
    types: {
      Permit: [
        { name: "signer", type: "address" },
        { name: "sender", type: "address" },
        { name: "nonceNamespace", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "value", type: "uint256" },
        { name: "data", type: "bytes" },
      ],
    },
    primaryType: "Permit" as const,
    message: {
      signer: p.signer,
      sender: p.sender,
      nonceNamespace: p.nonceNamespace,
      nonce: p.nonce,
      deadline: p.deadline,
      value: 0n,
      data: p.data,
    },
  };
}

/**
 * The Euler open-op EVC-permit tail: `abi.encode(EvcPermit[])`, appended at byte
 * 128 of the `Op.Open` data. Refuses a permit whose deadline passes the order's
 * expiry. Put `setAccountOperator` in its OWN permit and namespace, apart from the
 * per-order `enableController` / `enableCollateral` permit (use a per-order
 * namespace for that one), so retiring one order never burns another's grant.
 */
export function evcPermitTail(permits: readonly EvcPermit[], orderExpiry: bigint): Hex {
  for (const p of permits) {
    if (p.deadline > orderExpiry) throw new Error("evcPermitTail: a permit deadline exceeds the order expiry");
  }
  return encodeAbiParameters(
    [
      {
        type: "tuple[]",
        components: [
          { name: "nonceNamespace", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "evcData", type: "bytes" },
          { name: "sig", type: "bytes" },
        ],
      },
    ],
    [permits.map((p) => ({ ...p }))],
  );
}

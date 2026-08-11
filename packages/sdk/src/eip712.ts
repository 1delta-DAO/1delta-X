import type { Address, TypedDataDomain } from "viem";

/**
 * EIP-712 typed-data definitions. Field order, names AND TYPES match the
 * Solidity struct exactly, so viem's typed-data hashing reproduces the
 * contract's `hashOrder` / Permit3 witness digest byte-for-byte.
 *
 * ⚠ The order's five array members are `bytes`, not struct arrays: the contract
 * carries them as packed blobs (see {@link packOrder} and `PackedArrays.sol`),
 * because a `bytes` member is ONE `keccak256` where an array-of-struct member is
 * one per element plus one over the concatenation. `side` is likewise absent —
 * it is bit 101 of `timing`. Sign {@link packOrder}'s output, never a raw
 * authoring `Order`; `orderTypedData` and `hashOrderStruct` do that for you.
 */

export const ITEM_TYPE = [
  { name: "op", type: "uint8" },
  { name: "module", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "recipient", type: "address" },
  { name: "data", type: "bytes" },
] as const;

export const VALIDATOR_TYPE = [
  { name: "target", type: "address" },
  { name: "data", type: "bytes" },
] as const;

export const CURVE_POINT_TYPE = [
  { name: "timeDelta", type: "uint32" },
  { name: "bumpBps", type: "uint32" },
] as const;

/// One input leg: `token` given by the maker, `start`→`end` amounts (end == 0 =
/// fixed at `start`; else a RISING auction, start <= end).
export const LEG_IN_TYPE = [
  { name: "token", type: "address" },
  { name: "start", type: "uint256" },
  { name: "end", type: "uint256" },
] as const;

/// One output leg: `token` delivered to `recipient` (0x0 = maker), `start`→`end`
/// amounts (end == 0 = fixed at `start`; else a FALLING auction, start >= end).
export const LEG_OUT_TYPE = [
  { name: "token", type: "address" },
  { name: "start", type: "uint256" },
  { name: "end", type: "uint256" },
  { name: "recipient", type: "address" },
] as const;

export const ORDER_TYPE = [
  { name: "maker", type: "address" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
  { name: "legsIn", type: "bytes" },
  { name: "legsOut", type: "bytes" },
  { name: "timing", type: "uint256" },
  { name: "exclusiveFiller", type: "address" },
  { name: "minFillAnchor", type: "uint256" },
  { name: "exclusivityOverrideBps", type: "uint256" },
  { name: "curve", type: "bytes" },
  { name: "gasBumpBps", type: "uint256" },
  { name: "gasPriceRef", type: "uint256" },
  { name: "items", type: "bytes" },
  { name: "validators", type: "bytes" },
  { name: "invariants", type: "bytes" },
  { name: "fillModule", type: "address" },
  { name: "fillTotal", type: "uint256" },
] as const;

/**
 * The literal typestring the contract hashes into `OrderHash.ORDER_TYPEHASH`.
 * Asserted against {@link ORDER_TYPE} in the tests, so a field added on one side
 * and not the other cannot pass silently — the failure mode that let this file
 * drift two migrations behind the contract once already.
 */
export const ORDER_TYPESTRING =
  "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing," +
  "address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,bytes curve," +
  "uint256 gasBumpBps,uint256 gasPriceRef,bytes items,bytes validators,bytes invariants," +
  "address fillModule,uint256 fillTotal)";

export const TOKEN_PERMIT_TYPE = [
  { name: "spender", type: "address" },
  { name: "token", type: "address" },
  { name: "amount", type: "uint160" },
  { name: "expiration", type: "uint48" },
] as const;

export const TAKER_PERMIT_TYPE = [
  { name: "spender", type: "address" },
  { name: "ref", type: "bytes32" },
  { name: "amount", type: "uint160" },
  { name: "expiration", type: "uint48" },
] as const;

/// Types for signing/hashing a bare `Order` (Settlement domain).
export const ORDER_TYPES = { Order: ORDER_TYPE } as const;

/// Types for the single-signature `fillWithPermit` witness (Permit3 domain).
/// The `PermitBatchWitness` witness field IS the order — one signature endorses
/// the whole batch AND the exact order.
export const PERMIT_WITNESS_TYPES = {
  PermitBatchWitness: [
    { name: "tokens", type: "TokenPermit[]" },
    { name: "takers", type: "TakerPermit[]" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "witness", type: "Order" },
  ],
  TokenPermit: TOKEN_PERMIT_TYPE,
  TakerPermit: TAKER_PERMIT_TYPE,
  Order: ORDER_TYPE,
} as const;

export const SETTLEMENT_DOMAIN_NAME = "Settlement";
export const PERMIT3_DOMAIN_NAME = "Permit3";
export const DOMAIN_VERSION = "1";

export function settlementDomain(chainId: number, settlement: Address): TypedDataDomain {
  return {
    name: SETTLEMENT_DOMAIN_NAME,
    version: DOMAIN_VERSION,
    chainId,
    verifyingContract: settlement,
  };
}

export function permit3Domain(chainId: number, permit3: Address): TypedDataDomain {
  return {
    name: PERMIT3_DOMAIN_NAME,
    version: DOMAIN_VERSION,
    chainId,
    verifyingContract: permit3,
  };
}

import type { Address, TypedDataDomain } from "viem";

/**
 * EIP-712 typed-data definitions. Field order and names match the Solidity
 * structs exactly, so viem's typed-data hashing reproduces the contract's
 * `hashOrder` / Permit3 witness digest byte-for-byte. (The contract hashes
 * `LegIn[]`/`LegOut[]`/`Item[]`/`Validator[]`/`CurvePoint[]` as struct arrays
 * and the packed `timing` word as a single `uint256` — which is precisely what
 * viem does.)
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
  { name: "side", type: "uint8" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
  { name: "legsIn", type: "LegIn[]" },
  { name: "legsOut", type: "LegOut[]" },
  { name: "timing", type: "uint256" },
  { name: "exclusiveFiller", type: "address" },
  { name: "minFillAnchor", type: "uint256" },
  { name: "exclusivityOverrideBps", type: "uint256" },
  { name: "curve", type: "CurvePoint[]" },
  { name: "gasBumpBps", type: "uint256" },
  { name: "gasPriceRef", type: "uint256" },
  { name: "items", type: "Item[]" },
  { name: "validators", type: "Validator[]" },
  { name: "invariants", type: "Validator[]" },
  { name: "fillModule", type: "address" },
  { name: "fillTotal", type: "uint256" },
] as const;

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
export const ORDER_TYPES = {
  Order: ORDER_TYPE,
  CurvePoint: CURVE_POINT_TYPE,
  Item: ITEM_TYPE,
  LegIn: LEG_IN_TYPE,
  LegOut: LEG_OUT_TYPE,
  Validator: VALIDATOR_TYPE,
} as const;

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
  CurvePoint: CURVE_POINT_TYPE,
  Item: ITEM_TYPE,
  LegIn: LEG_IN_TYPE,
  LegOut: LEG_OUT_TYPE,
  Validator: VALIDATOR_TYPE,
} as const;

export const SETTLEMENT_DOMAIN_NAME = "UniversalSettlement";
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

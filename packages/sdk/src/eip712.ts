import type { Address, TypedDataDomain } from "viem";

/**
 * EIP-712 typed-data definitions. Field ORDER and names match the Solidity
 * structs exactly, so viem's typed-data hashing reproduces the contract's
 * `hashOrder` / Permit3 witness digest byte-for-byte. (The contract hashes
 * `address[]`/`uint256[]` as standard EIP-712 arrays and `Item[]`/`Validator[]`
 * as struct arrays — which is precisely what viem does.)
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

export const ORDER_TYPE = [
  { name: "maker", type: "address" },
  { name: "side", type: "uint8" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
  { name: "tokenIn", type: "address[]" },
  { name: "startAmountIn", type: "uint256[]" },
  { name: "endAmountIn", type: "uint256[]" },
  { name: "decayStartTime", type: "uint32" },
  { name: "decayDuration", type: "uint32" },
  { name: "tokenOut", type: "address[]" },
  { name: "startAmountOut", type: "uint256[]" },
  { name: "endAmountOut", type: "uint256[]" },
  { name: "exclusiveFiller", type: "address" },
  { name: "exclusivityEndTime", type: "uint32" },
  { name: "minFillAnchor", type: "uint256" },
  { name: "items", type: "Item[]" },
  { name: "validators", type: "Validator[]" },
  { name: "invariants", type: "Validator[]" },
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
  Item: ITEM_TYPE,
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
  Item: ITEM_TYPE,
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

import type { Address, Hex } from "viem";

import { PERMIT_WITNESS_TYPES, permit3Domain } from "./eip712";
import type { TypedDataSigner } from "./orders";
import type { Deployment, Order, PermitBatch, TakerPermit, TokenPermit } from "./types";

/**
 * Single-signature `fillWithPermit`: the maker signs a Permit3 `PermitBatch`
 * witnessed by the order, so ONE signature authorizes the order AND every token
 * + taker allowance the fill needs. Signed over the Permit3 domain.
 */
export function permitWitnessTypedData(batch: PermitBatch, order: Order, d: Deployment) {
  return {
    domain: permit3Domain(d.chainId, d.permit3),
    types: PERMIT_WITNESS_TYPES,
    primaryType: "PermitBatchWitness" as const,
    message: {
      tokens: batch.tokens,
      takers: batch.takers,
      nonce: batch.nonce,
      deadline: batch.deadline,
      witness: order,
    } as unknown as Record<string, unknown>,
  };
}

/** Sign the witness-bound permit batch (maker → 65-byte signature). */
export function signPermitWitness(
  signer: TypedDataSigner,
  batch: PermitBatch,
  order: Order,
  d: Deployment,
): Promise<Hex> {
  return signer.signTypedData(permitWitnessTypedData(batch, order, d));
}

// ──────────────────── builders ────────────────────

export function tokenPermit(spender: Address, token: Address, amount: bigint, expiration: number): TokenPermit {
  return { spender, token, amount, expiration };
}

export function takerPermit(spender: Address, ref: Hex, amount: bigint, expiration: number): TakerPermit {
  return { spender, ref, amount, expiration };
}

export function permitBatch(
  tokens: readonly TokenPermit[],
  takers: readonly TakerPermit[],
  nonce: bigint,
  deadline: bigint,
): PermitBatch {
  return { tokens, takers, nonce, deadline };
}

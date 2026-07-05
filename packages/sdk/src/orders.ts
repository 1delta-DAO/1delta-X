import { encodeFunctionData, hashStruct, hashTypedData, keccak256, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { ORDER_TYPES, settlementDomain } from "./eip712";
import type { Deployment, Order, PermitBatch } from "./types";

/** Minimal signer surface — a viem `LocalAccount`/`WalletClient` satisfies this. */
export interface TypedDataSigner {
  signTypedData(parameters: any): Promise<Hex>;
}

/** EIP-712 typed-data payload for signing a bare order (Settlement domain). */
export function orderTypedData(order: Order, d: Deployment) {
  return {
    domain: settlementDomain(d.chainId, d.settlement),
    types: ORDER_TYPES,
    primaryType: "Order" as const,
    message: order,
  };
}

/**
 * Domain-independent EIP-712 struct hash of an order — equals the contract's
 * `hashOrder(order)` / `filledAmountIn` key.
 */
export function hashOrderStruct(order: Order): Hex {
  return hashStruct({ data: order, primaryType: "Order", types: ORDER_TYPES } as any);
}

/** Full EIP-712 digest the maker signs for a direct `fill`. */
export function orderDigest(order: Order, d: Deployment): Hex {
  return hashTypedData(orderTypedData(order, d) as any);
}

/** Sign an order for `fill` (maker → 65-byte signature). */
export function signOrder(signer: TypedDataSigner, order: Order, d: Deployment): Promise<Hex> {
  return signer.signTypedData(orderTypedData(order, d));
}

/** Taker-book allowance ref for a TAKE item: `keccak256(item.data)`. */
export function refOf(itemData: Hex): Hex {
  return keccak256(itemData);
}

// ──────────────────── calldata builders ────────────────────

/** `settlement.fill(order, sig, fillAmountIn)` */
export function encodeFill(order: Order, sig: Hex, fillAmountIn: bigint): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "fill", args: [order as any, sig, fillAmountIn] });
}

/** `settlement.fillWithPermit(order, batch, sig, fillAmountIn)` */
export function encodeFillWithPermit(order: Order, batch: PermitBatch, sig: Hex, fillAmountIn: bigint): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillWithPermit",
    args: [order as any, batch as any, sig, fillAmountIn],
  });
}

/** `settlement.cancelOrders(nonces)` — maker self-service. */
export function encodeCancelOrders(nonces: readonly bigint[]): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "cancelOrders", args: [nonces] });
}

/** `settlement.invalidateNonceWord(wordIndex)` — cancels 256 nonces at once. */
export function encodeInvalidateNonceWord(wordIndex: bigint): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "invalidateNonceWord", args: [wordIndex] });
}

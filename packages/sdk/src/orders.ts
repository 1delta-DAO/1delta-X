import { packOrder } from "./packed";
import { encodeFunctionData, hashStruct, hashTypedData, keccak256, type Address, type Hex } from "viem";

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
    message: packOrder(order),
  };
}

/**
 * Domain-independent EIP-712 struct hash of an order — equals the contract's
 * `hashOrder(order)` / `filledAmountIn` key.
 */
export function hashOrderStruct(order: Order): Hex {
  return hashStruct({ data: packOrder(order), primaryType: "Order", types: ORDER_TYPES } as any);
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
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "fill", args: [packOrder(order) as any, sig, fillAmountIn] });
}

/** `settlement.fillWithPermit(order, batch, sig, fillAmountIn)` */
export function encodeFillWithPermit(order: Order, batch: PermitBatch, sig: Hex, fillAmountIn: bigint): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillWithPermit",
    args: [packOrder(order) as any, batch as any, sig, fillAmountIn],
  });
}

// ──────────────────── Cancellation ────────────────────
//
// Four on-chain granularities. Pick the narrowest one that expresses the intent:
// nonce cancellation is BULK (every order carrying that nonce dies), which is
// the right tool for a bracket and the wrong one for a single re-price.
// The free off-chain complement is `softcancel.ts`.

/**
 * `settlement.cancelOrder(order)` — cancel exactly ONE order, by hash. Orders
 * that happen to share its nonce stay fillable. Parks the order's `filled`
 * counter at the max sentinel, which the fill path already reads, so this costs
 * the hot path nothing. Works on a partially-filled order (the remainder becomes
 * unfillable).
 */
export function encodeCancelOrder(order: Order): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "cancelOrder", args: [packOrder(order) as never] });
}

/** `settlement.cancelOrders(nonces)` — cancel every order carrying any of these nonces. */
export function encodeCancelOrders(nonces: readonly bigint[]): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "cancelOrders", args: [nonces] });
}

/** `settlement.invalidateNonceWord(wordIndex)` — cancels 256 nonces at once. */
export function encodeInvalidateNonceWord(wordIndex: bigint): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "invalidateNonceWord", args: [wordIndex] });
}

/**
 * `settlement.rollbackNonces(minValid)` — invalidate every nonce below a
 * watermark in one write. The panic button: one transaction retires an entire
 * outstanding book. Monotonic, so it can never be walked back.
 */
export function encodeRollbackNonces(newMinValidNonce: bigint): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "rollbackNonces", args: [newMinValidNonce] });
}

/** `settlement.approveOrder(order)` — the signature-less authorization path. */
export function encodeApproveOrder(order: Order): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "approveOrder", args: [packOrder(order) as never] });
}

/**
 * `settlement.approveOrders(orders)` — batch signature-less authorization: one
 * transaction (one multisig action) approving a whole ladder. Reverts entirely
 * if any order names a different maker.
 */
export function encodeApproveOrders(orders: Order[]): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "approveOrders",
    args: [orders.map((o) => packOrder(o)) as never],
  });
}

/** `settlement.setOrderSigner(signer, expiry)` — nominate a delegated signer (`0` revokes). */
export function encodeSetOrderSigner(signer: Address, expiry: bigint): Hex {
  return encodeFunctionData({ abi: SETTLEMENT_ABI, functionName: "setOrderSigner", args: [signer, expiry] });
}

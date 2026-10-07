import { packOrder } from "./packed";
import { encodeFunctionData, hashStruct, hashTypedData, keccak256, type Address, type Hex } from "viem";

import { SETTLEMENT_ABI } from "./abi";
import { ORDER_TYPES, settlementDomain } from "./eip712";
import { assertPermit3Nonce, Permit3MessageKind } from "./permit3nonce";
import {
  BLOCK_CLOCK_BIT,
  ItemPolicy,
  itemPolicyOf,
  takeFundsInputLeg,
  type Deployment,
  type Order,
  type PermitBatch,
} from "./types";

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

/** The block-clock range: a block-clocked order's ticks are `uint32` block numbers. */
export const BLOCK_CLOCK_LIMIT = (1n << 32n) - 1n;
/** Default headroom {@link assertBlockClockHeadroom} demands below {@link BLOCK_CLOCK_LIMIT}. */
export const BLOCK_CLOCK_MIN_HEADROOM = 1_000_000n;

/**
 * Refuse a BLOCK-clocked order (timing bit 102) on a chain whose head block is at
 * or near `2^32 - 1` (audit 2026-09-30 CORE-FILL-3). The order's decay start and
 * exclusivity end are `uint32` block numbers: past that range a block-clocked
 * order can express neither (`now < exclusivityEndTime` is never true and the
 * elapsed term saturates the bump), and at 250 ms blocks a chain gets there in
 * ~34 years from genesis. `headBlock` is the chain's current block number;
 * `minHeadroom` blocks must remain below the limit. Timestamp-clocked orders pass.
 */
export function assertBlockClockHeadroom(
  order: Order,
  headBlock: bigint,
  minHeadroom: bigint = BLOCK_CLOCK_MIN_HEADROOM,
): void {
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) !== 1n) return;
  if (headBlock + minHeadroom >= BLOCK_CLOCK_LIMIT) {
    throw new Error(
      `block-clocked order refused: head block ${headBlock} is within ${minHeadroom} blocks of the uint32 ` +
        `block-clock limit ${BLOCK_CLOCK_LIMIT} — sign a timestamp-clocked order instead`,
    );
  }
}

/**
 * Sign an order for `fill` (maker → 65-byte signature).
 *
 * A BLOCK-clocked order (timing bit 102) requires `opts.headBlock` — the chain's
 * current block number — and is refused near the `uint32` block-clock limit
 * ({@link assertBlockClockHeadroom}).
 *
 * An order whose plain `TAKE` funds an input leg ({@link takeFundsInputLeg}) must
 * carry a policy other than `ItemPolicy.ANY` — run it through
 * {@link withDefaultItemPolicy} first (it signs `CANONICAL`). Signing it at `ANY`
 * lets any `matchSettle` caller PULL the leg before the TAKE and spend the maker's
 * Permit3 allowance twice for one fill (`ACCEPTED-PATTERNS-REVIEW.md` B8), so it
 * needs the explicit `opts.itemPolicy: ItemPolicy.ANY` (e.g. a CYCLE participant).
 * This cannot default silently here: the caller keeps and submits its own `order`
 * object, which must match what was signed.
 */
export async function signOrder(
  signer: TypedDataSigner,
  order: Order,
  d: Deployment,
  opts?: { headBlock?: bigint; itemPolicy?: ItemPolicy },
): Promise<Hex> {
  if (
    itemPolicyOf(order.timing) === ItemPolicy.ANY &&
    opts?.itemPolicy !== ItemPolicy.ANY &&
    takeFundsInputLeg(order, { settlement: d.settlement })
  ) {
    throw new Error(
      "signOrder: a TAKE item funds an input leg but the order signs ItemPolicy.ANY — a matchSettle caller could " +
        "pull that leg first and spend the Permit3 allowance twice. Apply withDefaultItemPolicy(order) (CANONICAL), " +
        "or pass opts.itemPolicy = ItemPolicy.ANY to sign ANY deliberately.",
    );
  }
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n) {
    if (opts?.headBlock === undefined) {
      throw new Error("signOrder: a block-clocked order needs opts.headBlock (the chain head) to check the uint32 clock range");
    }
    assertBlockClockHeadroom(order, opts.headBlock);
  }
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

/**
 * `settlement.fillWithPermit(order, batch, sig, fillAmountIn, minBumpBps, takerData)`.
 *
 * `minBumpBps` is the filler's price floor (bps of the band; `0n` = none), exactly
 * `fillUpTo`'s — quote it from `SettlementLens.previewBump`. A permit-witness order's
 * FIRST fill can only go through this entry, so on a price-module, priority or
 * non-monotone order a filler that wants its quote to hold should pass it.
 */
export function encodeFillWithPermit(
  order: Order,
  batch: PermitBatch,
  sig: Hex,
  fillAmountIn: bigint,
  minBumpBps: bigint = 0n,
  takerData: Hex = "0x",
): Hex {
  return encodeFunctionData({
    abi: SETTLEMENT_ABI,
    functionName: "fillWithPermit",
    // The nonce kind is asserted at the encoder too, not only in `permitBatch()`.
    args: [
      packOrder(order) as any,
      { ...batch, nonce: assertPermit3Nonce(batch.nonce, Permit3MessageKind.Batch) } as any,
      sig,
      fillAmountIn,
      minBumpBps,
      takerData,
    ],  });
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

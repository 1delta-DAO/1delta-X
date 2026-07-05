import type { Address, Hex } from "viem";

/// Operation kind per lending item. Mirrors the Solidity `ItemOp` enum.
export enum ItemOp {
  MAKE = 0,
  TAKE = 1,
}

/// A single lending item inside an order (deposit/repay = MAKE, borrow/withdraw = TAKE).
export interface Item {
  op: ItemOp;
  module: Address;
  amount: bigint;
  /** TAKE only: proceeds recipient. `0x0` (default) routes to Settlement. */
  recipient: Address;
  data: Hex;
}

/// Read-only pre-execution trigger (validator) or post-execution invariant.
export interface Validator {
  target: Address;
  data: Hex;
}

/**
 * A signed limit order. The conversion leg is multi-asset: the maker gives a
 * basket (`tokenIn`/`amountIn`) and receives a basket
 * (`tokenOut`/`startAmountOut`/`endAmountOut`). Partial fills scale every leg by
 * the single fraction `fillAmountIn / amountIn[0]`.
 */
export interface Order {
  maker: Address;
  nonce: bigint;
  deadline: bigint;
  tokenIn: readonly Address[];
  amountIn: readonly bigint[];
  decayStartTime: number;
  decayDuration: number;
  tokenOut: readonly Address[];
  startAmountOut: readonly bigint[];
  endAmountOut: readonly bigint[];
  exclusiveFiller: Address;
  exclusivityEndTime: number;
  minFillAmountIn: bigint;
  items: readonly Item[];
  validators: readonly Validator[];
  invariants: readonly Validator[];
}

/// Permit3 token-book permit (Settlement/module may pull `token`).
export interface TokenPermit {
  spender: Address;
  token: Address;
  amount: bigint;
  expiration: number;
}

/// Permit3 taker-book permit (spender may consume a position allowance keyed by `ref`).
export interface TakerPermit {
  spender: Address;
  ref: Hex;
  amount: bigint;
  expiration: number;
}

/// A batch of signed token + taker permits (Permit3 `PermitBatch`).
export interface PermitBatch {
  tokens: readonly TokenPermit[];
  takers: readonly TakerPermit[];
  nonce: bigint;
  deadline: bigint;
}

/// One output leg's flash + buyback plan for `MultiOutputFlashSolver`.
export interface OutputLeg {
  token: Address;
  flashAmount: bigint;
  dexFee: number;
  spendIn: bigint;
  minOut: bigint;
}

/// EIP-712 domain locators for the two verifying contracts.
export interface Deployment {
  chainId: number;
  settlement: Address;
  permit3: Address;
}

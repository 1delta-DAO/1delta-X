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
 * basket (`tokenIn`/`startAmountIn`/`endAmountIn`) and receives a basket
 * (`tokenOut`/`startAmountOut`/`endAmountOut`). One side is fixed and the other
 * is a dutch auction (`side` selects which). Partial fills scale every leg by the
 * single fraction `fillAmount / anchor[0]` (anchor = tokenIn[0] for SELL,
 * tokenOut[0] for BUY).
 */
export enum OrderSide {
  SELL = 0,
  BUY = 1,
}

/// One point on the piecewise-linear auction curve: `bumpBps` (0..10000) is the
/// normalized decay at `timeDelta` seconds after `decayStartTime`.
export interface CurvePoint {
  timeDelta: number;
  bumpBps: number;
}

export interface Order {
  maker: Address;
  /// SELL (fixed input, outputs decay) or BUY (fixed output, inputs rise).
  side: OrderSide;
  nonce: bigint;
  deadline: bigint;
  tokenIn: readonly Address[];
  /// Fixed amount when == endAmountIn; else the auction floor (best for maker)
  /// of a RISING leg — BUY conversion inputs or a SELL relayer-fee leg.
  startAmountIn: readonly bigint[];
  /// == startAmountIn (fixed) or the auction ceiling ("pay up to"); must be
  /// >= startAmountIn — inputs only rise.
  endAmountIn: readonly bigint[];
  decayStartTime: number;
  decayDuration: number;
  tokenOut: readonly Address[];
  startAmountOut: readonly bigint[];
  endAmountOut: readonly bigint[];
  /// Per-output delivery recipient; zero address = the maker. A fee leg is an
  /// output addressed to the originator (proportional start/end = bps-of-tick
  /// fee; start == end = absolute fee).
  recipientOut: readonly Address[];
  exclusiveFiller: Address;
  exclusivityEndTime: number;
  /// Anti-dust floor per fill, in anchor units (tokenIn[0] for SELL, tokenOut[0] for BUY).
  minFillAnchor: bigint;
  /// Soft exclusivity: bps a non-exclusive in-window filler must improve the maker by (0 = hard).
  exclusivityOverrideBps: bigint;
  /// Optional piecewise decay shape (shared clock); empty = single linear segment.
  curve: readonly CurvePoint[];
  /// Max extra decay (bps) the gas bump adds at/above `gasPriceRef` basefee; 0 = off.
  gasBumpBps: bigint;
  /// Reference basefee (wei) at which the gas bump reaches `gasBumpBps`.
  gasPriceRef: bigint;
  items: readonly Item[];
  validators: readonly Validator[];
  invariants: readonly Validator[];
}

// ──────────────────── Fee-leg helpers ────────────────────

/**
 * Build the two output legs of a bps-of-tick sourcing fee: the maker leg and a
 * fee leg addressed to `recipient`, each decaying in proportion so the realized
 * fee is exactly `feeBps` of the delivered tick at any point of the auction.
 * Spread the returned arrays into the order's output fields.
 */
export function feeSplitLegs(
  token: Address,
  startAmount: bigint,
  endAmount: bigint,
  recipient: Address,
  feeBps: bigint,
): {
  tokenOut: Address[];
  startAmountOut: bigint[];
  endAmountOut: bigint[];
  recipientOut: Address[];
} {
  const BPS = 10_000n;
  if (feeBps >= BPS) throw new Error(`feeBps ${feeBps} >= 10000`);
  if (feeBps !== 0n && BigInt(recipient) === 0n) throw new Error("fee set without recipient");
  const startFee = (startAmount * feeBps) / BPS;
  const endFee = (endAmount * feeBps) / BPS;
  const zero = "0x0000000000000000000000000000000000000000" as Address;
  return {
    tokenOut: [token, token],
    startAmountOut: [startAmount - startFee, startFee],
    endAmountOut: [endAmount - endFee, endFee],
    recipientOut: [zero, recipient], // zero = the maker
  };
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

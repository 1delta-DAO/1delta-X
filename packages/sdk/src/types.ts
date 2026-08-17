import type { Address, Hex } from "viem";

/// Operation kind per item. Mirrors the Solidity `ItemOp` enum.
/// SETTLE is the filler-aware generic solver↔maker exchange (e.g. an NFT sale).
export enum ItemOp {
  MAKE = 0,
  TAKE = 1,
  SETTLE = 2,
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

/**
 * One input leg the maker gives. `end == 0n` = fixed at `start`; otherwise a
 * RISING auction leg where `start <= end` (auction floor → ceiling). Used for
 * BUY conversion inputs and SELL relayer-fee legs.
 */
export interface LegIn {
  token: Address;
  start: bigint;
  end: bigint;
}

/**
 * One output leg delivered to `recipient` (zero address = the maker). `end == 0n`
 * = fixed at `start`; otherwise a FALLING auction leg where `start >= end`
 * (auction start → floor). A fee leg is simply an output addressed to the
 * originator (proportional start/end = bps-of-tick fee; fixed = absolute fee).
 */
export interface LegOut {
  token: Address;
  start: bigint;
  end: bigint;
  recipient: Address;
}

/**
 * A signed limit order. The conversion leg is multi-asset: the maker gives a
 * basket of `legsIn` and receives a basket of `legsOut`. Each leg is fixed
 * (`end == 0n`) or a dutch auction (SELL outputs fall, BUY/fee inputs rise).
 * Partial fills scale every leg by the single fraction `fillAmount / anchor`
 * (anchor = legsIn[0] for SELL, legsOut[0] for BUY, or `fillTotal` if set).
 * The three auction clocks are bit-packed into `timing` — see {@link packTiming}.
 */
export interface Order {
  maker: Address;
  /// SELL (fixed input, outputs decay) or BUY (fixed output, inputs rise).
  side: OrderSide;
  nonce: bigint;
  deadline: bigint;
  legsIn: readonly LegIn[];
  legsOut: readonly LegOut[];
  /// Packed auction clocks: decayStartTime | decayDuration<<32 | exclusivityEndTime<<64.
  /// Build/read with {@link packTiming} / {@link unpackTiming}.
  timing: bigint;
  exclusiveFiller: Address;
  /// Anti-dust floor per fill, in anchor units (legsIn[0] for SELL, legsOut[0] for BUY).
  minFillAnchor: bigint;
  /// Soft exclusivity: bps a non-exclusive in-window filler must improve the maker by (0 = hard).
  /// Folded into the wire `params` word by {@link packOrder} — see {@link packParams}.
  exclusivityOverrideBps: bigint;
  /// Optional piecewise decay shape (shared clock); empty = single linear segment.
  curve: readonly CurvePoint[];
  /// Max extra decay (bps) the gas bump adds at/above `gasPriceRef` basefee; 0 = off.
  gasBumpBps: bigint;
  /// Reference basefee (wei) at which the gas bump reaches `gasBumpBps`.
  gasPriceRef: bigint;
  /**
   * PRIORITY auction (timing bit 103): the priority fee, in wei, that buys a FULL
   * bump. The maker signs `start` as its ambition and `end` as its guaranteed
   * floor; an unbid fill clears at `end` and every wei of priority fee moves the
   * tick toward `start`. `0n` = the order is not a priority auction.
   */
  priorityScale: bigint;
  items: readonly Item[];
  validators: readonly Validator[];
  invariants: readonly Validator[];
  /**
   * Optional fill matcher — the generalized fill denominator. `0x0` (zero
   * address) = identity: the fill delta is the requested `fillAmount` in leg-
   * anchor units (classic fungible fill). When set, the module validates the
   * filler's proposal (carried in the shared `takerData`) against the order and
   * returns the accepted delta; the core keeps the over-fill cap + uniform
   * per-leg scaling. See `docs/fill-modules.md`.
   */
  fillModule: Address;
  /**
   * Fill denominator when the unit isn't a fungible leg (an NFT, an auction
   * lot). `0n` = derive from the leg anchor (legsIn[0].start/legsOut[0].start).
   * Maker-signed so the cap `filled + delta <= fillTotal` stays in the core.
   */
  fillTotal: bigint;
  /**
   * Optional EXTERNAL price provider (`IPriceModule`); the zero address = the
   * built-in clock. The module returns the shared decay bump, which the CORE
   * clamps to [0, 10000] and maps through each leg's own signed `start`/`end` —
   * so an oracle-pegged, range or cosigner-quoted price can move the tick
   * anywhere inside the band the maker signed and nowhere outside it.
   *
   * The module carries its configuration in its own immutables; there is no
   * per-order config blob. An order priced this way CANNOT be quoted by the
   * off-chain `pricing.ts` mirror — call `SettlementLens.previewFill`.
   */
  pricingModule: Address;
}

// ──────────────────── Packed timing helpers ────────────────────

/// `timing` bit 102: the decay clocks count BLOCKS, not seconds (fast L2s).
export const BLOCK_CLOCK_BIT = 102n;
/// `timing` bit 103: the bump is bid in PRIORITY FEE rather than elapsed time.
export const PRIORITY_AUCTION_BIT = 103n;
/// `timing` bit 104: deliver output legs by VERIFYING the recipient's balance
/// delta (>= the priced amount) instead of pushing a nominal amount — the
/// fee-on-transfer / rebasing-safe delivery mode. The filler delivers each output
/// leg out-of-band (its fill callback); the required amount is still the leg's
/// price, so it composes with every pricing mode.
export const DELTA_VERIFY_OUTPUTS_BIT = 104n;

/// Set the delta-verify-outputs mode on a packed `timing` word (see
/// {@link DELTA_VERIFY_OUTPUTS_BIT}). Mirrors `DutchAuction.deltaVerifyOutputs`.
export function withDeltaVerifyOutputs(timing: bigint): bigint {
  return timing | (1n << DELTA_VERIFY_OUTPUTS_BIT);
}

/**
 * Pack the four auction scalars into the wire `params` word, mirroring
 * `DutchAuction.packParams`: [0:16) overrideBps, [16:32) gasBumpBps,
 * [32:96) gasPriceRef, [96:160) priorityScale.
 */
export function packParams(
  overrideBps: bigint,
  gasBumpBps: bigint,
  gasPriceRef: bigint,
  priorityScale: bigint,
): bigint {
  const U16 = 0xffffn;
  const U64 = 0xffff_ffff_ffff_ffffn;
  if (overrideBps > U16 || gasBumpBps > U16) throw new Error("params bps field exceeds uint16");
  if (gasPriceRef > U64 || priorityScale > U64) throw new Error("params wei field exceeds uint64");
  return overrideBps | (gasBumpBps << 16n) | (gasPriceRef << 32n) | (priorityScale << 96n);
}

/// Inverse of {@link packParams}.
export function unpackParams(params: bigint): {
  overrideBps: bigint;
  gasBumpBps: bigint;
  gasPriceRef: bigint;
  priorityScale: bigint;
} {
  const U16 = 0xffffn;
  const U64 = 0xffff_ffff_ffff_ffffn;
  return {
    overrideBps: params & U16,
    gasBumpBps: (params >> 16n) & U16,
    gasPriceRef: (params >> 32n) & U64,
    priorityScale: (params >> 96n) & U64,
  };
}

const U32 = 0xffff_ffffn;

/**
 * Pack the three auction clocks into the single `Order.timing` word, mirroring
 * the Solidity layout: bits [0:32) decayStartTime, [32:64) decayDuration,
 * [64:96) exclusivityEndTime. Each must fit in a uint32.
 */
export function packTiming(decayStartTime: number, decayDuration: number, exclusivityEndTime: number): bigint {
  const s = BigInt(decayStartTime);
  const d = BigInt(decayDuration);
  const e = BigInt(exclusivityEndTime);
  if ((s & ~U32) !== 0n || (d & ~U32) !== 0n || (e & ~U32) !== 0n) throw new Error("timing field exceeds uint32");
  return s | (d << 32n) | (e << 64n);
}

/// Inverse of {@link packTiming}: unpack `Order.timing` into its three clocks.
export function unpackTiming(timing: bigint): {
  decayStartTime: number;
  decayDuration: number;
  exclusivityEndTime: number;
} {
  return {
    decayStartTime: Number(timing & U32),
    decayDuration: Number((timing >> 32n) & U32),
    exclusivityEndTime: Number((timing >> 64n) & U32),
  };
}

// ──────────────────── Fee-leg helpers ────────────────────

/**
 * Build the two output legs of a bps-of-tick sourcing fee: the maker leg and a
 * fee leg addressed to `recipient`, each decaying in proportion so the realized
 * fee is exactly `feeBps` of the delivered tick at any point of the auction.
 * `endAmount == 0n` yields two fixed legs (absolute fee). Concat the returned
 * legs into the order's `legsOut`.
 */
export function feeSplitLegs(
  token: Address,
  startAmount: bigint,
  endAmount: bigint,
  recipient: Address,
  feeBps: bigint,
): [LegOut, LegOut] {
  const BPS = 10_000n;
  if (feeBps >= BPS) throw new Error(`feeBps ${feeBps} >= 10000`);
  if (feeBps !== 0n && BigInt(recipient) === 0n) throw new Error("fee set without recipient");
  const startFee = (startAmount * feeBps) / BPS;
  const endFee = (endAmount * feeBps) / BPS;
  const zero = "0x0000000000000000000000000000000000000000" as Address;
  return [
    { token, start: startAmount - startFee, end: endAmount === 0n ? 0n : endAmount - endFee, recipient: zero },
    { token, start: startFee, end: endAmount === 0n ? 0n : endFee, recipient },
  ];
}

/// Permit3 token-book permit (Settlement/module may pull `token`).
export interface TokenPermit {
  spender: Address;
  token: Address;
  amount: bigint;
  expiration: number;
}

/// Permit3 taker-book permit: `spender` may dispatch `module` against the position
/// keyed by `ref = keccak256(data)`. The allowance is keyed
/// `(user, spender, module, ref)`, so `module` is a signed field — approving a
/// borrow module can never be consumed dispatching a different one.
export interface TakerPermit {
  spender: Address;
  module: Address;
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

import type { Address, Hex } from "viem";

/// Operation kind per item. Mirrors the Solidity `ItemOp` enum.
/// SETTLE is the filler-aware generic solver↔maker exchange (e.g. an NFT sale).
export enum ItemOp {
  MAKE = 0,
  TAKE = 1,
  SETTLE = 2,
  /// Composite: one dispatch that takes `amount` out of a position AND funds the
  /// value-in side of the same operation (deposit+borrow, repay+withdraw). The
  /// funding amount is computed by the settler from a descriptor the maker signs
  /// as the FIRST WORD of `data` — build it with `forLeg()` / `forTotal()`.
  /// Single-order path only: `matchSettle` refuses it.
  TAKE_FOR = 3,
}

/// Funding descriptor for a `TAKE_FOR` item, pointing at output leg `index`.
///
/// This is the form to prefer: the funding amount, its token and its decimals stay
/// in the typed `legsOut[index]` the maker already signs, so there is exactly ONE
/// copy of the number and no second, mis-scaled one can exist. A decaying leg
/// carries its auction price into the funding side automatically.
export function forLeg(index: number): bigint {
  if (!Number.isInteger(index) || index < 0 || index > 0xffff) {
    throw new Error(`forLeg: leg index out of range: ${index}`);
  }
  return (1n << 255n) | BigInt(index);
}

/// Funding descriptor for a BALANCE-RELATIVE funding leg: `min(balanceOf(token,
/// maker), cap)`, resolved at fill time, and bounded BOTH ways. For the
/// no-conversion shape where there is no output leg to reference and the maker
/// cannot know the amount at signing time (accrued interest, an in-flight transfer,
/// a wallet sweep).
///
/// The cap is MANDATORY and travels as `data`'s SECOND word, so lay the blob out as
/// `abi.encode(forBalance(token), cap, ...)`. A balance-funded order is FULL-FILL
/// ONLY — the settler rejects a sliced fill.
///
/// `floorBps` is the other half of the bound and rides in descriptor bits
/// [160:176): the fill reverts (`ForBalanceBelowFloor`) unless the resolved amount
/// is at least `floorBps` of the cap. The cap exists because anyone can RAISE a
/// maker's balance; the floor exists because whoever sequences fills can LOWER it —
/// filling another of the maker's live orders in the same token shrinks this leg
/// while the value-OUT leg still draws its full signed size, which is an
/// under-collateralised position rather than an unfilled order. The default of
/// 10000 means "fund the whole cap or do not fill", which is what a levered order
/// wants; lower it only for a genuine sweep whose position can take the variance.
/// `0` is the settler's legacy "any non-zero balance will do" and
/// `SettlementLens.validateOrder` rejects it.
export function forBalance(token: Address, floorBps: number | bigint = 10_000): bigint {
  const floor = BigInt(floorBps);
  if (floor < 0n || floor > 10_000n) throw new Error(`forBalance: floorBps out of range: ${floorBps}`);
  return (1n << 255n) | (1n << 254n) | (floor << 160n) | BigInt(token);
}

/// Read the funding FLOOR (bps of the cap) out of a balance descriptor.
export function forBalanceFloorBps(desc: bigint): number {
  return Number((desc >> 160n) & 0xffffn);
}

/// Funding descriptor carrying a LITERAL total, for a funding leg with no matching
/// output leg (the maker funds it from their own wallet — a fresh position, a new
/// trove). The settler slices it with the same differencing it applies to the
/// item's own `amount`, so partial fills sum exactly to `total`.
export function forTotal(total: bigint): bigint {
  if (total < 0n || total >= 1n << 255n) throw new Error(`forTotal: out of range: ${total}`);
  return total;
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
  /// Order EXPIRY — when the order stops being fillable. ALWAYS UNIX SECONDS, even for a
  /// block-clock order (bit 102) whose decay and exclusivity count blocks: the expiry
  /// stays wall-clock (a robust safety bound a chain halt cannot freeze; 0x/UniswapX keep
  /// it a timestamp for the same reason). `packOrder` folds it into `timing` bits
  /// [160:208); do not pass a block number here for a block-clock order. Distinct from the
  /// Permit3 `deadline`s, which bound signatures rather than the order.
  expiry: bigint;
  legsIn: readonly LegIn[];
  legsOut: readonly LegOut[];
  /// Packed auction clocks: decayStartTime | decayDuration<<32 | exclusivityEndTime<<64.
  /// All three are on the ORDER'S clock — block numbers under bit 102 ({@link BLOCK_CLOCK_BIT}),
  /// else unix seconds — so exclusivity aligns with the decay window rather than drifting
  /// on a separate clock. (The `expiry` above is the sole exception: always seconds.)
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
  /**
   * Reference basefee (wei) at which the gas bump reaches `gasBumpBps`. Read by the
   * gas bump and nothing else — set it without `gasBumpBps` and it is inert (the lens
   * reports that shape as malformed). For a priority auction you almost certainly
   * want {@link Order.baselinePriorityFeeWei} instead.
   */
  gasPriceRef: bigint;
  /**
   * PRIORITY auction (timing bit 103): the priority fee, in wei, that buys a FULL
   * bump. The maker signs `start` as its ambition and `end` as its guaranteed
   * floor; an unbid fill clears at `end` and every wei of priority fee moves the
   * tick toward `start`. `0n` = the order is not a priority auction.
   *
   * The bid is `tx.gasprice - block.basefee - baselinePriorityFeeWei` (clamped at 0).
   */
  priorityScale: bigint;
  /**
   * PRIORITY auction only: the tip, in wei, that does NOT count as a bid — UniswapX's
   * `baselinePriorityFeeWei`. Subtract whatever the chain currently wants just to
   * INCLUDE a transaction, so the inclusion tip is not mistaken for an auction bid and
   * `priorityScale` stays a pure economic parameter. `uint48`, so at most
   * ~281,474 gwei. Omitted or `0n` = every wei of tip bids, which is how every order
   * signed before this field existed reads — the field has bits of its own
   * (`params[160:208)`) precisely so that stays true.
   */
  baselinePriorityFeeWei?: bigint;
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
/**
 * `Order.exclusiveFiller` sentinel: the exclusivity window names a SET of fillers
 * instead of one. The set rides the signed `curve` bytes — build them with
 * {@link packFillerSet} — and the window/override keep their usual homes
 * (`timing` bits [64:96), `exclusivityOverrideBps`). `address(1)` is the
 * ecrecover precompile, which can never be a fill's `msg.sender`.
 * A set order decays on the plain LINEAR clock only: the set occupies the curve
 * blob, so a piecewise curve cannot be signed alongside it.
 */
export const FILLER_SET_SENTINEL = "0x0000000000000000000000000000000000000001" as Address;

export const BLOCK_CLOCK_BIT = 102n;
/// `timing` bit 103: the bump is bid in PRIORITY FEE rather than elapsed time.
export const PRIORITY_AUCTION_BIT = 103n;
/// `timing` bit 104: deliver output legs by VERIFYING the recipient's balance
/// delta (>= the priced amount) instead of pushing a nominal amount — the
/// fee-on-transfer / rebasing-safe delivery mode. The filler delivers each output
/// leg out-of-band (its fill callback); the required amount is still the leg's
/// price, so it composes with every pricing mode.
export const DELTA_VERIFY_OUTPUTS_BIT = 104n;

/**
 * `timing` bit 100 — FILL-ONCE: progress is recorded by consuming the maker's
 * nonce instead of a per-order counter, so the order is ALL-OR-NOTHING (a partial
 * reverts `FillOnceMustBeFull`).
 *
 * Named `…_BIT_INDEX` rather than `…_BIT` only because {@link FILL_ONCE_BIT} in
 * `oco.ts` already exports the same bit as a MASK (`1n << 100n`) and is public
 * API. That constant derives from this one, so there is a single source of truth.
 */
export const FILL_ONCE_BIT_INDEX = 100n;

/// Set the delta-verify-outputs mode on a packed `timing` word (see
/// {@link DELTA_VERIFY_OUTPUTS_BIT}). Mirrors `DutchAuction.deltaVerifyOutputs`.
export function withDeltaVerifyOutputs(timing: bigint): bigint {
  return timing | (1n << DELTA_VERIFY_OUTPUTS_BIT);
}

/// Set the BLOCK-CLOCK mode on a packed `timing` word (see {@link BLOCK_CLOCK_BIT}):
/// the decay and exclusivity clocks count blocks rather than seconds. `expiry` is
/// unaffected and stays wall-clock.
export function withBlockClock(timing: bigint): bigint {
  return timing | (1n << BLOCK_CLOCK_BIT);
}

/// Set the PRIORITY-AUCTION mode on a packed `timing` word (see
/// {@link PRIORITY_AUCTION_BIT}). Prefer {@link priorityOrder}, which also sets the
/// scale, applies the all-or-nothing default and rejects the shapes the settler
/// rejects — this helper is the raw bit.
export function withPriorityAuction(timing: bigint): bigint {
  return timing | (1n << PRIORITY_AUCTION_BIT);
}

/// Set FILL-ONCE on a packed `timing` word (see {@link FILL_ONCE_BIT_INDEX}).
export function withFillOnce(timing: bigint): bigint {
  return timing | (1n << FILL_ONCE_BIT_INDEX);
}

/**
 * How much freedom the maker grants a solver over the ORDER in which their `items`
 * execute. Mirrors the Solidity `ItemPolicy` library; the value lives in `timing`
 * bits [96:100), so it costs no field and no typehash change.
 *
 * Only `matchSettle` — where a solver supplies the schedule — can violate one. The
 * single-order path (`fill`, `fillUpTo`, `batchFill`) runs items in signed order
 * after delivering outputs and before paying inputs, so it satisfies every policy
 * by construction.
 *
 * The values are a LADDER of increasing strictness:
 *  - `ANY` — any order, any interleaving. The default, and what every order that
 *    does not set the field means. Required to participate in a CYCLE (an order's
 *    borrow deliberately hoisted ahead of its own delivery).
 *  - `ORDERED` — items in signed index order; other steps may interleave.
 *  - `ATOMIC` — signed order AND back-to-back, no foreign step between them. What a
 *    lender that checks health inside each call needs.
 *  - `CANONICAL` — `ATOMIC`, and the item group must run AFTER this order's
 *    delivery and BEFORE any pull of its input legs. That is exactly the
 *    single-order path's fixed shape. Sign this for a swap-and-deposit or a
 *    leverage loop: it is what stops a solver hoisting the deposit ahead of the
 *    delivery that funds it (so the item draws the maker's own wallet instead), or
 *    pulling an input leg ahead of the item that was going to fund it (which
 *    refunds the tokens but not the Permit3 allowance they moved with).
 */
export enum ItemPolicy {
  ANY = 0,
  ORDERED = 1,
  ATOMIC = 2,
  CANONICAL = 3,
}

/// `timing` bits [96:100) — the maker's {@link ItemPolicy}.
export const ITEM_POLICY_OFFSET = 96n;

/// Set the {@link ItemPolicy} on a packed `timing` word, replacing any previous
/// value. Mirrors `ItemPolicy.pack`.
export function withItemPolicy(timing: bigint, policy: ItemPolicy): bigint {
  const p = BigInt(policy);
  if (p < 0n || p > 0xfn) throw new Error(`withItemPolicy: policy out of range: ${policy}`);
  return (timing & ~(0xfn << ITEM_POLICY_OFFSET)) | (p << ITEM_POLICY_OFFSET);
}

/// Read the {@link ItemPolicy} out of a packed `timing` word. Solvers building a
/// `matchSettle` schedule must honour it — see `docs/filler-strategy.md`.
export function itemPolicyOf(timing: bigint): ItemPolicy {
  return Number((timing >> ITEM_POLICY_OFFSET) & 0xfn) as ItemPolicy;
}

/// Read the four `timing` mode flags an author may set. The clocks come from
/// {@link unpackTiming}; these are the booleans that sit above them.
export function timingFlags(timing: bigint): {
  fillOnce: boolean;
  blockClock: boolean;
  priorityAuction: boolean;
  deltaVerifyOutputs: boolean;
} {
  const on = (bit: bigint) => ((timing >> bit) & 1n) === 1n;
  return {
    fillOnce: on(FILL_ONCE_BIT_INDEX),
    blockClock: on(BLOCK_CLOCK_BIT),
    priorityAuction: on(PRIORITY_AUCTION_BIT),
    deltaVerifyOutputs: on(DELTA_VERIFY_OUTPUTS_BIT),
  };
}

/**
 * Pack the four auction scalars into the wire `params` word, mirroring
 * `DutchAuction.packParams`: [0:16) overrideBps, [16:32) gasBumpBps,
 * [32:96) gasPriceRef, [96:160) priorityScale, [160:208) baselinePriorityFeeWei.
 */
export function packParams(
  overrideBps: bigint,
  gasBumpBps: bigint,
  gasPriceRef: bigint,
  priorityScale: bigint,
  baselinePriorityFeeWei: bigint = 0n,
): bigint {
  const U16 = 0xffffn;
  const U48 = 0xffff_ffff_ffffn;
  const U64 = 0xffff_ffff_ffff_ffffn;
  if (overrideBps > U16 || gasBumpBps > U16) throw new Error("params bps field exceeds uint16");
  if (gasPriceRef > U64 || priorityScale > U64) throw new Error("params wei field exceeds uint64");
  if (baselinePriorityFeeWei > U48) throw new Error("params baselinePriorityFeeWei exceeds uint48");
  return (
    overrideBps |
    (gasBumpBps << 16n) |
    (gasPriceRef << 32n) |
    (priorityScale << 96n) |
    (baselinePriorityFeeWei << 160n)
  );
}

/// Inverse of {@link packParams}.
export function unpackParams(params: bigint): {
  overrideBps: bigint;
  gasBumpBps: bigint;
  gasPriceRef: bigint;
  priorityScale: bigint;
  baselinePriorityFeeWei: bigint;
} {
  const U16 = 0xffffn;
  const U48 = 0xffff_ffff_ffffn;
  const U64 = 0xffff_ffff_ffff_ffffn;
  return {
    overrideBps: params & U16,
    gasBumpBps: (params >> 16n) & U16,
    gasPriceRef: (params >> 32n) & U64,
    priorityScale: (params >> 96n) & U64,
    baselinePriorityFeeWei: (params >> 160n) & U48,
  };
}

const U32 = 0xffff_ffffn;

/**
 * Pack the three auction clocks into the single `Order.timing` word, mirroring
 * the Solidity layout: bits [0:32) decayStartTime, [32:64) decayDuration,
 * [64:96) exclusivityEndTime. Each must fit in a uint32. All three are read on the
 * order's clock — block numbers when {@link BLOCK_CLOCK_BIT} is set, else unix seconds —
 * so pass values in one consistent unit (the `expiry` field is separate and always
 * seconds).
 *
 * The bits ABOVE the clocks are set with their own helpers, not here: bits [96:100)
 * with {@link withItemPolicy}, bit 100 with {@link withFillOnce}, and 102–104 with
 * {@link withBlockClock} / {@link withPriorityAuction} / {@link withDeltaVerifyOutputs}.
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

/// A `(token, spender)` pair to zero in a token-book `lockdown` / `lockdownAll`.
export interface TokenSpenderPair {
  token: Address;
  spender: Address;
}

/// A `(spender, module, ref)` triple to zero in a taker-book `lockdownTakers` /
/// `lockdownAll`.
export interface SpenderRefPair {
  spender: Address;
  module: Address;
  ref: Hex;
}

/// Permit3 one-shot signed take (`PermitTake`): authorises exactly ONE dispatch of
/// `module` against the position `ref = keccak256(data)`, leaving no standing
/// allowance. The signed `spender` is always the consumer (`msg.sender`), never a
/// field — a leaked signature is useless to anyone else.
export interface PermitTake {
  module: Address;
  ref: Hex;
  amount: bigint;
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

// ──────────────────── The reserved nonce half ────────────────────

/**
 * `NonceManager.SIGNER_NONCE_NS` — bit 255. An `OrderSignerPermit` is consumed at
 * `nonce | SIGNER_NONCE_NS`, a coordinate an ORDER can therefore never occupy,
 * so relaying a nomination can never pull the nonce out from under a live order.
 * (Shared order nonces are not exotic — that is exactly how an OCO bracket is
 * built — which is why the two artifacts needed disjoint halves.)
 *
 * ⚠ The settler does NOT check that an order's nonce has bit 255 clear: that
 * would put a compare on the hot path of every fill forever, to guard a range no
 * allocator picks. Guarding it is the builder's job — {@link assertOrderNonce}.
 */
export const SIGNER_NONCE_NS = 1n << 255n;

/** Whether `nonce` lands in the reserved (signer-permit) half of the bitmap. */
export function isReservedNonce(nonce: bigint): boolean {
  return (nonce & SIGNER_NONCE_NS) !== 0n;
}

/**
 * Throw unless `nonce` is a legal ORDER nonce. Call this wherever order nonces
 * are allocated: an order signed with bit 255 set shares a bitmap coordinate
 * with a nomination permit, so relaying that permit would silently cancel the
 * order (or vice versa).
 */
export function assertOrderNonce(nonce: bigint): bigint {
  if (nonce < 0n) throw new Error(`order nonce out of range: ${nonce}`);
  if (isReservedNonce(nonce)) {
    throw new Error(
      `order nonce ${nonce} has bit 255 set, which is reserved for OrderSignerPermit ` +
        `(NonceManager.SIGNER_NONCE_NS). Order nonces must be < 2^255.`,
    );
  }
  return nonce;
}

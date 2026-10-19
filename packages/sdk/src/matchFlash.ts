import { concat, decodeFunctionResult, encodeFunctionData, encodePacked, type Address, type Hex } from "viem";

import { orderComponents } from "./abi";
import { packOrder } from "./packed";
import { DELTA_VERIFY_OUTPUTS_BIT, ItemOp, type Order } from "./types";

/**
 * `MatchFlashSolver` (packages/solvers/src/match/MatchFlashSolver.sol) — the zero-capital
 * filler for the CYCLE class (review 2026-10-18 S-4 / M-3): one flash loan around a
 * `Settlement.matchSettle` plan, repaid from the plan's own proceeds.
 *
 *   executeMatch(RaceCheck g, FlashMatch job, MatchPlan plan) returns (address[] tokens, uint256[] profit)
 *
 * operator-only. The plan's CALL step targets the solver's `onMatchStep(swaps, tokens,
 * amounts)`, which pushes the flash principal into the Settlement pool. The canonical
 * one-order shape ({@link buildFlashMatchPlan}) is
 *
 *   schedule = [CALL 0 → onMatchStep([], [flashToken], [max]), DELIVER 0, ITEM 0 0 … ITEM 0 n−1,
 *               PULL 0 0 … PULL 0 m−1]
 *   callTargets[0] = the solver, plan.profitRecipient = 0 (the residual returns to the solver)
 *
 * and `job.swaps` convert the proceeds back into the flash token. A v3 pool is `lock`ed
 * during its own flash: flash from a DIFFERENT pool / fee tier than the repayment swap,
 * or use {@link FlashKind.UNI_V3_SWAP} (one pool is the flash AND the repayment).
 * Plans with a SETTLE item are refused on-chain (`SettleUnsupported`).
 */

/** {FlashKind} in declaration order. */
export enum FlashKind {
  UNI_V3_FLASH = 0,
  UNI_V3_SWAP = 1,
  BALANCER_V2 = 2,
  AAVE_V3 = 3,
  MORPHO = 4,
  EULER = 5,
}

export interface FlashSource {
  kind: FlashKind;
  /** The asset borrowed (UNI_V3_SWAP: the swap's OUTPUT). */
  token: Address;
  amount: bigint;
  /** UNI_V3_*: the pool's other token (UNI_V3_SWAP: the token the flash swap is repaid in). */
  pairToken: Address;
  /** UNI_V3_*: the pool's fee tier. */
  fee: number;
  /** UNI_V3_*: index into the solver's venue allowlist. */
  venue: number;
  /** EULER only: the EVK vault. */
  vault: Address;
  /** Ceiling on what the provider takes back; `0` = none. */
  maxRepay: bigint;
}

/** An exact-input swap on derived pools. `path` = `tokenIn ‖ fee(3) ‖ venue(1) ‖ tokenOut …` ({@link encodeFlashPath}). */
export interface PoolSwap {
  path: Hex;
  /** `0` = the solver's whole balance of `tokenIn` at that moment. */
  amountIn: bigint;
  minOut: bigint;
}

export interface SweptFloor {
  token: Address;
  min: bigint;
}

export interface FlashMatch {
  flash: FlashSource;
  /** Proceeds → flash asset, run after `matchSettle` and before the repayment. */
  swaps: PoolSwap[];
  /** Where every residue is swept; `0` = `msg.sender` (the operator). */
  recipient: Address;
  extraSweep: Address[];
  /** Per-token floors on the final sweep — the filler's on-chain profit floor. */
  minProfit: SweptFloor[];
}

/** {MatchRaceGuard}'s cheap-loss check: `filled(orderHash) == expectedFilled`, and every listed `(maker, nonce)` still live. */
export interface RaceCheck {
  orderHashes: Hex[];
  expectedFilled: bigint[];
  nonceMakers: Address[];
  nonces: bigint[];
}

/** `MatchPlan` with STRUCTURED orders (packed at the wire boundary, as every SDK encoder does). */
export interface FlashMatchPlan {
  orders: Order[];
  sigs: Hex[];
  fillAmounts: bigint[];
  takerDatas: Hex[];
  schedule: bigint[];
  callTargets: Address[];
  callDatas: Hex[];
  profitRecipient: Address;
}

/** `MatchStep` kinds (core Structs.sol). */
export const MatchStepKind = { PULL: 0n, DELIVER: 1n, ITEM: 2n, PRESEND: 3n, CALL: 4n } as const;

/** Mirror of `MatchStep.pack(kind, a, b)` = `kind | a << 8 | b << 24`. */
export function packMatchStep(kind: bigint, a: bigint | number = 0n, b: bigint | number = 0n): bigint {
  return kind | (BigInt(a) << 8n) | (BigInt(b) << 24n);
}

/** One hop of a solver pool path. */
export interface FlashHop {
  tokenIn: Address;
  fee: number;
  venue: number;
  tokenOut: Address;
}

/** `tokenIn ‖ fee(3) ‖ venue(1) ‖ tokenOut [‖ fee ‖ venue ‖ tokenOut]…` — AggregatorFillSolver's pool-route hop layout. */
export function encodeFlashPath(tokens: readonly Address[], fees: readonly number[], venues: readonly number[]): Hex {
  if (tokens.length < 2 || fees.length !== tokens.length - 1 || venues.length !== fees.length) throw new Error("encodeFlashPath: tokens / fees / venues do not line up");
  const parts: Hex[] = [encodePacked(["address"], [tokens[0]!])];
  fees.forEach((f, i) => parts.push(encodePacked(["uint24", "uint8", "address"], [f, venues[i]!, tokens[i + 1]!])));
  return concat(parts);
}

/** Decode {@link encodeFlashPath}. */
export function decodeFlashPath(path: Hex): FlashHop[] {
  const b = path.slice(2);
  if (b.length < 40 || (b.length - 40) % 48 !== 0) throw new Error("decodeFlashPath: bad length");
  const hops: FlashHop[] = [];
  let tokenIn = `0x${b.slice(0, 40)}` as Address;
  for (let o = 40; o < b.length; o += 48) {
    const fee = parseInt(b.slice(o, o + 6), 16);
    const venue = parseInt(b.slice(o + 6, o + 8), 16);
    const tokenOut = `0x${b.slice(o + 8, o + 48)}` as Address;
    hops.push({ tokenIn, fee, venue, tokenOut });
    tokenIn = tokenOut;
  }
  return hops;
}

const poolSwapComponents = [
  { name: "path", type: "bytes" },
  { name: "amountIn", type: "uint256" },
  { name: "minOut", type: "uint256" },
] as const;

const flashSourceComponents = [
  { name: "kind", type: "uint8" },
  { name: "token", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "pairToken", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "venue", type: "uint8" },
  { name: "vault", type: "address" },
  { name: "maxRepay", type: "uint256" },
] as const;

const view = (name: string, type: string) => ({ type: "function", name, stateMutability: "view", inputs: [], outputs: [{ name: "", type }] }) as const;

export const MATCH_FLASH_SOLVER_ABI = [
  {
    type: "function",
    name: "executeMatch",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "g",
        type: "tuple",
        components: [
          { name: "orderHashes", type: "bytes32[]" },
          { name: "expectedFilled", type: "uint256[]" },
          { name: "nonceMakers", type: "address[]" },
          { name: "nonces", type: "uint256[]" },
        ],
      },
      {
        name: "job",
        type: "tuple",
        components: [
          { name: "flash", type: "tuple", components: flashSourceComponents },
          { name: "swaps", type: "tuple[]", components: poolSwapComponents },
          { name: "recipient", type: "address" },
          { name: "extraSweep", type: "address[]" },
          {
            name: "minProfit",
            type: "tuple[]",
            components: [
              { name: "token", type: "address" },
              { name: "min", type: "uint256" },
            ],
          },
        ],
      },
      {
        name: "plan",
        type: "tuple",
        components: [
          { name: "orders", type: "tuple[]", components: orderComponents },
          { name: "sigs", type: "bytes[]" },
          { name: "fillAmounts", type: "uint256[]" },
          { name: "takerDatas", type: "bytes[]" },
          { name: "schedule", type: "uint256[]" },
          { name: "callTargets", type: "address[]" },
          { name: "callDatas", type: "bytes[]" },
          { name: "profitRecipient", type: "address" },
        ],
      },
    ],
    outputs: [
      { name: "tokens", type: "address[]" },
      { name: "profit", type: "uint256[]" },
    ],
  },
  {
    type: "function",
    name: "onMatchStep",
    stateMutability: "nonpayable",
    inputs: [
      { name: "swaps", type: "tuple[]", components: poolSwapComponents },
      { name: "tokens", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
    ],
    outputs: [],
  },
  { type: "function", name: "isOperator", stateMutability: "view", inputs: [{ name: "who", type: "address" }], outputs: [{ name: "", type: "bool" }] },
  view("SETTLEMENT", "address"),
  view("EXECUTOR", "address"),
  view("POOL_VENUES", "uint256"),
  {
    type: "function",
    name: "poolVenue",
    stateMutability: "view",
    inputs: [{ name: "i", type: "uint256" }],
    outputs: [
      { name: "factory", type: "address" },
      { name: "initCodeHash", type: "bytes32" },
    ],
  },
  {
    type: "function",
    name: "poolFor",
    stateMutability: "view",
    inputs: [
      { name: "venue", type: "uint256" },
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
      { name: "fee", type: "uint24" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
  { type: "error", name: "NotOperator", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "BadOperatorSet", inputs: [] },
  { type: "error", name: "BadVenue", inputs: [] },
  { type: "error", name: "UnknownVenue", inputs: [{ name: "venue", type: "uint256" }] },
  { type: "error", name: "ProviderDisabled", inputs: [{ name: "kind", type: "uint8" }] },
  { type: "error", name: "BadFlashRequest", inputs: [] },
  { type: "error", name: "Busy", inputs: [] },
  { type: "error", name: "NotArmed", inputs: [] },
  { type: "error", name: "UnexpectedCaller", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "UnexpectedPayload", inputs: [] },
  { type: "error", name: "WrongCallback", inputs: [] },
  { type: "error", name: "FlashCallbackMissing", inputs: [] },
  { type: "error", name: "BadFlashLoan", inputs: [] },
  { type: "error", name: "BadFlashSwap", inputs: [] },
  { type: "error", name: "FlashNotRepaid", inputs: [{ name: "token", type: "address" }, { name: "owed", type: "uint256" }, { name: "held", type: "uint256" }] },
  { type: "error", name: "RepayAboveMax", inputs: [{ name: "owed", type: "uint256" }, { name: "maxRepay", type: "uint256" }] },
  { type: "error", name: "BadPath", inputs: [] },
  { type: "error", name: "BadPoolSwap", inputs: [] },
  { type: "error", name: "SwapBelowMin", inputs: [{ name: "out", type: "uint256" }, { name: "minOut", type: "uint256" }] },
  { type: "error", name: "PartialSwap", inputs: [{ name: "consumed", type: "uint256" }, { name: "amountIn", type: "uint256" }] },
  { type: "error", name: "NotPool", inputs: [] },
  { type: "error", name: "PoolOverBudget", inputs: [{ name: "owed", type: "uint256" }, { name: "budget", type: "uint256" }] },
  { type: "error", name: "OnlyExecutor", inputs: [] },
  { type: "error", name: "LengthMismatch", inputs: [] },
  { type: "error", name: "ProfitStranded", inputs: [] },
  { type: "error", name: "BadRecipient", inputs: [] },
  { type: "error", name: "SettleUnsupported", inputs: [{ name: "order", type: "uint256" }, { name: "item", type: "uint256" }] },
  { type: "error", name: "TooManyTokens", inputs: [] },
  { type: "error", name: "OrderTaken", inputs: [{ name: "index", type: "uint256" }, { name: "expected", type: "uint256" }, { name: "actual", type: "uint256" }] },
  { type: "error", name: "GuardLengthMismatch", inputs: [] },
  { type: "error", name: "NonceTaken", inputs: [{ name: "index", type: "uint256" }, { name: "maker", type: "address" }, { name: "nonce", type: "uint256" }] },
  { type: "error", name: "AnchorShrunk", inputs: [{ name: "index", type: "uint256" }, { name: "expected", type: "uint256" }, { name: "actual", type: "uint256" }] },
  { type: "error", name: "SweptShort", inputs: [{ name: "token", type: "address" }, { name: "expected", type: "uint256" }, { name: "actual", type: "uint256" }] },
] as const;

/** `onMatchStep(swaps, tokens, amounts)` calldata — the plan's CALL step. `amounts[i] = 2^256−1` = the solver's whole balance. */
export function encodeOnMatchStep(swaps: readonly PoolSwap[], tokens: readonly Address[], amounts: readonly bigint[]): Hex {
  if (tokens.length !== amounts.length) throw new Error("encodeOnMatchStep: tokens / amounts length mismatch (LengthMismatch)");
  return encodeFunctionData({ abi: MATCH_FLASH_SOLVER_ABI, functionName: "onMatchStep", args: [swaps as never, tokens as never, amounts as never] });
}

const MAX_UINT256 = (1n << 256n) - 1n;

/**
 * The canonical ONE-ORDER flash plan: `[CALL 0 → onMatchStep([], [flashToken], [max]),
 * DELIVER 0, ITEM 0 0 … ITEM 0 n−1, PULL 0 0 … PULL 0 m−1]`, `callTargets = [solver]`,
 * `profitRecipient = 0`. The order's items produce (and credit) its input; the residual is
 * swept back to the solver and repays the flash.
 *
 * The trailing PULL per input leg (review 2026-10-18 F-4) draws only `owed − credit`
 * (`Batch._stepPull`): zero — no transfer, no allowance spent — when the items credited
 * the leg in full, and the SHORTFALL from the maker's wallet when a venue rounded the
 * item's proceeds down (`owed − 1`), which without it reverts `LegUnfunded` every time.
 * Placed after every ITEM, it satisfies each ItemPolicy's pull precondition.
 */
export function buildFlashMatchPlan(a: { order: Order; sig: Hex; fillAmount: bigint; solver: Address; flashToken: Address; takerData?: Hex }): FlashMatchPlan {
  const n = a.order.items.length;
  const schedule = [packMatchStep(MatchStepKind.CALL, 0, 0), packMatchStep(MatchStepKind.DELIVER, 0, 0)];
  for (let k = 0; k < n; k++) schedule.push(packMatchStep(MatchStepKind.ITEM, 0, k));
  for (let j = 0; j < a.order.legsIn.length; j++) schedule.push(packMatchStep(MatchStepKind.PULL, 0, j));
  return {
    orders: [a.order],
    sigs: [a.sig],
    fillAmounts: [a.fillAmount],
    takerDatas: a.takerData && a.takerData !== "0x" ? [a.takerData] : [],
    schedule,
    callTargets: [a.solver],
    callDatas: [encodeOnMatchStep([], [a.flashToken], [MAX_UINT256])],
    profitRecipient: "0x0000000000000000000000000000000000000000",
  };
}

const eq = (x: string, y: string) => x.toLowerCase() === y.toLowerCase();

/**
 * Encode `executeMatch(g, job, plan)`, refusing what the solver or the core would revert
 * on before anything is signed: a SETTLE item (`SettleUnsupported`), a delta-verify order
 * (`matchSettle` refuses it), a plan recipient of the Settlement (`ProfitStranded`), guard
 * arrays out of line (`GuardLengthMismatch`), misaligned CALL targets, and the `LOK` trap
 * — a UNI_V3_FLASH whose own pool is also a hop of a repayment swap.
 */
export function encodeMatchFlashExecute(args: { race: RaceCheck; job: FlashMatch; plan: FlashMatchPlan; settlement?: Address }): Hex {
  const { race, job, plan } = args;
  if (race.orderHashes.length !== race.expectedFilled.length || race.nonceMakers.length !== race.nonces.length) {
    throw new Error("encodeMatchFlashExecute: race guard arrays out of line (GuardLengthMismatch)");
  }
  if (plan.callTargets.length !== plan.callDatas.length) throw new Error("encodeMatchFlashExecute: callTargets / callDatas length mismatch");
  if (plan.orders.length !== plan.sigs.length || plan.orders.length !== plan.fillAmounts.length) throw new Error("encodeMatchFlashExecute: orders / sigs / fillAmounts length mismatch");
  if (args.settlement && eq(plan.profitRecipient, args.settlement)) throw new Error("encodeMatchFlashExecute: profitRecipient is the Settlement (ProfitStranded)");
  plan.orders.forEach((o, i) => {
    if (((o.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) === 1n) throw new Error(`encodeMatchFlashExecute: order ${i} is delta-verify — matchSettle refuses it`);
    const k = o.items.findIndex((it) => it.op === ItemOp.SETTLE);
    if (k !== -1) throw new Error(`encodeMatchFlashExecute: order ${i} item ${k} is a SETTLE (SettleUnsupported)`);
  });
  const f = job.flash;
  if (f.kind === FlashKind.UNI_V3_FLASH) {
    for (const s of job.swaps) {
      for (const h of decodeFlashPath(s.path)) {
        const samePair = (eq(h.tokenIn, f.token) && eq(h.tokenOut, f.pairToken)) || (eq(h.tokenIn, f.pairToken) && eq(h.tokenOut, f.token));
        if (samePair && h.fee === f.fee && h.venue === f.venue) {
          throw new Error("encodeMatchFlashExecute: the repayment swap runs on the flash pool itself (LOK) — flash from another pool / fee tier, or use UNI_V3_SWAP");
        }
      }
    }
  }
  const wirePlan = { ...plan, orders: plan.orders.map(packOrder) };
  return encodeFunctionData({ abi: MATCH_FLASH_SOLVER_ABI, functionName: "executeMatch", args: [race as never, job as never, wirePlan as never] });
}

/** Decode `executeMatch`'s return: the swept token set and what each one paid the recipient. */
export function decodeMatchFlashResult(data: Hex): { tokens: Address[]; profit: bigint[] } {
  const [tokens, profit] = decodeFunctionResult({ abi: MATCH_FLASH_SOLVER_ABI, functionName: "executeMatch", data }) as readonly [readonly Address[], readonly bigint[]];
  return { tokens: [...tokens], profit: [...profit] };
}

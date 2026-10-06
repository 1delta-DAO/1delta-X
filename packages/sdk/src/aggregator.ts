import {
  concat,
  decodeFunctionData,
  decodeFunctionResult,
  encodeFunctionData,
  hexToBigInt,
  numberToHex,
  sliceHex,
  size,
  toFunctionSelector,
  type Address,
  type Hex,
} from "viem";

import { orderComponents } from "./abi";
import { packOrder } from "./packed";
import type { Order } from "./types";

/**
 * `AggregatorFillSolver` — the zero-inventory, DEX-routed filler
 * (packages/solvers/src/aggregator/AggregatorFillSolver.sol).
 *
 * An operator calls `executeFill(order, sig, fillAmount, plan, takerData)`. The
 * solver starts `Settlement.fillWithCallback(..., PostInputsDirect, takerData,
 * plan.minBumpBps)` — `PostInputsTypedDirect` when the plan needs the core's priced
 * amounts (an output leg in the input token, or `amountOutOffset` set) — receives the
 * maker's input (less any output leg owed in that same token), PUSHES it to its `RouteSandbox` (`SANDBOX()`), which approves
 * `plan.router` — ANY target, there is no allowlist since 2026-10-04 — fires
 * `plan.data` and sweeps every token back. The solver then either lets Settlement
 * pull the output (pull orders) or — for a delta-verify order naming the solver as
 * `exclusiveFiller` — has had the route pay the maker directly. The spread is
 * split per the instance's immutable `SurplusPolicy` and the rest goes to
 * `plan.profitRecipient` (`0` = the caller).
 *
 * The quote MUST name the solver contract (not the operator EOA) wherever the
 * route bakes in a recipient on the pull path — not the sandbox: proceeds paid
 * there sit in it for the rest of the route call — and the maker on the direct
 * path. The router's PAYER (`msg.sender`) is the sandbox.
 *
 * Every instance is operator-GATED since 2026-10 (the constructor reverts
 * `NoOperators` on an empty set): any target a route names keeps a standing
 * approval from the sandbox, so only operators may name targets. Never forward a
 * route whose target you would not trust with a later fill's in-flight balance.
 */

/** `RoutePlan.amountInOffset` / `amountOutOffset` sentinel: leave that word as quoted. `type(uint256).max`. */
export const NO_PATCH: bigint = (1n << 256n) - 1n;

/** Mirror of the Solidity `RoutePlan` struct (field order is load-bearing). */
export interface RoutePlan {
  /** The route's target — any contract (called by the sandbox, not the solver). */
  router: Address;
  /**
   * Floor on the swap proceeds in the ANCHOR OUTPUT token — the first output token no
   * input leg pays (`legsOut[0]`'s on a plain order); an inflow of that token the fill
   * paid the solver before the route (a same-token input leg) is netted out. Pull
   * path only; ignored on a direct-delivery order.
   */
  minOut: bigint;
  /**
   * Cap on what Settlement may pull from the solver in the anchor output token — PER
   * TOKEN, so two legs in it (maker + fee) must fit under it together; `0` = this
   * fill's proceeds (pull path only).
   */
  maxPay: bigint;
  /**
   * Byte offset in `data` of the 32-byte input amount to rewrite with what the fill
   * routes (its input delta less the output legs owed in that same token), or
   * {@link NO_PATCH}.
   */
  amountInOffset: bigint;
  /**
   * Byte offset in `data` of the 32-byte OUTPUT amount (an exact-output route's
   * `amountOut`) to rewrite with `legsOut[0]`'s LIVE price at inclusion, or
   * {@link NO_PATCH}. Meant for a direct (delta-verify) order: the route then pays
   * exactly what the core verifies and the auction's decay since the quote stays with
   * the filler. Switches the fill to the typed callback (~+5.9k gas). Ignored by
   * `executeItemFill`. BREAKING (2026-10): new field — see {@link RouterCall.amountOutOffset}.
   */
  amountOutOffset: bigint;
  /**
   * The filler's price floor on the order's resolved bump, bps of the band, exactly as
   * `Settlement.fillUpTo` takes it — `0` = none; a miss reverts `BumpTooLow` before
   * anything moves. Set it to the bump the route was quoted at (the lens
   * `previewBump`, called with the SEND gasPrice). Ignored by `executeItemFill`.
   * BREAKING (2026-10): new field.
   */
  minBumpBps: bigint;
  /** Where the filler's share of the spread goes; zero = `msg.sender`; the solver itself = retain (gated only). */
  profitRecipient: Address;
  originator: Address;
  /** Originator share of the surplus, ppm, out of the filler's remainder. */
  originatorPpm: number;
  /** The router calldata. */
  data: Hex;
}

const routePlanComponents = [
  { name: "router", type: "address" },
  { name: "minOut", type: "uint256" },
  { name: "maxPay", type: "uint256" },
  { name: "amountInOffset", type: "uint256" },
  { name: "amountOutOffset", type: "uint256" },
  { name: "minBumpBps", type: "uint256" },
  { name: "profitRecipient", type: "address" },
  { name: "originator", type: "address" },
  { name: "originatorPpm", type: "uint32" },
  { name: "data", type: "bytes" },
] as const;

const view = (name: string, type: string) =>
  ({ type: "function", name, stateMutability: "view", inputs: [], outputs: [{ name: "", type }] }) as const;

/**
 * `AggregatorFillSolver` ABI: `executeFill`, the views an operator checks at
 * start-up, `sweep`, and the custom errors — its own and its `RouteSandbox`'s,
 * which surface wrapped in `CallbackFailed` — so a simulated revert decodes to a
 * name.
 */
export const AGGREGATOR_FILL_SOLVER_ABI = [
  {
    type: "function",
    name: "executeFill",
    stateMutability: "nonpayable",
    inputs: [
      { name: "order", type: "tuple", components: orderComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmount", type: "uint256" },
      { name: "plan", type: "tuple", components: routePlanComponents },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [{ name: "fillAmountsOut", type: "uint256[]" }],
  },
  view("SETTLEMENT", "address"),
  view("EXECUTOR", "address"),
  view("SANDBOX", "address"),
  view("GATED", "bool"),
  view("MAKER_SURPLUS_PPM", "uint32"),
  view("PROTOCOL_SURPLUS_PPM", "uint32"),
  view("PROTOCOL_RECIPIENT", "address"),
  view("MAX_SET", "uint256"),
  view("MAX_TOKENS", "uint256"),
  {
    type: "function",
    name: "isOperator",
    stateMutability: "view",
    inputs: [{ name: "who", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "sweep",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  { type: "error", name: "OnlyExecutor", inputs: [] },
  { type: "error", name: "BadSurplusSplit", inputs: [] },
  { type: "error", name: "NotArmed", inputs: [] },
  {
    type: "error",
    name: "InsufficientOutput",
    inputs: [
      { name: "got", type: "uint256" },
      { name: "wanted", type: "uint256" },
    ],
  },
  { type: "error", name: "CallbackDidNotRun", inputs: [] },
  {
    type: "error",
    name: "PatchOutOfBounds",
    inputs: [
      { name: "offset", type: "uint256" },
      { name: "length", type: "uint256" },
    ],
  },
  { type: "error", name: "NotOperator", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "RouteOverspent", inputs: [] },
  { type: "error", name: "BadOperator", inputs: [] },
  { type: "error", name: "BadSetSize", inputs: [] },
  // Constructor: empty operator set (every instance is gated since 2026-10;
  // replaces DirectNeedsOperators / PolicyNeedsOperators / RetainNeedsOperators).
  { type: "error", name: "NoOperators", inputs: [] },
  { type: "error", name: "Reentrancy", inputs: [] },
  { type: "error", name: "TooManyTokens", inputs: [] },
  { type: "error", name: "BadItemSchedule", inputs: [] },
  { type: "error", name: "DirectNotMatchable", inputs: [] },
  { type: "error", name: "NoLegs", inputs: [] },
  // PackedArraysMem.validateLegsIn/Out inside `_plan` (a malformed legs blob):
  { type: "error", name: "MalformedPackedArray", inputs: [] },
  // RouteSandbox (bubbled through the solver):
  { type: "error", name: "OnlyOwner", inputs: [] },
  { type: "error", name: "ForbiddenTarget", inputs: [{ name: "target", type: "address" }] },
  { type: "error", name: "RouteFailed", inputs: [{ name: "ret", type: "bytes" }] },
  // SolverCallbackExecutor wraps every callback revert in this:
  { type: "error", name: "CallbackFailed", inputs: [{ name: "ret", type: "bytes" }] },
] as const;

/**
 * `RouteSandbox` — the authority-less identity every route runs from. Owner-only
 * `exec`; the views let an operator check the wiring at start-up.
 */
export const ROUTE_SANDBOX_ABI = [
  view("OWNER", "address"),
  view("SETTLEMENT", "address"),
  view("PERMIT3", "address"),
  view("EXECUTOR", "address"),
  view("FLOOR", "uint256"),
  {
    type: "function",
    name: "exec",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "target", type: "address" },
      { name: "data", type: "bytes" },
      { name: "sweepTokens", type: "address[]" },
    ],
    outputs: [],
  },
  { type: "error", name: "OnlyOwner", inputs: [] },
  { type: "error", name: "ForbiddenTarget", inputs: [{ name: "target", type: "address" }] },
  { type: "error", name: "RouteFailed", inputs: [{ name: "ret", type: "bytes" }] },
] as const;

/** Encode `AggregatorFillSolver.executeFill`. Send it from an operator. */
export function encodeAggregatorExecuteFill(args: {
  order: Order;
  sig: Hex;
  fillAmount: bigint;
  plan: RoutePlan;
  takerData?: Hex;
}): Hex {
  const p = args.plan;
  for (const field of ["amountInOffset", "amountOutOffset"] as const) {
    const off = p[field];
    if (off !== NO_PATCH && off + 32n > BigInt(size(p.data))) {
      // The contract reverts `PatchOutOfBounds`; fail before signing anything.
      throw new Error(`encodeAggregatorExecuteFill: ${field} ${off} past the end of a ${size(p.data)}-byte route`);
    }
  }
  return encodeFunctionData({
    abi: AGGREGATOR_FILL_SOLVER_ABI,
    functionName: "executeFill",
    args: [packOrder(args.order) as never, args.sig, args.fillAmount, p as never, args.takerData ?? "0x"],
  });
}

/** Decode `executeFill`'s return (`fillAmountsOut`, one per output leg) from an `eth_call`. */
export function decodeAggregatorExecuteFillResult(data: Hex): bigint[] {
  const out = decodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", data });
  return [...(out as readonly bigint[])];
}

// ──────────────────── Uniswap v3 SwapRouter02 ────────────────────
//
// SwapRouter02 (the router Oku deploys on Rootstock) — NOTE its param structs have
// NO `deadline` field, unlike the original v3 SwapRouter. Wrong struct = wrong
// selector = revert.

const exactInputSingleComponents = [
  { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "recipient", type: "address" },
  { name: "amountIn", type: "uint256" },
  { name: "amountOutMinimum", type: "uint256" },
  { name: "sqrtPriceLimitX96", type: "uint160" },
] as const;

const exactOutputSingleComponents = [
  { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "recipient", type: "address" },
  { name: "amountOut", type: "uint256" },
  { name: "amountInMaximum", type: "uint256" },
  { name: "sqrtPriceLimitX96", type: "uint160" },
] as const;

export const SWAP_ROUTER02_ABI = [
  {
    type: "function",
    name: "exactInputSingle",
    stateMutability: "payable",
    inputs: [{ name: "params", type: "tuple", components: exactInputSingleComponents }],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "exactInput",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "path", type: "bytes" },
          { name: "recipient", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMinimum", type: "uint256" },
        ],
      },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "exactOutputSingle",
    stateMutability: "payable",
    inputs: [{ name: "params", type: "tuple", components: exactOutputSingleComponents }],
    outputs: [{ name: "amountIn", type: "uint256" }],
  },
  {
    type: "function",
    name: "exactOutput",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "path", type: "bytes" },
          { name: "recipient", type: "address" },
          { name: "amountOut", type: "uint256" },
          { name: "amountInMaximum", type: "uint256" },
        ],
      },
    ],
    outputs: [{ name: "amountIn", type: "uint256" }],
  },
] as const;

/** Uniswap v3 QuoterV2 (the one Oku deploys on Rootstock). All quotes are `eth_call`s of non-view functions. */
export const QUOTER_V2_ABI = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "fee", type: "uint24" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96After", type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [
      { name: "path", type: "bytes" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96AfterList", type: "uint160[]" },
      { name: "initializedTicksCrossedList", type: "uint32[]" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "quoteExactOutputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "fee", type: "uint24" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [
      { name: "amountIn", type: "uint256" },
      { name: "sqrtPriceX96After", type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "quoteExactOutput",
    stateMutability: "nonpayable",
    inputs: [
      { name: "path", type: "bytes" },
      { name: "amountOut", type: "uint256" },
    ],
    outputs: [
      { name: "amountIn", type: "uint256" },
      { name: "sqrtPriceX96AfterList", type: "uint160[]" },
      { name: "initializedTicksCrossedList", type: "uint32[]" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

/**
 * A Uniswap v3 multi-hop path in SWAP order: `tokens[0] →(fees[0])→ tokens[1] → …`.
 * Exact-INPUT routes use it as is; exact-OUTPUT routes take it REVERSED — see
 * {@link encodeV3PathReversed}.
 */
export function encodeV3Path(tokens: readonly Address[], fees: readonly number[]): Hex {
  if (tokens.length < 2 || fees.length !== tokens.length - 1) {
    throw new Error(`encodeV3Path: need n tokens and n-1 fees (got ${tokens.length} / ${fees.length})`);
  }
  const parts: Hex[] = [];
  tokens.forEach((t, i) => {
    parts.push(t.toLowerCase() as Hex);
    if (i < fees.length) {
      const f = fees[i]!;
      if (!Number.isInteger(f) || f < 0 || f >= 1 << 24) throw new Error(`encodeV3Path: bad fee ${f}`);
      parts.push(numberToHex(f, { size: 3 }));
    }
  });
  return concat(parts);
}

/** The exact-OUTPUT form of the same swap-order path (`tokenOut … tokenIn`). */
export function encodeV3PathReversed(tokens: readonly Address[], fees: readonly number[]): Hex {
  return encodeV3Path([...tokens].reverse(), [...fees].reverse());
}

/** A SwapRouter02 call plus where its input amount (amountIn / amountInMaximum) sits. */
export interface RouterCall {
  data: Hex;
  /** Byte offset in `data` (selector included) of the input-amount word — what `RoutePlan.amountInOffset` takes. */
  amountInOffset: bigint;
  /**
   * Byte offset of the exact-output forms' `amountOut` word — what `RoutePlan.amountOutOffset`
   * takes on a direct order — or {@link NO_PATCH} for the exact-input forms (their
   * `amountOutMinimum` is a floor, not the amount the route pays).
   */
  amountOutOffset: bigint;
}

/** `exactInputSingle` (SwapRouter02 — no deadline). */
export function encodeExactInputSingle(p: {
  tokenIn: Address;
  tokenOut: Address;
  fee: number;
  recipient: Address;
  amountIn: bigint;
  amountOutMinimum: bigint;
  sqrtPriceLimitX96?: bigint;
}): RouterCall {
  const data = encodeFunctionData({
    abi: SWAP_ROUTER02_ABI,
    functionName: "exactInputSingle",
    args: [{ ...p, sqrtPriceLimitX96: p.sqrtPriceLimitX96 ?? 0n }],
  });
  return { data, amountInOffset: swapRouter02AmountInOffset(data), amountOutOffset: swapRouter02AmountOutOffset(data) };
}

/** `exactInput` over a swap-order path (SwapRouter02 — no deadline). */
export function encodeExactInput(p: {
  tokens: readonly Address[];
  fees: readonly number[];
  recipient: Address;
  amountIn: bigint;
  amountOutMinimum: bigint;
}): RouterCall {
  const data = encodeFunctionData({
    abi: SWAP_ROUTER02_ABI,
    functionName: "exactInput",
    args: [
      {
        path: encodeV3Path(p.tokens, p.fees),
        recipient: p.recipient,
        amountIn: p.amountIn,
        amountOutMinimum: p.amountOutMinimum,
      },
    ],
  });
  return { data, amountInOffset: swapRouter02AmountInOffset(data), amountOutOffset: swapRouter02AmountOutOffset(data) };
}

/** `exactOutputSingle` (SwapRouter02). The patchable word is `amountInMaximum`. */
export function encodeExactOutputSingle(p: {
  tokenIn: Address;
  tokenOut: Address;
  fee: number;
  recipient: Address;
  amountOut: bigint;
  amountInMaximum: bigint;
  sqrtPriceLimitX96?: bigint;
}): RouterCall {
  const data = encodeFunctionData({
    abi: SWAP_ROUTER02_ABI,
    functionName: "exactOutputSingle",
    args: [{ ...p, sqrtPriceLimitX96: p.sqrtPriceLimitX96 ?? 0n }],
  });
  return { data, amountInOffset: swapRouter02AmountInOffset(data), amountOutOffset: swapRouter02AmountOutOffset(data) };
}

/** `exactOutput` over a SWAP-order path (reversed internally). The patchable word is `amountInMaximum`. */
export function encodeExactOutput(p: {
  tokens: readonly Address[];
  fees: readonly number[];
  recipient: Address;
  amountOut: bigint;
  amountInMaximum: bigint;
}): RouterCall {
  const data = encodeFunctionData({
    abi: SWAP_ROUTER02_ABI,
    functionName: "exactOutput",
    args: [
      {
        path: encodeV3PathReversed(p.tokens, p.fees),
        recipient: p.recipient,
        amountOut: p.amountOut,
        amountInMaximum: p.amountInMaximum,
      },
    ],
  });
  return { data, amountInOffset: swapRouter02AmountInOffset(data), amountOutOffset: swapRouter02AmountOutOffset(data) };
}

const SEL = {
  exactInputSingle: toFunctionSelector(SWAP_ROUTER02_ABI[0]),
  exactInput: toFunctionSelector(SWAP_ROUTER02_ABI[1]),
  exactOutputSingle: toFunctionSelector(SWAP_ROUTER02_ABI[2]),
  exactOutput: toFunctionSelector(SWAP_ROUTER02_ABI[3]),
} as const;

/**
 * Byte offset (selector included — the solver writes at `data + offset`) of the
 * input-amount word of a SwapRouter02 call: `amountIn` for the exact-input forms,
 * `amountInMaximum` for the exact-output forms.
 *
 *   exactInputSingle   static tuple, word 4  → 4 + 4·32 = 132
 *   exactOutputSingle  static tuple, word 5  → 4 + 5·32 = 164
 *   exactInput         dynamic tuple at head[0]; amountIn is its word 2
 *   exactOutput        dynamic tuple at head[0]; amountInMaximum is its word 3
 *
 * The dynamic forms read the tuple offset from the calldata rather than assuming
 * the canonical `0x20`.
 */
export function swapRouter02AmountInOffset(data: Hex): bigint {
  if (size(data) < 4) throw new Error("swapRouter02AmountInOffset: no selector");
  const sel = sliceHex(data, 0, 4).toLowerCase();
  let off: number;
  if (sel === SEL.exactInputSingle) off = 4 + 4 * 32;
  else if (sel === SEL.exactOutputSingle) off = 4 + 5 * 32;
  else if (sel === SEL.exactInput || sel === SEL.exactOutput) {
    const tuple = Number(hexToBigInt(sliceHex(data, 4, 36)));
    off = 4 + tuple + (sel === SEL.exactInput ? 2 : 3) * 32;
  } else {
    throw new Error(`swapRouter02AmountInOffset: unknown selector ${sel}`);
  }
  if (off + 32 > size(data)) throw new Error("swapRouter02AmountInOffset: calldata too short");
  return BigInt(off);
}

/**
 * Byte offset (selector included) of a SwapRouter02 call's `amountOut` word — the
 * exact-output forms only — or {@link NO_PATCH} for the exact-input forms:
 *
 *   exactOutputSingle  static tuple, word 4  → 4 + 4·32 = 132
 *   exactOutput        dynamic tuple at head[0]; amountOut is its word 2
 */
export function swapRouter02AmountOutOffset(data: Hex): bigint {
  if (size(data) < 4) throw new Error("swapRouter02AmountOutOffset: no selector");
  const sel = sliceHex(data, 0, 4).toLowerCase();
  let off: number;
  if (sel === SEL.exactInputSingle || sel === SEL.exactInput) return NO_PATCH;
  if (sel === SEL.exactOutputSingle) off = 4 + 4 * 32;
  else if (sel === SEL.exactOutput) off = 4 + Number(hexToBigInt(sliceHex(data, 4, 36))) + 2 * 32;
  else throw new Error(`swapRouter02AmountOutOffset: unknown selector ${sel}`);
  if (off + 32 > size(data)) throw new Error("swapRouter02AmountOutOffset: calldata too short");
  return BigInt(off);
}

/** Exactly what the solver's `_patch` does: overwrite the 32-byte word at `offset`. */
export function patchAmountIn(data: Hex, offset: bigint, amount: bigint): Hex {
  if (offset === NO_PATCH) return data;
  const o = Number(offset);
  if (o + 32 > size(data)) throw new Error(`patchAmountIn: offset ${o} past the end of ${size(data)} bytes`);
  const tail: Hex = o + 32 === size(data) ? "0x" : sliceHex(data, o + 32);
  return concat([sliceHex(data, 0, o), numberToHex(amount, { size: 32 }), tail]);
}

// ──────────────────── SushiSwap RedSnwapper ────────────────────
//
// What `api.sushi.com/swap/v7/{chain}` returns as `tx`: a call to Sushi's
// RedSnwapper (Rootstock: 0xAC4c6e212A361c968F1725b4d055b47E63F80b75) —
//   snwap(tokenIn, amountIn, recipient, tokenOut, amountOutMin, executor, executorData)
// which pulls `amountIn` from ITS `msg.sender` (for the aggregator solver: the
// RouteSandbox) straight into `executor` (a RouteProcessor run through RedSnwapper's
// approval-less SafeExecutor), and then REQUIRES `recipient`'s `tokenOut` balance to
// have risen by `amountOutMin`. `amountIn == 0` means "RedSnwapper's own balance" —
// never accept that. The executor swaps what it actually received, so the
// `amountIn` word is patchable, but `amountOutMin` is a fixed figure.

export const SUSHI_RED_SNWAPPER_ABI = [
  {
    type: "function",
    name: "snwap",
    stateMutability: "payable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "amountOutMin", type: "uint256" },
      { name: "executor", type: "address" },
      { name: "executorData", type: "bytes" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "error",
    name: "MinimalOutputBalanceViolation",
    inputs: [
      { name: "tokenOut", type: "address" },
      { name: "amountOut", type: "uint256" },
    ],
  },
] as const;

/** Byte offset (selector included) of `snwap`'s `amountIn` word — what `RoutePlan.amountInOffset` takes. */
export const SNWAP_AMOUNT_IN_OFFSET = 36n;

export interface SnwapCall {
  tokenIn: Address;
  amountIn: bigint;
  recipient: Address;
  tokenOut: Address;
  amountOutMin: bigint;
  executor: Address;
  executorData: Hex;
}

/**
 * Decode RedSnwapper `snwap` calldata. Throws on any other selector, a malformed
 * body, or a NON-CANONICAL encoding — the caller validates the decoded fields
 * against the order.
 *
 * Canonical means: re-encoding the decoded arguments yields byte-identical
 * calldata. That refuses trailing bytes after the ABI body, a relocated
 * `executorData` (offset ≠ 0xe0, gaps or overlaps), dirty padding and
 * non-minimal head words — anything where what the router executes could
 * differ from what a decoder shows. (Executor pinning is the caller's policy:
 * see `isSnwapExecutorAllowed`.)
 */
export function decodeSnwap(data: Hex): SnwapCall {
  const { functionName, args } = decodeFunctionData({ abi: SUSHI_RED_SNWAPPER_ABI, data });
  if (functionName !== "snwap") throw new Error(`decodeSnwap: not snwap (${functionName})`);
  const [tokenIn, amountIn, recipient, tokenOut, amountOutMin, executor, executorData] = args;
  const canonical = encodeFunctionData({ abi: SUSHI_RED_SNWAPPER_ABI, functionName: "snwap", args });
  if (canonical.toLowerCase() !== data.toLowerCase()) throw new Error("decodeSnwap: non-canonical calldata");
  // The patch offset assumes the canonical head layout: the amount is the second word.
  // (Implied by the canonical check; kept as a belt-and-braces assertion.)
  if (hexToBigInt(sliceHex(data, Number(SNWAP_AMOUNT_IN_OFFSET), Number(SNWAP_AMOUNT_IN_OFFSET) + 32)) !== amountIn) {
    throw new Error("decodeSnwap: amountIn is not at the canonical offset");
  }
  return { tokenIn, amountIn, recipient, tokenOut, amountOutMin, executor, executorData };
}

/**
 * Executor pin check for a decoded snwap: `true` when `allowed` is empty (no pin
 * configured — the caller should warn) or contains `executor` (case-insensitive).
 */
export function isSnwapExecutorAllowed(executor: Address, allowed: readonly Address[]): boolean {
  if (allowed.length === 0) return true;
  const e = executor.toLowerCase();
  return allowed.some((a) => a.toLowerCase() === e);
}

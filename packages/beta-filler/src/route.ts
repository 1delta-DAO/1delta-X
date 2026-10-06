import {
  BLOCK_CLOCK_BIT,
  encodeExactInput,
  encodeExactInputSingle,
  encodeExactOutput,
  encodeExactOutputSingle,
  NO_PATCH,
  OrderSide,
  unpackTiming,
  type Order,
  type RoutePlan,
  type RouterCall,
} from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

import type { RouteConfig, RoutePath } from "./config";
import { isDeltaVerify, plainShape, type Verdict } from "./policy";

/**
 * Pure decision logic of the ROUTE strategy: zero-inventory fills through the
 * operator-gated `AggregatorFillSolver`, swapping the maker's input on Uniswap v3
 * (Oku SwapRouter02, quoted locally on QuoterV2) or — pull orders only — along a
 * Sushi API route (./sushi.ts), whichever nets more after its own gas. The solver
 * runs every route in its `RouteSandbox`, so either target needs no allowlisting.
 * Everything chain-dependent (previews, quotes, gas price) is passed in.
 *
 * Two delivery modes, decided by the ORDER (the maker signed it), never by us:
 *
 *  • PULL (no timing bit 104, `exclusiveFiller` 0 or the solver): an exact-INPUT
 *    route pays the solver; Settlement then pulls the owed amount (capped by
 *    `maxPay`) and the surplus — our spread — is split to `profitRecipient`.
 *    `minOut` = owed + grossUp(gas + min profit), so the route reverts rather than
 *    fill at a loss — "gas" being the gas LIMIT the tx is sent with (never a
 *    guess: see RouteFiller's re-price step) and grossUp the solver's surplus split;
 *    `amountInOffset` points at `amountIn` so the route swaps exactly what the fill
 *    delivered.
 *
 *  • DIRECT (bit 104, `exclusiveFiller` == the solver): an exact-OUTPUT route pays
 *    the MAKER exactly the owed amount, the core verifies the maker's balance
 *    delta, and the unconsumed INPUT is our spread. `amountInMaximum` = input −
 *    (grossUp(gas + min profit), in input units, gas at the sent gas LIMIT), so the
 *    route reverts rather than eat into the margin. No input patch (the bounded
 *    maximum must not be overwritten). On a SELL whose output is still DECAYING
 *    ({@link patchesLiveOutput}) `amountOutOffset` points at the router call's
 *    `amountOut` word: the solver runs the typed callback (~+{@link TYPED_CALLBACK_GAS}
 *    gas, priced into the plan) and writes the core's live `outputAt(t_incl)` there,
 *    so the route pays exactly what the core verifies and the decay since the
 *    preview stays on the solver as INPUT residue — our spread (task 05, option 3).
 *    The gate and `amountInMaximum` are still sized on the PREVIEWED owed, so the
 *    margin never counts on a decay that may not happen (the live owed is ≤ the
 *    preview on a falling leg; a maker-ward move reverts `BumpTooLow`). A BUY
 *    (fixed output) and an order past its decay window keep NO_PATCH: the live
 *    output equals the preview and the typed path would only cost gas.
 *
 * Both modes carry `minBumpBps` = the lens `previewBump` at the SEND gas price
 * (RouteFiller): the solver forwards it to `fillWithCallback` as the filler's price
 * floor, so a tick that moved maker-ward after the preview — a priority auction
 * whose effective bid rose, a gas bump, a custom curve — reverts `BumpTooLow`
 * instead of eroding the margin (task 08).
 */

const BPS = 10_000n;

/**
 * Extra gas of the solver's TYPED callback path (`PostInputsTypedDirect` /
 * `onSettlementFill`), which a set `amountOutOffset` switches on: measured +5.9k in
 * `AggregatorFillGas.t.sol` (direct seeded 173,864 → typed 179,773), rounded up.
 */
export const TYPED_CALLBACK_GAS = 6_000n;

/**
 * Whether a direct fill should patch the core's LIVE output into the route
 * (`amountOutOffset`): a delta-verify SELL whose `legsOut[0]` is a falling auction
 * leg (`end != 0`, `end < start`) that may still fall at inclusion. On a wall-clock
 * order that is "before `decayStart + decayDuration`" at `nowSec`; a block-clock
 * order (bit 102) is assumed to still decay (we do not read the block number here —
 * the cost of being wrong is only the typed path's gas, which the plan prices).
 */
export function patchesLiveOutput(order: Order, direct: boolean, nowSec: bigint): boolean {
  if (!direct || order.side !== OrderSide.SELL) return false;
  const leg = order.legsOut[0];
  if (!leg || leg.end === 0n || leg.end >= leg.start) return false;
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n) return true;
  const t = unpackTiming(order.timing);
  return nowSec < BigInt(t.decayStartTime) + BigInt(t.decayDuration);
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * Every configured way from `tokenIn` to `tokenOut`: each direct pool (any fee
 * tier) and each configured multi-hop path, in either direction. The caller
 * quotes them all and takes the best.
 */
export function candidatePaths(tokenIn: Address, tokenOut: Address, rc: Pick<RouteConfig, "pools" | "paths">): RoutePath[] {
  const out: RoutePath[] = [];
  for (const p of rc.pools) {
    if (eq(p.tokenA, tokenIn) && eq(p.tokenB, tokenOut)) out.push({ tokens: [tokenIn, tokenOut], fees: [p.fee] });
    else if (eq(p.tokenB, tokenIn) && eq(p.tokenA, tokenOut)) out.push({ tokens: [tokenIn, tokenOut], fees: [p.fee] });
  }
  for (const p of rc.paths) {
    const first = p.tokens[0]!;
    const last = p.tokens[p.tokens.length - 1]!;
    if (eq(first, tokenIn) && eq(last, tokenOut)) out.push({ tokens: [...p.tokens], fees: [...p.fees] });
    else if (eq(first, tokenOut) && eq(last, tokenIn)) out.push({ tokens: [...p.tokens].reverse(), fees: [...p.fees].reverse() });
  }
  return out;
}

export interface RouteClass {
  /** Delta-verify order naming our solver: the route pays the maker. */
  direct: boolean;
  tokenIn: Address;
  tokenOut: Address;
  paths: RoutePath[];
}

/**
 * The inventory strategy's strictness (plain one-in/one-out, no items, validators,
 * modules, fee legs, proportional legs or permit/sigless announces), except:
 *   • priority auctions (timing bit 103 / `priorityScale`), gas-bump orders
 *     (`gasBumpBps`) and custom `curve`s ARE admitted since 2026-10 (task 08): their
 *     tick can move maker-ward after the preview, but the plan now carries
 *     `minBumpBps` (the bump previewed at the send gas price) and the solver passes
 *     it to `fillWithCallback`, so such a move reverts `BumpTooLow` before anything
 *     moves — the same on-chain floor `fillUpTo` gives the inventory path. (Until
 *     then the three were refused: the plan's floor/cap was the previewed
 *     `owed`/`received`, a pull or direct-SELL fill reverted on the move and a
 *     direct BUY lost margin silently; review 2026-10-05 §4.)
 *   • a delta-verify order IS allowed — when it names OUR solver as
 *     `exclusiveFiller` (the core fills such an order only for that filler);
 *   • a pull order must be open (`exclusiveFiller` 0) or name the solver — the
 *     core compares `exclusiveFiller` with the SOLVER contract, which is
 *     `msg.sender` to Settlement, never with our EOA.
 *   • BOTH tokens must be in `ROUTE_TOKENS` (default: the Rootstock market tokens
 *     WRBTC, USDT0, WETH, USDRIF) — otherwise, with Sushi on, every pair in the
 *     book would pass and cost an API call per sweep;
 *   • the pair must be routable on a configured pool or path — or, for a PULL
 *     order with the Sushi source enabled, Sushi may find the route instead.
 */
export function classifyRoute(
  order: Order,
  rc: Pick<RouteConfig, "solver" | "pools" | "paths" | "routeTokens"> & { sushi?: { enabled: boolean } },
  extras: { hasPermitBatch?: boolean; sigless?: boolean } = {},
): Verdict<RouteClass> {
  const shape = plainShape(order, extras);
  if (!shape.ok) return shape;
  const direct = isDeltaVerify(order);
  const ex = order.exclusiveFiller;
  if (direct) {
    if (!eq(ex, rc.solver)) return { ok: false, reason: "delta-verify order for another filler" };
  } else if (ex !== zeroAddress && !eq(ex, rc.solver)) {
    return { ok: false, reason: "names another exclusive filler" };
  }
  const tokenIn = order.legsIn[0]!.token;
  const tokenOut = order.legsOut[0]!.token;
  if (eq(tokenIn, tokenOut)) return { ok: false, reason: "same-token order" };
  if (!rc.routeTokens.some((t) => eq(t, tokenIn)) || !rc.routeTokens.some((t) => eq(t, tokenOut))) {
    return { ok: false, reason: "pair outside ROUTE_TOKENS" };
  }
  const paths = candidatePaths(tokenIn, tokenOut, rc);
  if (paths.length === 0 && (direct || !rc.sushi?.enabled)) return { ok: false, reason: "no configured pool/path for the pair" };
  return { ok: true, direct, tokenIn, tokenOut, paths };
}

/** `ceil(a * b / c)`. */
export function mulDivUp(a: bigint, b: bigint, c: bigint): bigint {
  if (c === 0n) throw new Error("mulDivUp: division by zero");
  return (a * b + c - 1n) / c;
}

/** RBTC wei → token units at a reference quote (`refIn` wei bought `refOut` token), rounded up. */
export function nativeToTokenAtQuote(wei: bigint, refIn: bigint, refOut: bigint): bigint {
  return mulDivUp(wei, refOut, refIn);
}

/** RBTC wei → units of a $1 token at a configured RBTC/USD price (18-dec fixed), rounded up. */
export function nativeToUsdToken(wei: bigint, rbtcUsd18: bigint, decimals: number): bigint {
  return mulDivUp(wei * rbtcUsd18, 10n ** BigInt(decimals), 10n ** 36n);
}

/** Parts per million — the unit of the solver's surplus split. */
export const PPM = 1_000_000n;

/**
 * The solver splits every fill's surplus per its immutable `SurplusPolicy`: the
 * maker gets `MAKER_SURPLUS_PPM`, the protocol `PROTOCOL_SURPLUS_PPM`, the filler
 * (us) keeps `keepPpm = 1e6 − both`. For OUR share to cover `cost`, the surplus
 * must be `ceil(cost × 1e6 / keepPpm)`.
 */
export function grossUp(cost: bigint, keepPpm: bigint = PPM): bigint {
  if (keepPpm <= 0n || keepPpm > PPM) throw new Error(`grossUp: keepPpm ${keepPpm} out of range`);
  return keepPpm === PPM ? cost : mulDivUp(cost, PPM, keepPpm);
}

export interface Profitability {
  /** The quote after the slippage haircut. */
  haircutOut: bigint;
  /** What the route must produce: owed + costOut. */
  requiredOut: bigint;
  /** gas + min profit grossed up for the surplus split — the margin the plan's floor carries. */
  costOut: bigint;
  /** haircutOut − requiredOut (≥ 0 when ok). */
  marginOut: bigint;
}

/**
 * The quote haircut for a pair: {@link RouteConfig.stableSlippageBps} when both
 * tokens are $1 tokens, {@link RouteConfig.slippageBps} otherwise.
 */
export function haircutBps(rc: Pick<RouteConfig, "slippageBps" | "stableSlippageBps" | "usdTokens">, tokenIn: Address, tokenOut: Address): bigint {
  const usd = (t: Address) => rc.usdTokens.some((u) => u.toLowerCase() === t.toLowerCase());
  return usd(tokenIn) && usd(tokenOut) ? rc.stableSlippageBps : rc.slippageBps;
}

/**
 * The gate: `quotedOut × (1 − slippage) ≥ owed + grossUp(gasOut + minProfitOut)`,
 * every term in output-token units; `keepPpm` is our share of the surplus after
 * the solver's maker/protocol split (default: all of it).
 */
export function routeProfitable(a: {
  quotedOut: bigint;
  owed: bigint;
  slippageBps: bigint;
  gasOut: bigint;
  minProfitOut: bigint;
  keepPpm?: bigint;
}): Verdict<Profitability> {
  if (a.owed === 0n) return { ok: false, reason: "nothing owed (zero-sized fill)" };
  const haircutOut = (a.quotedOut * (BPS - a.slippageBps)) / BPS;
  const keep = a.keepPpm ?? PPM;
  const costOut = grossUp(a.gasOut + a.minProfitOut, keep);
  const requiredOut = a.owed + costOut;
  if (haircutOut < requiredOut) {
    const split = keep === PPM ? "" : ` (÷ keep ${keep} ppm = ${costOut})`;
    return {
      ok: false,
      reason: `unprofitable: quote ${a.quotedOut} −${a.slippageBps}bps = ${haircutOut} < owed ${a.owed} + gas ${a.gasOut} + profit ${a.minProfitOut}${split}`,
    };
  }
  return { ok: true, haircutOut, requiredOut, costOut, marginOut: haircutOut - requiredOut };
}

export interface BuiltRoute {
  plan: RoutePlan;
  call: RouterCall;
}

/**
 * The RoutePlan + SwapRouter02 calldata for one fill. See the module note for
 * the two delivery modes.
 *
 * @param received the input the solver receives (lens `previewFill(...).received[0]`)
 * @param owed     the output the maker is owed (lens `previewFill(...).paid[0]`)
 * @param quotedOut the exact-input quote of `received` along `path`
 * @param costOut  gas + min profit, in output units — the margin we keep
 * @param minBumpBps the lens `previewBump` at the send gas price — the filler's
 *        on-chain price floor (`0` = none; the order's tick cannot move)
 * @param liveOut  direct only: patch the live output into the route's `amountOut`
 *        word ({@link patchesLiveOutput}); ignored (NO_PATCH) on the pull path
 */
export function buildRoutePlan(a: {
  direct: boolean;
  path: RoutePath;
  router: Address;
  solver: Address;
  maker: Address;
  received: bigint;
  owed: bigint;
  quotedOut: bigint;
  costOut: bigint;
  profitRecipient: Address;
  minBumpBps: bigint;
  liveOut?: boolean;
}): BuiltRoute {
  const single = a.path.tokens.length === 2;
  if (!a.direct) {
    const minOut = a.owed + a.costOut;
    const call = single
      ? encodeExactInputSingle({
          tokenIn: a.path.tokens[0]!,
          tokenOut: a.path.tokens[1]!,
          fee: a.path.fees[0]!,
          recipient: a.solver,
          amountIn: a.received,
          amountOutMinimum: minOut,
        })
      : encodeExactInput({ tokens: a.path.tokens, fees: a.path.fees, recipient: a.solver, amountIn: a.received, amountOutMinimum: minOut });
    return {
      call,
      plan: {
        router: a.router,
        minOut,
        maxPay: a.owed,
        amountInOffset: call.amountInOffset,
        amountOutOffset: NO_PATCH, // exact-input: no output word to patch
        minBumpBps: a.minBumpBps,
        profitRecipient: a.profitRecipient,
        originator: zeroAddress,
        originatorPpm: 0,
        data: call.data,
      },
    };
  }
  if (a.quotedOut === 0n) throw new Error("buildRoutePlan: zero quote");
  // The margin, in INPUT units at the quoted rate, stays on the solver as residue.
  const keepIn = mulDivUp(a.costOut, a.received, a.quotedOut);
  if (keepIn >= a.received) throw new Error("buildRoutePlan: margin exceeds the input");
  const amountInMaximum = a.received - keepIn;
  const call = single
    ? encodeExactOutputSingle({
        tokenIn: a.path.tokens[0]!,
        tokenOut: a.path.tokens[1]!,
        fee: a.path.fees[0]!,
        recipient: a.maker,
        amountOut: a.owed,
        amountInMaximum,
      })
    : encodeExactOutput({ tokens: a.path.tokens, fees: a.path.fees, recipient: a.maker, amountOut: a.owed, amountInMaximum });
  return {
    call,
    plan: {
      router: a.router,
      minOut: 0n, // ignored on the direct path
      maxPay: 0n, // ignored on the direct path
      amountInOffset: NO_PATCH, // the bounded amountInMaximum must survive
      // A decaying SELL: pay the LIVE owed, keep the decay as input residue (task 05).
      // Otherwise pay the previewed owed — fixed output, nothing to reclaim.
      amountOutOffset: a.liveOut ? call.amountOutOffset : NO_PATCH,
      minBumpBps: a.minBumpBps,
      profitRecipient: a.profitRecipient,
      originator: zeroAddress,
      originatorPpm: 0,
      data: call.data,
    },
  };
}

/** One executable route candidate for a PULL fill. */
export interface RouteCandidate {
  source: "oku" | "sushi";
  /** The quoted output for the fill's input. */
  out: bigint;
  /** The route's OWN gas (not the whole fill), in output-token units. */
  routeGasOut: bigint;
}

/**
 * Candidates best-first by NET output (`out − routeGasOut`): the fill overhead
 * around the route is the same whichever route runs, so only the route's own gas
 * separates them. Ties keep the input order (Oku first: no API dependency).
 */
export function rankRoutes<T extends RouteCandidate>(cands: readonly T[]): T[] {
  return cands
    .map((c, i) => ({ c, i, net: c.out - c.routeGasOut }))
    .sort((a, b) => (a.net === b.net ? a.i - b.i : a.net > b.net ? -1 : 1))
    .map((x) => x.c);
}

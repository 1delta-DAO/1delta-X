import {
  BLOCK_CLOCK_BIT,
  decodePoolRoute,
  encodePoolRoute,
  NO_PATCH,
  OrderSide,
  POOL_AMOUNT_IN_OFFSET,
  POOL_AMOUNT_OUT_OFFSET,
  POOL_ROUTE,
  unpackTiming,
  type ItemFillCaps,
  type Order,
  type RoutePlan,
  type RouterCall,
} from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

import type { RouteConfig, RoutePath } from "./config";
import { enumeratePaths, pathKey, pathVenues, type GraphPool } from "./poolGraph";
import { anchorOutToken, exclusivityFor, isDeltaVerify, plainShape, type ShapeAdmit, type Verdict } from "./policy";

/**
 * Pure decision logic of the ROUTE strategy: zero-inventory fills through the
 * operator-gated `AggregatorFillSolver`, swapping the maker's input either along a
 * configured Uniswap-v3-style POOL path (Oku = venue 0, SushiSwap v3 = venue 1;
 * quoted locally on each venue's QuoterV2) or — pull orders only — along an API route
 * (Sushi ./sushi.ts, Nordstern ./nordstern.ts), whichever nets more after its own gas.
 * Everything chain-dependent (previews, quotes, gas price) is passed in.
 *
 * Two plan kinds:
 *
 *  • POOL plan (`RoutePlan.router = POOL_ROUTE`, data = SDK `encodePoolRoute`): the
 *    solver swaps on the pools ITSELF — every pool recomputed (CREATE2) from its
 *    immutable venue allowlist and paid inside `uniswapV3SwapCallback`. No sandbox,
 *    no router, no approval: ~{@link SANDBOX_ROUTE_OVERHEAD_GAS} cheaper. The PAYEE is
 *    decided on-chain from the ORDER (direct → `legsOut[0]`'s recipient / the maker;
 *    pull → the solver), never by the plan.
 *  • SANDBOX plan (an API route's router + calldata): the solver runs it in its
 *    `RouteSandbox`, unchanged.
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
 *  • DIRECT (bit 104, `exclusiveFiller` == the solver): an exact-OUTPUT pool plan pays
 *    the MAKER exactly the owed amount, the core verifies the maker's balance delta,
 *    and the unconsumed INPUT is our spread. The plan's `amountIn` word is the input
 *    CEILING = input − (grossUp(gas + min profit), in input units, gas at the sent gas
 *    LIMIT), so the route reverts rather than eat into the margin (the solver also
 *    caps it at the routed delta). No input patch (the bounded ceiling must not be
 *    overwritten). On a SELL whose output is still DECAYING ({@link patchesLiveOutput})
 *    `amountOutOffset` points at the plan's `amountOut` word: the solver runs the typed
 *    callback (~+{@link TYPED_CALLBACK_GAS} gas, priced into the plan) and writes the
 *    core's live `outputAt(t_incl)` there, so the route pays exactly what the core
 *    verifies and the decay since the preview stays on the solver as INPUT residue —
 *    our spread (task 05, option 3). The gate and the ceiling are still sized on the
 *    PREVIEWED owed, so the margin never counts on a decay that may not happen (the
 *    live owed is ≤ the preview on a falling leg; a maker-ward move reverts
 *    `BumpTooLow`). A BUY (fixed output) and an order past its decay window keep
 *    NO_PATCH: the live output equals the preview and the typed path would only cost gas.
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
 * `AggregatorFillGas.t.sol` (direct seeded 173,824 → typed 179,738) and +5.4k net on
 * the Rootstock fork bench pool route (231,657 → 237,058; 2026-10-12 gas pass), rounded up.
 */
export const TYPED_CALLBACK_GAS = 6_000n;

/**
 * Gas a SANDBOX plan (an API route: RouteSandbox + an external router) costs over a
 * POOL plan for the same swap — the sandbox hop, the router's dispatch and approvals.
 * Added to every API candidate's own gas when routes are RANKED ({@link rankRoutes}
 * callers), and taken off ROUTE_GAS_ESTIMATE for a pool plan's pre-simulation
 * estimate ({@link planGasEstimate}). Measured on the Rootstock fork bench,
 * packages/solvers/test/PoolRouteFork.t.sol — see packages/solvers/README.md
 * (block 9,295,925, net tx gas: 24.3k–34.5k over 1–2 hops, direct and pull, before
 * the 2026-10-12 solver gas pass; 28.8k–41.1k after it — the pool path got cheaper
 * faster than the sandbox path. Left at 30k: a ranking tie-breaker, not a price).
 */
export const SANDBOX_ROUTE_OVERHEAD_GAS = 30_000n;

/**
 * Extra gas of an `executeFill` that carries the maker's ERC-2612 permit (the solver
 * calls `token.permit` before the fill — USD₮0: the allowance 0→value and nonce
 * writes). Charged to the route gate's PRE-simulation estimate only when the fill
 * carries a permit; the simulation (estimateGas, which runs the permit) stays the
 * source of truth for what is sent. Measured on the Rootstock fork bench,
 * packages/solvers/test/PoolRouteFork.t.sol (+58.7k execution / +45.8k net against a
 * directly-approved maker, 2026-10-12; was +59.3k / +46.5k), rounded up.
 */
export const PERMIT_IN_FILL_GAS = 60_000n;

/**
 * Gas of one EXTRA pool hop in a pool plan, net tx gas: the Rootstock fork bench
 * (packages/solvers/test/PoolRouteFork.t.sol, block 9,295,925) measures 1 hop direct
 * 231,657 vs 2 hops 295,956 (+64.3k) and pull 254,906 vs 316,257 (+61.4k) on the
 * deployed (via-IR) solver after the 2026-10-12 gas pass; rounded up. (Was 62,500 from
 * 2-hop figures the bench under-stated by 4.5k: it read the maker's balance inside the
 * measured transaction, warming the slots the fill then wrote — fixed the same day.)
 * Added to a pool plan's pre-simulation estimate per hop beyond the first
 * ({@link extraHopGas}) and the floor of a pool path's ranking gas
 * ({@link poolRouteGasUnits}): a second hop must earn its own gas.
 */
export const POOL_HOP_GAS = 65_000n;

/** Gas a pool plan of `hops` hops costs over a single hop ({@link POOL_HOP_GAS} per extra hop). */
export function extraHopGas(hops: number): bigint {
  return hops > 1 ? BigInt(hops - 1) * POOL_HOP_GAS : 0n;
}

/**
 * A pool path's own gas for RANKING: the quoters' summed `gasEstimate`, but at least
 * {@link POOL_HOP_GAS} per hop — the quoter measures a bare `pool.swap`, the solver
 * also pays the callback and the transfer of each hop.
 */
export function poolRouteGasUnits(hops: number, quoterGas: bigint): bigint {
  const floor = BigInt(hops) * POOL_HOP_GAS;
  return quoterGas > floor ? quoterGas : floor;
}

/** The plan kinds a candidate builds: a direct pool plan, or an API route run in the sandbox. */
export type PlanKind = "pool" | "sandbox";

/**
 * The pre-simulation gas estimate of a fill with this plan kind: ROUTE_GAS_ESTIMATE
 * describes a SANDBOX plan; a pool plan skips the sandbox and the router
 * ({@link SANDBOX_ROUTE_OVERHEAD_GAS}). Only a floor: the plan is priced at
 * max(this, simulated) × r.
 */
export function planGasEstimate(sandboxEstimate: bigint, kind: PlanKind): bigint {
  if (kind === "sandbox") return sandboxEstimate;
  return sandboxEstimate > SANDBOX_ROUTE_OVERHEAD_GAS ? sandboxEstimate - SANDBOX_ROUTE_OVERHEAD_GAS : sandboxEstimate;
}

/** A pool venue's name for logs and the quote API's `route.source` (the app shows "Oku" / "Sushi"). */
export function venueName(venue: number): string {
  return venue === 0 ? "oku" : venue === 1 ? "sushi-v3" : `venue-${venue}`;
}

/** A path's venues for logs and `route.source`: "oku", "sushi-v3", or "oku+sushi-v3" for a mixed path (first-hop venue first). */
export function pathLabel(path: Pick<RoutePath, "fees" | "venue" | "venues">): string {
  return [...new Set(pathVenues(path))].map(venueName).join("+");
}

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

/** Rootstock's block interval, seconds: how far one block of delay moves an auction. */
export const BLOCK_SECONDS = 30n;

/**
 * What the live patch can capture on this fill: one block of `legsOut[0]`'s decay
 * (capped at what is left of it), pro rata to `owed`, rounded down. Only meaningful
 * when {@link patchesLiveOutput} holds; the caller weighs it against
 * {@link TYPED_CALLBACK_GAS}, so a small ticket does not pay the typed path's gas for
 * a decay worth less than it. A block-clock order counts one block of its decay.
 */
export function liveDecayPerBlock(order: Order, owed: bigint, nowSec: bigint): bigint {
  const leg = order.legsOut[0];
  if (!leg || leg.end === 0n || leg.end >= leg.start) return 0n;
  const t = unpackTiming(order.timing);
  const dur = BigInt(t.decayDuration);
  if (dur === 0n) return 0n;
  let steps = 1n;
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 0n) {
    const end = BigInt(t.decayStartTime) + dur;
    const left = end > nowSec ? end - nowSec : 0n;
    steps = left < BLOCK_SECONDS ? left : BLOCK_SECONDS;
  }
  if (steps > dur) steps = dur;
  return (owed * (leg.start - leg.end) * steps) / (leg.start * dur);
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * Every configured way from `tokenIn` to `tokenOut`: each direct pool (any fee
 * tier, any venue) and each configured multi-hop path, in either direction, with
 * its venue(s) (unset = 0). The caller quotes the ones whose venues it can quote and
 * takes the best.
 */
export function candidatePaths(tokenIn: Address, tokenOut: Address, rc: Pick<RouteConfig, "pools" | "paths">): RoutePath[] {
  const out: RoutePath[] = [];
  for (const p of rc.pools) {
    const venue = p.venue ?? 0;
    if (eq(p.tokenA, tokenIn) && eq(p.tokenB, tokenOut)) out.push({ tokens: [tokenIn, tokenOut], fees: [p.fee], venue });
    else if (eq(p.tokenB, tokenIn) && eq(p.tokenA, tokenOut)) out.push({ tokens: [tokenIn, tokenOut], fees: [p.fee], venue });
  }
  for (const p of rc.paths) {
    const first = p.tokens[0]!;
    const last = p.tokens[p.tokens.length - 1]!;
    const mixed = p.venues !== undefined && p.venues.length === p.fees.length;
    const venue = p.venue ?? 0;
    if (eq(first, tokenIn) && eq(last, tokenOut)) {
      out.push(mixed ? { tokens: [...p.tokens], fees: [...p.fees], venues: [...p.venues!] } : { tokens: [...p.tokens], fees: [...p.fees], venue });
    } else if (eq(first, tokenOut) && eq(last, tokenIn)) {
      const tokens = [...p.tokens].reverse();
      const fees = [...p.fees].reverse();
      out.push(mixed ? { tokens, fees, venues: [...p.venues!].reverse() } : { tokens, fees, venue });
    }
  }
  return out;
}

/**
 * Every pool path tokenIn → tokenOut: the configured ones ({@link candidatePaths})
 * and — with a discovered pool graph — every path of ≤ `maxHops` hops through
 * `hubTokens` over its pools (./poolGraph.ts `enumeratePaths`, mixed venues
 * included). Deduplicated, configured first. Zero RPC.
 */
export function routePaths(
  tokenIn: Address,
  tokenOut: Address,
  rc: Pick<RouteConfig, "pools" | "paths"> & Partial<Pick<RouteConfig, "maxHops">> & { discovery?: Pick<RouteConfig["discovery"], "hubTokens"> },
  graph?: readonly GraphPool[],
): RoutePath[] {
  const out = candidatePaths(tokenIn, tokenOut, rc);
  if (graph && graph.length) {
    const seen = new Set(out.map(pathKey));
    for (const p of enumeratePaths(graph, tokenIn, tokenOut, { maxHops: rc.maxHops ?? 1, hubs: rc.discovery?.hubTokens ?? [] })) {
      const k = pathKey(p);
      if (!seen.has(k)) {
        seen.add(k);
        out.push(p);
      }
    }
  }
  return out;
}

/** {@link classifyRoute}'s refusal when no pool path joins the pair (and no API may route it). */
export const NO_ROUTE_REASON = "no configured pool/path for the pair";

export interface RouteClass {
  /** Delta-verify order naming our solver: the route pays the maker (or, native, the solver). */
  direct: boolean;
  tokenIn: Address;
  /** The token the ROUTE ends in: `legsOut[0]`'s, or the wrapped native coin for a native order. */
  tokenOut: Address;
  paths: RoutePath[];
  /** The maker receives raw RBTC: the WRBTC leg goes to the NativeUnwrapModule (policy.ts `nativeOutShape`) — an item fill. */
  nativeOut?: boolean;
  /**
   * NATIVE delivery through the NativeBalance view (task 30): the route ends in WRBTC
   * ({@link tokenOut}) and its last hop pays the SOLVER, which unwraps it and sends the coin.
   */
  native?: boolean;
  /** An item fill (`executeItemFill`, task 31) with this schedule; PULL only. */
  itemFill?: { lateItems: bigint };
  /** A FLASH-REQUIRED item order (a cycle: SDK `needsFlash`): only the flash path may take it (./flash.ts). */
  flash?: { reason: string };
  /** A balance-relative `legsIn[0]`: filled whole with the `type(uint256).max` sentinel (PULL). */
  proportional?: boolean;
  /** Fee legs: owed = Σ the anchor-token legs, the in-kind legs are kept back from the route (PULL). */
  feeLegs?: boolean;
}

/**
 * Extra gas of a NATIVE-OUT fill (task 28): the module's MAKE item — WRBTC `withdraw` and
 * the native send to the maker — on top of the plain pull fill. Measured on the Rootstock
 * fork against the live Settlement (packages/modules/transfer/test/fork, 2026-10-14:
 * ~33k), rounded up. Charged to the pre-simulation estimate and to quotes until the
 * native shape's own receipts are learned.
 */
export const NATIVE_OUT_GAS = 40_000n;

/**
 * Why the route refuses the NativeUnwrapModule shape (see {@link classifyRoute}) unless the
 * SDK item classifier schedules it for `executeItemFill` — which needs the task-31
 * Settlement (pre-funded MAKE on the netted path) and an item policy below CANONICAL
 * (CANONICAL is forward-only; the app signs ORDERED since task 31). Native receipts go
 * through the NativeBalance view instead (task 30), which needs no Settlement change.
 */
export const NATIVE_OUT_NOT_ROUTABLE =
  "native-out via the NativeUnwrapModule: not an item fill the solver can schedule (executeFill is item-free) — sign the NativeBalance shape";

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
 *   • a pull order must be open (`exclusiveFiller` 0), name the solver — the
 *     core compares `exclusiveFiller` with the SOLVER contract, which is
 *     `msg.sender` to Settlement, never with our EOA — or name another filler
 *     whose window is over or SOFT (the solver-side preview prices the premium).
 *     The app's pull markets name THIS solver with a ~2-block soft window (B13):
 *     inside it the route fills premium-free, after it the order is open to all.
 *   • BOTH tokens must be in `ROUTE_TOKENS` (default: the Rootstock market tokens
 *     WRBTC, USDT0, WETH, USDRIF) — otherwise, with Sushi on, every pair in the
 *     book would pass and cost an API call per sweep;
 *   • the pair must be routable on a configured pool or path, or a path over the
 *     discovered pool graph (`extras.graph`, ./poolGraph.ts) — or, for a PULL order
 *     with an API source enabled (Sushi, Nordstern), the API may find the route
 *     instead. (Zero RPC: whether the pool's venue is quotable is the filler's call.)
 */
export function classifyRoute(
  order: Order,
  rc: Pick<RouteConfig, "solver" | "pools" | "paths" | "routeTokens"> &
    Partial<Pick<RouteConfig, "maxHops">> & { discovery?: Pick<RouteConfig["discovery"], "hubTokens">; sushi?: { enabled: boolean }; nordstern?: { enabled: boolean } },
  extras: {
    hasPermitBatch?: boolean;
    sigless?: boolean;
    nowS?: bigint;
    graph?: readonly GraphPool[];
    anyPath?: boolean;
    nativeUnwrap?: { module: Address; wrapped: Address };
    nativeBalance?: { view: Address; wrapped: Address };
    itemFills?: ItemFillCaps;
    admit?: ShapeAdmit;
  } = {},
): Verdict<RouteClass> {
  const shape = plainShape(order, extras);
  if (!shape.ok) return shape;
  // The NativeUnwrapModule shape is the route's only as an ITEM FILL (2026-10-14,
  // fork-proven): `executeFill` drives `PostInputs`, which is item-free
  // (`ReverseModeRequiresNoItems`), and the LIVE `matchSettle` refuses a pre-funded MAKE.
  // Refused here rather than simulated and reverted unless the classifier scheduled it.
  if (shape.nativeOut && !shape.itemFill) return { ok: false, reason: `${NATIVE_OUT_NOT_ROUTABLE}${shape.itemSkip ? ` (${shape.itemSkip})` : ""}` };
  const direct = isDeltaVerify(order);
  const ex = order.exclusiveFiller;
  if (direct) {
    if (!eq(ex, rc.solver)) return { ok: false, reason: "delta-verify order for another filler" };
  } else if (ex !== zeroAddress && !eq(ex, rc.solver)) {
    // Another filler's window: the core admits the solver once it ends, or inside
    // a SOFT one at the premium (the solver-side preview prices it) — refused only
    // while a HARD one runs. Our own app's pull orders name THIS solver, so for
    // them the route is the exclusive filler and pays nothing (B13).
    const w = exclusivityFor(order, rc.solver, extras.nowS ?? BigInt(Math.floor(Date.now() / 1000)));
    if (w.kind === "hard") return { ok: false, reason: "names another exclusive filler (hard window)" };
  }
  const tokenIn = order.legsIn[0]!.token;
  // A native order routes into the wrapped coin (the solver unwraps it); every other
  // order into its ANCHOR output token — `legsOut[0]`'s on a plain order, the first leg
  // not in the input token when an in-kind fee leg is listed first (the solver's rule).
  const tokenOut = shape.nativeBalance ? extras.nativeBalance!.wrapped : anchorOutToken(order) ?? order.legsOut[0]!.token;
  if (eq(tokenIn, tokenOut)) return { ok: false, reason: "same-token order" };
  if (!rc.routeTokens.some((t) => eq(t, tokenIn)) || !rc.routeTokens.some((t) => eq(t, tokenOut))) {
    return { ok: false, reason: "pair outside ROUTE_TOKENS" };
  }
  const paths = routePaths(tokenIn, tokenOut, rc, extras.graph);
  // `anyPath`: the pool graph is not loaded yet, so "no path" would be a guess.
  if (paths.length === 0 && !extras.anyPath && (direct || !(rc.sushi?.enabled || rc.nordstern?.enabled))) return { ok: false, reason: NO_ROUTE_REASON };
  return {
    ok: true,
    direct,
    tokenIn,
    tokenOut,
    paths,
    ...(shape.nativeOut ? { nativeOut: true } : {}),
    ...(shape.nativeBalance ? { native: true } : {}),
    ...(shape.itemFill ? { itemFill: shape.itemFill } : {}),
    ...(shape.flash ? { flash: shape.flash } : {}),
    ...(shape.proportional ? { proportional: true } : {}),
    ...(shape.feeLegs ? { feeLegs: true } : {}),
  };
}

/**
 * The amounts a fill's route works with, from the lens preview (`received` / `paid` per
 * leg) — the fee-leg math of {@link ShapeAdmit.feeLegs}:
 *   • `owed`   — Σ `paid[j]` over the output legs in the ANCHOR output token (`tokenOut`):
 *                Settlement pulls each of them from the solver, so the route must cover
 *                them together (the plan's per-token `maxPay`), and `minOut` floors them
 *                plus our margin. A NATIVE order: leg 0 only.
 *   • `kept`   — Σ `paid[j]` over the legs in the INPUT token (in-kind fees): the solver keeps
 *                them back from the input before the route runs (the typed callback /
 *                PRESEND), so they are not swapped.
 *   • `routeIn` — `received[0] − kept`: what the route actually swaps (quote it, size the
 *                pool plan with it). ≤ 0 = the fee legs eat the whole input.
 */
export function legAmounts(
  order: Order,
  pv: { received: readonly bigint[]; paid: readonly bigint[] },
  tokenOut: Address,
  native = false,
): { received: bigint; owed: bigint; kept: bigint; routeIn: bigint } {
  const received = pv.received[0] ?? 0n;
  if (native) return { received, owed: pv.paid[0] ?? 0n, kept: 0n, routeIn: received };
  const tin = order.legsIn[0]!.token;
  let owed = 0n;
  let kept = 0n;
  order.legsOut.forEach((l, j) => {
    const v = pv.paid[j] ?? 0n;
    if (eq(l.token, tokenOut)) owed += v;
    else if (eq(l.token, tin)) kept += v;
  });
  return { received, owed, kept, routeIn: received - kept };
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
 * The RoutePlan for one fill along a POOL path (`router = POOL_ROUTE`, data =
 * `encodePoolRoute` with each hop's own venue — `pathVenues`). See the module note for the
 * two delivery modes; the payee is the ORDER's (decided on-chain), so the plan names
 * no recipient.
 *
 *  • pull: exact-input (`amountOut` word 0) of `received`, `amountInOffset` = the
 *    amountIn word (the solver rewrites it with what the fill routed), minOut = owed +
 *    costOut, maxPay = owed;
 *  • direct: exact-output of `owed` with the `amountIn` word = the input ceiling
 *    (received − the margin in input units), `amountInOffset` = NO_PATCH,
 *    `amountOutOffset` = the amountOut word only when `liveOut`.
 *
 * @param received the input the solver receives (lens `previewFill(...).received[0]`)
 * @param owed     the output the maker is owed (lens `previewFill(...).paid[0]`)
 * @param quotedOut the output `received` buys along `path`: the exact-input quote
 *        (pull) or, direct, `owed × received / need` where `need` is the backward
 *        exact-output quote of `owed` — so the ceiling's margin is priced at the rate
 *        the route actually executes
 * @param costOut  gas + min profit, in output units — the margin we keep
 * @param minBumpBps the lens `previewBump` at the send gas price — the filler's
 *        on-chain price floor (`0` = none; the order's tick cannot move)
 * @param liveOut  direct only: patch the live output into the plan's `amountOut`
 *        word ({@link patchesLiveOutput}); ignored (NO_PATCH) on the pull path
 */
export function buildPoolPlan(a: {
  direct: boolean;
  path: RoutePath;
  received: bigint;
  owed: bigint;
  quotedOut: bigint;
  costOut: bigint;
  profitRecipient: Address;
  minBumpBps: bigint;
  liveOut?: boolean;
}): BuiltRoute {
  const route = { tokens: a.path.tokens, fees: a.path.fees, venues: pathVenues(a.path) };
  const tail = { minBumpBps: a.minBumpBps, profitRecipient: a.profitRecipient, originator: zeroAddress, originatorPpm: 0 };
  if (!a.direct) {
    const minOut = a.owed + a.costOut;
    const call = encodePoolRoute({ ...route, amountIn: a.received, amountOut: 0n });
    return {
      call,
      plan: {
        router: POOL_ROUTE,
        minOut,
        maxPay: a.owed,
        amountInOffset: POOL_AMOUNT_IN_OFFSET, // swap exactly what the fill routed
        amountOutOffset: NO_PATCH, // exact-input: setting it would turn the route exact-output
        ...tail,
        data: call.data,
      },
    };
  }
  if (a.quotedOut === 0n) throw new Error("buildPoolPlan: zero quote");
  // The margin, in INPUT units at the quoted rate, stays on the solver as residue.
  const keepIn = mulDivUp(a.costOut, a.received, a.quotedOut);
  if (keepIn >= a.received) throw new Error("buildPoolPlan: margin exceeds the input");
  const call = encodePoolRoute({ ...route, amountIn: a.received - keepIn, amountOut: a.owed });
  return {
    call,
    plan: {
      router: POOL_ROUTE,
      minOut: 0n, // ignored on the direct path
      maxPay: 0n, // ignored on the direct path
      amountInOffset: NO_PATCH, // the bounded input ceiling must survive
      // A decaying SELL: pay the LIVE owed, keep the decay as input residue (task 05).
      // Otherwise pay the previewed owed — fixed output, nothing to reclaim.
      amountOutOffset: a.liveOut ? POOL_AMOUNT_OUT_OFFSET : NO_PATCH,
      ...tail,
      data: call.data,
    },
  };
}

/**
 * Pre-send check of a pool plan against the ORDER and the fill — the pool-plan
 * counterpart of the Sushi/Nordstern calldata validation: decode `plan.data` and
 * require the path to run from `legsIn[0]`'s token to `legsOut[0]`'s (the solver
 * reverts `BadPoolRoute` otherwise), match the candidate's tokens / fees / venue of
 * EVERY hop, and
 * carry the amounts and offsets of its delivery mode.
 */
export function validatePoolPlan(
  plan: RoutePlan,
  order: Order,
  a: {
    direct: boolean;
    path: RoutePath;
    received: bigint;
    owed: bigint;
    /** The token the route must end in when it is not `legsOut[0]`'s — WRBTC for a native (NativeBalance) order. */
    routeOut?: Address;
  },
): Verdict<{ plan: RoutePlan }> {
  const bad = (why: string): Verdict<{ plan: RoutePlan }> => ({ ok: false, reason: `pool plan: ${why}` });
  if (plan.router !== POOL_ROUTE) return bad(`router ${plan.router} is not POOL_ROUTE`);
  let d: ReturnType<typeof decodePoolRoute>;
  try {
    d = decodePoolRoute(plan.data);
  } catch (e) {
    return bad((e as Error).message);
  }
  const tokenIn = order.legsIn[0]?.token;
  const tokenOut = a.routeOut ?? order.legsOut[0]?.token;
  if (!tokenIn || !eq(d.tokens[0]!, tokenIn)) return bad(`first token ${d.tokens[0]} is not the order's input ${tokenIn}`);
  if (!tokenOut || !eq(d.tokens[d.tokens.length - 1]!, tokenOut)) return bad(`last token ${d.tokens[d.tokens.length - 1]} is not the order's output ${tokenOut}`);
  const venues = pathVenues(a.path);
  if (d.tokens.length !== a.path.tokens.length || d.tokens.some((t, i) => !eq(t, a.path.tokens[i]!))) return bad("tokens differ from the quoted path");
  if (d.fees.length !== a.path.fees.length || d.fees.some((f, i) => f !== a.path.fees[i])) return bad("fees differ from the quoted path");
  if (d.venues.length !== venues.length || d.venues.some((v, i) => v !== venues[i])) return bad(`venues ${d.venues.join(",")} differ from the quoted path's ${venues.join(",")}`);
  if (!a.direct) {
    if (d.amountOut !== 0n || d.amountIn !== a.received) return bad(`pull plan must be exact-input of ${a.received} (got in ${d.amountIn}, out ${d.amountOut})`);
    if (plan.amountInOffset !== POOL_AMOUNT_IN_OFFSET || plan.amountOutOffset !== NO_PATCH) return bad("pull plan offsets");
    if (plan.maxPay !== a.owed || plan.minOut < a.owed) return bad(`pull plan floor/cap (minOut ${plan.minOut}, maxPay ${plan.maxPay}, owed ${a.owed})`);
  } else {
    if (d.amountOut !== a.owed) return bad(`direct plan must pay exactly owed ${a.owed} (got ${d.amountOut})`);
    if (d.amountIn === 0n || d.amountIn >= a.received) return bad(`direct plan input ceiling ${d.amountIn} must be below the input ${a.received}`);
    if (plan.amountInOffset !== NO_PATCH) return bad("direct plan must not patch its input ceiling");
    if (plan.amountOutOffset !== NO_PATCH && plan.amountOutOffset !== POOL_AMOUNT_OUT_OFFSET) return bad("direct plan output offset");
  }
  return { ok: true, plan };
}

/**
 * Whether a plan is EXACT-INPUT — what an ITEM fill must be quoted as (review 2026-10-18
 * S-6): on the netted path no priced amount reaches the route and `minBumpBps` is refused,
 * so an exact-output plan's spread would sit as INPUT residue no floor checks; an
 * exact-input plan's whole proceeds are floored by `minOut` (with `maxPay`). A pool plan
 * is exact-input when its `amountOut` word is 0; an API route (Sushi / Nordstern) is
 * exact-input by construction, and patches no output word.
 */
export function isExactInputPlan(plan: RoutePlan): boolean {
  if (plan.router === POOL_ROUTE) {
    try {
      return decodePoolRoute(plan.data).amountOut === 0n;
    } catch {
      return false;
    }
  }
  return plan.amountOutOffset >= NO_PATCH;
}

/** Whether the route follows the fill's input (`amountInOffset` set) — the v4 remainder sentinel's precondition. */
export function isInputPatched(plan: RoutePlan): boolean {
  return plan.amountInOffset < NO_PATCH;
}

/** One executable route candidate. */
export interface RouteCandidate {
  /** A local pool path (pool plan) or an API route (sandbox plan). */
  source: "pool" | "sushi" | "nordstern";
  /** The quoted output for the fill's input. */
  out: bigint;
  /**
   * The route's OWN gas (not the whole fill), in output-token units: for a pool path
   * the quoters' summed estimate, at least {@link POOL_HOP_GAS} per hop
   * ({@link poolRouteGasUnits}); the API's figure + {@link SANDBOX_ROUTE_OVERHEAD_GAS}
   * for an API route (the sandbox + router hops a pool plan does not run).
   */
  routeGasOut: bigint;
}

/** The candidate's plan kind: pool paths build pool plans, API routes sandbox plans. */
export const planKind = (c: Pick<RouteCandidate, "source">): PlanKind => (c.source === "pool" ? "pool" : "sandbox");

/** A candidate's own gas units for ranking: a sandbox plan pays {@link SANDBOX_ROUTE_OVERHEAD_GAS} on top of its route. */
export function rankingGasUnits(kind: PlanKind, routeGasUnits: bigint): bigint {
  return kind === "sandbox" ? routeGasUnits + SANDBOX_ROUTE_OVERHEAD_GAS : routeGasUnits;
}

/**
 * Candidates best-first by NET output (`out − routeGasOut`): the fill overhead
 * around the route is the same whichever route runs, so only the route's own gas
 * (sandbox overhead included, {@link rankingGasUnits}) separates them. Ties keep the
 * input order (pool paths first: no API dependency, no sandbox).
 */
export function rankRoutes<T extends RouteCandidate>(cands: readonly T[]): T[] {
  return cands
    .map((c, i) => ({ c, i, net: c.out - c.routeGasOut }))
    .sort((a, b) => (a.net === b.net ? a.i - b.i : a.net > b.net ? -1 : 1))
    .map((x) => x.c);
}

import {
  OrderSide,
  anchorTotal,
  signBid,
  type Order,
  type QuoteBinding,
  type QuoteSigner,
  type SignedBid,
} from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

/**
 * The SOLVER side of the quote channel — the counterpart to {@link Auctioneer}.
 *
 * A bid is a bump: how much concession the solver needs to do the job. Lower is
 * better for the maker, and the LOWEST bid wins — so a solver's whole job is to
 * compute the smallest bump its route can support, and bid exactly that.
 *
 * Under the default Vickrey rule that number is also the honest one: bidding
 * your true break-even is dominant, because the price you are charged is the
 * runner-up's bump, not your own. Shading up only loses you rounds you would
 * have been paid for.
 */

const BPS = 10_000n;

/** What a route source promises for one leg. */
export interface RouteQuote {
  /** Output the route yields for the requested input. */
  amountOut: bigint;
  /** Opaque execution payload (router target + calldata), passed back to the
   *  caller's fill callback. This package never interprets it. */
  route?: unknown;
  /** Which source produced it, for logging and tie-breaking. */
  source?: string;
  /** Gas units the ROUTE alone is expected to burn, when the source reports one
   *  (Sushi returns `tx.gas`). The settlement's own overhead is added on top. */
  gasUnits?: bigint;
}

export interface RouteRequest {
  chainId: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  /** Who receives the output — the settlement, or the solver's own contract. */
  recipient: Address;
}

/**
 * A pluggable price source: an aggregator API, a local AMM simulator, an
 * inventory desk. Return `null` when the pair or size cannot be served, rather
 * than throwing — one dead source must not stop a solver bidding from another.
 *
 * Sushi and Nordstern ship in `./sources` as the DEFAULT quoter
 * ({@link defaultRouteSources}) — the floor a competing solver has to beat.
 * Add your own for private inventory or a venue we do not cover.
 */
export interface RouteSource {
  name: string;
  quote(req: RouteRequest): Promise<RouteQuote | null>;
}

/** The maker's signed band on the leg that prices. */
export interface PricedBand {
  start: bigint;
  end: bigint;
  /** True for a BUY order's input leg (rises start→end); false for a SELL
   *  order's output leg (falls start→end). */
  rising: boolean;
}

function ceilDiv(a: bigint, b: bigint): bigint {
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

const WEI = 10n ** 18n;

/**
 * Gas, denominated in the band's token.
 *
 * A solver pays gas in the native token but can only express cost through the
 * bump, so the fee has to be carried into whichever token the band prices in
 * before it can be bid. `nativePriceInToken` is the exchange rate: how many
 * units of the band token one WHOLE native token (1e18 wei) is worth.
 *
 * Rounded UP — an understated cost is a bid the solver cannot honour.
 */
export function gasInBandToken(args: {
  gasUnits: bigint;
  gasPriceWei: bigint;
  /** Band-token units per 1e18 wei of native. */
  nativePriceInToken: bigint;
}): bigint {
  const costWei = args.gasUnits * args.gasPriceWei;
  return ceilDiv(costWei * args.nativePriceInToken, WEI);
}

/**
 * Resolve `nativePriceInToken` live from the solver's own route sources.
 *
 * Quotes a WHOLE native token rather than the gas amount itself: aggregators
 * routinely fail to route dust, and a few hundred thousand wei is dust. The
 * rate that comes back is then scaled by the actual cost.
 */
export async function nativePriceVia(args: {
  routes: RouteSource[];
  chainId: number;
  token: Address;
  recipient?: Address;
  /** Native placeholder to quote FROM. Default the zero address. */
  nativeToken?: Address;
  referenceWei?: bigint;
}): Promise<bigint | null> {
  const reference = args.referenceWei ?? WEI;
  const req: RouteRequest = {
    chainId: args.chainId,
    tokenIn: args.nativeToken ?? ("0x0000000000000000000000000000000000000000" as Address),
    tokenOut: args.token,
    amountIn: reference,
    recipient: args.recipient ?? ("0x0000000000000000000000000000000000000000" as Address),
  };
  let best: bigint | null = null;
  for (const src of args.routes) {
    try {
      const q = await src.quote(req);
      if (q && (best === null || q.amountOut > best)) best = q.amountOut;
    } catch {
      /* a dead source must not stop the rate resolving from another */
    }
  }
  if (best === null) return null;
  return reference === WEI ? best : (best * WEI) / reference;
}

/**
 * The smallest bump a route can support, in bps — a solver's honest bid.
 *
 * SELL (falling output band): the maker must receive
 * `start − (start−end)·b/BPS`. The solver holds `amountOut` from its route, so
 * the least it can concede is the `b` where those meet, plus its margin.
 *
 * BUY (rising input band): the maker pays `start + (end−start)·b/BPS` and the
 * solver must cover `cost`. Same equation, mirrored.
 *
 * Returns `null` when the route cannot clear even at the maker's floor — the
 * correct outcome is NOT to bid, rather than to bid `10000` and win a round the
 * solver will then fail to fill.
 *
 * ⚠ `available` IS A COST IN THE BAND'S TOKEN, on both sides. On a falling
 * (SELL) band that happens to coincide with the route's `amountOut`; on a rising
 * (BUY) band it does NOT — the band is the input leg and the route's output is
 * denominated in the other token. Use {@link costInBandToken} rather than
 * passing a quote field straight in.
 */
export function minimumBump(args: {
  band: PricedBand;
  available: bigint;
  minProfitBps?: number;
  /** Gas cost of the whole fill, denominated in the BAND's token. */
  gasInBandToken?: bigint;
}): number | null {
  const { band } = args;
  const margin = BigInt(args.minProfitBps ?? 0);
  if (margin < 0n) throw new Error("minProfitBps must be non-negative");
  const gas = args.gasInBandToken ?? 0n;
  if (gas < 0n) throw new Error("gasInBandToken must be non-negative");

  // Gas is a cost, and the bump is the only lever a solver has to express it —
  // so it moves the bid in whichever direction that side's band runs:
  //   SELL (falling output) — the solver DELIVERS less, so gas comes off what
  //                           its route left it to deliver with.
  //   BUY  (rising input)   — the solver TAKES more, so gas adds to what the
  //                           maker must pay it.
  // Applied BEFORE the margin, because margin is profit on the net, not on the
  // gross. Both are floored/ceiled toward the solver being able to honour the bid.
  const available = band.rising ? args.available + gas : args.available - gas;
  // Gas alone exceeding the route's output is not a bid at any price.
  if (available <= 0n) return null;

  const span = band.rising ? band.end - band.start : band.start - band.end;
  if (span < 0n) throw new Error("band is signed the wrong way round");
  // A fixed leg (no span) admits exactly one price: bid 0 if it clears, else nothing.
  if (span === 0n) {
    return band.rising ? (available >= band.start ? 0 : null) : available >= band.start ? 0 : null;
  }

  let bump: bigint;
  if (band.rising) {
    // The solver needs to RECEIVE at least `available` (its cost) from the maker.
    // required(b) = start + span·b/BPS  ≥  cost·(BPS+margin)/BPS
    const needed = (available * (BPS + margin)) / BPS;
    if (needed <= band.start) bump = 0n;
    else bump = ceilDiv((needed - band.start) * BPS, span);
  } else {
    // The solver must DELIVER `required(b)` and holds `available`.
    // required(b) = start − span·b/BPS  ≤  available·BPS/(BPS+margin)
    const affordable = (available * BPS) / (BPS + margin);
    if (affordable >= band.start) bump = 0n;
    else bump = ceilDiv((band.start - affordable) * BPS, span);
  }
  if (bump > BPS) return null; // cannot clear even at the maker's floor
  return Number(bump);
}

/** The leg a solver is quoting, resolved from the order. */
export interface PricedLeg {
  band: PricedBand;
  /** The band's denomination. `minimumBump`'s `available` and `gasInBandToken`
   *  are BOTH in this token — mixing denominations there is silent mispricing,
   *  which is why the field exists rather than being inferred at the call site. */
  bandToken: Address;
  tokenIn: Address;
  tokenOut: Address;
  /** What to quote the route FOR (a `tokenIn` amount, both sides). */
  amountIn: bigint;
  side: OrderSide;
  /** BUY only: the FIXED output the solver must deliver, in `tokenOut`. A BUY
   *  order's band is on the input leg, so the route's `amountOut` is not the
   *  solver's cost — this is what converts one into the other. `0n` on SELL. */
  requiredOut: bigint;
}

/**
 * The band an order prices on, and the input a solver receives for a full fill.
 *
 * Single-leg orders only — a multi-leg order needs the caller to decide which
 * leg it is quoting, and guessing would silently misprice. Returns `null` for
 * shapes this helper will not price.
 */
export function pricedLegOf(order: Order): PricedLeg | null {
  if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return null;
  const legIn = order.legsIn[0]!;
  const legOut = order.legsOut[0]!;
  if (order.side === OrderSide.SELL) {
    if (legOut.end === 0n) return null; // fixed output — nothing decays, no bump to bid
    return {
      band: { start: legOut.start, end: legOut.end, rising: false },
      // A SELL order's band is its OUTPUT leg, so gas is denominated there.
      bandToken: legOut.token,
      tokenIn: legIn.token,
      tokenOut: legOut.token,
      amountIn: anchorTotal(order),
      side: OrderSide.SELL,
      requiredOut: 0n,
    };
  }
  if (legIn.end === 0n) return null;
  return {
    band: { start: legIn.start, end: legIn.end, rising: true },
    // A BUY order's band is its INPUT leg — the side the solver is paid on.
    bandToken: legIn.token,
    tokenIn: legIn.token,
    tokenOut: legOut.token,
    amountIn: legIn.end, // the most the maker will pay; the solver bids down from it
    side: OrderSide.BUY,
    // BUY outputs are FIXED — `legOut.start` is exactly what must be delivered.
    requiredOut: legOut.start,
  };
}

/**
 * The solver's COST for this leg, in the BAND's token — the quantity
 * {@link minimumBump} wants as `available`.
 *
 * ⚠ THE TWO SIDES ARE NOT SYMMETRIC, and treating them as one is a silent
 * mispricing rather than a visible error:
 *
 *   • SELL — the band is the OUTPUT leg, so the route's `amountOut` already IS
 *     the band-denominated quantity the solver has to deliver with. Pass it
 *     through.
 *   • BUY — the band is the INPUT leg. The route's `amountOut` is in `tokenOut`,
 *     which is neither the right quantity (it is an output, not a cost) nor the
 *     right denomination (the band and `gasInBandToken` are in `tokenIn`). The
 *     cost is the `tokenIn` needed to produce `requiredOut`, interpolated from
 *     the quote the solver actually holds.
 *
 * Returns `null` when the route cannot produce the fixed output at all — not a
 * price the solver should bid at any bump.
 */
export function costInBandToken(leg: PricedLeg, quote: RouteQuote): bigint | null {
  if (leg.side === OrderSide.SELL) return quote.amountOut;
  // The route was quoted for `leg.amountIn` (the band's ceiling) and yielded
  // `quote.amountOut`. Linear interpolation is the honest read of a single
  // quote — it is exact for a constant price and CONSERVATIVE (over-states the
  // cost) for any convex venue, so the resulting bid is never too low.
  if (quote.amountOut <= 0n) return null;
  if (quote.amountOut < leg.requiredOut) return null; // cannot fill at any bump
  return ceilDiv(leg.amountIn * leg.requiredOut, quote.amountOut);
}

/**
 * What a fill costs the solver in gas, and how to price it.
 *
 * `gasPriceWei` and the rate are the caller's to keep fresh — this package does
 * no chain reads. Supply `nativePriceInToken` when you already track the rate;
 * omit it and the solver resolves one through its own route sources, which
 * costs one extra quote per distinct band token.
 */
export interface GasConfig {
  /** Effective wei per gas the solver expects to pay. */
  gasPriceWei: bigint;
  /**
   * Settlement-side gas, on top of whatever the route reports. A plain fill is
   * ~200k; a route with items or a callback is more. MEASURE it — an
   * understated overhead is a bid the solver cannot profitably honour.
   */
  settlementGasUnits?: bigint;
  /** Fallback route gas when a source reports none (Nordstern does not). */
  routeGasUnits?: bigint;
  /** Band-token units per 1e18 wei of native. Omit to resolve live. */
  nativePriceInToken?: bigint;
  /** Native placeholder for the live rate lookup. Default the zero address. */
  nativeToken?: Address;
}

export interface SolverConfig {
  /** Signs bids. Its address IS the filler the bid commits. */
  account: QuoteSigner;
  /** The quote module instance + chain the round is bound to. */
  binding: QuoteBinding;
  /** Price sources, tried in parallel; the best quote wins. */
  routes: RouteSource[];
  /** Margin over break-even, in bps. Default 0 — honest Vickrey bidding. */
  minProfitBps?: number;
  /**
   * WHO THE ROUTE IS QUOTED FOR — the address that will hold the input and
   * receive the swap output at fill time. Aggregators bake the recipient (and
   * often the sender) into the calldata they return, so this must be whatever
   * actually executes:
   *
   *   • an `AggregatorFillSolver` (or any callback solver) → THAT CONTRACT
   *   • an inventory solver filling from its own balance    → the EOA
   *
   * Defaults to the bidding account, which is right ONLY for the inventory
   * model. Quoting for the EOA and then executing through a contract sends the
   * swap output to the EOA and the fill reverts `InsufficientOutput` — the funds
   * are not lost, but the round is.
   */
  recipient?: Address;
  /** Gas costing. Omit only if gas is genuinely free — it never is on a fill. */
  gas?: GasConfig;
  onError?: (source: string, err: unknown) => void;
}

/**
 * Where the input amount sits inside a route's calldata, for the on-chain
 * `RoutePlan.amountInOffset`.
 *
 * The priced amount is resolved DURING the fill — it rises with the clock on a
 * BUY order, comes from the maker's live balance on a proportional leg, and
 * shrinks on a partial fill sized after the quote. The aggregator's bytes carry
 * whatever was quoted, so a solver executing through
 * `AggregatorFillSolver` should hand it the offset and let the contract rewrite
 * the amount to what actually arrived.
 *
 * `null` (the default) means "use the calldata verbatim", which is correct for a
 * fixed-input SELL order filled in full — there the quoted figure is already
 * exact.
 */
export const NO_PATCH = null;

export interface SolverBid {
  bid: SignedBid;
  bumpBps: number;
  /** The route the bid was priced from — execute THIS if the bid wins. */
  quote: RouteQuote;
  /** Gas folded into the bid, in the band's token. `0n` when gas was not costed. */
  gasInBandToken: bigint;
}

/**
 * A default solver: price an order across its route sources, and bid the
 * smallest bump it can honour.
 *
 * It does NOT execute. The winner's fill is the caller's — it holds the route
 * payload, the private key, and the gas policy, and this class deliberately
 * touches none of them.
 */
export class QuoteSolver {
  constructor(private readonly config: SolverConfig) {}

  /** Best quote across every source. Dead sources are skipped, not fatal. */
  async bestRoute(req: RouteRequest): Promise<RouteQuote | null> {
    const settled = await Promise.all(
      this.config.routes.map(async (src) => {
        try {
          const q = await src.quote(req);
          return q ? { ...q, source: q.source ?? src.name } : null;
        } catch (err) {
          this.config.onError?.(src.name, err);
          return null;
        }
      }),
    );
    let best: RouteQuote | null = null;
    for (const q of settled) {
      if (q && (best === null || q.amountOut > best.amountOut)) best = q;
    }
    return best;
  }

  /**
   * Price an order and produce a signed bid, or `null` when this solver cannot
   * serve it — an unpriceable shape, no route, or a route that cannot clear the
   * maker's floor. Not bidding is a first-class outcome: winning a round you
   * cannot fill costs the maker the improvement and costs you your reputation.
   */
  async bidFor(order: Order, round: { orderHash: Hex; closesAt: number }): Promise<SolverBid | null> {
    const leg = pricedLegOf(order);
    if (leg === null) return null;

    const quote = await this.bestRoute({
      chainId: this.config.binding.chainId,
      tokenIn: leg.tokenIn,
      tokenOut: leg.tokenOut,
      amountIn: leg.amountIn,
      recipient: this.config.recipient ?? this.config.account.address,
    });
    if (quote === null) return null;

    // The route's output is NOT the solver's cost on a BUY order — see
    // {costInBandToken}. Converting here is what keeps `available`, `band` and
    // `gasInBandToken` in one denomination.
    const cost = costInBandToken(leg, quote);
    if (cost === null) return null;

    const gas = await this.gasFor(leg.bandToken, quote);
    // A gas policy that cannot resolve a rate must NOT silently price the fill
    // as free — that is a bid the solver loses money honouring.
    if (gas === null) return null;

    const bumpBps = minimumBump({
      band: leg.band,
      available: cost,
      gasInBandToken: gas,
      ...(this.config.minProfitBps !== undefined ? { minProfitBps: this.config.minProfitBps } : {}),
    });
    if (bumpBps === null) return null;

    const bid = await signBid(
      this.config.account,
      {
        orderHash: round.orderHash,
        filler: this.config.account.address,
        bumpBps,
        closesAt: round.closesAt,
      },
      this.config.binding,
    );
    return { bid, bumpBps, quote, gasInBandToken: gas };
  }

  /**
   * The fill's gas cost in `bandToken`, or `null` when it cannot be priced.
   *
   * Route gas comes from the source when it reports one (Sushi's `tx.gas`),
   * else `routeGasUnits`; the settlement's own overhead is added on top,
   * because the solver pays for both in one transaction.
   */
  private async gasFor(bandToken: Address, quote: RouteQuote): Promise<bigint | null> {
    const cfg = this.config.gas;
    if (!cfg) return 0n;

    const gasUnits =
      (quote.gasUnits ?? cfg.routeGasUnits ?? 0n) + (cfg.settlementGasUnits ?? 200_000n);

    let rate = cfg.nativePriceInToken;
    if (rate === undefined) {
      const resolved = await nativePriceVia({
        routes: this.config.routes,
        chainId: this.config.binding.chainId,
        token: bandToken,
        ...(this.config.recipient ? { recipient: this.config.recipient } : {}),
        ...(cfg.nativeToken ? { nativeToken: cfg.nativeToken } : {}),
      });
      if (resolved === null) return null;
      rate = resolved;
    }
    return gasInBandToken({ gasUnits, gasPriceWei: cfg.gasPriceWei, nativePriceInToken: rate });
  }
}

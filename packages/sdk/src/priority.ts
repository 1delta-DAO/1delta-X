import { FILL_ONCE_BIT } from "./oco";
import { anchorTotal } from "./pricing";
import {
  type Order,
  PRIORITY_AUCTION_BIT,
  timingFlags,
  unpackTiming,
  withPriorityAuction,
} from "./types";

/** Does `minFillAnchor` sit above the fill denominator, making every fill revert
 *  `FillTooSmall`? Returns false when the anchor cannot be resolved off-chain (a
 *  {@link isProportional} marker needs the maker's live balance), so the lint
 *  falls back to the softer "inert" wording rather than guessing. */
function unfillableFloor(order: Order): boolean {
  try {
    return order.minFillAnchor > anchorTotal(order);
  } catch {
    return false;
  }
}

/**
 * PRIORITY-AUCTION orders — the bump is bid in priority fee rather than elapsed
 * time (`timing` bit 103), for chains whose sequencer orders transactions by tip
 * (OP-stack, Arbitrum timeboost). The parity feature with UniswapX's
 * `PriorityOrderReactor`.
 *
 * ══ WHY THIS MODULE EXISTS, AND WHY THE DEFAULT IS ALL-OR-NOTHING ══
 *
 * Every other pricing mode here is a function of the CLOCK, so two partial fills
 * of one order price by *when* they happened. A priority auction is different in
 * kind: the bump is resolved from the filling transaction's OWN tip and pinned
 * once per fill. Two slices submitted at different tips therefore clear at
 * DIFFERENT ticks, in the same block, with no clock movement — the maker's
 * realised average price depends on how the solver chose to slice.
 *
 * That turns the auction into a different mechanism:
 *
 *   UniswapX priority       single-unit FIRST-PRICE   maker gets the TOP bid
 *   ours, partially fillable  multi-unit PAY-AS-BID   maker gets the quantity-
 *                                                     weighted AVERAGE of bids
 *
 * Pay-as-bid multi-unit auctions are perfectly respectable (treasury auctions run
 * this way) and partial fills genuinely broaden the bidder pool — an inventory-
 * constrained solver can bid at all, where UniswapX excludes it. But the expected
 * clearing price is LOWER, because an average is bounded above by the maximum.
 *
 * `PriorityOrderReactor` sidesteps the question entirely by being all-or-nothing:
 * it keeps no filled-amount accounting and consumes the order through a Permit2
 * nonce bit, so "only the fill transaction with the highest priority fee will win
 * the order, all other transactions will revert onchain".
 *
 * **So {@link priorityOrder} sets FILL-ONCE by default.** Anyone porting a
 * priority order from UniswapX gets UniswapX's economics, which is what they
 * expect. Partial fills remain available behind an explicit
 * `partiallyFillable: true`, because the maker who wants them should be choosing
 * them rather than inheriting them.
 *
 * ⚠ There is NO safety difference between the two — this is purely about the
 * clearing price. Every slice is priced inside the maker's signed band, and a
 * solver's cheapest schedule (every slice unbid) clears at the floor, which is
 * exactly what one unbid fill of the whole order would have paid. Slicing buys a
 * solver nothing it could not already have. Unlike a *time* dutch auction, there
 * is no waiting strategy: each slice is priced at its own transaction's tip.
 *
 * See `docs/pricing-modes.md` and `docs/edge-case-matrix.md` §G-8.
 */

export interface PriorityAuctionOptions {
  /**
   * Wei of priority fee that buys a FULL bump — the maker moves from `end` (the
   * guaranteed floor, what an unbid fill pays) to `start` (the ambition).
   * MANDATORY: the settler reverts `InvalidAuctionParams` on a zero scale, since
   * an order that opts into the auction without one is malformed rather than
   * merely unbid.
   */
  priorityScale: bigint;
  /**
   * The tip that does NOT count as a bid — UniswapX's field of the same name.
   * Subtract whatever the chain wants just to INCLUDE a transaction, or every
   * ordinary tip reads as an aggressive bid. `uint48`, so at most ~281,474 gwei.
   */
  baselinePriorityFeeWei?: bigint;
  /**
   * Opt OUT of the all-or-nothing default and allow partial fills.
   *
   * Read the module note first: this changes the auction from single-unit
   * first-price to multi-unit pay-as-bid, and the maker's realised price from the
   * top bid to the quantity-weighted average of accepted bids. Set
   * {@link PriorityAuctionOptions.minFillAnchor} alongside it to bound how finely
   * the order can be diluted.
   */
  partiallyFillable?: boolean;
  /**
   * Anti-dust floor per fill, in anchor units. Its job is on a PARTIALLY
   * FILLABLE order, where it bounds how many bids the maker's average is diluted
   * across; {@link lintPriorityOrder} reports a partially fillable priority order
   * that leaves it at zero.
   *
   * Passed through untouched on an all-or-nothing order too, where it is inert
   * rather than wrong (`== anchor` is a redundant restatement of fill-once, and
   * anything above the anchor makes the order unfillable — which the settler and
   * `SettlementLens.validateOrder` already catch). The lint mentions it; this
   * builder does not rewrite a maker-signed field to tidy it away.
   */
  minFillAnchor?: bigint;
}

/** Whether an order opted into the priority auction (`timing` bit 103). */
export function isPriorityAuction(order: Order): boolean {
  return ((order.timing >> PRIORITY_AUCTION_BIT) & 1n) === 1n;
}

/**
 * Stamp an order as a priority auction, **all-or-nothing by default**.
 *
 * ══ WHAT THROWS HERE vs WHAT ONLY LINTS ══
 *
 * The rule is one line: **this throws only where the SETTLER reverts.** Failing at
 * build time on an order that could never fill is strictly earlier failure of an
 * already-doomed order; failing on one that would fill perfectly well is the SDK
 * inventing a rule the protocol does not have.
 *
 *   THROWS — the settler reverts `InvalidAuctionParams` on both:
 *     • `priorityScale == 0`  — an order opting into the auction without a scale
 *                               is malformed, not merely unbid;
 *     • `gasBumpBps != 0`     — the basefee bump moves the tick toward `end` while
 *                               the bid moves it toward `start`. The settler says
 *                               so rather than silently drop one signed parameter.
 *
 *   LINTS — {@link lintPriorityOrder} — everything that is merely INERT under a
 *     priority auction (a decay duration, a curve, a `minFillAnchor` on an
 *     all-or-nothing order) or economically noteworthy (pay-as-bid slicing). These
 *     mirror `SettlementLens.validateOrder`'s priority branch, so a builder can get
 *     the same answer without an RPC round trip.
 *
 * That split is the house convention, not a new one: the settler reverts only on
 * CONTRADICTIONS, the lens reports PROVABLY INERT fields, and neither invents a
 * rule for a field it cannot prove is unread. It also matches the two references —
 * UniswapX's `_validateOrder` reverts on contradictions (`InputAndOutputDecay`,
 * `InputOutputScaling`) and has no advisory tier at all, while CoW validates almost
 * nothing on-chain (a malformed order can only harm its own maker) and puts every
 * shape opinion in the off-chain order book.
 *
 * Nothing else about the order is rewritten: this sets the mode, the scale and the
 * fill semantics, and leaves every other maker-signed field exactly as given.
 */
export function priorityOrder<T extends Order>(order: T, opts: PriorityAuctionOptions): T {
  if (opts.priorityScale === 0n) {
    throw new Error(
      "priorityOrder: priorityScale must be non-zero (the settler reverts InvalidAuctionParams) — it is the wei of priority fee that buys a full bump",
    );
  }
  if (order.gasBumpBps !== 0n) {
    throw new Error(
      "priorityOrder: gasBumpBps must be 0 under a priority auction — the basefee bump moves the tick toward `end` while the bid moves it toward `start`, and the settler reverts InvalidAuctionParams rather than drop one of them",
    );
  }
  const partial = opts.partiallyFillable === true;
  // FILL-ONCE unless the caller explicitly asked for partials. See the module note.
  let timing = withPriorityAuction(order.timing);
  timing = partial ? timing & ~FILL_ONCE_BIT : timing | FILL_ONCE_BIT;
  return {
    ...order,
    timing,
    priorityScale: opts.priorityScale,
    baselinePriorityFeeWei: opts.baselinePriorityFeeWei ?? order.baselinePriorityFeeWei ?? 0n,
    // PASSED THROUGH, never rewritten. On an all-or-nothing order a
    // `minFillAnchor` at or below the anchor is inert — the delta is always the
    // whole anchor — but inert is not wrong, and `minFillAnchor == anchor` is a
    // legitimate (if redundant) second way of saying "full fill only", which is
    // how `FillUpTo.t.sol` expresses it without the bit. Silently zeroing a
    // MAKER-SIGNED field to tidy up would change the order hash behind the
    // author's back; {lintPriorityOrder} says so instead. See the tiering note.
    minFillAnchor: opts.minFillAnchor ?? order.minFillAnchor,
  };
}

/**
 * Non-fatal diagnostics for a priority order — the advice that is a judgement
 * call rather than a contract rule, so it is reported rather than thrown.
 *
 * Returns an empty array for a well-formed order. Order builders should surface
 * these; nothing here blocks signing.
 */
export function lintPriorityOrder(order: Order): string[] {
  const out: string[] = [];
  if (!isPriorityAuction(order)) return out;
  const flags = timingFlags(order.timing);

  if (order.priorityScale === 0n) {
    out.push("priorityScale is 0 — the settler will revert InvalidAuctionParams; this order can never fill.");
  }
  if ((order.baselinePriorityFeeWei ?? 0n) === 0n) {
    out.push(
      "baselinePriorityFeeWei is 0, so every wei of the chain's ordinary inclusion tip is read as an auction bid. Set it to what the chain currently wants just to include a transaction, or priorityScale stops being a pure economic parameter.",
    );
  }
  if (!flags.fillOnce) {
    out.push(
      "partially fillable priority order: slices clear at their own tips, so the maker realises the quantity-weighted AVERAGE of accepted bids rather than the top bid (multi-unit pay-as-bid, not UniswapX's single-unit first-price). Intentional? If not, set fill-once.",
    );
    if (order.minFillAnchor === 0n) {
      out.push(
        "…and minFillAnchor is 0, so there is no bound on how finely that average can be diluted. Set it to the smallest slice worth filling.",
      );
    }
  } else if (order.minFillAnchor !== 0n) {
    // INERT, not wrong — hence a note rather than a throw or a silent rewrite.
    // The delta on a fill-once order is always the whole anchor, so any floor at
    // or below the anchor can never bind. `== anchor` is a deliberate, redundant
    // restatement of fill-once and is fine; anything ABOVE the anchor makes the
    // order unfillable, which the settler (`FillTooSmall`) and
    // `SettlementLens.validateOrder` ("minFillAnchor > anchor (unfillable)")
    // already catch — repeated here only so a builder sees it before signing.
    out.push(
      unfillableFloor(order)
        ? "minFillAnchor exceeds the fill anchor, so EVERY fill reverts FillTooSmall — this order can never fill. (An all-or-nothing order needs no floor at all.)"
        : "minFillAnchor is set on an all-or-nothing order, where it can never bind: the delta is always the whole anchor. Harmless — `== anchor` is a redundant way of saying the same thing — but drop it, or drop fill-once, if a floor was the intent.",
    );
  }

  // The rest of the clock is INERT under a priority auction: the bump comes from
  // the bid, so the curve and the decay window never run. Mirrors the lens's
  // "decay duration with priority auction" / "curve with priority auction".
  // `decayStartTime` is deliberately NOT flagged — it keeps its "not before"
  // meaning and is the documented way to write "not fillable before block N,
  // then bid".
  if (unpackTiming(order.timing).decayDuration !== 0) {
    out.push(
      "decayDuration is set on a priority auction, where the clock never runs — the bump comes from the bid. It is inert (decayStartTime, by contrast, keeps its 'not before' meaning).",
    );
  }
  if (order.curve.length !== 0) {
    out.push("a decay curve is set on a priority auction, where it never runs — the bump comes from the bid.");
  }
  if (BigInt(order.pricingModule) !== 0n) {
    out.push(
      "an IPriceModule is set alongside the priority auction; the settler silently prefers the MODULE, so the priority bid is dead. The lens rejects this shape outright.",
    );
  }
  if (order.legsOut.some((l) => l.end === 0n)) {
    out.push(
      "an output leg is FIXED (end == 0), so the bid buys the maker nothing on that leg — a priority auction only moves legs that carry a band.",
    );
  }
  return out;
}

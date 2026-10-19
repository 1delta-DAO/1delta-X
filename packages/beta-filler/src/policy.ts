import {
  BLOCK_CLOCK_BIT,
  classifyItemFill,
  DELTA_VERIFY_OUTPUTS_BIT,
  forLegPreFund,
  isFillOnce,
  isProportional,
  ItemOp,
  OrderSide,
  overrideHasCarrier,
  unpackTiming,
  type ItemFillCaps,
  type Order,
} from "@1delta-x/sdk";
import { decodeAbiParameters, zeroAddress, type Address } from "viem";

import { MOC_FEE_BPS, type Config, type Policy } from "./config";
import type { SpendEntry } from "./state";

/**
 * Pure decision logic: which orders this filler takes, at what size and price.
 * Everything chain-dependent (previews, quotes, balances) is passed in, so the
 * whole policy is unit-testable.
 */

/**
 * `buyUsdrif`: the maker sells USDRIF, we pay USDT0. `sellUsdrif`: the maker buys USDRIF,
 * we deliver it. `sellRif`: the maker buys RIF with USDT0, we deliver RIF from the float
 * (the RIF rail — priced at its MoC replacement cost, {@link railUsdrifFor}). `buyRif`:
 * the maker sells RIF for USDT0, we pay USDT0 and keep the RIF ({@link rifBand}).
 * `sellRifUsdrif`: the maker buys RIF with USDRIF — we deliver RIF and replace it with
 * one `redeemTP` of the USDRIF received (no pool leg at all).
 */
export type Direction = "buyUsdrif" | "sellUsdrif" | "sellRif" | "buyRif" | "sellRifUsdrif";

/** The rail directions that deliver RIF from the wallet. */
export function sellsRif(direction: Direction): direction is "sellRif" | "sellRifUsdrif" {
  return direction === "sellRif" || direction === "sellRifUsdrif";
}

/** Whether we PAY USDT0 in this direction (the maker sells us USDRIF / RIF). */
export function paysUsdt0(direction: Direction): boolean {
  return direction === "buyUsdrif" || direction === "buyRif";
}

export type Verdict<T> = ({ ok: true } & T) | { ok: false; reason: string };

const ONE = 10n ** 18n;
/** USDT0 (6 dec) → 18-dec scale factor. */
const USDT0_TO_18 = 10n ** 12n;

/** What {@link plainShape} may admit beyond the plain shape — each off unless given. */
export interface ShapeExtras {
  hasPermitBatch?: boolean;
  sigless?: boolean;
  /** The NativeUnwrapModule item shape (task 28) — recognised; routable only through an item fill. */
  nativeUnwrap?: { module: Address; wrapped: Address };
  /**
   * NATIVE delivery through the `NativeBalance` view (task 30): a DIRECT order whose only
   * output leg is `view`, routed as `wrapped` and unwrapped by the solver. Unset = off.
   */
  nativeBalance?: { view: Address; wrapped: Address };
  /**
   * Item fills through `executeItemFill` (task 31), with the target Settlement's
   * capabilities (SDK `classifyItemFill`). Unset = every item refused.
   */
  itemFills?: ItemFillCaps;
}

/** What {@link plainShape} found beyond the plain shape. */
export interface ShapeInfo {
  /** The NativeUnwrapModule item shape (task 28). */
  nativeOut?: boolean;
  /** …and why it is not an item fill (it is then not routable). */
  itemSkip?: string;
  /** NATIVE delivery through the NativeBalance view (task 30). */
  nativeBalance?: boolean;
  /** An item fill: `executeItemFill`'s `lateItems` (SDK `classifyItemFill`). */
  itemFill?: { lateItems: bigint };
}

/**
 * The plain one-in/one-out shape the beta app signs, minus the delivery-mode and
 * exclusivity checks (which differ per strategy). Every extra feature (items,
 * validators, modules, fee legs, proportional legs, single-signature permits) is a
 * way for the price we preview to differ from what we pay, so in the beta we
 * simply do not take it — except, each behind its own switch in `extras`:
 *   • NATIVE delivery (`nativeBalance`): the output leg is the `NativeBalance` view,
 *     DIRECT only, to the maker, no items — returned as `nativeBalance: true`;
 *   • ITEM fills (`itemFills`): an item-bearing PULL order the SDK classifier schedules
 *     for `executeItemFill` — returned as `itemFill.lateItems`. Validators and
 *     invariants are admitted on that path (they can only revert, and the fill is
 *     simulated first), and the output leg may go to the module of an item that
 *     consumes it (a pre-funded MAKE, a leg-reference TAKE_FOR);
 *   • the NativeUnwrapModule shape (`nativeUnwrap`) — `nativeOut: true`, routable only
 *     when it is also an item fill (route.ts `classifyRoute`).
 * Shared by the inventory and route strategies (the inventory passes no switches).
 */
export function plainShape(
  order: Order,
  extras: ShapeExtras = {},
): Verdict<ShapeInfo> {
  if (extras.hasPermitBatch) return { ok: false, reason: "single-signature permit orders not supported" };
  if (extras.sigless) return { ok: false, reason: "on-chain-approved (sigless) orders not supported" };
  if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return { ok: false, reason: "not one-in/one-out" };
  if (order.fillModule !== zeroAddress || order.pricingModule !== zeroAddress) {
    return { ok: false, reason: "fill/pricing modules not supported" };
  }
  const legIn = order.legsIn[0]!;
  const legOut = order.legsOut[0]!;
  if (isProportional(legIn.start)) return { ok: false, reason: "proportional (balance-relative) leg" };
  const toMaker = legOut.recipient === zeroAddress || eqAddr(legOut.recipient, order.maker);

  // NATIVE DELIVERY through the NativeBalance view (task 30) — exactly the app's shape.
  const nb = extras.nativeBalance;
  if (nb && eqAddr(legIn.token, nb.view)) return { ok: false, reason: "NativeBalance as an input leg (a balance view cannot be pulled)" };
  if (nb && eqAddr(legOut.token, nb.view)) {
    if (order.items.length) return { ok: false, reason: "native (NativeBalance) order with items" };
    if (order.validators.length || order.invariants.length) return { ok: false, reason: "validators/invariants not supported" };
    if (!isDeltaVerify(order)) return { ok: false, reason: "a NativeBalance output needs DIRECT delivery (it cannot be pulled)" };
    if (eqAddr(legIn.token, nb.wrapped)) return { ok: false, reason: "native-out from the wrapped native coin (an unwrap, not a swap)" };
    if (!toMaker) return { ok: false, reason: "native output goes to a third party" };
    return { ok: true, nativeBalance: true };
  }

  if (order.items.length) {
    // The NativeUnwrapModule shape (task 28) is recognised; it routes only as an item fill.
    const module = extras.nativeUnwrap ? nativeOutShape(order, extras.nativeUnwrap.module, extras.nativeUnwrap.wrapped).ok : false;
    if (!extras.itemFills) return module ? { ok: true, nativeOut: true, itemSkip: "item fills are off (ITEM_FILLS)" } : { ok: false, reason: "items not supported" };
    const c = classifyItemFill(order, extras.itemFills);
    if (c.path !== "executeItemFill") {
      const why = c.path === "skip" ? c.reason : "no item path";
      return module ? { ok: true, nativeOut: true, itemSkip: why } : { ok: false, reason: `item fill: ${why}` };
    }
    // The leg may go to the maker, or to the module of an item that consumes it.
    if (!toMaker) {
      const sink = order.items.some((it, k) => eqAddr(it.module, legOut.recipient) && (c.roles[k]!.kind === "make-prefund" || c.roles[k]!.kind === "take-for-leg"));
      if (!sink) return { ok: false, reason: "output goes to a third party" };
    }
    return { ok: true, itemFill: { lateItems: c.lateItems }, ...(module ? { nativeOut: true } : {}) };
  }
  if (order.validators.length || order.invariants.length) return { ok: false, reason: "validators/invariants not supported" };
  if (!toMaker) return { ok: false, reason: "output goes to a third party" };
  return { ok: true };
}

const eqAddr = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * NATIVE-OUT (task 28): the maker receives raw RBTC. Exactly the shape the app signs:
 * the single output leg is the wrapped native coin, addressed to `module` (the deployed
 * NativeUnwrapModule), plus ONE MAKE item on that module — amount 0 (sized from the
 * fill's delivery ledger), the pre-fund leg reference `forLegPreFund(0, wrapped, 0)` and a
 * payout of the maker (`0x0` or the maker's own address; never a third party). PULL only:
 * a delta-verify order would measure the module's balance, which the item empties.
 */
export function nativeOutShape(order: Order, module: Address, wrapped: Address): Verdict<{}> {
  const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  if (order.items.length !== 1 || order.legsOut.length !== 1) return { ok: false, reason: "native-out: one item and one output leg" };
  const it = order.items[0]!;
  const leg = order.legsOut[0]!;
  if (it.op !== ItemOp.MAKE || !eq(it.module, module)) return { ok: false, reason: "item is not our NativeUnwrapModule's MAKE" };
  if (it.amount !== 0n || it.recipient !== zeroAddress) return { ok: false, reason: "native-out: item amount/recipient must be 0" };
  if (!eq(leg.token, wrapped) || !eq(leg.recipient, module)) return { ok: false, reason: "native-out: the leg must deliver the wrapped native coin to the module" };
  if (isDeltaVerify(order)) return { ok: false, reason: "native-out orders are pull delivery" };
  let desc: bigint;
  let payout: Address;
  try {
    [desc, payout] = decodeAbiParameters([{ type: "uint256" }, { type: "address" }], it.data);
  } catch {
    return { ok: false, reason: "native-out: undecodable item data" };
  }
  if (it.data.length !== 2 + 128) return { ok: false, reason: "native-out: item data must be exactly (descriptor, payout)" };
  if (desc !== forLegPreFund(0, wrapped as `0x${string}`, 0)) return { ok: false, reason: "native-out: wrong leg reference" };
  if (payout !== zeroAddress && !eq(payout, order.maker)) return { ok: false, reason: "native-out: payout to a third party" };
  return { ok: true };
}

/** Whether the order carries timing bit 104 (delta-verify / direct delivery). */
export function isDeltaVerify(order: Order): boolean {
  return ((order.timing >> DELTA_VERIFY_OUTPUTS_BIT) & 1n) === 1n;
}

/**
 * How `me` stands against a PULL order's exclusivity at `nowS` (unix seconds) — the
 * off-chain reading of `OrderGates.exclusivityOverride`:
 *   • `open`      — no `exclusiveFiller`, the window is over, or we ARE the named filler;
 *   • `soft`      — another filler's window is still running, but it is SOFT: the
 *                   core lets us fill by paying `exclusivityOverrideBps` to the maker
 *                   (a carrier leg exists, override in (0, 10 000]). The lens previews
 *                   it for `filler = me`, so every price / profit gate downstream sees
 *                   the premium — nothing else has to price it;
 *   • `hard`      — another filler's window is running and the core would refuse us
 *                   (`NotExclusiveFiller`): override 0, nothing to carry it, or a
 *                   block-clocked window we cannot place on the wall clock.
 * Delta-verify orders are NOT read here (their exclusivity is whole-life, Core F30).
 *
 * Why this matters (B13, 2026-10-06): the app's PULL markets name the deployment's
 * SOLVER contract with a ~2-block soft window. The inventory strategy fills as our
 * EOA, so inside that window it is an outsider like any other — it may fill at the
 * premium (the maker is better off, and the preview prices it), or wait the ≤ 2
 * blocks for the window to end; the engine re-quotes a held order the moment its
 * window ends ({@link windowEndMs}).
 */
export function exclusivityFor(
  order: Order,
  me: Address,
  nowS: bigint,
): { kind: "open" } | { kind: "soft"; endsAt: bigint; overrideBps: bigint } | { kind: "hard"; endsAt?: bigint } {
  const ex = order.exclusiveFiller;
  if (ex === zeroAddress || ex.toLowerCase() === me.toLowerCase()) return { kind: "open" };
  const endsAt = BigInt(unpackTiming(order.timing).exclusivityEndTime);
  const blockClock = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n;
  if (!blockClock && nowS >= endsAt) return { kind: "open" };
  const bps = order.exclusivityOverrideBps;
  if (blockClock) return { kind: "hard" };
  if (bps === 0n || bps > 10_000n || !overrideHasCarrier(order)) return { kind: "hard", endsAt };
  return { kind: "soft", endsAt, overrideBps: bps };
}

/**
 * When a held order should be re-quoted because its exclusivity window ends — the one
 * moment its price steps in an outsider's favour (the premium drops away, a hard
 * window opens). `undefined` when there is no running timestamp-clocked window.
 */
export function windowEndMs(order: Order, nowMs: number): number | undefined {
  if (order.exclusiveFiller === zeroAddress || isDeltaVerify(order)) return undefined;
  if (((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n) return undefined;
  const end = unpackTiming(order.timing).exclusivityEndTime * 1000;
  return end > nowMs ? end : undefined;
}

/**
 * INVENTORY strategy: the plain shape, pull delivery only (an EOA cannot run the
 * callback a delta-verify order needs), on the USDRIF/USDT0 pair, and fillable by
 * this wallet NOW: open, exclusive to this wallet, or inside another filler's SOFT
 * window (priced at the override by the preview — see {@link exclusivityFor}).
 */
export function classify(
  order: Order,
  cfg: Pick<Config, "tokens"> & { policy: Pick<Policy, "buyUsdrif" | "sellUsdrif"> & Partial<Pick<Policy, "sellRif" | "buyRif">> },
  me: Address,
  extras: { hasPermitBatch?: boolean; sigless?: boolean; nowS?: bigint } = {},
): Verdict<{ direction: Direction }> {
  const shape = plainShape(order, extras);
  if (!shape.ok) return shape;
  if (isDeltaVerify(order)) {
    return { ok: false, reason: "delta-verify order: needs a callback filler, an EOA cannot fill it" };
  }
  const ex = exclusivityFor(order, me, extras.nowS ?? BigInt(Math.floor(Date.now() / 1000)));
  if (ex.kind === "hard") {
    return { ok: false, reason: `exclusive to another filler (hard window${ex.endsAt !== undefined ? ` until ${ex.endsAt}` : ""})` };
  }
  const tin = order.legsIn[0]!.token.toLowerCase();
  const tout = order.legsOut[0]!.token.toLowerCase();
  const usdrif = cfg.tokens.usdrif.toLowerCase();
  const usdt0 = cfg.tokens.usdt0.toLowerCase();
  if (tin === usdrif && tout === usdt0) {
    return cfg.policy.buyUsdrif ? { ok: true, direction: "buyUsdrif" } : { ok: false, reason: "buy side disabled" };
  }
  if (tin === usdt0 && tout === usdrif) {
    return cfg.policy.sellUsdrif ? { ok: true, direction: "sellUsdrif" } : { ok: false, reason: "sell side disabled" };
  }
  if (tin === usdt0 && tout === cfg.tokens.rif.toLowerCase()) {
    return cfg.policy.sellRif ? { ok: true, direction: "sellRif" } : { ok: false, reason: "RIF rail disabled" };
  }
  if (tin === usdrif && tout === cfg.tokens.rif.toLowerCase()) {
    return cfg.policy.sellRif ? { ok: true, direction: "sellRifUsdrif" } : { ok: false, reason: "RIF rail disabled" };
  }
  if (tin === cfg.tokens.rif.toLowerCase() && tout === usdt0) {
    return cfg.policy.buyRif ? { ok: true, direction: "buyRif" } : { ok: false, reason: "RIF buy side disabled" };
  }
  return { ok: false, reason: "not an inventory pair (USDRIF/USDT0, USDT0→RIF)" };
}

/**
 * Whether an ENABLED inventory direction already owns the pair (`tokenIn` → `tokenOut`,
 * the maker's view): such a pair is that direction's — priced its own way (the USDRIF exit,
 * the RIF rail) — and never the spot strategy's.
 */
export function claimedPair(tokenIn: Address, tokenOut: Address, cfg: Pick<Config, "tokens" | "policy">): boolean {
  const tin = tokenIn.toLowerCase();
  const tout = tokenOut.toLowerCase();
  const { usdrif, usdt0, rif } = { usdrif: cfg.tokens.usdrif.toLowerCase(), usdt0: cfg.tokens.usdt0.toLowerCase(), rif: cfg.tokens.rif.toLowerCase() };
  const p = cfg.policy;
  return (
    (tin === usdrif && tout === usdt0 && p.buyUsdrif) ||
    (tin === usdt0 && tout === usdrif && p.sellUsdrif) ||
    (tin === usdt0 && tout === rif && p.sellRif) ||
    (tin === usdrif && tout === rif && p.sellRif) ||
    (tin === rif && tout === usdt0 && p.buyRif)
  );
}

/** The token we pay and the token we receive, for a direction. */
export function legsFor(direction: Direction, tokens: Config["tokens"]): { pay: Address; receive: Address } {
  if (direction === "buyUsdrif") return { pay: tokens.usdt0, receive: tokens.usdrif };
  if (direction === "buyRif") return { pay: tokens.usdt0, receive: tokens.rif };
  if (direction === "sellRifUsdrif") return { pay: tokens.rif, receive: tokens.usdrif };
  return { pay: direction === "sellRif" ? tokens.rif : tokens.usdrif, receive: tokens.usdt0 };
}

/** USDT0 per USDRIF (per RIF on the rail), 1e18-scaled, for one fill's `paid`/`received` (each in its own token's units). */
export function fillPrice(direction: Direction, paid: bigint, received: bigint): bigint {
  // buy: we pay USDT0 (paid) for USDRIF (received); sell: we receive USDT0 for USDRIF paid.
  // USDRIF per RIF (both 18 dec), USDRIF ≈ $1.
  if (direction === "sellRifUsdrif") return paid === 0n ? 0n : (received * ONE) / paid;
  const buy = paysUsdt0(direction);
  const usdt0 = buy ? paid : received;
  const usdrif = buy ? received : paid;
  if (usdrif === 0n) return buy ? 2n ** 255n : 0n;
  return (usdt0 * USDT0_TO_18 * ONE) / usdrif;
}

export function priceOk(direction: Direction, paid: bigint, received: bigint, p: Policy): Verdict<{ price: bigint }> {
  if (paid === 0n || received === 0n) return { ok: false, reason: "zero-sized leg" };
  const price = fillPrice(direction, paid, received);
  // The rail has no fixed price bound: its gate is the live replacement cost (filler.ts).
  if (direction === "sellRif" || direction === "buyRif" || direction === "sellRifUsdrif") return { ok: true, price };
  if (direction === "buyUsdrif" && price > p.maxBuyPrice) {
    return { ok: false, reason: `price ${fmt18(price)} above max ${fmt18(p.maxBuyPrice)}` };
  }
  if (direction === "sellUsdrif" && price < p.minSellPrice) {
    return { ok: false, reason: `price ${fmt18(price)} below min ${fmt18(p.minSellPrice)}` };
  }
  return { ok: true, price };
}

/** Whether `order` prices the same at every time: no curve and every leg fixed (`end == 0`). */
export function isFixedPrice(order: Order): boolean {
  return order.curve.length === 0 && order.legsIn.every((l) => l.end === 0n) && order.legsOut.every((l) => l.end === 0n);
}

/**
 * Zero-RPC price pre-filter for a FIXED-price plain order: its implied price at full
 * size (we pay `legsOut[0].start`, receive `legsIn[0].start` — either direction)
 * against MAX_BUY_PRICE / MIN_SELL_PRICE. A partial fill scales both legs and rounds
 * maker-ward, so the price at any size is that one or worse: out of bounds here means
 * out of bounds after any preview. An order whose price moves with time passes (it
 * is judged on a live preview).
 */
export function fixedPriceOk(order: Order, direction: Direction, p: Policy): Verdict<{}> {
  const legIn = order.legsIn[0];
  const legOut = order.legsOut[0];
  if (!isFixedPrice(order) || !legIn || !legOut) return { ok: true };
  const v = priceOk(direction, legOut.start, legIn.start, p);
  return v.ok ? { ok: true } : { ok: false, reason: `fixed-price order: ${v.reason}` };
}

/**
 * Buy side only: the USDT0 we would actually get back by redeeming the received
 * USDRIF at MoC's oracle and selling the RIF on the pool must beat what we pay by
 * `minExitEdgeBps`. `exitQuoteUsdt0` is that round trip, quoted live by the caller.
 */
export function exitOk(paidUsdt0: bigint, exitQuoteUsdt0: bigint, p: Policy): Verdict<{ edgeBps: bigint }> {
  if (paidUsdt0 === 0n) return { ok: false, reason: "zero payment" };
  const edgeBps = ((exitQuoteUsdt0 - paidUsdt0) * 10_000n) / paidUsdt0;
  if (edgeBps < p.minExitEdgeBps) return { ok: false, reason: `exit edge ${edgeBps} bps < ${p.minExitEdgeBps}` };
  return { ok: true, edgeBps };
}

/**
 * The inventory fill's all-in cost gate. `edgeUsdt0` is what the fill earns before
 * gas (buy: live redeem+sell exit − paid; sell: received − mint replacement cost).
 * It must cover the fill's own gas, its pro-rata share of the rebalance it causes,
 * and `minProfitUsdt0` — all already converted to USDT0 by the caller.
 */
export function inventoryProfitOk(edgeUsdt0: bigint, costUsdt0: bigint, minProfitUsdt0: bigint): Verdict<{ marginUsdt0: bigint }> {
  const margin = edgeUsdt0 - costUsdt0 - minProfitUsdt0;
  if (margin < 0n) {
    return { ok: false, reason: `unprofitable after gas: edge ${edgeUsdt0} < gas+rebalance ${costUsdt0} + min profit ${minProfitUsdt0} (USDT0 units)` };
  }
  return { ok: true, marginUsdt0: margin };
}

/** Pro-rata share of a rebalance cost for a fill of `usdrif` when a rebalance batches `redeemMin`. */
export function rebalanceShare(costWei: bigint, usdrif: bigint, redeemMin: bigint): bigint {
  if (redeemMin === 0n || usdrif >= redeemMin) return costWei;
  return (costWei * usdrif + redeemMin - 1n) / redeemMin; // round up: never under-charge
}

/**
 * Sell side: the USDT0 it costs to replace `usdrif` sold from inventory — ~$1 each
 * through a MoC mint, plus the mint fee (`MOC_FEE_BPS`); 18 → 6 decimals, rounded up.
 * Used by both the all-in gate and the recorded `profitEst`, so the two agree.
 */
export function mintReplaceUsdt0(usdrif: bigint): bigint {
  return (usdrif * (10_000n + MOC_FEE_BPS) + 10n ** 16n - 1n) / 10n ** 16n;
}

/** RIF out of MoC's `redeemTP` for `usdrif`, after its fee and the rail haircut (rounded down). */
export function railRifOut(usdrif: bigint, pACtp: bigint, haircutBps: bigint): bigint {
  return (usdrif * ONE * (10_000n - MOC_FEE_BPS - haircutBps)) / pACtp / 10_000n;
}

/**
 * The USDRIF that buys back `rif` through `redeemTP` (its fee and the rail haircut
 * on top), rounded up — the inverse of {@link railRifOut}. Pool-priced into USDT0 by
 * the caller (exact output on the 0.05 % pool).
 */
export function railUsdrifFor(rif: bigint, pACtp: bigint, haircutBps: bigint): bigint {
  const keep = 10_000n - MOC_FEE_BPS - haircutBps;
  return (rif * pACtp * 10_000n + ONE * keep - 1n) / (ONE * keep);
}

/** USDT0 notional of a fill (the USDT0 side, whichever direction). */
export function notionalUsdt0(direction: Direction, paid: bigint, received: bigint): bigint {
  if (direction === "sellRifUsdrif") return received / USDT0_TO_18; // USDRIF at $1
  return paysUsdt0(direction) ? paid : received;
}

/** The wallet as the RIF band sees it: balances and MoC's oracle (USDRIF per RIF, 1e18). */
export interface WalletMix {
  usdt0: bigint;
  usdrif: bigint;
  rif: bigint;
  pACtp: bigint;
}

/** USD value (18 dec) of `rif` at the MoC oracle (USDRIF ≈ $1). */
export function rifValue18(rif: bigint, pACtp: bigint): bigint {
  return (rif * pACtp) / ONE;
}

/**
 * Where the wallet stands in the RIF band: its value (18-dec USD: USDT0, USDRIF at $1,
 * RIF at the oracle), RIF's share of it (bps) and how far RIF's value is from the target
 * share (`gap18` > 0: below target, buy that much; < 0: above, sell).
 */
export function rifBand(m: WalletMix, p: Pick<Policy, "rifShareTargetBps">): { total18: bigint; rif18: bigint; shareBps: bigint; gap18: bigint } {
  const rif18 = rifValue18(m.rif, m.pACtp);
  const total18 = m.usdt0 * USDT0_TO_18 + m.usdrif + rif18;
  const shareBps = total18 === 0n ? 0n : (rif18 * 10_000n) / total18;
  return { total18, rif18, shareBps, gap18: (total18 * p.rifShareTargetBps) / 10_000n - rif18 };
}

/** RIF's share (bps) after `rifIn` more RIF is bought for `usdt0Out` USDT0 units. */
export function shareAfterBuy(m: WalletMix, rifIn: bigint, usdt0Out: bigint): bigint {
  return rifBand({ ...m, rif: m.rif + rifIn, usdt0: m.usdt0 > usdt0Out ? m.usdt0 - usdt0Out : 0n }, { rifShareTargetBps: 0n }).shareBps;
}

/**
 * Scale a fill down so the amount we PAY stays within `capPaid`. Previews are
 * linear in the fill amount up to rounding, so the caller must re-preview the
 * result. Returns 0 when nothing fits.
 */
export function capFillAmount(fillAmount: bigint, paidAtFill: bigint, capPaid: bigint): bigint {
  if (paidAtFill <= capPaid) return fillAmount;
  if (capPaid <= 0n || paidAtFill === 0n) return 0n;
  // Floor, then shave one unit so the rounded-up output of the re-preview still fits.
  const scaled = (fillAmount * capPaid) / paidAtFill;
  return scaled > 1n ? scaled - 1n : 0n;
}

/**
 * FILL-ONCE (`timing` bit 100, `DutchAuction.useNonceInvalidator`): the core settles
 * such an order by consuming its nonce, so it accepts ONLY the fill that closes it —
 * `_openFill` reverts `FillOnceMustBeFull` unless `prevFilled + delta == total`, and
 * `prevFilled` is always 0 (`filled[hash]` is never written). The app signs every
 * market ticket this way. A partial is therefore never a smaller fill, only a revert:
 * every strategy fills the WHOLE order or skips it.
 *
 * @returns why the order cannot be filled at the book's `fillable`, or null (also for
 *   any non-fill-once order). A lens `fillable` below the full size means the maker's
 *   balance / allowance cannot fund all of it.
 */
export function fillOnceBlocker(order: Order, fillable: bigint): string | null {
  if (!isFillOnce(order)) return null;
  const total = order.fillTotal !== 0n ? order.fillTotal : order.side === OrderSide.BUY ? order.legsOut[0]?.start : order.legsIn[0]?.start;
  // A proportional anchor resolves on-chain; such orders are classified out anyway.
  if (total === undefined || isProportional(total)) return null;
  if (fillable < total) return `fill-once order: only ${fillable} of ${total} fillable (maker under-funded) — a partial fill reverts FillOnceMustBeFull`;
  return null;
}

/**
 * Rolling one-hour outflow budget per token. The hot wallet's blast radius is its
 * balance; this bounds how fast even a mispriced stream of orders can move it.
 */
export class Budget {
  constructor(
    private readonly caps: Record<string, bigint>,
    private spends: SpendEntry[] = [],
    private readonly windowMs = 3_600_000,
  ) {}

  private prune(now: number) {
    this.spends = this.spends.filter((s) => now - s.at < this.windowMs);
  }

  remaining(token: Address, now: number): bigint {
    this.prune(now);
    const cap = this.caps[token.toLowerCase()] ?? 0n;
    const used = this.spends
      .filter((s) => s.token === token.toLowerCase())
      .reduce((a, s) => a + BigInt(s.amount), 0n);
    return cap > used ? cap - used : 0n;
  }

  /**
   * Record a spend. `ref` (a tx hash) makes it a reservation {@link settle} can
   * adjust later — and makes the spend idempotent per `(ref, token)`: a dropped
   * tx re-sent with identical bytes has the same hash, and used to stack a second
   * full-limit entry the receipt's `settle` could never reach (review 2026-10-05).
   * The entry takes the newer time, so the window runs from the actual send.
   */
  spend(token: Address, amount: bigint, now: number, ref?: string) {
    this.prune(now);
    const k = token.toLowerCase();
    const i = ref ? this.spends.findIndex((s) => s.ref === ref && s.token === k) : -1;
    const entry = { token: k, amount: amount.toString(), at: now, ...(ref ? { ref } : {}) };
    if (i < 0) this.spends.push(entry);
    else this.spends[i] = entry;
  }

  /**
   * Replace the amount of the reservation tagged `ref` for `token` (0 removes it).
   * The entry keeps its original time, so the rolling window is unchanged.
   */
  settle(ref: string, token: Address, amount: bigint): void {
    const k = token.toLowerCase();
    const i = this.spends.findIndex((s) => s.ref === ref && s.token === k);
    if (i < 0) return;
    if (amount === 0n) this.spends.splice(i, 1);
    else this.spends[i] = { ...this.spends[i]!, amount: amount.toString() };
  }

  toJSON(): SpendEntry[] {
    return this.spends;
  }
}

export function fmt18(v: bigint): string {
  const neg = v < 0n;
  const a = neg ? -v : v;
  const s = `${a / ONE}.${(a % ONE).toString().padStart(18, "0").slice(0, 6)}`;
  return neg ? `-${s}` : s;
}

export function fmtUnits(v: bigint, decimals: number): string {
  const base = 10n ** BigInt(decimals);
  return `${v / base}.${(v % base).toString().padStart(decimals, "0").slice(0, Math.min(decimals, 6))}`;
}

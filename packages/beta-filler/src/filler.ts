import { decodeFillUpToResult, encodeFillUpTo, type Order } from "@1delta-x/sdk";
import type { BookEntry } from "./intake";
import type { Address, Hex } from "viem";

import type { PricedCandidate } from "./quote";

import { sanitize } from "./sanitize";

import { allowanceCall, balanceOf, MOC_QUEUE_ABI, OPER_REDEEM_TP, previewBump, previewFill, quoteRifToUsdt0, quoteWrbtcToUsdt0, rifForUsdrif, type Chain } from "./chain";
import { MOC_FEE_BPS, type Config } from "./config";
import { gasShape, GasRatios } from "./gasRatio";
import { broadcast, estimateAndBroadcast, Guard } from "./guard";
import { isAuctionNotStarted, recheckAtMs, scaleUp } from "./recheck";
import {
  Budget,
  capFillAmount,
  classify,
  exclusivityFor,
  exitOk,
  fixedPriceOk,
  isFixedPrice,
  fmt18,
  legsFor,
  mintReplaceUsdt0,
  notionalUsdt0,
  priceOk,
  type Direction,
  type Verdict,
  inventoryProfitOk,
  rebalanceShare,
} from "./policy";

/** Headroom on the simulation's gas estimate for the tx gas limit. */
const GAS_LIMIT_PCT = 125n;

export interface FillOutcome {
  orderHash: Hex;
  /**
   * `pending`: a tx was SENT for the order (a fill, or the approval it needs);
   * a later tick reads its receipt (./guard.ts `resolvePending`). `filled` /
   * `failed` with a `tx` come from that resolution.
   */
  status: "skipped" | "dry-run" | "filled" | "failed" | "pending";
  reason?: string;
  tx?: Hex;
  paid?: bigint;
  received?: bigint;
  /** Which strategy produced this outcome. */
  strategy?: "inventory" | "route";
  /**
   * Stop dispatch here — do not let another strategy try this order now: a tx was
   * sent for it (reverted or pending), or it is under the shared on-chain backoff.
   */
  final?: boolean;
  /**
   * A `skipped` verdict about the ORDER at its current terms — its shape, size or
   * price against the market (unprofitable, above the max price, below the minimum
   * fill, no route) — not about our own transient state (budgets, balance, gas
   * price, a pending tx, a backoff). Such an order need not be re-quoted until the
   * book's fillable for it changes or RESTING_RECHECK_SECONDS pass.
   */
  rest?: boolean;
  /**
   * With `rest` on an order whose price moves with time: when (ms, wall clock) its
   * gate is expected to pass, the market held fixed (./recheck.ts) — the engine
   * re-quotes it then instead of a full {@link AUCTION_RECHECK_MS} later. Unset: no
   * prediction (the cap applies).
   */
  recheckAt?: number;
}

/**
 * Takes one book entry at a time. Every fill is: classify the shape → size it
 * against the per-order cap, the hourly budget and the wallet balance → preview it
 * on the lens → check price (and, on the buy side, the live redemption exit) →
 * simulate the exact calldata from our address → broadcast with the previewed bump
 * as `minBumpBps`, so a maker-ward price move between preview and inclusion makes
 * the fill revert instead of costing us.
 *
 * Gas: the shared {@link Guard} (one hourly RBTC budget with the route strategy,
 * MAX_GAS_PRICE_GWEI, per-order backoff). The tx gas limit is the simulation's
 * estimate × 1.25, and the budget is checked against limit × price before sending;
 * the profit gate prices the fill's gas at estimate × r (the receipt/estimate ratio
 * learned for this shape, gasRatio.ts) at the send price (chain.ts `withSendGasPrice`).
 *
 * Non-blocking: a live fill SENDS and returns `pending`; the receipt is read by a
 * later tick. A missing Settlement approval is sent as its own tx first (the
 * fill is retried on a later tick, once the approval is mined).
 */
export class Filler {
  private busy = false;
  /** Orders we already decided not to take, with the reason (logged once). */
  private readonly skipped = new Map<Hex, string>();

  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    readonly budget: Budget,
    private readonly log: (m: string) => void,
    private readonly onSpend: () => void = () => {},
    readonly guard: Guard = new Guard(cfg.gas),
    readonly gasRatios: GasRatios = new GasRatios(cfg.gas.defaultReceiptRatioPpm),
  ) {
    guard.register("inventory", budget);
  }

  /**
   * Zero-RPC classification: the shape, then — for a FIXED-price order (no curve,
   * every leg `end == 0`) — its implied price against MAX_BUY_PRICE / MIN_SELL_PRICE.
   * Partial fills scale every leg and round maker-ward, so an order whose full-size
   * price is out of bounds is out of bounds at every size: no preview needed.
   */
  private precheck(entry: BookEntry): Verdict<{ direction: Direction }> {
    const order = entry.announce.order;
    const cls = classify(order, this.cfg, this.chain.me, {
      hasPermitBatch: !!entry.announce.permitBatch,
      sigless: !!entry.announce.sigless,
    });
    if (!cls.ok) return cls;
    const price = fixedPriceOk(order, cls.direction, this.cfg.policy);
    return price.ok ? cls : price;
  }

  /** Whether this strategy would even look at the order (cheap, no RPC). */
  accepts(entry: BookEntry): boolean {
    return this.precheck(entry).ok && (entry.state?.fillableAmount ?? 0n) > 0n;
  }

  async consider(entry: BookEntry): Promise<FillOutcome> {
    const { orderHash } = entry;
    const order = entry.announce.order;
    const cls = this.precheck(entry);
    if (!cls.ok) return this.skip(orderHash, cls.reason, true);
    const fillable = entry.state?.fillableAmount ?? 0n;
    if (fillable === 0n) return this.skip(orderHash, "nothing fillable", true);
    if (this.busy) return { orderHash, status: "skipped", reason: "busy", strategy: "inventory" };
    this.busy = true;
    try {
      const blocked = this.guard.admit(orderHash, "inventory", Date.now());
      if (blocked) return { ...this.skip(orderHash, blocked.reason), final: blocked.global };
      return await this.tryFill(orderHash, order, entry.announce.sig, fillable, cls.direction);
    } catch (e) {
      // The latest block predates the auction's start (blocks lag the wall clock): try the next tick.
      if (isAuctionNotStarted(e)) return this.skip(orderHash, "auction not started at the latest block");
      // Nothing was sent (a sent tx is handled inside tryFill): short strategy-scoped backoff.
      this.guard.onSimFail(orderHash, "inventory", Date.now());
      const reason = sanitize(e instanceof Error ? e.message.split("\n")[0]! : String(e));
      this.log(`✗ [inventory] ${orderHash} ${reason}`);
      return { orderHash, status: "failed", reason, strategy: "inventory" };
    } finally {
      this.busy = false;
    }
  }

  private rbtcPrice?: { at: number; perRef: bigint };

  /** RBTC wei → USDT0 units, rounded up, at max(WRBTC/USDT0 pool quote, RBTC_PRICE_USD). */
  async rbtcToUsdt0(wei: bigint): Promise<bigint | undefined> {
    if (wei === 0n) return 0n;
    const REF = 10n ** 15n; // 0.001 RBTC
    let perRef = this.rbtcPrice && Date.now() - this.rbtcPrice.at < 60_000 ? this.rbtcPrice.perRef : undefined;
    if (perRef === undefined) {
      perRef = await quoteWrbtcToUsdt0(this.chain, this.cfg, REF).catch(() => 0n);
      this.rbtcPrice = { at: Date.now(), perRef };
    }
    const fromPool = perRef > 0n ? (wei * perRef + REF - 1n) / REF : undefined;
    const usd = this.cfg.policy.rbtcUsd;
    const fromUsd = usd ? (wei * usd + 10n ** 30n - 1n) / 10n ** 30n : undefined; // 1e18 wei × 1e18 usd → 1e6 units
    if (fromPool === undefined) return fromUsd;
    if (fromUsd === undefined) return fromPool;
    return fromPool > fromUsd ? fromPool : fromUsd;
  }

  /**
   * The inventory candidate for an indicative quote (./quote.ts) — BUY side only (the
   * maker sells USDRIF for USDT0; we pay USDT0 out of inventory). What we would pay for
   * `amountIn` USDRIF is bounded three ways, exactly the gates a fill must pass:
   *   • the price cap: amountIn × MAX_BUY_PRICE (`capOut`);
   *   • the exit edge: paid ≤ exit / (1 + MIN_EXIT_EDGE_BPS), exit = the live redeem-and-
   *     sell value of the USDRIF (`capOut` too);
   *   • the all-in profit: paid ≤ exit − INVENTORY_MIN_PROFIT_USDT0 − cost, cost = the
   *     fill's gas (estimate × r, estimate = max(INVENTORY_GAS_ESTIMATE, the largest
   *     learned for the shape)) + its share of the rebalance — `grossOut` is
   *     exit − min profit and `costOut` the cost, so the quote's gas margin applies.
   * Refused when the ticket is outside MIN_FILL / MAX_FILL, or the wallet or the hourly
   * budget could not pay it.
   */
  async quoteInventory(tokenIn: Address, tokenOut: Address, amountIn: bigint, gasPrice: bigint): Promise<Verdict<{ candidate: PricedCandidate }>> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const t = cfg.tokens;
    if (tokenIn.toLowerCase() !== t.usdrif.toLowerCase() || tokenOut.toLowerCase() !== t.usdt0.toLowerCase()) return { ok: false, reason: "inventory: not USDRIF→USDT0" };
    if (!p.buyUsdrif) return { ok: false, reason: "inventory: buy side disabled" };
    const ONE = 10n ** 18n;
    const priceCap = (amountIn * p.maxBuyPrice) / ONE / 10n ** 12n; // USDRIF 18 dec × price 1e18 → USDT0 6 dec
    const rif = ((await rifForUsdrif(chain, cfg, amountIn)) * (10_000n - MOC_FEE_BPS)) / 10_000n;
    const exit = await quoteRifToUsdt0(chain, cfg, rif);
    const edgeCap = (exit * 10_000n) / (10_000n + p.minExitEdgeBps);
    const shape = gasShape("inventory", "inventory", t.usdrif, t.usdt0);
    const learned = this.gasRatios.typicalEstimate(shape);
    const estimate = learned !== undefined && learned > p.inventoryGasEstimate ? learned : p.inventoryGasEstimate;
    const gasUnits = this.gasRatios.priced(shape, estimate);
    const rebalanceWei = await this.rebalanceShareWei(gasPrice, amountIn);
    const cost = await this.rbtcToUsdt0(gasPrice * gasUnits + rebalanceWei);
    if (cost === undefined) return { ok: false, reason: "inventory: cannot price gas in USDT0" };
    const capOut = priceCap < edgeCap ? priceCap : edgeCap;
    const grossOut = exit - p.minProfitUsdt0;
    if (capOut <= 0n || grossOut <= 0n) return { ok: false, reason: "inventory: no edge at this size" };
    const most = capOut < grossOut ? capOut : grossOut;
    if (most < p.minFillUsdt0) return { ok: false, reason: "inventory: below minimum fill" };
    if (most > p.maxFillUsdt0) return { ok: false, reason: "inventory: above maximum fill" };
    const now = Date.now();
    const room = this.budget.remaining(t.usdt0, now);
    const bal = await balanceOf(chain, t.usdt0);
    if (most > room || most > bal) return { ok: false, reason: "inventory: no capacity (balance / hourly budget)" };
    return { ok: true, candidate: { strategy: "inventory", grossOut, capOut, costOut: cost, gasUnits, source: "inventory" } };
  }

  /** What the fill earns before gas, in USDT0 units. */
  private async edgeUsdt0(direction: Direction, paid: bigint, received: bigint): Promise<bigint> {
    if (direction === "buyUsdrif") {
      const rif = ((await rifForUsdrif(this.chain, this.cfg, received)) * (10_000n - MOC_FEE_BPS)) / 10_000n;
      return (await quoteRifToUsdt0(this.chain, this.cfg, rif)) - paid;
    }
    // Sell side: replacing `paid` USDRIF costs ~$1 each plus the MoC mint fee.
    return received - mintReplaceUsdt0(paid);
  }

  /** This fill's share (wei) of the rebalance it causes: redeem/sell gas + the MoC exec fee. */
  private async rebalanceShareWei(gasPrice: bigint, usdrif: bigint): Promise<bigint> {
    const execFee = await this.chain.pub
      .readContract({ address: this.cfg.moc.queue, abi: MOC_QUEUE_ABI, functionName: "getExecFee", args: [OPER_REDEEM_TP] })
      .catch(() => 0n);
    return rebalanceShare(gasPrice * this.cfg.policy.rebalanceGas + execFee, usdrif, this.cfg.policy.redeemMin);
  }

  /** `rest`: a verdict about the order's terms (see FillOutcome.rest), not our transient state. */
  private skip(orderHash: Hex, reason: string, rest = false, recheckAt?: number): FillOutcome {
    if (this.skipped.get(orderHash) !== reason) {
      if (this.skipped.size > 5_000) this.skipped.clear(); // a long-running host must not grow without bound
      this.skipped.set(orderHash, reason);
      this.log(`· [inventory] skip ${orderHash}: ${reason}${recheckAt !== undefined ? ` (re-quote at ${new Date(recheckAt).toISOString()})` : ""}`);
    }
    return { orderHash, status: "skipped", reason, strategy: "inventory", ...(rest ? { rest: true } : {}), ...(rest && recheckAt !== undefined ? { recheckAt } : {}) };
  }

  /**
   * For a DECAYING order a gate refused: when it is expected to pass (ms), with the
   * market held fixed (./recheck.ts). One extra read (the lens bump the preview was
   * priced at), only on this path; a failed read is simply no prediction.
   */
  private async recheckAt(order: Order, gasPrice: bigint, paid: bigint, received: bigint, passes: (paid: bigint, received: bigint) => boolean): Promise<number | undefined> {
    if (isFixedPrice(order)) return undefined;
    try {
      const bumpNow = await previewBump(this.chain, this.cfg.lens, order, this.chain.me, gasPrice);
      return recheckAtMs(order, bumpNow, paid, received, BigInt(Math.floor(Date.now() / 1000)), passes);
    } catch {
      return undefined;
    }
  }

  private async tryFill(orderHash: Hex, order: Order, sig: Hex, fillable: bigint, direction: Direction): Promise<FillOutcome> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const { pay, receive } = legsFor(direction, cfg.tokens);
    const now = Date.now();

    // 0. Gas price ceiling (MAX_GAS_PRICE_GWEI) — the same price is what we send at.
    const gasPrice = await chain.pub.getGasPrice();
    const priceErr = this.guard.checkGasPrice(gasPrice);
    if (priceErr) return this.skip(orderHash, priceErr);

    // 1. Size: the most we are willing to PAY in this fill.
    //    Previewed at the gas price we send with (a priority / gas-bump tick reads it).
    let full = await previewFill(chain, cfg.lens, order, fillable, chain.me, gasPrice);
    const paidFull = full.paid[0] ?? 0n;
    const receivedFull = full.received[0] ?? 0n;
    const notionalFull = notionalUsdt0(direction, paidFull, receivedFull);
    const balance = await balanceOf(chain, pay);
    const budgetLeft = this.budget.remaining(pay, now);
    // The USDT0-notional cap, converted into units of the token we pay.
    const capByNotional = notionalFull === 0n ? 0n : (paidFull * p.maxFillUsdt0) / notionalFull;
    const capPaid = [capByNotional, balance, budgetLeft].reduce((a, b) => (a < b ? a : b));
    let fillAmount = capFillAmount(fillable, paidFull, capPaid);
    if (fillAmount === 0n) return this.skip(orderHash, `no capacity (balance ${balance}, budget ${budgetLeft})`);
    if (fillAmount !== fillable) full = await previewFill(chain, cfg.lens, order, fillAmount, chain.me, gasPrice);
    const paid = full.paid[0] ?? 0n;
    const received = full.received[0] ?? 0n;
    if (paid > capPaid) return this.skip(orderHash, "re-preview above cap");
    // Below the minimum: about the ORDER only when even its uncapped size is (else our balance / budget capped it).
    if (notionalUsdt0(direction, paid, received) < p.minFillUsdt0) return this.skip(orderHash, "below minimum fill", notionalFull < p.minFillUsdt0);

    // 2. Price.
    const price = priceOk(direction, paid, received, p);
    if (!price.ok) {
      return this.skip(orderHash, price.reason, true, await this.recheckAt(order, gasPrice, paid, received, (pd, rv) => priceOk(direction, pd, rv, p).ok));
    }

    // 3. Buy side: the live exit (redeem at oracle − MoC fee, sell RIF on the pool) must beat what we pay.
    if (direction === "buyUsdrif") {
      const rif = ((await rifForUsdrif(chain, cfg, received)) * (10_000n - MOC_FEE_BPS)) / 10_000n;
      const exitUsdt0 = await quoteRifToUsdt0(chain, cfg, rif);
      const exit = exitOk(paid, exitUsdt0, p);
      if (!exit.ok) {
        // The exit is the received USDRIF's round trip: it scales with what we receive.
        const at = await this.recheckAt(order, gasPrice, paid, received, (pd, rv) => exitOk(pd, scaleUp(exitUsdt0, rv, received), p).ok);
        return this.skip(orderHash, exit.reason, true, at);
      }
    }

    // 3b. All-in cost: the fill's own gas, its share of the rebalance it causes and a
    //     minimum profit, priced in USDT0 at max(pool quote, RBTC_PRICE_USD). A fill
    //     whose spread does not cover them is skipped (audit follow-up 2026-10-05).
    //     The fill's gas is priced at estimate × r (gasRatio.ts), r learned per shape.
    const shape = gasShape("inventory", "inventory", receive, pay);
    const edgeUsdt0 = await this.edgeUsdt0(direction, paid, received);
    const rebalanceWei = await this.rebalanceShareWei(gasPrice, direction === "buyUsdrif" ? received : paid);
    const preCost = await this.rbtcToUsdt0(gasPrice * this.gasRatios.priced(shape, p.inventoryGasEstimate) + rebalanceWei);
    if (preCost === undefined) return this.skip(orderHash, "cannot price gas in USDT0 (no pool quote and no RBTC_PRICE_USD)");
    // The edge at another (paid, received), the market held: buy — the exit value
    // (edge + paid) scales with the USDRIF received; sell — received − mint cost.
    const edgeAt = (pd: bigint, rv: bigint) => (direction === "buyUsdrif" ? scaleUp(edgeUsdt0 + paid, rv, received) - pd : rv - mintReplaceUsdt0(pd));
    const pre = inventoryProfitOk(edgeUsdt0, preCost, p.minProfitUsdt0);
    if (!pre.ok) {
      const at = await this.recheckAt(order, gasPrice, paid, received, (pd, rv) => inventoryProfitOk(edgeAt(pd, rv), preCost, p.minProfitUsdt0).ok);
      return this.skip(orderHash, pre.reason, true, at);
    }

    // 4. Floor: the bump we just priced at. Inclusion at a worse tick reverts (BumpTooLow).
    const minBumpBps = await previewBump(chain, cfg.lens, order, chain.me, gasPrice);
    const data = encodeFillUpTo({ order, sig, fillAmount, minBumpBps });

    // 5. Allowance for Settlement to pull what we pay (direct-approval path, bounded).
    //    Live, a missing approval is its own tx: send it and come back next tick.
    const hourly = pay.toLowerCase() === cfg.tokens.usdt0.toLowerCase() ? p.hourlyUsdt0 : p.hourlyUsdrif;
    const appr = await allowanceCall(chain, pay, cfg.settlement, paid, hourly);
    if (appr) {
      if (cfg.dryRun) this.log(`[dry-run] would approve ${cfg.settlement} for ${appr.amount} of ${pay}`);
      else return this.sendApproval(orderHash, pay, appr, gasPrice);
    }

    // 6. Simulate the exact calldata from our address.
    // Inside another filler's SOFT window we fill as an outsider: the preview above
    // (filler = our EOA) already priced the premium, so the gates saw it; say so.
    const ex = exclusivityFor(order, chain.me, BigInt(Math.floor(now / 1000)));
    const premium = ex.kind === "soft" ? ` (in-window outsider: +${ex.overrideBps} bps to the maker)` : "";
    const tag = `${direction} ${orderHash} pay ${paid} ${pay} for ${received} ${receive} @ ${fmt18(price.price)}${premium}`;
    let simPaid = paid;
    let simReceived = received;
    try {
      const sim = await chain.pub.call({ account: chain.me, to: cfg.settlement, data });
      if (!sim.data) throw new Error("simulation returned no data");
      const out = decodeFillUpToResult(sim.data);
      simPaid = out.paid[0] ?? 0n;
      simReceived = out.received[0] ?? 0n;
    } catch (e) {
      // In dry-run the Settlement approval may not exist yet, so a revert there is
      // reported rather than fatal. Live, nothing is sent without a clean simulation.
      if (!cfg.dryRun) throw e;
      this.log(`[dry-run] simulation reverted (missing approval?): ${e instanceof Error ? e.message.split("\n")[0] : e}`);
      this.log(`[dry-run] [inventory] would fill ${tag}`);
      return { orderHash, status: "dry-run", paid, received, strategy: "inventory" };
    }
    if (simPaid > paid || simReceived < received) throw new Error("simulation worse than preview");

    if (cfg.dryRun) {
      this.log(`[dry-run] [inventory] would fill ${tag} (simulation ok)`);
      return { orderHash, status: "dry-run", paid: simPaid, received: simReceived, strategy: "inventory" };
    }

    // 7. Gas limit = estimate × 1.25; the shared hourly budget must cover limit × price.
    const est = await chain.pub.estimateGas({ account: chain.me, to: cfg.settlement, data, gasPrice });
    const gas = (est * GAS_LIMIT_PCT + 99n) / 100n;
    const room = this.guard.gasRoom(gas * gasPrice, Date.now());
    if (room) return this.skip(orderHash, room);
    // Re-check the all-in gate with the REAL estimate × r (what the receipt is
    // expected to charge; a heavier burn loses at most (receipt − r × est) × price).
    const pricedGas = this.gasRatios.priced(shape, est);
    const realCost = await this.rbtcToUsdt0(gasPrice * pricedGas + rebalanceWei);
    if (realCost === undefined) return this.skip(orderHash, "cannot price gas in USDT0");
    const post = inventoryProfitOk(edgeUsdt0, realCost, p.minProfitUsdt0);
    if (!post.ok) {
      const at = await this.recheckAt(order, gasPrice, paid, received, (pd, rv) => inventoryProfitOk(edgeAt(pd, rv), realCost, p.minProfitUsdt0).ok);
      return this.skip(orderHash, post.reason, true, at);
    }

    // 8. Broadcast (legacy, Rootstock has no EIP-1559 market) and return: the
    //    receipt is read by a later tick. The outflow is reserved until then.
    const usdt0Eq = (amt: bigint, token: string) => (token.toLowerCase() === cfg.tokens.usdt0.toLowerCase() ? amt : amt / 10n ** 12n);
    const profitEst =
      direction === "buyUsdrif"
        ? (usdt0Eq(simReceived, receive) * (10_000n - MOC_FEE_BPS)) / 10_000n - simPaid
        : simReceived - mintReplaceUsdt0(simPaid); // the mint fee too, as the gate above
    const r = await broadcast(chain, this.guard, {
      to: cfg.settlement,
      data,
      gas,
      gasPrice,
      kind: "fill",
      strategy: "inventory",
      orderHash,
      expiry: order.expiry,
      reserve: { budget: "inventory", token: pay, amount: simPaid },
      gasMeter: { shape, estimate: est.toString() },
      info: {
        tag,
        payToken: pay,
        paid: simPaid.toString(),
        recvToken: receive,
        received: simReceived.toString(),
        profitEst: profitEst.toString(),
        profitToken: cfg.tokens.usdt0,
      },
    });
    switch (r.kind) {
      case "refused":
        return this.skip(orderHash, r.reason);
      case "failed":
        throw new Error(r.reason);
      case "sent":
        this.onSpend();
        this.log(`→ [inventory] sent fill ${tag} tx ${r.tx} (gas limit ${gas} @ ${gasPrice} wei, estimate ${est}, priced ${pricedGas})`);
        return { orderHash, status: "pending", tx: r.tx, paid: simPaid, received: simReceived, strategy: "inventory", final: true };
    }
  }

  /** Send the approval a fill needs as its own tx; the fill itself is retried after it is mined. */
  private async sendApproval(orderHash: Hex, token: Hex, appr: { data: Hex; amount: bigint; reset: boolean }, gasPrice: bigint): Promise<FillOutcome> {
    const { cfg, chain } = this;
    const backoffKey = `approve:${token}:${cfg.settlement}`;
    const blocked = this.guard.admit(backoffKey, "approve", Date.now());
    if (blocked) return this.skip(orderHash, `approval ${blocked.reason}`);
    const r = await estimateAndBroadcast(chain, this.guard, { to: token, data: appr.data, gasPrice, kind: "approve", strategy: "inventory", backoffKey, info: { note: `approve ${cfg.settlement} for ${appr.amount} of ${token}` } });
    if (r.kind === "refused") return this.skip(orderHash, r.reason);
    if (r.kind === "failed") throw new Error(r.reason);
    this.onSpend();
    this.log(`→ [inventory] sent ${appr.reset ? "approval reset (0)" : `approval of ${appr.amount}`} of ${token} to Settlement, tx ${r.tx} — the fill follows once it is mined`);
    return { orderHash, status: "pending", reason: "approval sent", tx: r.tx, strategy: "inventory", final: true };
  }
}

import { decodeFillUpToResult, encodeFillUpTo, type Order } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";

import { allowanceCall, balanceOf, previewBump, previewFill, type Chain } from "./chain";
import { spotBand, type Config, type SpotReserve } from "./config";
import type { FillOutcome } from "./filler";
import { gasShape, type GasRatios } from "./gasRatio";
import { broadcast, type Guard } from "./guard";
import type { BookEntry } from "./intake";
import { claimedPair, exclusivityFor, fillOnceBlocker, fmtUnits, isDeltaVerify, plainShape, type Budget, type Verdict } from "./policy";
import type { PricedCandidate } from "./quote";

/**
 * SPOT RESERVES (2026-10-19, INVENTORY-POLICY §9): small tickets filled from the wallet.
 *
 * The wallet holds small reserves of the busiest assets (`SPOT_RESERVES`, e.g. WRBTC $60,
 * USDRIF $50) next to its USD₮0. A PULL ticket of `MIN_FILL_USDT0`..`SPOT_MAX_TICKET_USD`
 * between any two of {USD₮0, the reserves} — and not claimed by another inventory
 * direction (`claimedPair`) — is filled from the wallet with `fillUpTo` (~92k gas)
 * instead of routed (222k–409k). It is:
 *   • VALUED at the live pool quote for swapping the received token back into the paid
 *     one (`dexQuote`, the route's own pool quoting): what replacing the paid token costs;
 *   • GATED at fill time: value − paid ≥ the fill's gas (estimate × r) + its share of the
 *     rebalance swap it causes + the min profit — never below the replacement value;
 *   • QUOTED like a route fill: the charge is `SPOT_CHARGE_GAS` (~250k, about a route fill)
 *     against the real ~92k + rebalance share, so the price stays about the DEX's and the
 *     gas gap is the margin.
 * NO SWAP RUNS ON ITS OWN (operator's rule, 2026-10-19: unpredictable gas and conversion
 * fees). Reserves move only with the flow. At a threshold — the paid reserve cannot cover
 * the ticket, or the fill would lift the RECEIVED reserve past its band top — spot passes,
 * and the ticket is QUOTED AND FILLED THROUGH THE DEX ROUTE instead: the quoter prices both
 * strategies in parallel and the dispatcher hands a spot skip (never `final`) to the route
 * in the same sweep. Spot never blocks a pair. Re-centring a reserve is an operator action
 * (rebalance.ts `spotStep`, `POST /rebalance-spot`).
 */

/** The `Budget` key spot outflows are counted under, in USD₮0 units (6 dec). */
export const SPOT_BUDGET_KEY = "spot-usd" as Address;

export interface SpotDeps {
  /** Best exact-input pool output (routeFiller.ts `dexQuote`). */
  dexQuote(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<bigint | undefined>;
  /** RBTC wei → `token` units at the route's reference price (routeFiller.ts `nativeToToken`). */
  nativeToToken(wei: bigint, token: Address): Promise<bigint | undefined>;
}

/** What the spot path needs from the inventory Filler it runs inside. */
export interface SpotHost {
  skip(orderHash: Hex, reason: string, rest?: boolean): FillOutcome;
  sendApproval(orderHash: Hex, token: Hex, appr: { data: Hex; amount: bigint; reset: boolean }, gasPrice: bigint): Promise<FillOutcome>;
  onSpend(): void;
  log(m: string): void;
}

const lc = (a: string) => a.toLowerCase();
const GAS_LIMIT_PCT = 125n;

export class SpotFiller {
  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    private readonly budget: Budget,
    private readonly guard: Guard,
    private readonly gasRatios: GasRatios,
    private readonly deps: SpotDeps,
  ) {}

  get enabled(): boolean {
    return this.cfg.policy.spot.reserves.length > 0;
  }

  /** The spot assets: USD₮0 (the hub) and every reserve. */
  private isSpotToken(t: string): boolean {
    return lc(t) === lc(this.cfg.tokens.usdt0) || this.cfg.policy.spot.reserves.some((r) => lc(r.token) === lc(t));
  }

  reserveOf(t: string): SpotReserve | undefined {
    return this.cfg.policy.spot.reserves.find((r) => lc(r.token) === lc(t));
  }

  /** Spot's pair: both tokens spot assets, distinct, and no enabled inventory direction owns it. */
  isSpotPair(tokenIn: Address, tokenOut: Address): boolean {
    return this.enabled && lc(tokenIn) !== lc(tokenOut) && this.isSpotToken(tokenIn) && this.isSpotToken(tokenOut) && !claimedPair(tokenIn, tokenOut, this.cfg);
  }

  /** Zero-RPC classification: the plain shape, PULL, fillable by us now, a spot pair. */
  classify(entry: BookEntry, me: Address): Verdict<{ tokenIn: Address; tokenOut: Address }> {
    const order = entry.announce.order;
    const shape = plainShape(order, { hasPermitBatch: !!entry.announce.permitBatch, sigless: !!entry.announce.sigless });
    if (!shape.ok) return shape;
    if (shape.nativeOut) return { ok: false, reason: "spot: native-out orders are not spot's" };
    if (isDeltaVerify(order)) return { ok: false, reason: "spot: delta-verify order needs a callback filler" };
    if (entry.fillPermit) return { ok: false, reason: "spot: funded only by the maker's permit (route only)" };
    const ex = exclusivityFor(order, me, BigInt(Math.floor(Date.now() / 1000)));
    if (ex.kind === "hard") return { ok: false, reason: "spot: exclusive to another filler" };
    const tokenIn = order.legsIn[0]!.token;
    const tokenOut = order.legsOut[0]!.token;
    if (!this.isSpotPair(tokenIn, tokenOut)) return { ok: false, reason: "spot: not a spot pair" };
    return { ok: true, tokenIn, tokenOut };
  }

  /** USD₮0 (6 dec) value of `amount` of `token`: 1:1 for USD₮0, else the pool quote into it. */
  private async usd6(token: Address, amount: bigint): Promise<bigint | undefined> {
    if (lc(token) === lc(this.cfg.tokens.usdt0)) return amount;
    return this.deps.dexQuote(token, this.cfg.tokens.usdt0, amount);
  }

  /** What the wallet may pay out of `token`: its balance above USDT0_RESERVE for USD₮0, all of it otherwise. */
  private async spendable(token: Address): Promise<bigint> {
    const bal = await balanceOf(this.chain, token);
    if (lc(token) !== lc(this.cfg.tokens.usdt0)) return bal;
    const r = this.cfg.policy.usdt0Reserve;
    return bal > r ? bal - r : 0n;
  }

  /**
   * This fill's share (wei) of a rebalance swap, pro rata to its USD over one band's width.
   * Reserves are rebalanced only by the OPERATOR (rebalance.ts `spotStep`, never on its own),
   * so the default SPOT_REBALANCE_GAS is 0: fills charge nothing they do not cause.
   */
  private rebalanceShareWei(gasPrice: bigint, usd6: bigint, tokenIn: Address, tokenOut: Address): bigint {
    const p = this.cfg.policy.spot;
    const res = this.reserveOf(tokenOut) ?? this.reserveOf(tokenIn);
    if (!res || p.rebalanceGas === 0n) return 0n;
    const width = (res.targetUsd6 * spotBand(res, p)) / 10_000n;
    const whole = gasPrice * p.rebalanceGas;
    if (width === 0n || usd6 >= width) return whole;
    return (whole * usd6 + width - 1n) / width;
  }

  /**
   * With no automatic rebalancing, a fill must not grow the RECEIVED reserve past its
   * band's top (target × (1 + SPOT_BAND_BPS)) — the wallet would otherwise pile up a
   * volatile asset nothing sells down. USD₮0 (the hub) has no cap. `addUsd6` = the fill's
   * USD value. Returns the refusal, or undefined.
   */
  private async overReserve(tokenIn: Address, addUsd6: bigint): Promise<string | undefined> {
    const res = this.reserveOf(tokenIn);
    if (!res) return undefined;
    const bal = await balanceOf(this.chain, tokenIn);
    const held = bal === 0n ? 0n : await this.usd6(tokenIn, bal);
    if (held === undefined) return "spot: cannot value the received reserve";
    const top = (res.targetUsd6 * (10_000n + spotBand(res, this.cfg.policy.spot))) / 10_000n;
    return held + addUsd6 > top ? `spot: would lift the ${tokenIn} reserve to $${fmtUnits(held + addUsd6, 6)}, over its band top $${fmtUnits(top, 6)}` : undefined;
  }

  /**
   * The spot QUOTE candidate (pull, no permit): gross = the pool quote for `amountIn`
   * (what the DEX gives), cost = SPOT_CHARGE_GAS priced like a route fill + the min profit,
   * capped by the paid token's spendable balance.
   */
  async quote(tokenIn: Address, tokenOut: Address, amountIn: bigint, gasPrice: bigint): Promise<Verdict<{ candidate: PricedCandidate }>> {
    if (!this.isSpotPair(tokenIn, tokenOut)) return { ok: false, reason: "spot: not a spot pair" };
    const p = this.cfg.policy;
    const [dexOut, spendable] = await Promise.all([this.deps.dexQuote(tokenIn, tokenOut, amountIn), this.spendable(tokenOut)]);
    if (dexOut === undefined || dexOut === 0n) return { ok: false, reason: "spot: no pool quote" };
    // The ticket's USD value: the output itself when it is USD₮0, else the input's pool value.
    const usd = lc(tokenOut) === lc(this.cfg.tokens.usdt0) ? dexOut : await this.usd6(tokenIn, amountIn);
    if (usd === undefined) return { ok: false, reason: "spot: cannot value the ticket in USD₮0" };
    if (usd < p.minFillUsdt0) return { ok: false, reason: "spot: below minimum fill" };
    if (usd > p.spot.maxTicketUsd6) return { ok: false, reason: `spot: above SPOT_MAX_TICKET_USD ${fmtUnits(p.spot.maxTicketUsd6, 6)}` };
    if (this.budget.remaining(SPOT_BUDGET_KEY, Date.now()) < usd) return { ok: false, reason: "spot: hourly spot budget exhausted" };
    const over = await this.overReserve(tokenIn, usd);
    if (over) return { ok: false, reason: over };
    const shape = gasShape("spot", "inventory", tokenIn, tokenOut, this.cfg.settlement);
    const learned = this.gasRatios.typicalEstimate(shape);
    const charge = learned !== undefined && learned > p.spot.chargeGas ? learned : p.spot.chargeGas;
    const gasUnits = this.gasRatios.priced(shape, charge);
    const [gasOut, profitOut] = await Promise.all([this.deps.nativeToToken(gasPrice * gasUnits, tokenOut), Promise.resolve(usd === 0n ? 0n : (p.minProfitUsdt0 * dexOut) / usd)]);
    if (gasOut === undefined) return { ok: false, reason: "spot: cannot price gas" };
    const costOut = gasOut + profitOut;
    if (spendable < dexOut - costOut) return { ok: false, reason: "spot: reserve too small for this ticket" };
    return { ok: true, candidate: { strategy: "inventory", grossOut: dexOut, capOut: spendable, costOut, gasUnits, source: "inventory-spot" } };
  }

  /** Fill one spot order from the wallet (the inventory Filler calls this; it holds the busy lock and the guard admission). */
  async fill(host: SpotHost, entry: BookEntry, tokenIn: Address, tokenOut: Address): Promise<FillOutcome> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const order: Order = entry.announce.order;
    const { orderHash } = entry;
    const fillable = entry.state?.fillableAmount ?? 0n;
    const once = fillOnceBlocker(order, fillable);
    if (once) return host.skip(orderHash, once, true);

    const gasPrice = await chain.pub.getGasPrice();
    const priceErr = this.guard.checkGasPrice(gasPrice);
    if (priceErr) return host.skip(orderHash, priceErr);

    // 1. What the full fill pays / receives, previewed as us at the send price.
    const pv = await previewFill(chain, cfg.lens, order, fillable, chain.me, gasPrice);
    const paid = pv.paid[0] ?? 0n;
    const received = pv.received[0] ?? 0n;
    if (paid === 0n || received === 0n) return host.skip(orderHash, "spot: zero-sized preview", true);

    // 2. Value the received token at the live pool (swapping it back into the paid one).
    const [value, usd, spendable] = await Promise.all([this.deps.dexQuote(tokenIn, tokenOut, received), this.usd6(tokenIn, received), this.spendable(tokenOut)]);
    if (value === undefined || usd === undefined) return host.skip(orderHash, "spot: no pool quote to value the fill");
    if (usd < p.minFillUsdt0) return host.skip(orderHash, "spot: below minimum fill", true);
    if (usd > p.spot.maxTicketUsd6) return host.skip(orderHash, `spot: above SPOT_MAX_TICKET_USD`, true);
    if (paid > spendable) return host.skip(orderHash, `spot: reserve ${fmtUnits(spendable, 18)} short of ${paid} ${tokenOut}`);
    if (this.budget.remaining(SPOT_BUDGET_KEY, Date.now()) < usd) return host.skip(orderHash, "spot: hourly spot budget exhausted");
    const over = await this.overReserve(tokenIn, usd);
    if (over) return host.skip(orderHash, over);

    // 3. The all-in gate at the pre-simulation estimate: value − paid ≥ gas + rebalance share + min profit.
    const shape = gasShape("spot", "inventory", tokenIn, tokenOut, cfg.settlement);
    const rebalanceWei = this.rebalanceShareWei(gasPrice, usd, tokenIn, tokenOut);
    const profitOut = (p.minProfitUsdt0 * value) / usd;
    const costAt = async (gasUnits: bigint) => this.deps.nativeToToken(gasPrice * this.gasRatios.priced(shape, gasUnits) + rebalanceWei, tokenOut);
    const preCost = await costAt(p.spot.fillGas);
    if (preCost === undefined) return host.skip(orderHash, "spot: cannot price gas");
    const edge = value - paid;
    if (edge < preCost + profitOut) {
      return host.skip(orderHash, `spot: unprofitable: value ${value} − paid ${paid} = ${edge} < gas+rebalance ${preCost} + min profit ${profitOut}`, true);
    }

    // 4. Settlement may pull what we pay: the maximum, once (chain.ts `maxApprovalSpender`).
    const appr = await allowanceCall(chain, tokenOut, cfg.settlement, paid, paid, undefined, true);
    if (appr) {
      if (cfg.dryRun) host.log(`[dry-run] would approve ${cfg.settlement} for ${appr.amount} of ${tokenOut}`);
      else return host.sendApproval(orderHash, tokenOut as Hex, appr, gasPrice);
    }

    // 5. Simulate the exact calldata; the bump we priced is the on-chain floor.
    const minBumpBps = await previewBump(chain, cfg.lens, order, chain.me, gasPrice);
    const data = encodeFillUpTo({ order, sig: entry.announce.sig, fillAmount: fillable, minBumpBps });
    const tag = `spot ${orderHash} pay ${paid} ${tokenOut} for ${received} ${tokenIn} (value ${value}, edge ${edge})`;
    let simPaid = paid;
    let simReceived = received;
    try {
      const sim = await chain.pub.call({ account: chain.me, to: cfg.settlement, data });
      if (!sim.data) throw new Error("simulation returned no data");
      const out = decodeFillUpToResult(sim.data);
      simPaid = out.paid[0] ?? 0n;
      simReceived = out.received[0] ?? 0n;
    } catch (e) {
      if (!cfg.dryRun) throw e;
      host.log(`[dry-run] [inventory] spot simulation reverted (missing approval?): ${e instanceof Error ? e.message.split("\n")[0] : e}`);
      return { orderHash, status: "dry-run", paid, received, strategy: "inventory" };
    }
    if (simPaid > paid || simReceived < received) throw new Error("spot: simulation worse than preview");
    if (cfg.dryRun) {
      host.log(`[dry-run] [inventory] would fill ${tag} (simulation ok)`);
      return { orderHash, status: "dry-run", paid: simPaid, received: simReceived, strategy: "inventory" };
    }

    // 6. Gas limit = estimate × 1.25 within the shared budget; re-check the gate at the real estimate × r.
    const est = await chain.pub.estimateGas({ account: chain.me, to: cfg.settlement, data, gasPrice });
    const gas = (est * GAS_LIMIT_PCT + 99n) / 100n;
    const room = this.guard.gasRoom(gas * gasPrice, Date.now());
    if (room) return host.skip(orderHash, room);
    const realCost = await costAt(est);
    if (realCost === undefined) return host.skip(orderHash, "spot: cannot price gas");
    if (edge < realCost + profitOut) return host.skip(orderHash, `spot: unprofitable at the estimate ${est}: edge ${edge} < ${realCost} + ${profitOut}`, true);

    // 7. Send; the receipt is read by a later tick. The USD outflow is reserved until then.
    const r = await broadcast(chain, this.guard, {
      to: cfg.settlement,
      data,
      gas,
      gasPrice,
      kind: "fill",
      strategy: "inventory",
      orderHash,
      expiry: order.expiry,
      reserve: { budget: "inventory", token: SPOT_BUDGET_KEY, amount: usd },
      gasMeter: { shape, estimate: est.toString() },
      info: { tag, payToken: tokenOut, paid: simPaid.toString(), recvToken: tokenIn, received: simReceived.toString(), profitEst: (edge - realCost).toString(), profitToken: tokenOut },
    });
    switch (r.kind) {
      case "refused":
        return host.skip(orderHash, r.reason);
      case "failed":
        throw new Error(r.reason);
      case "sent":
        host.onSpend();
        host.log(`→ [inventory] sent ${tag} tx ${r.tx} (gas limit ${gas} @ ${gasPrice} wei, estimate ${est})`);
        return { orderHash, status: "pending", tx: r.tx, paid: simPaid, received: simReceived, strategy: "inventory", final: true };
    }
  }
}

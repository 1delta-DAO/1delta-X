import { encodeFunctionData, zeroAddress, type Address, type Hex } from "viem";

import {
  allowanceCall,
  maxApprovalSpender,
  allowanceOf,
  balanceOf,
  MOC_CORE_ABI,
  MOC_QUEUE_ABI,
  OPER_MINT_TP,
  OPER_REDEEM_TP,
  mocPACtp,
  quoteRifToUsdt0,
  quoteSingle,
  quoteUsdrifToUsdt0,
  quoteUsdt0ForUsdrif,
  quoteUsdt0ToUsdrif,
  walletMix,
  rifForUsdrif,
  SWAP_ROUTER02_ABI,
  type Chain,
} from "./chain";
import { MOC_FEE_BPS, spotBand, type Config } from "./config";
import { estimateAndBroadcast, type Guard, type TxKind } from "./guard";
import { fmtUnits, rifBand } from "./policy";
import { sanitize } from "./sanitize";

/** The rebalancer's durable state: the MoC redemption we are waiting on. */
export interface RebalanceState {
  /** opId (decimal string) of a redemption the MoC queue has not executed yet. */
  pendingOp?: string;
  /** When that redemption tx was mined, ms. */
  pendingOpAt?: number;
  /**
   * An operator-started RIF re-centring (`rebalance-rif`) still in progress: the regular
   * step carries its next legs (the swap, the MoC op after the queue) until the band is at
   * target. Unset = the RIF band moves only with the flow (2026-10-20).
   */
  railRebalance?: { legs: number };
}

/** An operator re-centring sends at most this many txs (approvals, swaps, MoC ops), then stops. */
export const RAIL_MAX_LEGS = 8;

/**
 * Approval headroom, in batches, for a spender that is NOT approved for the maximum: an
 * approval covers this many REDEEM_MIN_USDRIF / RIF_SELL_MIN. Every spender the
 * rebalancer uses today (MoC's core, SwapRouter02) gets the maximum instead
 * (chain.ts `maxApprovalSpender`, 2026-10-19), so this is only the bounded fallback.
 */
export const APPROVAL_BATCHES = 4n;

const maxOf = (a: bigint, b: bigint) => (a > b ? a : b);
const minOf = (a: bigint, b: bigint) => (a < b ? a : b);

/** What one rebalancer action did. */
export interface RebalanceOutcome {
  action: "redeem" | "sell-rif" | "mint" | "refill" | "drain" | "spot";
  status: "sent" | "dry-run" | "held" | "skipped" | "failed";
  /** The tx sent (the action itself, or the approval it needs first). */
  tx?: Hex;
  /** The sent tx was the APPROVAL, not the action: run the action again once it is mined. */
  approval?: boolean;
  reason?: string;
}

/**
 * Turns filled USDRIF back into USDT0: redeem USDRIF → RIF at the MoC oracle price
 * (async, ~2.5 min through the MoC queue), then sell RIF → USDT0 on the Uniswap v3
 * pool. MoC requires `recipient == msg.sender`, which an EOA satisfies by
 * construction. The vendor is always the zero address — a vendor markup is a skim.
 *
 * Every tx goes through the shared Guard (`estimateAndBroadcast`): the hourly gas
 * budget, MAX_GAS_PRICE_GWEI, the one-outstanding-tx rule and a per-action backoff
 * on reverts (`rebalance:<action>`). Nothing waits for a receipt: an action sends
 * at most ONE tx (its approval first, if missing) and returns.
 *
 * Approvals: an action uses the allowance it HAS — it redeems / sells
 * `min(balance, allowance)` once that covers a batch — and only (re)approves when the
 * allowance is below one batch, then to `max(balance, APPROVAL_BATCHES × batch)`.
 * It used to approve exactly the current balance; every fill in between grew the
 * balance past it, so the next step reset the allowance to 0, re-approved, and was
 * outgrown again — approvals churned and no redemption was ever sent. Since
 * 2026-10-19 its spenders (MoC's core, SwapRouter02) are approved for the MAXIMUM,
 * once (chain.ts `maxApprovalSpender`): the bounded rule above is the fallback.
 */
export class Rebalancer {
  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    private readonly log: (m: string) => void,
    private readonly guard: Guard,
    readonly state: RebalanceState = {},
    private readonly persist: () => void = () => {},
    /** Best pool quote (routeFiller.ts `dexQuote`): values the SPOT reserves; absent = no spot step. */
    private readonly dexQuote?: (tokenIn: Address, tokenOut: Address, amountIn: bigint) => Promise<bigint | undefined>,
  ) {}

  /**
   * One step, at most one tx. With the RIF band on (SELL_RIF / BUY_RIF) NOTHING runs on its
   * own (operator's rule — unpredictable gas and conversion fees: spot since 2026-10-19,
   * the RIF band since 2026-10-20): RIF and USDRIF move only with the flow, and the step
   * only carries the next leg of a re-centring the operator started ({@link rebalanceRif}).
   * SPOT reserves are never rebalanced here either (`spotStep` is an admin action). With the
   * band off: redeem USDRIF if needed, then sell RIF if needed.
   */
  async step(): Promise<RebalanceOutcome | undefined> {
    if (this.cfg.policy.sellRif || this.cfg.policy.buyRif) {
      return this.state.railRebalance ? this.continueRail() : undefined;
    }
    const r = await this.redeemIfNeeded();
    if (r && (r.status === "sent" || r.status === "failed")) return r;
    const s = await this.sellRifIfNeeded();
    return s ?? r;
  }

  /**
   * THE RIF BAND (the RIF rail's inventory, `SELL_RIF` / `BUY_RIF`): keep RIF at about
   * RIF_SHARE_TARGET_BPS of the wallet's value (policy.ts `rifBand`) — a minority, RIF is
   * volatile. One tx per step, in this order:
   *   1. a MoC op (redeem / mint) in the queue → hold (its tokens have not arrived);
   *   2. USDRIF on hand (a refill swap's output, a drain's mint, USDRIF → RIF fills, the
   *      USDRIF buy side) → below target: redeem what reaches it (`redeemTP`, → RIF); at
   *      or above: swap it to USDT0 on the 0.05 % pool — each once RAIL_USDRIF_BATCH has
   *      collected (a MoC op costs ~$2.4), or at once below LOW;
   *   3. RIF below RIF_SHARE_LOW_BPS → swap USDT0 → USDRIF for the gap to target (step 2
   *      redeems it next);
   *   4. RIF above RIF_SHARE_HIGH_BPS → `mintTP` the excess RIF into USDRIF (step 2 swaps
   *      it to USDT0 next).
   * `force` (admin) rebalances to target from anywhere inside the band too. Nothing
   * smaller than MIN_FILL_USDT0 is moved; USDT0_RESERVE is never spent; a pool more than
   * USDRIF_PEG_TOLERANCE_BPS off $1 is refused. With the band on, RIF is never auto-sold.
   */
  async railStep(force = false): Promise<RebalanceOutcome | undefined> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    if (await this.queueBusy()) return { action: "refill", status: "held", reason: `MoC op ${this.state.pendingOp} not executed yet` };
    const m = await walletMix(chain, cfg);
    const band = rifBand(m, p);
    const dust18 = p.minFillUsdt0 * 10n ** 12n;
    const where = `RIF ${fmtUnits(m.rif, 18)} = ${band.shareBps} bps of $${fmtUnits(band.total18, 18)}`;
    // USDRIF held as a SPOT reserve (up to its band's top) is not the rail's to move.
    const usdrifKeep = maxOf(p.usdrifReserve, this.spotKeep18(cfg.tokens.usdrif));
    const usdrifFree = m.usdrif > usdrifKeep ? m.usdrif - usdrifKeep : 0n;
    // 2. USDRIF on hand: in batches, or at once when RIF is below the band.
    const urgent = band.gap18 >= dust18 && band.shareBps < p.rifShareLowBps;
    if (usdrifFree >= dust18 && (urgent || force || usdrifFree >= p.railUsdrifBatch)) {
      if (band.gap18 >= dust18) {
        // Redeem what fills the gap (the MoC fee comes off the RIF paid out).
        const want = (band.gap18 * 10_000n) / (10_000n - MOC_FEE_BPS);
        return this.redeem(minOf(usdrifFree, want), `toward the RIF target (${where})`);
      }
      return this.swap("drain", cfg.tokens.usdrif, cfg.tokens.usdt0, usdrifFree, `USDRIF to USDT0 (${where})`);
    }
    // 3. Below the band (or forced below target): buy RIF back to target.
    if (band.gap18 >= dust18 && (force || band.shareBps < p.rifShareLowBps)) {
      const usdt0Free = m.usdt0 > p.usdt0Reserve ? m.usdt0 - p.usdt0Reserve : 0n;
      const usdrifNeed = (band.gap18 * 10_000n) / (10_000n - MOC_FEE_BPS);
      const amountIn = minOf(await quoteUsdt0ForUsdrif(chain, cfg, usdrifNeed), usdt0Free);
      if (amountIn < p.minFillUsdt0) {
        const reason = `refill held: ${fmtUnits(usdt0Free, 6)} USDT0 spendable (reserve ${fmtUnits(p.usdt0Reserve, 6)}; ${where})`;
        return force ? { action: "refill", status: "held", reason } : undefined;
      }
      return this.swap("refill", cfg.tokens.usdt0, cfg.tokens.usdrif, amountIn, `refill (${where})`);
    }
    // 4. Above the band (or forced above target): mint the excess RIF into USDRIF.
    if (-band.gap18 >= dust18 && (force || band.shareBps > p.rifShareHighBps)) {
      // Mint USDRIF worth the excess net of the fee and slippage, so ≤ the excess RIF is pulled.
      const qTP = (-band.gap18 * (10_000n - MOC_FEE_BPS - p.redeemSlippageBps)) / 10_000n;
      return this.mint(qTP, p.redeemSlippageBps, `drain (${where})`);
    }
    return force ? { action: "refill", status: "held", reason: `nothing to move (${where})` } : undefined;
  }

  /**
   * ADMIN (`POST /rebalance-rif`, CLI `rebalance-rif`): re-centre the RIF band on its
   * target. Sends the first leg now; the regular step carries the rest (a swap, the MoC op
   * once the queue has executed the last) until nothing is left to move, a leg fails or is
   * held for a reason other than the MoC queue, or {@link RAIL_MAX_LEGS} txs have gone out.
   */
  async rebalanceRif(): Promise<RebalanceOutcome | undefined> {
    this.state.railRebalance = { legs: 0 };
    this.persist();
    return this.continueRail();
  }

  /** One leg of an operator re-centring ({@link rebalanceRif}); ends it when done. */
  private async continueRail(): Promise<RebalanceOutcome | undefined> {
    const run = this.state.railRebalance;
    if (!run) return undefined;
    const r = await this.railStep(true);
    // Waiting is not done: a MoC op in its queue, or a step the guard skipped (a tx outstanding, a backoff, the gas-price cap).
    const queued = (r?.status === "held" && !!r.reason?.startsWith("MoC op")) || r?.status === "skipped";
    const moved = r?.status === "sent" || r?.status === "dry-run";
    if (moved) run.legs++;
    if ((!queued && !moved) || run.legs >= RAIL_MAX_LEGS) {
      this.state.railRebalance = undefined;
      this.log(`rebalance-rif: done after ${run.legs} tx(s)${r?.reason ? ` (${r.reason})` : ""}`);
    }
    this.persist();
    return r;
  }

  /** A SPOT reserve's band top in 18-dec units of a $1 token (USDRIF), else 0 — what the rail must leave alone. */
  private spotKeep18(token: Address): bigint {
    const sp = this.cfg.policy.spot;
    const r = sp.reserves.find((x) => x.token.toLowerCase() === token.toLowerCase());
    return r ? ((r.targetUsd6 * (10_000n + spotBand(r, sp))) / 10_000n) * 10n ** 12n : 0n;
  }

  /**
   * SPOT reserves (./spot.ts, INVENTORY-POLICY §9) — an ADMIN action only (`POST
   * /rebalance-spot`, CLI `rebalance-spot`), never part of {@link step}: the operator does
   * not want swaps running on their own. Moves the first reserve outside ±SPOT_BAND_BPS of
   * its USD target back to target against USD₮0 on its configured pool: below the band,
   * buy with USD₮0 (never USDT0_RESERVE); above, sell the excess. One tx per call (its
   * router approval first — the maximum, once). Nothing under MIN_FILL_USDT0.
   */
  async spotStep(): Promise<RebalanceOutcome | undefined> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const sp = p.spot;
    if (sp.reserves.length === 0 || !this.dexQuote) return undefined;
    const usdt0 = cfg.tokens.usdt0;
    for (const r of sp.reserves) {
      const bal = await balanceOf(chain, r.token);
      const value = bal === 0n ? 0n : await this.dexQuote(r.token, usdt0, bal);
      if (value === undefined) continue;
      const low = (r.targetUsd6 * (10_000n - spotBand(r, sp))) / 10_000n;
      const high = (r.targetUsd6 * (10_000n + spotBand(r, sp))) / 10_000n;
      if (value < low) {
        const u = await balanceOf(chain, usdt0);
        const free = u > p.usdt0Reserve ? u - p.usdt0Reserve : 0n;
        const amountIn = minOf(r.targetUsd6 - value, free);
        if (amountIn < p.minFillUsdt0) continue;
        return this.spotSwap(usdt0, r.token, r.fee, amountIn, `spot reserve ${r.token} at $${fmtUnits(value, 6)} < $${fmtUnits(low, 6)}: buy back to $${fmtUnits(r.targetUsd6, 6)}`);
      }
      if (value > high) {
        const excess = value - r.targetUsd6;
        if (excess < p.minFillUsdt0) continue;
        const amountIn = (bal * excess) / value;
        return this.spotSwap(r.token, usdt0, r.fee, amountIn, `spot reserve ${r.token} at $${fmtUnits(value, 6)} > $${fmtUnits(high, 6)}: sell down to $${fmtUnits(r.targetUsd6, 6)}`);
      }
    }
    return undefined;
  }

  /** One spot rebalance swap on the reserve's pool, floored at SPOT_SLIPPAGE_BPS under its quote. */
  private async spotSwap(tokenIn: Address, tokenOut: Address, fee: number, amountIn: bigint, why: string): Promise<RebalanceOutcome> {
    const { cfg, chain } = this;
    const quote = await quoteSingle(chain, cfg, tokenIn, tokenOut, fee, amountIn);
    if (quote === 0n) return { action: "spot", status: "held", reason: `${why}: no pool quote` };
    const minOut = (quote * (10_000n - cfg.policy.spot.slippageBps)) / 10_000n;
    const msg = `${why}: swap ${amountIn} ${tokenIn} → ≥${minOut} ${tokenOut} (quote ${quote}, fee ${fee})`;
    const data = encodeFunctionData({
      abi: SWAP_ROUTER02_ABI,
      functionName: "exactInputSingle",
      args: [{ tokenIn, tokenOut, fee, recipient: chain.me, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }],
    });
    return this.act("spot", "spot", msg, { token: tokenIn, spender: cfg.uniswap.router, needed: amountIn, target: amountIn }, cfg.uniswap.router, data);
  }

  /** A rail pool swap USDT0 ⇄ USDRIF (exact in), refused off the peg, `RAIL_SWAP_SLIPPAGE_BPS` floor. */
  private async swap(action: "refill" | "drain", tokenIn: Address, tokenOut: Address, amountIn: bigint, why: string): Promise<RebalanceOutcome> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const toUsdrif = tokenOut.toLowerCase() === cfg.tokens.usdrif.toLowerCase();
    const quote = toUsdrif ? await quoteUsdt0ToUsdrif(chain, cfg, amountIn) : await quoteUsdrifToUsdt0(chain, cfg, amountIn);
    // The peg guard, in USDRIF terms (18 dec): what we give vs what we get, either way.
    const give18 = toUsdrif ? amountIn * 10n ** 12n : amountIn;
    const get18 = toUsdrif ? quote : quote * 10n ** 12n;
    if (get18 * (10_000n + p.usdrifPegToleranceBps) < give18 * 10_000n) {
      const reason = `${action} held: the pool gives ${fmtUnits(get18, 18)} for ${fmtUnits(give18, 18)} (over ${p.usdrifPegToleranceBps} bps off $1)`;
      this.log(reason);
      return { action, status: "held", reason };
    }
    const minOut = (quote * (10_000n - p.railSwapSlippageBps)) / 10_000n;
    const [dIn, dOut, sIn, sOut] = toUsdrif ? [6, 18, "USDT0", "USDRIF"] : [18, 6, "USDRIF", "USDT0"];
    const msg = `${why}: swap ${fmtUnits(amountIn, dIn)} ${sIn} → ≥${fmtUnits(minOut, dOut)} ${sOut} (quote ${fmtUnits(quote, dOut)})`;
    const data = encodeFunctionData({
      abi: SWAP_ROUTER02_ABI,
      functionName: "exactInputSingle",
      args: [{ tokenIn, tokenOut, fee: cfg.uniswap.usdrifUsdt0Fee, recipient: chain.me, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }],
    });
    return this.act(action, action, msg, { token: tokenIn, spender: cfg.uniswap.router, needed: amountIn, target: amountIn }, cfg.uniswap.router, data);
  }

  /** The MoC redemption we wait on, if any: its op id and how long ago it was mined. */
  pendingRedemption(now: number = Date.now()): { opId: bigint; ageMs: number } | undefined {
    if (this.state.pendingOp === undefined) return undefined;
    return { opId: BigInt(this.state.pendingOp), ageMs: now - (this.state.pendingOpAt ?? now) };
  }

  private async queueBusy(): Promise<boolean> {
    if (this.state.pendingOp === undefined) return false;
    const pendingOp = BigInt(this.state.pendingOp);
    const first = await this.chain.pub.readContract({
      address: this.cfg.moc.queue,
      abi: MOC_QUEUE_ABI,
      functionName: "firstOperId",
    });
    // FIFO: an op is executed (or refunded) once the head has moved past it.
    if (first > pendingOp) {
      this.log(`MoC op ${pendingOp} executed`);
      delete this.state.pendingOp;
      delete this.state.pendingOpAt;
      this.persist();
      return false;
    }
    return true;
  }

  /**
   * Called when our redeemTP tx is mined. An EOA does not get the returned op id;
   * the newest op right after our mined tx is ours or later, so waiting for the
   * queue head to pass it is conservative.
   */
  async onRedeemMined(now: number = Date.now()): Promise<void> {
    const count = await this.chain.pub.readContract({
      address: this.cfg.moc.queue,
      abi: [{ type: "function", name: "operIdCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }] as const,
      functionName: "operIdCount",
    });
    this.state.pendingOp = (count === 0n ? 0n : count - 1n).toString();
    this.state.pendingOpAt = now;
    this.persist();
  }

  async redeemIfNeeded(force = false): Promise<RebalanceOutcome | undefined> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    if (await this.queueBusy()) return { action: "redeem", status: "held", reason: `MoC op ${this.state.pendingOp} not executed yet` };
    const bal = await balanceOf(chain, cfg.tokens.usdrif);
    const avail = bal > p.usdrifReserve ? bal - p.usdrifReserve : 0n;
    if (avail === 0n || (!force && avail < p.redeemMin)) return undefined;
    // One batch is what the allowance must cover to redeem now (forced: everything).
    const need = force ? avail : maxOf(p.redeemMin, 1n);
    const allowance = await allowanceOf(chain, cfg.tokens.usdrif, cfg.moc.core);
    const qTP = allowance >= need ? minOf(avail, allowance) : avail;
    return this.redeem(qTP, undefined, { current: allowance, needed: need, target: maxOf(bal, APPROVAL_BATCHES * p.redeemMin) });
  }

  /** `redeemTP` `qTP` USDRIF → RIF at the oracle (an approval first if the allowance is short). */
  private async redeem(qTP: bigint, why?: string, appr?: { current: bigint; needed: bigint; target: bigint }): Promise<RebalanceOutcome> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const expectedRif = await rifForUsdrif(chain, cfg, qTP);
    // MoC deducts its 0.2% fee from the RIF paid out; tolerate `redeemSlippageBps` of oracle move on top.
    const qACmin = (expectedRif * (10_000n - MOC_FEE_BPS - p.redeemSlippageBps)) / 10_000n;
    const fee = await chain.pub.readContract({
      address: cfg.moc.queue,
      abi: MOC_QUEUE_ABI,
      functionName: "getExecFee",
      args: [OPER_REDEEM_TP],
    });
    const msg = `${why ? `${why}: ` : ""}redeem ${fmtUnits(qTP, 18)} USDRIF → ≥${fmtUnits(qACmin, 18)} RIF (exec fee ${fee} wei)`;
    const data = encodeFunctionData({ abi: MOC_CORE_ABI, functionName: "redeemTP", args: [cfg.tokens.usdrif, qTP, qACmin, chain.me, zeroAddress] });
    const a = appr ?? { needed: qTP, target: qTP };
    return this.act("redeem", "redeem", msg, { token: cfg.tokens.usdrif, spender: cfg.moc.core, ...a }, cfg.moc.core, data, fee);
  }

  async sellRifIfNeeded(force = false): Promise<RebalanceOutcome | undefined> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    // With the RIF rail on, the wallet's RIF IS the rail's float: never auto-sell it
    // (2026-10-14: the old rule sold a fresh 1,251 RIF float within a minute).
    if ((p.sellRif || p.buyRif) && !force) return undefined;
    const bal = await balanceOf(chain, cfg.tokens.rif);
    if (bal === 0n || (!force && bal < p.rifSellMin)) return undefined;
    // The same allowance rule as the redemption (a MoC execution adds RIF between steps).
    const need = force ? bal : maxOf(p.rifSellMin, 1n);
    const allowance = await allowanceOf(chain, cfg.tokens.rif, cfg.uniswap.router);
    const amountIn = allowance >= need ? minOf(bal, allowance) : bal;
    const quote = await quoteRifToUsdt0(chain, cfg, amountIn);
    // Oracle value of the RIF in USDT0 (6 dec): RIF ÷ (RIF per 1 USDRIF), USDRIF ≈ $1.
    const rifPerUsdrif = await rifForUsdrif(chain, cfg, 10n ** 18n);
    const oracleUsdt0 = (amountIn * 10n ** 6n) / rifPerUsdrif;
    const floor = (oracleUsdt0 * (10_000n - p.rifSellMaxDiscountBps)) / 10_000n;
    if (quote < floor) {
      const reason = `RIF sell held: pool quote ${fmtUnits(quote, 6)} USDT0 is more than ${p.rifSellMaxDiscountBps} bps below oracle ${fmtUnits(oracleUsdt0, 6)}`;
      this.log(reason);
      return { action: "sell-rif", status: "held", reason };
    }
    const minOut = (quote * (10_000n - p.rifSellSlippageBps)) / 10_000n;
    const msg = `sell ${fmtUnits(amountIn, 18)} RIF → ≥${fmtUnits(minOut, 6)} USDT0 (quote ${fmtUnits(quote, 6)})`;
    const data = encodeFunctionData({
      abi: SWAP_ROUTER02_ABI,
      functionName: "exactInputSingle",
      args: [
        {
          tokenIn: cfg.tokens.rif,
          tokenOut: cfg.tokens.usdt0,
          fee: cfg.uniswap.rifUsdt0Fee,
          recipient: chain.me,
          amountIn,
          amountOutMinimum: minOut,
          sqrtPriceLimitX96: 0n,
        },
      ],
    });
    const target = maxOf(bal, APPROVAL_BATCHES * p.rifSellMin);
    return this.act("sell-rif", "sell-rif", msg, { token: cfg.tokens.rif, spender: cfg.uniswap.router, needed: need, target, current: allowance }, cfg.uniswap.router, data);
  }

  /**
   * Manual: mint `qTP` USDRIF from RIF already in the wallet (sell-side inventory).
   * MoC pulls `qACmax` RIF up front and refunds the surplus at execution.
   */
  async mint(qTP: bigint, slippageBps = 50n, why?: string): Promise<RebalanceOutcome> {
    const { cfg, chain } = this;
    const needed = await rifForUsdrif(chain, cfg, qTP);
    const qACmax = (needed * (10_000n + MOC_FEE_BPS + slippageBps)) / 10_000n;
    const have = await balanceOf(chain, cfg.tokens.rif);
    if (have < qACmax) throw new Error(`need ${fmtUnits(qACmax, 18)} RIF, wallet holds ${fmtUnits(have, 18)}`);
    const fee = await chain.pub.readContract({
      address: cfg.moc.queue,
      abi: MOC_QUEUE_ABI,
      functionName: "getExecFee",
      args: [OPER_MINT_TP],
    });
    const msg = `${why ? `${why}: ` : ""}mint ${fmtUnits(qTP, 18)} USDRIF for ≤${fmtUnits(qACmax, 18)} RIF (exec fee ${fee} wei)`;
    const data = encodeFunctionData({ abi: MOC_CORE_ABI, functionName: "mintTP", args: [cfg.tokens.usdrif, qTP, qACmax, chain.me, zeroAddress] });
    return (await this.act("mint", "mint", msg, { token: cfg.tokens.rif, spender: cfg.moc.core, needed: qACmax, target: qACmax }, cfg.moc.core, data, fee))!;
  }

  /**
   * Approval first (its own tx) when the allowance is below `needed`, to `target`
   * (the maximum for the router and MoC — chain.ts `maxApprovalSpender`) — else the action, through the Guard.
   */
  private async act(
    action: RebalanceOutcome["action"],
    kind: TxKind,
    msg: string,
    allowance: { token: Address; spender: Address; needed: bigint; target: bigint; current?: bigint },
    to: Address,
    data: Hex,
    value?: bigint,
  ): Promise<RebalanceOutcome> {
    const { cfg, chain, guard } = this;
    if (cfg.dryRun) {
      this.log(`[dry-run] would ${msg}`);
      return { action, status: "dry-run" };
    }
    const now = Date.now();
    const key = `rebalance:${action}`;
    const blocked = guard.admit(key, "rebalance", now);
    if (blocked) return { action, status: "skipped", reason: blocked.reason };
    try {
      const appr = await allowanceCall(
        chain,
        allowance.token,
        allowance.spender,
        allowance.needed,
        allowance.target,
        allowance.current,
        maxApprovalSpender(cfg, allowance.spender),
      );
      if (appr) {
        const akey = `approve:${allowance.token}:${allowance.spender}`;
        const ablocked = guard.admit(akey, "approve", now);
        if (ablocked) return { action, status: "skipped", reason: `approval ${ablocked.reason}` };
        const r = await estimateAndBroadcast(chain, guard, {
          to: allowance.token,
          data: appr.data,
          kind: "approve",
          strategy: "rebalance",
          backoffKey: akey,
          info: { note: `approve ${allowance.spender} for ${appr.amount} of ${allowance.token} (for ${action})` },
        });
        if (r.kind !== "sent") return this.notSent(action, key, r.reason, r.kind === "failed");
        this.log(`→ [rebalance] sent ${appr.reset ? "approval reset (0)" : `approval of ${appr.amount}`} of ${allowance.token} to ${allowance.spender} for ${action}, tx ${r.tx}`);
        return { action, status: "sent", tx: r.tx, approval: true };
      }
      const r = await estimateAndBroadcast(chain, guard, { to, data, ...(value ? { value } : {}), kind, strategy: "rebalance", backoffKey: key, info: { note: msg } });
      if (r.kind !== "sent") return this.notSent(action, key, r.reason, r.kind === "failed");
      this.log(`→ [rebalance] sent ${msg}, tx ${r.tx}`);
      return { action, status: "sent", tx: r.tx };
    } catch (e) {
      // Estimate (= simulation) or RPC failure: nothing was sent.
      return this.notSent(action, key, sanitize(e instanceof Error ? e.message.split("\n")[0] : e), true);
    }
  }

  private notSent(action: RebalanceOutcome["action"], key: string, reason: string, failed: boolean): RebalanceOutcome {
    if (failed) this.guard.onSimFail(key, "rebalance", Date.now());
    this.log(`· [rebalance] ${action} not sent: ${reason}`);
    return { action, status: failed ? "failed" : "skipped", reason };
  }
}

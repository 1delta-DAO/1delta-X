import { encodeFunctionData, zeroAddress, type Address, type Hex } from "viem";

import {
  allowanceCall,
  allowanceOf,
  balanceOf,
  MOC_CORE_ABI,
  MOC_QUEUE_ABI,
  OPER_MINT_TP,
  OPER_REDEEM_TP,
  quoteRifToUsdt0,
  rifForUsdrif,
  SWAP_ROUTER02_ABI,
  type Chain,
} from "./chain";
import { MOC_FEE_BPS, type Config } from "./config";
import { estimateAndBroadcast, type Guard, type TxKind } from "./guard";
import { fmtUnits } from "./policy";
import { sanitize } from "./sanitize";

/** The rebalancer's durable state: the MoC redemption we are waiting on. */
export interface RebalanceState {
  /** opId (decimal string) of a redemption the MoC queue has not executed yet. */
  pendingOp?: string;
  /** When that redemption tx was mined, ms. */
  pendingOpAt?: number;
}

/** Approval headroom, in batches: an approval covers this many REDEEM_MIN_USDRIF / RIF_SELL_MIN (bounded, never unlimited). */
export const APPROVAL_BATCHES = 4n;

const maxOf = (a: bigint, b: bigint) => (a > b ? a : b);
const minOf = (a: bigint, b: bigint) => (a < b ? a : b);

/** What one rebalancer action did. */
export interface RebalanceOutcome {
  action: "redeem" | "sell-rif" | "mint";
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
 * outgrown again — approvals churned and no redemption was ever sent.
 */
export class Rebalancer {
  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    private readonly log: (m: string) => void,
    private readonly guard: Guard,
    readonly state: RebalanceState = {},
    private readonly persist: () => void = () => {},
  ) {}

  /** One step: redeem if needed, else sell RIF if needed. Sends at most one tx. */
  async step(): Promise<RebalanceOutcome | undefined> {
    const r = await this.redeemIfNeeded();
    if (r && (r.status === "sent" || r.status === "failed")) return r;
    const s = await this.sellRifIfNeeded();
    return s ?? r;
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
    const expectedRif = await rifForUsdrif(chain, cfg, qTP);
    // MoC deducts its 0.2% fee from the RIF paid out; tolerate `redeemSlippageBps` of oracle move on top.
    const qACmin = (expectedRif * (10_000n - MOC_FEE_BPS - p.redeemSlippageBps)) / 10_000n;
    const fee = await chain.pub.readContract({
      address: cfg.moc.queue,
      abi: MOC_QUEUE_ABI,
      functionName: "getExecFee",
      args: [OPER_REDEEM_TP],
    });
    const msg = `redeem ${fmtUnits(qTP, 18)} USDRIF → ≥${fmtUnits(qACmin, 18)} RIF (exec fee ${fee} wei)`;
    const data = encodeFunctionData({ abi: MOC_CORE_ABI, functionName: "redeemTP", args: [cfg.tokens.usdrif, qTP, qACmin, chain.me, zeroAddress] });
    const target = maxOf(bal, APPROVAL_BATCHES * p.redeemMin);
    return this.act("redeem", "redeem", msg, { token: cfg.tokens.usdrif, spender: cfg.moc.core, needed: need, target, current: allowance }, cfg.moc.core, data, fee);
  }

  async sellRifIfNeeded(force = false): Promise<RebalanceOutcome | undefined> {
    const { cfg, chain } = this;
    const p = cfg.policy;
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
  async mint(qTP: bigint, slippageBps = 50n): Promise<RebalanceOutcome> {
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
    const msg = `mint ${fmtUnits(qTP, 18)} USDRIF for ≤${fmtUnits(qACmax, 18)} RIF (exec fee ${fee} wei)`;
    const data = encodeFunctionData({ abi: MOC_CORE_ABI, functionName: "mintTP", args: [cfg.tokens.usdrif, qTP, qACmax, chain.me, zeroAddress] });
    return (await this.act("mint", "mint", msg, { token: cfg.tokens.rif, spender: cfg.moc.core, needed: qACmax, target: qACmax }, cfg.moc.core, data, fee))!;
  }

  /**
   * Approval first (its own tx) when the allowance is below `needed`, to `target`
   * (bounded, never unlimited) — else the action, through the Guard.
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
      const appr = await allowanceCall(chain, allowance.token, allowance.spender, allowance.needed, allowance.target, allowance.current);
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

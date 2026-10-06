import { zeroAddress } from "viem";

import {
  balanceOf,
  ensureAllowance,
  MOC_CORE_ABI,
  MOC_QUEUE_ABI,
  OPER_MINT_TP,
  OPER_REDEEM_TP,
  quoteRifToUsdt0,
  rifForUsdrif,
  send,
  SWAP_ROUTER02_ABI,
  type Chain,
} from "./chain";
import { MOC_FEE_BPS, type Config } from "./config";
import { fmtUnits } from "./policy";

/**
 * Turns filled USDRIF back into USDT0: redeem USDRIF → RIF at the MoC oracle price
 * (async, ~2.5 min through the MoC queue), then sell RIF → USDT0 on the Uniswap v3
 * pool. MoC requires `recipient == msg.sender`, which an EOA satisfies by
 * construction. The vendor is always the zero address — a vendor markup is a skim.
 */
export class Rebalancer {
  /** opId of a redemption we initiated that the queue has not executed yet. */
  private pendingOp: bigint | null = null;

  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    private readonly log: (m: string) => void,
  ) {}

  async tick(): Promise<void> {
    await this.redeemIfNeeded();
    await this.sellRifIfNeeded();
  }

  private async queueBusy(): Promise<boolean> {
    if (this.pendingOp === null) return false;
    const first = await this.chain.pub.readContract({
      address: this.cfg.moc.queue,
      abi: MOC_QUEUE_ABI,
      functionName: "firstOperId",
    });
    // FIFO: an op is executed (or refunded) once the head has moved past it.
    if (first > this.pendingOp) {
      this.log(`MoC op ${this.pendingOp} executed`);
      this.pendingOp = null;
      return false;
    }
    return true;
  }

  async redeemIfNeeded(force = false): Promise<void> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    if (await this.queueBusy()) return;
    const bal = await balanceOf(chain, cfg.tokens.usdrif);
    const qTP = bal > p.usdrifReserve ? bal - p.usdrifReserve : 0n;
    if (qTP === 0n || (!force && qTP < p.redeemMin)) return;
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
    if (cfg.dryRun) {
      this.log(`[dry-run] would ${msg}`);
      return;
    }
    await ensureAllowance(chain, cfg.tokens.usdrif, cfg.moc.core, qTP, qTP, false, this.log);
    this.log(msg);
    await send(
      chain,
      {
        address: cfg.moc.core,
        abi: MOC_CORE_ABI,
        functionName: "redeemTP",
        args: [cfg.tokens.usdrif, qTP, qACmin, chain.me, zeroAddress],
      } as never,
      this.log,
      fee,
    );
    // An EOA does not get the returned op id; the newest op right after our mined
    // tx is ours or later, so waiting for the head to pass it is conservative.
    this.pendingOp = await this.lastOpId();
  }

  private async lastOpId(): Promise<bigint> {
    const count = await this.chain.pub.readContract({
      address: this.cfg.moc.queue,
      abi: [{ type: "function", name: "operIdCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }] as const,
      functionName: "operIdCount",
    });
    return count === 0n ? 0n : count - 1n;
  }

  async sellRifIfNeeded(force = false): Promise<void> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const amountIn = await balanceOf(chain, cfg.tokens.rif);
    if (amountIn === 0n || (!force && amountIn < p.rifSellMin)) return;
    const quote = await quoteRifToUsdt0(chain, cfg, amountIn);
    // Oracle value of the RIF in USDT0 (6 dec): RIF ÷ (RIF per 1 USDRIF), USDRIF ≈ $1.
    const rifPerUsdrif = await rifForUsdrif(chain, cfg, 10n ** 18n);
    const oracleUsdt0 = (amountIn * 10n ** 6n) / rifPerUsdrif;
    const floor = (oracleUsdt0 * (10_000n - p.rifSellMaxDiscountBps)) / 10_000n;
    if (quote < floor) {
      this.log(
        `RIF sell held: pool quote ${fmtUnits(quote, 6)} USDT0 is more than ${p.rifSellMaxDiscountBps} bps below oracle ${fmtUnits(oracleUsdt0, 6)}`,
      );
      return;
    }
    const minOut = (quote * (10_000n - p.rifSellSlippageBps)) / 10_000n;
    const msg = `sell ${fmtUnits(amountIn, 18)} RIF → ≥${fmtUnits(minOut, 6)} USDT0 (quote ${fmtUnits(quote, 6)})`;
    if (cfg.dryRun) {
      this.log(`[dry-run] would ${msg}`);
      return;
    }
    await ensureAllowance(chain, cfg.tokens.rif, cfg.uniswap.router, amountIn, amountIn, false, this.log);
    this.log(msg);
    await send(
      chain,
      {
        address: cfg.uniswap.router,
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
      } as never,
      this.log,
    );
  }

  /**
   * Manual: mint `qTP` USDRIF from RIF already in the wallet (sell-side inventory).
   * MoC pulls `qACmax` RIF up front and refunds the surplus at execution.
   */
  async mint(qTP: bigint, slippageBps = 50n): Promise<void> {
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
    if (cfg.dryRun) {
      this.log(`[dry-run] would ${msg}`);
      return;
    }
    await ensureAllowance(chain, cfg.tokens.rif, cfg.moc.core, qACmax, qACmax, false, this.log);
    this.log(msg);
    await send(
      chain,
      {
        address: cfg.moc.core,
        abi: MOC_CORE_ABI,
        functionName: "mintTP",
        args: [cfg.tokens.usdrif, qTP, qACmax, chain.me, zeroAddress],
      } as never,
      this.log,
      fee,
    );
  }
}

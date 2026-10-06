import { decodeFillUpToResult, encodeFillUpTo, type Order } from "@1delta-x/sdk";
import type { BookEntry } from "./intake";
import type { Hex } from "viem";

import { balanceOf, ensureAllowance, previewBump, previewFill, quoteRifToUsdt0, rifForUsdrif, type Chain } from "./chain";
import { MOC_FEE_BPS, type Config } from "./config";
import {
  Budget,
  capFillAmount,
  classify,
  exitOk,
  fmt18,
  legsFor,
  notionalUsdt0,
  priceOk,
  type Direction,
} from "./policy";

export interface FillOutcome {
  orderHash: Hex;
  status: "skipped" | "dry-run" | "filled" | "failed";
  reason?: string;
  tx?: Hex;
  paid?: bigint;
  received?: bigint;
}

/**
 * Takes one book entry at a time. Every fill is: classify the shape → size it
 * against the per-order cap, the hourly budget and the wallet balance → preview it
 * on the lens → check price (and, on the buy side, the live redemption exit) →
 * simulate the exact calldata from our address → broadcast with the previewed bump
 * as `minBumpBps`, so a maker-ward price move between preview and inclusion makes
 * the fill revert instead of costing us.
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
  ) {}

  async consider(entry: BookEntry): Promise<FillOutcome> {
    const { orderHash } = entry;
    const order = entry.announce.order;
    const cls = classify(order, this.cfg, this.chain.me, {
      hasPermitBatch: !!entry.announce.permitBatch,
      sigless: !!entry.announce.sigless,
    });
    if (!cls.ok) return this.skip(orderHash, cls.reason);
    const fillable = entry.state?.fillableAmount ?? 0n;
    if (fillable === 0n) return this.skip(orderHash, "nothing fillable");
    if (this.busy) return { orderHash, status: "skipped", reason: "busy" };
    this.busy = true;
    try {
      return await this.tryFill(orderHash, order, entry.announce.sig, fillable, cls.direction);
    } catch (e) {
      const reason = e instanceof Error ? e.message.split("\n")[0]! : String(e);
      this.log(`✗ ${orderHash} ${reason}`);
      return { orderHash, status: "failed", reason };
    } finally {
      this.busy = false;
    }
  }

  private skip(orderHash: Hex, reason: string): FillOutcome {
    if (this.skipped.get(orderHash) !== reason) {
      this.skipped.set(orderHash, reason);
      this.log(`· skip ${orderHash}: ${reason}`);
    }
    return { orderHash, status: "skipped", reason };
  }

  private async tryFill(orderHash: Hex, order: Order, sig: Hex, fillable: bigint, direction: Direction): Promise<FillOutcome> {
    const { cfg, chain } = this;
    const p = cfg.policy;
    const { pay, receive } = legsFor(direction, cfg.tokens);
    const now = Date.now();

    // 1. Size: the most we are willing to PAY in this fill.
    let full = await previewFill(chain, cfg.lens, order, fillable);
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
    if (fillAmount !== fillable) full = await previewFill(chain, cfg.lens, order, fillAmount);
    const paid = full.paid[0] ?? 0n;
    const received = full.received[0] ?? 0n;
    if (paid > capPaid) return this.skip(orderHash, "re-preview above cap");
    if (notionalUsdt0(direction, paid, received) < p.minFillUsdt0) return this.skip(orderHash, "below minimum fill");

    // 2. Price.
    const price = priceOk(direction, paid, received, p);
    if (!price.ok) return this.skip(orderHash, price.reason);

    // 3. Buy side: the live exit (redeem at oracle − MoC fee, sell RIF on the pool) must beat what we pay.
    if (direction === "buyUsdrif") {
      const rif = ((await rifForUsdrif(chain, cfg, received)) * (10_000n - MOC_FEE_BPS)) / 10_000n;
      const exitUsdt0 = await quoteRifToUsdt0(chain, cfg, rif);
      const exit = exitOk(paid, exitUsdt0, p);
      if (!exit.ok) return this.skip(orderHash, exit.reason);
    }

    // 4. Floor: the bump we just priced at. Inclusion at a worse tick reverts (BumpTooLow).
    const minBumpBps = await previewBump(chain, cfg.lens, order);
    const data = encodeFillUpTo({ order, sig, fillAmount, minBumpBps });

    // 5. Allowance for Settlement to pull what we pay (direct-approval path, bounded).
    const hourly = pay.toLowerCase() === cfg.tokens.usdt0.toLowerCase() ? p.hourlyUsdt0 : p.hourlyUsdrif;
    await ensureAllowance(chain, pay, cfg.settlement, paid, hourly, cfg.dryRun, this.log);

    // 6. Simulate the exact calldata from our address.
    const tag = `${direction} ${orderHash} pay ${paid} ${pay} for ${received} ${receive} @ ${fmt18(price.price)}`;
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
      this.log(`[dry-run] would fill ${tag}`);
      return { orderHash, status: "dry-run", paid, received };
    }
    if (simPaid > paid || simReceived < received) throw new Error("simulation worse than preview");

    if (cfg.dryRun) {
      this.log(`[dry-run] would fill ${tag} (simulation ok)`);
      return { orderHash, status: "dry-run", paid: simPaid, received: simReceived };
    }

    // 7. Broadcast.
    const tx = await chain.wallet.sendTransaction({ account: chain.account, chain: chain.wallet.chain, to: cfg.settlement, data });
    const receipt = await chain.pub.waitForTransactionReceipt({ hash: tx });
    if (receipt.status !== "success") throw new Error(`fill ${tx} reverted`);
    this.budget.spend(pay, simPaid, Date.now());
    this.onSpend();
    this.log(`✓ filled ${tag} tx ${tx}`);
    return { orderHash, status: "filled", tx, paid: simPaid, received: simReceived };
  }
}

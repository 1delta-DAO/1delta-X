/**
 * The RIF RAIL (2026-10-14): USDT0 → RIF pull orders filled from the wallet's RIF float,
 * priced at its MoC replacement cost, and the float's refill (USDT0 → USDRIF on the
 * 0.05 % pool, then redeemTP). Quote selection is in quote.test.ts.
 */
import { OrderSide, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, erc20Abi, keccak256, maxUint256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { allowanceCall, maxApprovalSpender, MOC_CORE_ABI, SWAP_ROUTER02_ABI } from "../src/chain";
import { loadConfig, ROOTSTOCK } from "../src/config";
import { Guard } from "../src/guard";
import { classify, legsFor, railRifOut, railUsdrifFor, rifBand, shareAfterBuy } from "../src/policy";
import { RAIL_MAX_LEGS, Rebalancer, type RebalanceState } from "../src/rebalance";

const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const MAKER = "0x00000000000000000000000000000000000000bB" as Address;
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
  DRY_RUN: "0",
  SELL_RIF: "1",
  BUY_RIF: "1",
  USDT0_RESERVE: "100",
};
const cfg = loadConfig(ENV);
const T = cfg.tokens;
const PACTP = 8n * 10n ** 16n; // 0.08 USDRIF per RIF
const eqa = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

function railOrder(over: Partial<Order> = {}): Order {
  return {
    maker: MAKER, side: OrderSide.SELL, nonce: 1n, expiry: 2_000_000_000n,
    legsIn: [{ token: T.usdt0, start: 50_000_000n, end: 0n }],
    legsOut: [{ token: T.rif, start: 600n * 10n ** 18n, end: 0n, recipient: zeroAddress }],
    timing: 0n, exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress, ...over,
  } as Order;
}

describe("the rail's shape and arithmetic", () => {
  it("USDT0 → RIF (SELL_RIF: we pay RIF) and RIF → USDT0 (BUY_RIF: we pay USDT0, keep the RIF) are inventory orders", () => {
    const off = loadConfig({ ...ENV, SELL_RIF: "0", BUY_RIF: "0" });
    expect(classify(railOrder(), cfg, ACCOUNT.address)).toEqual({ ok: true, direction: "sellRif" });
    expect(classify(railOrder(), off, ACCOUNT.address)).toEqual({ ok: false, reason: "RIF rail disabled" });
    const sell = railOrder({ legsIn: [{ token: T.rif, start: 10n ** 21n, end: 0n }], legsOut: [{ token: T.usdt0, start: 1n, end: 0n, recipient: zeroAddress }] });
    expect(classify(sell, cfg, ACCOUNT.address)).toEqual({ ok: true, direction: "buyRif" });
    expect(classify(sell, off, ACCOUNT.address)).toEqual({ ok: false, reason: "RIF buy side disabled" });
    expect(legsFor("sellRif", T)).toEqual({ pay: T.rif, receive: T.usdt0 });
    expect(legsFor("buyRif", T)).toEqual({ pay: T.usdt0, receive: T.rif });
    // USDRIF → RIF (the maker pays USDRIF): delivered from the float, replaced by one redemption.
    const viaUsdrif = railOrder({ legsIn: [{ token: T.usdrif, start: 50n * 10n ** 18n, end: 0n }] });
    expect(classify(viaUsdrif, cfg, ACCOUNT.address)).toEqual({ ok: true, direction: "sellRifUsdrif" });
    expect(classify(viaUsdrif, off, ACCOUNT.address).ok).toBe(false);
    expect(legsFor("sellRifUsdrif", T)).toEqual({ pay: T.rif, receive: T.usdrif });
  });

  it("the band: RIF's share of USDT0 + USDRIF + RIF at the oracle, and the gap to the target", () => {
    // 300 USDT0 + 20 USDRIF + 1000 RIF × $0.08 = $400; RIF = 20 %.
    const m = { usdt0: 300_000_000n, usdrif: 20n * 10n ** 18n, rif: 1_000n * 10n ** 18n, pACtp: PACTP };
    expect(rifBand(m, cfg.policy)).toEqual({ total18: 400n * 10n ** 18n, rif18: 80n * 10n ** 18n, shareBps: 2_000n, gap18: 0n });
    expect(rifBand({ ...m, rif: 0n }, cfg.policy).gap18).toBe(64n * 10n ** 18n); // 20 % of $320
    // Buying 500 RIF ($40) for 40 USDT0: $120 of $400.
    expect(shareAfterBuy(m, 500n * 10n ** 18n, 40_000_000n)).toBe(3_000n);
  });

  it("railUsdrifFor buys back at least what railRifOut paid out (rounded against us)", () => {
    for (const usdrif of [1n, 10n ** 18n, 123_456_789_012_345_678_901n]) {
      const rif = railRifOut(usdrif, PACTP, 20n);
      const back = railUsdrifFor(rif, PACTP, 20n);
      expect(back).toBeLessThanOrEqual(usdrif);
      expect(railRifOut(back, PACTP, 20n)).toBeGreaterThanOrEqual(rif);
    }
    // 100 USDRIF at $0.08 → 1250 RIF − 0.2 % MoC − 0.2 % haircut.
    expect(railRifOut(100n * 10n ** 18n, PACTP, 20n)).toBe(1_245n * 10n ** 18n);
  });

  it("config: the band must be ordered (low ≤ target ≤ high)", () => {
    expect(() => loadConfig({ ...ENV, RIF_SHARE_LOW_BPS: "2500" })).toThrow(/RIF_SHARE_LOW_BPS/);
    expect(cfg.policy).toMatchObject({ rifShareLowBps: 1_500n, rifShareTargetBps: 2_000n, rifShareHighBps: 2_500n });
  });
});

/** A chain where the wallet holds `bal` and the MoC queue's head is `head`; records sent txs. The pool: 0.999 USDRIF per USDT0, both ways. */
function fakeChain(bal: Record<string, bigint>, q: { head: bigint; count: bigint } = { head: 0n, count: 0n }, allowance = 10n ** 30n) {
  const sent: Array<{ to: Address; data: Hex; value: bigint }> = [];
  const pub: Record<string, unknown> = {
    getGasPrice: async () => 26_065_600n,
    getTransactionCount: async () => 0,
    estimateGas: async () => 200_000n,
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      const t = parseTransaction(serializedTransaction);
      sent.push({ to: t.to!, data: t.data!, value: t.value ?? 0n });
      return keccak256(serializedTransaction);
    },
    readContract: async ({ functionName, address }: { functionName: string; address: string }) => {
      switch (functionName) {
        case "balanceOf": return bal[address.toLowerCase()] ?? 0n;
        case "allowance": return allowance;
        case "getPACtp": return PACTP;
        case "getExecFee": return 9n * 10n ** 12n;
        case "firstOperId": return q.head;
        case "operIdCount": return q.count;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ functionName, args }: { functionName: string; args: [{ tokenIn: string; tokenOut: string; amountIn?: bigint; amount?: bigint }] }) => {
      const p = args[0];
      if (eqa(p.tokenIn, T.usdrif) && eqa(p.tokenOut, T.usdt0) && functionName === "quoteExactInputSingle") return { result: [(p.amountIn! * 999n) / 10n ** 15n, 0n, 0, 0n] };
      if (!eqa(p.tokenIn, T.usdt0) || !eqa(p.tokenOut, T.usdrif)) throw new Error("unexpected quote");
      if (functionName === "quoteExactInputSingle") return { result: [p.amountIn! * 999n * 10n ** 9n, 0n, 0, 0n] };
      return { result: [p.amount! / (999n * 10n ** 9n) + 1n, 0n, 0, 0n] };
    },
  };
  return { sent, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const rebalancer = (chain: never, state: RebalanceState = {}, c = cfg) => new Rebalancer(c, chain, () => {}, new Guard(c.gas), state);
const wallet = (usdt0: bigint, usdrif: bigint, rif: bigint) => ({ [T.usdt0.toLowerCase()]: usdt0, [T.usdrif.toLowerCase()]: usdrif, [T.rif.toLowerCase()]: rif });
const E18 = 10n ** 18n;
const swapArgs = (data: Hex) => decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data }).args[0];

describe("the RIF band: RIF stays a minority (15–25 %, target 20 %) of the wallet", () => {
  it("below the band: swap USDT0 → USDRIF for the gap to 20 %, then redeem it for RIF", async () => {
    const bal = wallet(400_000_000n, 0n, 0n);
    const { sent, chain } = fakeChain(bal);
    expect(await rebalancer(chain).railStep()).toMatchObject({ action: "refill", status: "sent" });
    const p = swapArgs(sent[0]!.data);
    expect([sent[0]!.to.toLowerCase(), p.tokenIn, p.tokenOut, p.fee, p.recipient]).toEqual([cfg.uniswap.router.toLowerCase(), T.usdt0, T.usdrif, 500, ACCOUNT.address]);
    // 20 % of $400 = $80 of RIF ÷ (1 − 0.2 % MoC fee) = 80.160320… USDRIF ≈ 80.240562 USDT0 at 0.999 (rounded up).
    expect(p.amountIn).toBe(80_240_562n);
    expect(p.amountOutMinimum).toBe((p.amountIn * 999n * 10n ** 9n * 9_970n) / 10_000n);

    // The swap is mined: the USDRIF on hand is redeemed (RIF still below target).
    bal[T.usdt0.toLowerCase()] = 400_000_000n - p.amountIn;
    bal[T.usdrif.toLowerCase()] = 80_160_320_641_282_565_130n;
    expect(await rebalancer(chain).railStep()).toMatchObject({ action: "redeem", status: "sent" });
    const redeem = decodeFunctionData({ abi: MOC_CORE_ABI, data: sent[1]!.data });
    expect(redeem.functionName).toBe("redeemTP");
    // The swap cost a little ($399.92 now): it redeems what reaches 20 % of that, the dust stays.
    expect(redeem.args[1]).toBe(80_144_240_208_673_860_747n);
    expect(sent[1]!.value).toBe(9n * 10n ** 12n); // the MoC exec fee
  });

  it("inside the band nothing moves — unless forced (admin), which goes to the target", async () => {
    // 330 USDT0 + 875 RIF ($70) = $400: 17.5 %.
    const { sent, chain } = fakeChain(wallet(330_000_000n, 0n, 875n * E18));
    expect(await rebalancer(chain).railStep()).toBeUndefined();
    expect(await rebalancer(chain).step()).toBeUndefined();
    expect(await rebalancer(chain).railStep(true)).toMatchObject({ action: "refill", status: "sent" });
    expect(swapArgs(sent[0]!.data).amountIn).toBe(10_030_071n); // the $10 gap
  });

  it("above the band: mintTP the excess RIF into USDRIF; USDRIF at or above target is swapped to USDT0", async () => {
    // 300 USDT0 + 2000 RIF ($160) = $460: 34.8 % > 25 %. Target $92: mint (160 − 92) × (1 − 0.2 % − 0.5 %).
    const { sent, chain } = fakeChain(wallet(300_000_000n, 0n, 2_000n * E18));
    expect(await rebalancer(chain).railStep()).toMatchObject({ action: "mint", status: "sent" });
    const mint = decodeFunctionData({ abi: MOC_CORE_ABI, data: sent[0]!.data });
    expect(mint.functionName).toBe("mintTP");
    expect(mint.args[1]).toBe(67_524n * 10n ** 15n);
    expect(mint.args[2]).toBeLessThanOrEqual(2_000n * E18 - 1_150n * E18); // ≤ the excess RIF is pulled

    // The mint executed (or the USDRIF buy side filled): RIF at 23 %, USDRIF → USDT0.
    const after = fakeChain(wallet(300_000_000n, 100n * E18, 1_500n * E18));
    expect(await rebalancer(after.chain).railStep()).toMatchObject({ action: "drain", status: "sent" });
    const s = swapArgs(after.sent[0]!.data);
    expect([s.tokenIn, s.tokenOut, s.amountIn]).toEqual([T.usdrif, T.usdt0, 100n * E18]);
  });

  it("USDRIF from USDRIF → RIF fills is batched (RAIL_USDRIF_BATCH 100): held below it, redeemed from it, at once below LOW", async () => {
    // 300 USDT0 + 30 USDRIF + 875 RIF ($70) = $400: 17.5 % — in the band, below target.
    const held = fakeChain(wallet(300_000_000n, 30n * E18, 875n * E18));
    expect(await rebalancer(held.chain).railStep()).toBeUndefined();
    // 120 USDRIF collected (RIF $70 of $490 = 14.3 % — below LOW anyway): redeem the gap to 20 %.
    const batch = fakeChain(wallet(300_000_000n, 120n * E18, 875n * E18));
    expect(await rebalancer(batch.chain).railStep()).toMatchObject({ action: "redeem", status: "sent" });
    expect(decodeFunctionData({ abi: MOC_CORE_ABI, data: batch.sent[0]!.data }).args[1]).toBe(28_056_112_224_448_897_795n); // ($98 − $70) ÷ 0.998
    // Below LOW with only 10 USDRIF on hand: redeemed at once (it is part of the refill).
    const urgent = fakeChain(wallet(330_000_000n, 10n * E18, 500n * E18));
    expect(await rebalancer(urgent.chain).railStep()).toMatchObject({ action: "redeem", status: "sent" });
  });

  it("USDT0_RESERVE is never spent; a MoC op in the queue holds everything", async () => {
    // 110 USDT0, reserve 100: a $22 gap, but only 10 spendable.
    const { sent, chain } = fakeChain(wallet(110_000_000n, 0n, 0n));
    await rebalancer(chain).railStep();
    expect(swapArgs(sent[0]!.data).amountIn).toBe(10_000_000n);

    const busy = fakeChain(wallet(400_000_000n, 0n, 0n), { head: 7n, count: 9n });
    expect(await rebalancer(busy.chain, { pendingOp: "8", pendingOpAt: 0 }).railStep()).toMatchObject({ status: "held" });
    expect(busy.sent).toHaveLength(0);
  });

  it("the peg guard: a pool more than USDRIF_PEG_TOLERANCE_BPS off $1 is refused", async () => {
    const { sent, chain } = fakeChain(wallet(400_000_000n, 0n, 0n));
    const strict = loadConfig({ ...ENV, USDRIF_PEG_TOLERANCE_BPS: "5" }); // the fake pool is 10 bps off
    expect(await rebalancer(chain, {}, strict).railStep()).toMatchObject({ action: "refill", status: "held" });
    expect(sent).toHaveLength(0);
  });

  it("with the band on, the wallet's RIF is never auto-sold (the 2026-10-14 incident)", async () => {
    const { sent, chain } = fakeChain(wallet(0n, 0n, 5_000n * E18));
    const c = loadConfig({ ...ENV, RIF_SELL_MIN: "200" });
    expect(await rebalancer(chain, {}, c).sellRifIfNeeded()).toBeUndefined();
    expect(sent).toHaveLength(0);
  });
});

describe("the RIF band moves only with the flow (2026-10-20): re-centred only by the operator", () => {
  it("the regular step sends nothing, even far outside the band", async () => {
    for (const w of [wallet(400_000_000n, 0n, 0n), wallet(300_000_000n, 0n, 2_000n * E18), wallet(300_000_000n, 120n * E18, 875n * E18)]) {
      const { sent, chain } = fakeChain(w);
      expect(await rebalancer(chain).step()).toBeUndefined();
      expect(sent).toHaveLength(0);
    }
  });

  it("rebalance-rif opens a re-centring the step carries leg by leg, through the MoC queue, until the band is at target", async () => {
    const bal = wallet(400_000_000n, 0n, 0n);
    const { sent, chain } = fakeChain(bal);
    const state: RebalanceState = {};
    const r = rebalancer(chain, state);
    expect(await r.rebalanceRif()).toMatchObject({ action: "refill", status: "sent" });
    expect(state.railRebalance).toEqual({ legs: 1 });
    // The swap is mined: the next regular step redeems the USDRIF.
    bal[T.usdt0.toLowerCase()] = 400_000_000n - swapArgs(sent[0]!.data).amountIn;
    bal[T.usdrif.toLowerCase()] = 80_160_320_641_282_565_130n;
    expect(await r.step()).toMatchObject({ status: "skipped" }); // the swap tx still outstanding: wait, stay open
    expect(state.railRebalance).toEqual({ legs: 1 });
    expect(await rebalancer(chain, state).step()).toMatchObject({ action: "redeem", status: "sent" }); // mined
    expect(state.railRebalance).toEqual({ legs: 2 });
    // The MoC op waits in its queue: held, the re-centring stays open.
    const busy = fakeChain(wallet(400_000_000n, 0n, 0n), { head: 7n, count: 9n });
    const waiting: RebalanceState = { pendingOp: "8", pendingOpAt: 0, railRebalance: { legs: 2 } };
    expect(await rebalancer(busy.chain, waiting).step()).toMatchObject({ status: "held" });
    expect(waiting.railRebalance).toEqual({ legs: 2 });
    // Executed, the band at target (320 USDT0 + $80 of RIF = 20 %): done, and the step is quiet again.
    const done: RebalanceState = { railRebalance: { legs: 2 } };
    const at = fakeChain(wallet(320_000_000n, 0n, 1_000n * E18));
    expect(await rebalancer(at.chain, done).step()).toMatchObject({ status: "held", reason: expect.stringMatching(/nothing to move/) });
    expect(done.railRebalance).toBeUndefined();
    expect(await rebalancer(at.chain, done).step()).toBeUndefined();
    expect(at.sent).toHaveLength(0);
  });

  it("a re-centring stops after RAIL_MAX_LEGS txs", async () => {
    const state: RebalanceState = { railRebalance: { legs: RAIL_MAX_LEGS - 1 } };
    const { sent, chain } = fakeChain(wallet(400_000_000n, 0n, 0n));
    expect(await rebalancer(chain, state).step()).toMatchObject({ status: "sent" });
    expect(state.railRebalance).toBeUndefined();
    expect(await rebalancer(chain, state).step()).toBeUndefined();
    expect(sent).toHaveLength(1);
  });
});

describe("approvals (2026-10-19): the maximum, once, to Settlement, the router and MoC", () => {
  const approveOf = (data: Hex) => decodeFunctionData({ abi: erc20Abi, data });

  it("a refill approves the ROUTER for the maximum (no per-swap exact approvals to churn)", async () => {
    const { sent, chain } = fakeChain(wallet(400_000_000n, 0n, 0n), undefined, 0n);
    expect(await rebalancer(chain).railStep()).toMatchObject({ action: "refill", status: "sent", approval: true });
    const a = approveOf(sent[0]!.data);
    expect([sent[0]!.to.toLowerCase(), a.functionName, (a.args[0] as string).toLowerCase(), a.args[1]]).toEqual([
      T.usdt0.toLowerCase(), "approve", cfg.uniswap.router.toLowerCase(), maxUint256,
    ]);
  });

  it("a redemption approves Money on Chain's core for the maximum too (trusted by the operator)", async () => {
    // USDRIF on hand below the band: the redeem leg, approval first.
    const { sent, chain } = fakeChain(wallet(330_000_000n, 100n * E18, 0n), undefined, 0n);
    expect(await rebalancer(chain).railStep()).toMatchObject({ action: "redeem", approval: true });
    const a = approveOf(sent[0]!.data);
    expect([(a.args[0] as string).toLowerCase(), a.args[1]]).toEqual([cfg.moc.core.toLowerCase(), maxUint256]);
  });

  it("only Settlement, the router and MoC qualify; anything else is refused an unlimited approval", async () => {
    for (const s of [cfg.settlement, cfg.uniswap.router, cfg.moc.core]) expect(maxApprovalSpender(cfg, s)).toBe(true);
    const stranger = "0x00000000000000000000000000000000000000dd" as Address;
    expect(maxApprovalSpender(cfg, stranger)).toBe(false);
    const { chain } = fakeChain({}, undefined, 0n);
    await expect(allowanceCall(chain, T.usdt0, stranger, 1n, maxUint256)).rejects.toThrow(/unlimited/);
  });
});

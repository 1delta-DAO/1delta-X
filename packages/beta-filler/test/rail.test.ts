/**
 * The RIF RAIL (2026-10-14): USDT0 → RIF pull orders filled from the wallet's RIF float,
 * priced at its MoC replacement cost, and the float's refill (USDT0 → USDRIF on the
 * 0.05 % pool, then redeemTP). Quote selection is in quote.test.ts.
 */
import { OrderSide, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, keccak256, parseTransaction, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { MOC_CORE_ABI, SWAP_ROUTER02_ABI } from "../src/chain";
import { loadConfig, ROOTSTOCK } from "../src/config";
import { Guard } from "../src/guard";
import { classify, legsFor, railRifOut, railUsdrifFor } from "../src/policy";
import { Rebalancer, type RebalanceState } from "../src/rebalance";

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
  RIF_FLOAT_TARGET: "3000",
  RIF_REFILL_BELOW: "1500",
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
  it("USDT0 → RIF is an inventory order only with SELL_RIF; we pay RIF and receive USDT0", () => {
    expect(classify(railOrder(), cfg, ACCOUNT.address)).toEqual({ ok: true, direction: "sellRif" });
    expect(classify(railOrder(), loadConfig({ ...ENV, SELL_RIF: "0", RIF_FLOAT_TARGET: "0", RIF_REFILL_BELOW: "0" }), ACCOUNT.address)).toEqual({ ok: false, reason: "RIF rail disabled" });
    // RIF → USDT0 (the maker SELLS RIF) is not the rail's.
    const sell = railOrder({ legsIn: [{ token: T.rif, start: 10n ** 21n, end: 0n }], legsOut: [{ token: T.usdt0, start: 1n, end: 0n, recipient: zeroAddress }] });
    expect(classify(sell, cfg, ACCOUNT.address).ok).toBe(false);
    expect(legsFor("sellRif", T)).toEqual({ pay: T.rif, receive: T.usdt0 });
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

  it("config: RIF_REFILL_BELOW above RIF_FLOAT_TARGET is a typo", () => {
    expect(() => loadConfig({ ...ENV, RIF_REFILL_BELOW: "4000" })).toThrow(/RIF_REFILL_BELOW/);
  });
});

/** A chain where the wallet holds `bal` and the MoC queue's head is `head`; records sent txs. */
function fakeChain(bal: Record<string, bigint>, q: { head: bigint; count: bigint } = { head: 0n, count: 0n }) {
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
        case "allowance": return 10n ** 30n;
        case "getPACtp": return PACTP;
        case "getExecFee": return 9n * 10n ** 12n;
        case "firstOperId": return q.head;
        case "operIdCount": return q.count;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ functionName, args }: { functionName: string; args: [{ tokenIn: string; tokenOut: string; amountIn?: bigint; amount?: bigint }] }) => {
      const p = args[0];
      if (!eqa(p.tokenIn, T.usdt0) || !eqa(p.tokenOut, T.usdrif)) throw new Error("unexpected quote");
      // The pool: 0.999 USDRIF per USDT0, both ways.
      if (functionName === "quoteExactInputSingle") return { result: [(p.amountIn! * 999n * 10n ** 9n), 0n, 0, 0n] };
      return { result: [p.amount! / (999n * 10n ** 9n) + 1n, 0n, 0, 0n] };
    },
  };
  return { sent, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const rebalancer = (chain: never, state: RebalanceState, c = cfg) => new Rebalancer(c, chain, () => {}, new Guard(c.gas), state);

describe("the float's refill: swap USDT0 → USDRIF, then redeem it for RIF", () => {
  it("below RIF_REFILL_BELOW: swaps what buys back to RIF_FLOAT_TARGET, then redeems the USDRIF it bought", async () => {
    const bal = { [T.rif.toLowerCase()]: 1_000n * 10n ** 18n, [T.usdt0.toLowerCase()]: 500_000_000n };
    const { sent, chain } = fakeChain(bal);
    const state: RebalanceState = {};
    const r = await rebalancer(chain, state).step();
    expect(r).toMatchObject({ action: "refill", status: "sent" });
    expect(state.refillPending).toBe(true);
    const swap = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: sent[0]!.data });
    const p = swap.args[0];
    expect([sent[0]!.to.toLowerCase(), p.tokenIn, p.tokenOut, p.fee, p.recipient]).toEqual([cfg.uniswap.router.toLowerCase(), T.usdt0, T.usdrif, 500, ACCOUNT.address]);
    // 2000 RIF × $0.08 ÷ (1 − 0.2 % MoC fee) = 160.32 USDRIF (no haircut on the refill itself) ≈ 160.48 USDT0.
    expect(p.amountIn).toBe(160_481_123n);
    expect(p.amountOutMinimum).toBe((p.amountIn * 999n * 10n ** 9n * 9_970n) / 10_000n);

    // The swap is mined: the USDRIF is redeemed (forced — below REDEEM_MIN_USDRIF 1000).
    bal[T.usdrif.toLowerCase()] = 160n * 10n ** 18n;
    const r2 = await rebalancer(chain, state).step();
    expect(r2).toMatchObject({ action: "redeem", status: "sent" });
    const redeem = decodeFunctionData({ abi: MOC_CORE_ABI, data: sent[1]!.data });
    expect(redeem.functionName).toBe("redeemTP");
    expect(redeem.args[1]).toBe(160n * 10n ** 18n);
    expect(sent[1]!.value).toBe(9n * 10n ** 12n); // the MoC exec fee
    expect(state.refillPending).toBeUndefined();
  });

  it("never spends USDT0_RESERVE; holds while a redemption waits in the MoC queue; at the target it does nothing", async () => {
    // 150 USDT0, reserve 100: only 50 are spendable.
    const { sent, chain } = fakeChain({ [T.rif.toLowerCase()]: 0n, [T.usdt0.toLowerCase()]: 150_000_000n });
    await rebalancer(chain, {}).step();
    expect(decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: sent[0]!.data }).args[0].amountIn).toBe(50_000_000n);

    const busy = fakeChain({ [T.rif.toLowerCase()]: 0n, [T.usdt0.toLowerCase()]: 500_000_000n }, { head: 7n, count: 9n });
    const held = await rebalancer(busy.chain, { pendingOp: "8", pendingOpAt: 0 }).refillRifIfNeeded(true);
    expect(held).toMatchObject({ action: "refill", status: "held" });
    expect(busy.sent).toHaveLength(0);

    const full = fakeChain({ [T.rif.toLowerCase()]: 3_000n * 10n ** 18n, [T.usdt0.toLowerCase()]: 500_000_000n });
    expect(await rebalancer(full.chain, {}).step()).toBeUndefined();
    // …unless an admin names an amount.
    expect(await rebalancer(full.chain, {}).refillRifIfNeeded(true, 20_000_000n)).toMatchObject({ action: "refill", status: "sent" });
  });

  it("the oracle guard: a pool charging over REFILL_MAX_PREMIUM_BPS above $1 per USDRIF is refused", async () => {
    const { sent, chain } = fakeChain({ [T.rif.toLowerCase()]: 0n, [T.usdt0.toLowerCase()]: 500_000_000n });
    const strict = loadConfig({ ...ENV, REFILL_MAX_PREMIUM_BPS: "5" }); // the fake pool charges ~10 bps
    expect(await rebalancer(chain, {}, strict).step()).toMatchObject({ action: "refill", status: "held" });
    expect(sent).toHaveLength(0);
  });

  it("with the rail on, the wallet's RIF is never auto-sold (the 2026-10-14 incident)", async () => {
    const { sent, chain } = fakeChain({ [T.rif.toLowerCase()]: 5_000n * 10n ** 18n, [T.usdt0.toLowerCase()]: 0n });
    const c = loadConfig({ ...ENV, RIF_SELL_MIN: "200" });
    expect(await rebalancer(chain, {}, c).sellRifIfNeeded()).toBeUndefined();
    expect(sent).toHaveLength(0);
  });
});

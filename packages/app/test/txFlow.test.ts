import { describe, expect, it } from "vitest";
import type { Hex } from "viem";

import { quote, type Quote } from "../src/lib/ladder";
import { EXPIRY_OPTIONS, LIMIT_TTL_SECONDS, MARKET_TTL_SECONDS, MAX_LIMIT_TTL_SECONDS, expiryLabel, limitTtlSeconds, planTicket } from "../src/lib/plan";
import { IDLE, explorerTx, inFlight, isRejection, runTx, txLine, txReducer, type TxEvent, type TxState } from "../src/lib/txFlow";

const H = `0x${"ab".repeat(32)}` as Hex;
const meta = { label: "Approve to Permit3", step: 2, of: 3 };

function recorder() {
  let s: TxState = IDLE;
  const seen: TxState["kind"][] = [];
  const dispatch = (e: TxEvent) => {
    s = txReducer(s, e);
    seen.push(s.kind);
  };
  return { dispatch, get: () => s, seen };
}

describe("transaction state line (lib/txFlow)", () => {
  it("success: wallet → submitted → confirming → confirmed, with step k of n and the hash", async () => {
    const r = recorder();
    const hash = await runTx(r.dispatch, meta, {
      send: async () => H,
      blockNumber: async () => 100n,
      wait: async () => ({ status: "success", blockNumber: 101n }),
    });
    expect(hash).toBe(H);
    expect(r.seen).toEqual(["wallet", "submitted", "confirming", "confirmed"]);
    const l = txLine(r.get());
    expect(l).toMatchObject({ step: "Step 2 of 3", tone: "confirmed", hash: H, retry: false });
    expect(l.text).toMatch(/confirmed ✓ in block 101/);
  });

  it("each intermediate line says what is happening", () => {
    let s = txReducer(IDLE, { type: "start", ...meta });
    expect(txLine(s).text).toMatch(/confirm in your wallet/);
    expect(inFlight(s)).toBe(true);
    s = txReducer(s, { type: "sent", hash: H });
    expect(txLine(s)).toMatchObject({ tone: "busy", hash: H });
    expect(txLine(s).text).toMatch(/submitted/);
    s = txReducer(s, { type: "confirming", sinceBlock: 7n });
    expect(txLine(s).text).toMatch(/confirming… \(sent after block 7\)/);
    expect(inFlight(s)).toBe(true);
    expect(txLine(txReducer(s, { type: "confirmed", block: null })).text).toMatch(/confirmed ✓$/);
    // single-step flows say no "step"
    expect(txLine(txReducer(IDLE, { type: "start", label: "Unwrap", step: 1, of: 1 })).step).toBe("");
  });

  it("a declined prompt is 'rejected in wallet' and can be retried", async () => {
    const r = recorder();
    const rejected = Object.assign(new Error("User rejected the request."), { code: 4001 });
    await expect(runTx(r.dispatch, meta, { send: async () => Promise.reject(rejected), wait: async () => ({ status: "success" }) })).rejects.toBe(rejected);
    expect(r.get().kind).toBe("rejected");
    expect(txLine(r.get())).toMatchObject({ tone: "rejected", retry: true, hash: null });
    expect(inFlight(r.get())).toBe(false);
  });

  it("a revert after submission is 'failed' and keeps the hash to inspect", async () => {
    const r = recorder();
    await expect(
      runTx(r.dispatch, meta, { send: async () => H, wait: async () => ({ status: "reverted", blockNumber: 5n }) }),
    ).rejects.toThrow(/reverted/);
    const s = r.get();
    expect(s.kind).toBe("failed");
    expect(txLine(s)).toMatchObject({ tone: "failed", hash: H, retry: true });
    expect(txLine(s).text).toMatch(/failed: transaction reverted on-chain/);
  });

  it("a wallet error that is not a rejection is a failure with its first line", async () => {
    const r = recorder();
    const e = new Error("insufficient funds for gas\nDetails: …");
    await expect(runTx(r.dispatch, meta, { send: async () => Promise.reject(e), wait: async () => ({ status: "success" }) })).rejects.toBe(e);
    expect(r.get()).toMatchObject({ kind: "failed", reason: "insufficient funds for gas", hash: null });
    expect(isRejection({ cause: { code: 4001 } })).toBe(true);
    expect(isRejection(new Error("execution reverted"))).toBe(false);
  });

  it("explorer: Rootstock transactions link to Blockscout", () => {
    expect(explorerTx(30, H)).toBe(`https://rootstock.blockscout.com/tx/${H}`);
    expect(explorerTx(30, "0x1234")).toBeNull();
    expect(explorerTx(999, H)).toBeNull();
  });
});

describe("limit expiry selector → plan ttl and funding ttl", () => {
  const book = { bids: [{ price: 1, size: 1e9, source: "UNI" as const }], asks: [{ price: 1, size: 1e9, source: "UNI" as const }] };
  // A sell limit above the bids rests: the limit branch of planTicket.
  const q: Quote = quote({ ...book, side: "sell", amountIn: 20, limit: 1.1, slippageBps: 30 });
  const plan = (expiry?: (typeof EXPIRY_OPTIONS)[number]["id"]) =>
    planTicket({ q, mid: 1, mode: "limit", side: "sell", amount: 20, limit: 1.1, slices: 1, everyMin: 1, expiry })!;

  it("each choice signs that life, and the Permit3 grant follows it", () => {
    expect(EXPIRY_OPTIONS.map((o) => o.id)).toEqual(["1h", "1d", "7d", "30d", "90d"]);
    for (const o of EXPIRY_OPTIONS) {
      const p = plan(o.id);
      expect(p.kind).toBe("limit");
      expect(p.ttlSeconds).toBe(limitTtlSeconds(o.id));
      expect(p.fundingTtlSeconds).toBe(p.ttlSeconds);
    }
    expect(plan("1h").ttlSeconds).toBe(3600);
    expect(plan("7d").ttlSeconds).toBe(7 * 86400);
    expect(plan("30d").ttlSeconds).toBe(30 * 86400);
    expect(plan("90d").ttlSeconds).toBe(MAX_LIMIT_TTL_SECONDS);
    expect(MAX_LIMIT_TTL_SECONDS).toBeLessThanOrEqual(90 * 86400);
  });

  it("default is 1 day; unknown ids fall back to it; labels for Details", () => {
    expect(plan().ttlSeconds).toBe(LIMIT_TTL_SECONDS);
    expect(limitTtlSeconds("nope")).toBe(LIMIT_TTL_SECONDS);
    expect(expiryLabel("90d")).toBe("90 days");
    expect(expiryLabel(undefined)).toBe("1 day");
  });

  it("market tickets ignore the selector and keep their 300 s life", () => {
    const mq = quote({ ...book, side: "sell", amountIn: 20, limit: null, slippageBps: 30 });
    const p = planTicket({ q: mq, mid: 1, mode: "market", side: "sell", amount: 20, limit: null, slices: 1, everyMin: 1, expiry: "90d" })!;
    expect(p.ttlSeconds).toBe(MARKET_TTL_SECONDS);
    expect(p.fundingTtlSeconds).toBe(MARKET_TTL_SECONDS);
  });
});

describe("a receipt-wait timeout is not a failure (Rootstock inclusion can take minutes)", () => {
  it("keeps waiting while confirming and confirms when the receipt lands", async () => {
    const { runTx, txReducer, IDLE, isReceiptTimeout } = await import("../src/lib/txFlow");
    let s = IDLE;
    const states: string[] = [];
    let waits = 0;
    const timeout = Object.assign(new Error('Timed out while waiting for transaction with hash "0xa3e769f30381a4db65de41bed6c16bda321e84317d986fe20d8f663f2238412" to be confirmed.'), {
      name: "WaitForTransactionReceiptTimeoutError",
    });
    expect(isReceiptTimeout(timeout)).toBe(true);
    const hash = await runTx(
      (e) => {
        s = txReducer(s, e);
        states.push(s.kind);
      },
      { label: "Approve", step: 1, of: 1 },
      {
        send: async () => "0x" + "ab".repeat(32) as `0x${string}`,
        wait: async () => {
          if (++waits < 3) throw timeout;
          return { status: "success", blockNumber: 9n };
        },
      },
    );
    expect(hash).toBe("0x" + "ab".repeat(32));
    expect(waits).toBe(3);
    expect(states).not.toContain("failed");
    expect(s.kind).toBe("confirmed");
  });

  it("error lines shorten hashes so they fit the panel", async () => {
    const { errorReason } = await import("../src/lib/txFlow");
    expect(errorReason(new Error('boom for "0xa3e769f30381a4db65de41bed6c16bda321e84317d986fe20d8f663f2238412"'))).toBe('boom for "0xa3e769…238412"');
  });
});

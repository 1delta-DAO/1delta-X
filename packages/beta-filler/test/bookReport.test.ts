import type { Hex } from "viem";
import { describe, expect, it } from "vitest";

import { fillReporter, fillReportOf } from "../src/bookReport";
import type { EngineEvent } from "../src/engine";
import type { PendingTx, Resolution } from "../src/guard";

const TX = `0x${"ab".repeat(32)}` as Hex;
const ORDER = `0x${"cd".repeat(32)}` as Hex;
const fillTx = (over: Partial<PendingTx> = {}): PendingTx =>
  ({ hash: TX, nonce: 1, gasLimit: "1", gasPrice: "1", kind: "fill", strategy: "route", orderHash: ORDER, sentAt: 0, ...over }) as PendingTx;
const resolved = (status: Resolution["status"], p = fillTx()): EngineEvent => ({ type: "resolved", resolution: { status, pending: p } as Resolution });

describe("fillReportOf", () => {
  it("maps fill events: sent → pending, success → confirmed, reverted/dropped → failed, timeout/waiting → nothing", () => {
    expect(fillReportOf({ type: "sent", pending: fillTx() })).toEqual({ txHash: TX, orderHash: ORDER, status: "pending" });
    expect(fillReportOf(resolved("success"))).toEqual({ txHash: TX, status: "confirmed" });
    expect(fillReportOf(resolved("reverted"))).toEqual({ txHash: TX, status: "failed" });
    expect(fillReportOf(resolved("dropped"))).toEqual({ txHash: TX, status: "failed" });
    expect(fillReportOf(resolved("timeout"))).toBeUndefined();
    expect(fillReportOf(resolved("waiting"))).toBeUndefined();
  });

  it("never reports a non-fill tx (approvals, rebalancing)", () => {
    const approve = fillTx({ kind: "approve", orderHash: undefined });
    expect(fillReportOf({ type: "sent", pending: approve })).toBeUndefined();
    expect(fillReportOf(resolved("success", approve))).toBeUndefined();
    expect(fillReportOf(resolved("success", fillTx({ kind: "redeem" })))).toBeUndefined();
  });
});

describe("fillReporter", () => {
  it("POSTs to <base>/fills/report with the binding key", async () => {
    const calls: Array<{ url: string; init?: RequestInit }> = [];
    const hook = fillReporter({
      base: "https://book.example/",
      bindingKey: "k",
      fetch: async (url, init) => (calls.push({ url, init }), Response.json({ results: [{ result: "indexed" }] })),
    });
    await hook(resolved("success"));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://book.example/fills/report");
    expect(new Headers(calls[0]!.init!.headers).get("x-orderbook-binding-key")).toBe("k");
    expect(JSON.parse(String(calls[0]!.init!.body))).toEqual({ txHash: TX, status: "confirmed" });
  });

  it("is a no-op without a binding key", async () => {
    let n = 0;
    const hook = fillReporter({ base: "https://b", fetch: async () => (n++, new Response("")) });
    await hook(resolved("success"));
    expect(n).toBe(0);
  });

  it("swallows a thrown fetch, an HTTP error and a hang (bounded by the timeout)", async () => {
    const logs: string[] = [];
    const log = (m: string) => logs.push(m);
    await expect(fillReporter({ base: "https://b", bindingKey: "k", log, fetch: async () => { throw new Error("down"); } })(resolved("success"))).resolves.toBeUndefined();
    await expect(fillReporter({ base: "https://b", bindingKey: "k", log, fetch: async () => new Response("x", { status: 403 }) })(resolved("success"))).resolves.toBeUndefined();
    const t0 = Date.now();
    await expect(fillReporter({ base: "https://b", bindingKey: "k", log, timeoutMs: 50, fetch: () => new Promise<Response>(() => {}) })(resolved("success"))).resolves.toBeUndefined();
    expect(Date.now() - t0).toBeLessThan(1_000);
    expect(logs).toEqual([
      expect.stringMatching(/confirmed .*: down/),
      expect.stringMatching(/HTTP 403/),
      expect.stringMatching(/timed out after 50 ms/),
    ]);
  });
});

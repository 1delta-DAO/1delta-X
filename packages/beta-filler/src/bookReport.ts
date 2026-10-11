import type { Hex } from "viem";

import type { EngineEvent } from "./engine";

/**
 * Telling the orderbook about our own fill txs (`POST /fills/report` on
 * packages/orderbook-worker). The book's RPC may serve no `eth_getLogs`
 * (Rootstock's public node), so its log scan never sees a fill; it does serve
 * receipts, and the book indexes a reported tx from its OWN receipt read.
 *
 *   sent fill        → `{ txHash, orderHash, status: "pending" }` (the app shows "Fill submitted")
 *   resolved success → `{ txHash, status: "confirmed" }` (the book reads the receipt and indexes it)
 *   reverted/dropped → `{ txHash, status: "failed" }` (clears the pending marker)
 *
 * Timeouts are still pending: nothing is reported. Non-fill txs are never reported.
 */
export interface FillReport {
  txHash: Hex;
  status: "pending" | "confirmed" | "failed";
  orderHash?: Hex;
}

/** The report an engine event calls for, if any. */
export function fillReportOf(e: EngineEvent): FillReport | undefined {
  if (e.type === "sent") {
    const p = e.pending;
    return p.kind === "fill" && p.orderHash ? { txHash: p.hash, orderHash: p.orderHash, status: "pending" } : undefined;
  }
  if (e.type === "resolved") {
    const r = e.resolution;
    if (r.pending.kind !== "fill") return undefined;
    if (r.status === "success") return { txHash: r.pending.hash, status: "confirmed" };
    if (r.status === "reverted" || r.status === "dropped") return { txHash: r.pending.hash, status: "failed" };
  }
  return undefined;
}

export const BINDING_KEY_HEADER = "x-orderbook-binding-key";
/** A report never holds a tick longer than this. */
export const REPORT_TIMEOUT_MS = 3_000;

export interface ReporterOptions {
  /** The book's base URL (`https://book` over a service binding). */
  base: string;
  fetch: (url: string, init?: RequestInit) => Promise<Response>;
  /** The book's `BINDING_KEY`. Without one nothing is reported (the book would 403). */
  bindingKey?: string;
  /** Extra headers (e.g. the binding's client-IP header). */
  headers?: Record<string, string>;
  timeoutMs?: number;
  log?: (m: string) => void;
}

/**
 * An engine `onEvent` hook that reports fill txs to the book. Best effort: a
 * failure (network, 4xx/5xx, timeout) is logged and swallowed, never thrown, and
 * the call is bounded by `timeoutMs`. A no-op without a binding key.
 */
export function fillReporter(o: ReporterOptions): (e: EngineEvent) => Promise<void> {
  const key = o.bindingKey?.trim();
  return async (e) => {
    if (!key) return;
    const report = fillReportOf(e);
    if (!report) return;
    await postFillReport(o, key, report);
  };
}

async function postFillReport(o: ReporterOptions, key: string, report: FillReport): Promise<void> {
  const timeoutMs = o.timeoutMs ?? REPORT_TIMEOUT_MS;
  const ctrl = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<"timeout">((resolve) => {
    timer = setTimeout(() => {
      ctrl.abort();
      resolve("timeout");
    }, timeoutMs);
  });
  try {
    const res = await Promise.race([
      o.fetch(`${o.base.replace(/\/+$/, "")}/fills/report`, {
        method: "POST",
        headers: { ...(o.headers ?? {}), "content-type": "application/json", [BINDING_KEY_HEADER]: key },
        body: JSON.stringify(report),
        signal: ctrl.signal,
      }),
      timeout,
    ]);
    if (res === "timeout") o.log?.(`book report ${report.status} ${report.txHash}: timed out after ${timeoutMs} ms`);
    else if (!res.ok) o.log?.(`book report ${report.status} ${report.txHash}: HTTP ${res.status}`);
    else if (report.status === "confirmed") {
      // The book's RPC may lag ours by a block: say so (its lens re-check still catches the fill).
      const body = (await res.json().catch(() => null)) as { results?: Array<{ result?: string }> } | null;
      const result = body?.results?.[0]?.result;
      if (result === "no-receipt" || result === "rpc-error") o.log?.(`book report confirmed ${report.txHash}: book says ${result}`);
    } else await res.body?.cancel();
  } catch (err) {
    o.log?.(`book report ${report.status} ${report.txHash}: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
  } finally {
    clearTimeout(timer);
  }
}

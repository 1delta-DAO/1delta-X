/**
 * Staging-harness JSON-RPC proxy (LOCAL ONLY): sits between the two workers and
 * anvil. Not part of CI.
 *
 *   PROXY_PORT=18646 UPSTREAM=http://127.0.0.1:18645 RUN_DIR=… tsx e2e/rpc-proxy.ts
 *
 * Each worker gets its own path, so every call is attributed: RPC_URL =
 * http://127.0.0.1:<port>/ob for the orderbook, /filler for the filler.
 *
 *  - counts calls per tag and method, with upstream timing and errors;
 *  - injects latency (mean ± uniform jitter, per HTTP request);
 *  - optionally rate-limits (token bucket per tag → HTTP 429, JSON-RPC -32005);
 *  - answers `eth_gasPrice` with Rootstock's price (anvil always says 1 gwei
 *    whatever `--gas-price` is; anvil mines any price ≥ the 0 base fee);
 *  - logs every `eth_sendRawTransaction` (hash, from, nonce) — the double-send /
 *    nonce-clash evidence — and can HOLD or DROP them (crash-during-broadcast test);
 *  - is the alert webhook sink (`POST /__webhook`);
 *  - streams a per-call timeline to $RUN_DIR/rpc-timeline.jsonl.
 *
 * Control: GET /__stats, POST /__reset, POST /__config {latencyMs, jitterMs,
 * rateLimit: {perSecond, burst} | null, gasPriceWei, sendRaw: "pass"|"hold"|"hold-drop"|"drop",
 * holdMs}, GET /__txs, GET /__webhooks.
 */
import { appendFileSync, mkdirSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join } from "node:path";

import { keccak256, parseTransaction, recoverTransactionAddress, type Hex, type TransactionSerialized } from "viem";

const PORT = Number(process.env.PROXY_PORT ?? 18646);
const UPSTREAM = process.env.UPSTREAM ?? "http://127.0.0.1:18645";
const RUN_DIR = process.env.RUN_DIR ?? ".";

interface Config {
  latencyMs: number;
  jitterMs: number;
  /** Token bucket per tag; `tags` limits it to those tags (default: every tag). */
  rateLimit: { perSecond: number; burst: number; tags?: string[] } | null;
  gasPriceWei: string | null;
  /**
   * pass: forward. hold: wait holdMs, then forward (the node gets it late).
   * hold-drop: wait holdMs, then never forward (a broadcast lost in flight — kill
   * the worker during the hold). drop: fail the transport at once.
   */
  sendRaw: "pass" | "hold" | "hold-drop" | "drop";
  holdMs: number;
  /**
   * Methods refused per tag with JSON-RPC -32601, as Rootstock's public node does for
   * eth_getLogs / eth_newFilter (DENY_METHODS="ob:eth_getLogs,filler:eth_foo").
   */
  deny: Record<string, string[]>;
}

const config: Config = {
  latencyMs: Number(process.env.LATENCY_MS ?? 0),
  jitterMs: Number(process.env.JITTER_MS ?? 0),
  rateLimit: process.env.RATE_LIMIT_RPS ? { perSecond: Number(process.env.RATE_LIMIT_RPS), burst: Number(process.env.RATE_LIMIT_BURST ?? process.env.RATE_LIMIT_RPS) } : null,
  gasPriceWei: process.env.GAS_PRICE_WEI ?? "26065600",
  sendRaw: "pass",
  holdMs: 0,
  deny: (process.env.DENY_METHODS ?? "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean)
    .reduce<Record<string, string[]>>((a, x) => {
      const [tag, m] = x.split(":");
      if (tag && m) (a[tag] ??= []).push(m);
      return a;
    }, {}),
};

interface TagStats {
  calls: number;
  httpRequests: number;
  byMethod: Record<string, number>;
  errors: Record<string, number>;
  rateLimited: number;
  upstreamMs: number[];
}

let stats: Record<string, TagStats> = {};
let since = Date.now();
const txs: Array<{ at: number; tag: string; hash: Hex; raw: Hex; from?: string; nonce?: number; to?: string | null; gas?: string; gasPrice?: string; mode: string; forwardedAt?: number; result?: string; error?: string }> = [];
const webhooks: Array<{ at: number; body: unknown }> = [];
const buckets: Record<string, { tokens: number; at: number }> = {};

mkdirSync(RUN_DIR, { recursive: true });
const timelinePath = join(RUN_DIR, "rpc-timeline.jsonl");
let timelineBuf: string[] = [];
setInterval(() => {
  if (!timelineBuf.length) return;
  appendFileSync(timelinePath, timelineBuf.join(""));
  timelineBuf = [];
}, 1000).unref();

const tagStats = (tag: string): TagStats => (stats[tag] ??= { calls: 0, httpRequests: 0, byMethod: {}, errors: {}, rateLimited: 0, upstreamMs: [] });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function takeToken(tag: string): boolean {
  const rl = config.rateLimit;
  if (!rl || (rl.tags && !rl.tags.includes(tag))) return true;
  const now = Date.now();
  const b = (buckets[tag] ??= { tokens: rl.burst, at: now });
  b.tokens = Math.min(rl.burst, b.tokens + ((now - b.at) / 1000) * rl.perSecond);
  b.at = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(text);
}

function pct(xs: number[], p: number): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]!;
}

function summary(): unknown {
  const out: Record<string, unknown> = {};
  for (const [tag, s] of Object.entries(stats)) {
    out[tag] = {
      calls: s.calls,
      httpRequests: s.httpRequests,
      rateLimited: s.rateLimited,
      byMethod: Object.fromEntries(Object.entries(s.byMethod).sort((a, b) => b[1] - a[1])),
      errors: s.errors,
      upstreamMs: { p50: pct(s.upstreamMs, 50), p95: pct(s.upstreamMs, 95), max: Math.max(0, ...s.upstreamMs) },
    };
  }
  return { since, now: Date.now(), config, tags: out, txs: txs.length, webhooks: webhooks.length };
}

async function recordSendRaw(tag: string, raw: Hex): Promise<(typeof txs)[number]> {
  const rec: (typeof txs)[number] = { at: Date.now(), tag, hash: keccak256(raw), raw, mode: config.sendRaw };
  try {
    const tx = parseTransaction(raw as TransactionSerialized);
    rec.nonce = tx.nonce;
    rec.to = tx.to ?? null;
    rec.gas = tx.gas?.toString();
    rec.gasPrice = (tx as { gasPrice?: bigint }).gasPrice?.toString();
    rec.from = (await recoverTransactionAddress({ serializedTransaction: raw as TransactionSerialized })).toLowerCase();
  } catch (e) {
    rec.error = `parse: ${(e as Error).message.split("\n")[0]}`;
  }
  txs.push(rec);
  return rec;
}

async function forward(body: string): Promise<{ status: number; text: string; ms: number }> {
  const t0 = Date.now();
  const r = await fetch(UPSTREAM, { method: "POST", headers: { "content-type": "application/json" }, body });
  const text = await r.text();
  return { status: r.status, text, ms: Date.now() - t0 };
}

async function handleRpc(tag: string, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readBody(req);
  const s = tagStats(tag);
  s.httpRequests++;
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return send(res, 400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
  }
  const calls = (Array.isArray(parsed) ? parsed : [parsed]) as Array<{ id?: unknown; method?: string; params?: unknown[] }>;
  const t = Date.now();
  for (const c of calls) {
    const m = String(c.method ?? "?");
    s.calls++;
    s.byMethod[m] = (s.byMethod[m] ?? 0) + 1;
  }
  if (!takeToken(tag)) {
    s.rateLimited++;
    for (const c of calls) timelineBuf.push(`${JSON.stringify({ t, tag, m: c.method, rl: 1 })}\n`);
    const err = calls.map((c) => ({ jsonrpc: "2.0", id: c.id ?? null, error: { code: -32005, message: "rate limited by staging proxy" } }));
    return send(res, 429, Array.isArray(parsed) ? err : err[0]);
  }
  const lat = Math.max(0, config.latencyMs + (config.jitterMs ? (Math.random() * 2 - 1) * config.jitterMs : 0));
  if (lat > 0) await sleep(lat);

  // Methods the emulated provider does not serve (single calls only).
  if (!Array.isArray(parsed) && config.deny[tag]?.includes(String(calls[0]?.method))) {
    const m = String(calls[0]?.method);
    s.errors[`${m}:-32601`] = (s.errors[`${m}:-32601`] ?? 0) + 1;
    timelineBuf.push(`${JSON.stringify({ t, tag, m, ms: 0, err: `${m}:-32601`, denied: 1 })}\n`);
    return send(res, 200, { jsonrpc: "2.0", id: calls[0]?.id ?? null, error: { code: -32601, message: `the method ${m} does not exist/is not available` } });
  }

  // Local answers (single calls only — both workers run viem with batch: false).
  if (!Array.isArray(parsed) && calls[0]?.method === "eth_gasPrice" && config.gasPriceWei) {
    timelineBuf.push(`${JSON.stringify({ t, tag, m: "eth_gasPrice", ms: 0, local: 1 })}\n`);
    return send(res, 200, { jsonrpc: "2.0", id: calls[0].id ?? null, result: `0x${BigInt(config.gasPriceWei).toString(16)}` });
  }
  let rec: (typeof txs)[number] | undefined;
  if (!Array.isArray(parsed) && calls[0]?.method === "eth_sendRawTransaction") {
    rec = await recordSendRaw(tag, (calls[0].params?.[0] ?? "0x") as Hex);
    if ((config.sendRaw === "hold" || config.sendRaw === "hold-drop") && config.holdMs > 0) await sleep(config.holdMs);
    if (config.sendRaw === "drop" || config.sendRaw === "hold-drop") {
      rec.result = `${config.sendRaw} by proxy (never reached the node)`;
      // Never reaches the node; a still-connected client sees a transport failure.
      res.destroy();
      return;
    }
  }
  try {
    const up = await forward(body);
    s.upstreamMs.push(up.ms);
    if (s.upstreamMs.length > 200_000) s.upstreamMs.splice(0, 100_000);
    let errCode: string | undefined;
    if (up.text.includes('"error"')) {
      try {
        const j = JSON.parse(up.text) as { error?: { code?: number; message?: string } } | Array<{ error?: { code?: number; message?: string } }>;
        for (const one of Array.isArray(j) ? j : [j]) {
          if (one.error) {
            errCode = `${calls[0]?.method}:${one.error.code}`;
            s.errors[errCode] = (s.errors[errCode] ?? 0) + 1;
          }
        }
      } catch {
        // not JSON
      }
    }
    if (rec) {
      rec.forwardedAt = Date.now();
      rec.result = errCode ? `error ${up.text.slice(0, 200)}` : "ok";
    }
    for (const c of calls) timelineBuf.push(`${JSON.stringify({ t, tag, m: c.method, ms: up.ms, lat: Math.round(lat), ...(errCode ? { err: errCode } : {}) })}\n`);
    res.writeHead(up.status, { "content-type": "application/json" });
    res.end(up.text);
  } catch (e) {
    const k = `upstream:${(e as Error).message.slice(0, 60)}`;
    s.errors[k] = (s.errors[k] ?? 0) + 1;
    send(res, 502, { jsonrpc: "2.0", id: calls[0]?.id ?? null, error: { code: -32603, message: "upstream unreachable" } });
  }
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
  void (async () => {
    try {
      if (url.pathname === "/__stats") return send(res, 200, summary());
      if (url.pathname === "/__txs") return send(res, 200, txs);
      if (url.pathname === "/__webhooks") return send(res, 200, webhooks);
      if (url.pathname === "/__reset" && req.method === "POST") {
        stats = {};
        since = Date.now();
        return send(res, 200, { ok: true, since });
      }
      if (url.pathname === "/__config" && req.method === "POST") {
        const patch = JSON.parse((await readBody(req)) || "{}") as Partial<Config>;
        Object.assign(config, patch);
        return send(res, 200, config);
      }
      if (url.pathname === "/__webhook" && req.method === "POST") {
        const text = await readBody(req);
        let body: unknown = text;
        try {
          body = JSON.parse(text);
        } catch {
          // keep text
        }
        webhooks.push({ at: Date.now(), body });
        appendFileSync(join(RUN_DIR, "webhooks.jsonl"), `${JSON.stringify({ at: Date.now(), body })}\n`);
        return send(res, 200, { ok: true });
      }
      if (req.method !== "POST") return send(res, 405, { error: "POST JSON-RPC only" });
      const tag = url.pathname.replace(/^\/+|\/+$/g, "") || "default";
      await handleRpc(tag, req, res);
    } catch (e) {
      if (!res.headersSent) send(res, 500, { error: (e as Error).message });
    }
  })();
});
server.keepAliveTimeout = 30_000;
server.listen(PORT, "127.0.0.1", () => {
  console.log(`rpc-proxy :${PORT} → ${UPSTREAM} (latency ${config.latencyMs}±${config.jitterMs} ms, gasPrice ${config.gasPriceWei ?? "upstream"})`);
});

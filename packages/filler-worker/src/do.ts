import { DurableObject } from "cloudflare:workers";
import {
  balanceOf,
  connect,
  Engine,
  fetchOrders,
  fmtUnits,
  ROOTSTOCK,
  sanitize,
  type BookEntry,
  type Chain,
  type Config,
  type EngineEvent,
  type StateStore,
  type RecentEvent,
  type TickReport,
} from "@1delta-x/beta-filler/core";
import { formatEther, type Address } from "viem";

import { Alerter, emptyAlertState, type AlertState } from "./alerts";
import { isConfigured, loadFillerConfig, loadWorkerConfig, rpcUrls, type Env, type WorkerConfig } from "./config";
import { countSince, listFills, migrateFills, recordResolution, toCsv, type Sql } from "./fills";

/** What the DO needs from the outside world — swapped wholesale in tests. */
export interface WorkerDeps {
  /** The chain client. `rpc.fetchFn` counts every RPC call against the tick's subrequest budget. */
  makeChain(cfg: Config, rpc: { fetchFn: typeof fetch; count: () => void }): Chain;
  /** Overrides the book transport (service binding / ORDERBOOK_URL). */
  fetchBook?: (url: string, init?: RequestInit) => Promise<Response>;
  /** Overrides the webhook transport. */
  fetchAlert?: (url: string, init: RequestInit) => Promise<Response>;
  now(): number;
}

export const defaultDeps: WorkerDeps = {
  makeChain: (cfg, rpc) => connect(cfg, { fetchFn: rpc.fetchFn, retryCount: 1 }),
  now: () => Date.now(),
};

let deps: WorkerDeps = defaultDeps;

/** Tests: inject a fake chain / book / clock. Module state; not reachable from any request. */
export function setDeps(d: Partial<WorkerDeps>): void {
  deps = { ...defaultDeps, ...d };
}

/** The worker's own durable state (next to the engine's). */
export interface WorkerState {
  paused: boolean;
  /** The admin API's dry-run override (unset = the DRY_RUN var). */
  dryRun?: boolean;
  lastTickAt?: number;
  lastTickMs?: number;
  lastSummary?: TickSummary;
  lastError?: string;
  rpcErrorStreak: number;
  intakeErrorStreak: number;
  lastBalanceCheck?: number;
  lastRebalanceAt?: number;
  balances?: Record<string, string>;
  alerts: AlertState;
  ticks: number;
  /** The last orderbook /health read by the monitor (every BOOK_HEALTH_SECONDS). */
  lastBookHealthAt?: number;
  bookHealth?: BookHealthView;
  /** Since when the orderbook reported no alarm at all (`lastAlarm: null`), ms. */
  bookNoAlarmSince?: number;
}

/** What the monitor keeps of the orderbook's /health. */
export interface BookHealthView {
  at: number;
  error?: string;
  lastAlarm?: number | null;
  alarmIntervalSeconds?: number;
  logsUnsupported?: boolean;
  logsOk?: boolean;
  logsError?: string | null;
  rpc?: string;
}

/** One tick, as /tick and /status report it. */
export interface TickSummary {
  at: number;
  source: string;
  durationMs?: number;
  subrequests?: number;
  entries?: number;
  evaluated?: number;
  bounded?: boolean;
  resolution?: { status: string; tx: string; kind: string };
  sent?: { tx: string; kind: string; strategy: string; orderHash?: string };
  pending?: boolean;
  /** Orders skipped with zero RPC: a resting verdict / own-fill hold still valid, or expiring too soon. */
  held?: number;
  paused?: boolean;
  rebalance?: { action: string; status: string; reason?: string };
  outcomes?: Array<{ orderHash: string; status: string; strategy?: string; reason?: string }>;
  errors: string[];
  skipped?: string;
}

const WORKER_KEY = "worker";
/**
 * The orderbook /health is re-read this soon (instead of BOOK_HEALTH_SECONDS) after an
 * INCONCLUSIVE read: unreachable, or its alarm has not run yet (`lastAlarm: null` —
 * right after a deploy, before the book's first alarm). Otherwise a book whose RPC
 * serves no eth_getLogs went unreported for the first 5 minutes.
 */
const BOOK_HEALTH_RETRY_MS = 60_000;
const json = (v: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x), 1), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
const errMsg = (e: unknown) => sanitize(e instanceof Error ? e.message.split("\n")[0] : e);

/**
 * Strip (possibly secret, API-key-bearing) RPC URLs from any text that leaves the
 * worker — `RPC_URL_SECRET` and the `RPC_URL` var alike.
 */
export function redact(text: string, rpcUrl: unknown): string {
  for (const url of Array.isArray(rpcUrl) ? rpcUrl : [rpcUrl]) text = redactOne(text, url);
  return text;
}

function redactOne(text: string, rpcUrl: unknown): string {
  if (typeof rpcUrl !== "string" || !rpcUrl) return text;
  let out = text.split(rpcUrl).join("<RPC_URL>");
  try {
    const u = new URL(rpcUrl);
    if (u.pathname.length > 1 || u.search) out = out.split(`${u.origin}${u.pathname}`).join("<RPC_URL>");
    out = out.split(u.host).join("<rpc-host>");
  } catch {
    // not a URL: the exact-string replacement above is all we can do
  }
  return out;
}

/**
 * THE filler: one instance (`idFromName("filler")`). Its alarm runs one tick of
 * the platform-agnostic engine (@1delta-x/beta-filler/core) and re-arms itself —
 * every TICK_SECONDS, every PENDING_TICK_SECONDS while a tx is outstanding so its
 * receipt is read quickly. The cron trigger only re-arms a missing alarm.
 *
 * A tick: resolve the outstanding tx → if none, sweep the book (≤ MAX_ORDERS_PER_TICK
 * orders, round-robin, ≤ MAX_SUBREQUESTS_PER_TICK, ≤ TICK_BUDGET_MS; at most ONE tx
 * sent) → if nothing was sent, one rebalancer step → alerts.
 *
 * Ticks are serialised in memory (an alarm and a manual /tick never overlap: the
 * second joins the first), so there is never more than one send in flight.
 */
export class FillerDO extends DurableObject<Env> {
  private wcfg: WorkerConfig | undefined;
  private wcfgError: string | undefined;
  private enginePromise: Promise<Engine> | undefined;
  private engineDryRun: boolean | undefined;
  private ws: WorkerState | undefined;
  private running: Promise<TickSummary> | undefined;
  private readonly meter = { used: 0 };
  private readonly logTail: string[] = [];
  private readonly sql: Sql;
  private readonly store: StateStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql as unknown as Sql;
    migrateFills(this.sql);
    this.store = {
      get: async <T>(k: string) => (await ctx.storage.get<T>(k)) ?? undefined,
      put: async (k: string, v: unknown) => ctx.storage.put(k, v),
    };
    try {
      this.wcfg = loadWorkerConfig(env);
    } catch (e) {
      this.wcfgError = errMsg(e);
    }
  }

  // ──────────────────── state ────────────────────

  private async state(): Promise<WorkerState> {
    if (this.ws) return this.ws;
    const saved = await this.ctx.storage.get<WorkerState>(WORKER_KEY);
    this.ws = saved ?? { paused: this.wcfg?.startPaused ?? false, rpcErrorStreak: 0, intakeErrorStreak: 0, alerts: emptyAlertState(), ticks: 0 };
    this.ws.alerts ??= emptyAlertState();
    return this.ws;
  }

  private async saveState(): Promise<void> {
    if (this.ws) await this.ctx.storage.put(WORKER_KEY, this.ws);
  }

  private readonly log = (m: string): void => {
    const line = redact(sanitize(m, 600), rpcUrls(this.env));
    console.log(line);
    this.logTail.push(`${new Date(deps.now()).toISOString()} ${line}`);
    if (this.logTail.length > 200) this.logTail.splice(0, this.logTail.length - 200);
  };

  /**
   * The engine, built once and cached. Only a TICK may rebuild it (after a dry-run
   * toggle): ticks are serialised, and the previous engine saved its state at the end
   * of its tick, so the new one loads exactly that. Readers (/status) take whatever
   * engine exists — never a second instance with its own in-memory state.
   */
  private getEngine(rebuildIfStale = false): Promise<Engine> {
    const ws = this.ws;
    const want = ws?.dryRun;
    if (this.enginePromise && (!rebuildIfStale || this.engineDryRun === want)) return this.enginePromise;
    this.engineDryRun = want;
    const p = this.buildEngine(want).catch((e: unknown) => {
      if (this.enginePromise === p) this.enginePromise = undefined;
      throw e;
    });
    this.enginePromise = p;
    return p;
  }

  private async buildEngine(dryRun: boolean | undefined): Promise<Engine> {
    const cfg = loadFillerConfig(this.env, dryRun);
    const count = () => {
      this.meter.used++;
    };
    const fetchFn = ((input: RequestInfo | URL, init?: RequestInit) => {
      count();
      return fetch(input, init);
    }) as typeof fetch;
    const chain = deps.makeChain(cfg, { fetchFn, count });
    return Engine.create({ cfg, chain, store: this.store, log: this.log, now: () => deps.now(), onEvent: (e) => this.onEvent(e) });
  }

  private onEvent(e: EngineEvent): void {
    if (e.type === "resolved") recordResolution(this.sql, e.resolution, deps.now(), this.wcfg?.maxFillRows ?? 20_000);
  }

  private alerter(ws: WorkerState): Alerter | undefined {
    if (!this.wcfg) return undefined;
    const doFetch = deps.fetchAlert ?? ((u: string, i: RequestInit) => fetch(u, i));
    const a = new Alerter(this.wcfg.alerts, ws.alerts, doFetch, this.log);
    const raise = a.raise.bind(a);
    a.raise = (key, text, now) => raise(key, redact(text, rpcUrls(this.env)), now);
    return a;
  }

  // ──────────────────── the tick ────────────────────

  /** Run one tick, or join the one already running. */
  runTick(source: string): Promise<TickSummary> {
    this.running ??= this.doTick(source).finally(() => {
      this.running = undefined;
    });
    return this.running;
  }

  /** How the orderbook is reached: the injected test book, the ORDERBOOK binding, or ORDERBOOK_URL. Counted as subrequests. */
  private bookTransport(wcfg: WorkerConfig): { doFetch: (url: string, init?: RequestInit) => Promise<Response>; base: string; headers: Record<string, string> } {
    const binding = this.env.ORDERBOOK;
    let doFetch: (url: string, init?: RequestInit) => Promise<Response>;
    let base: string;
    const headers: Record<string, string> = {};
    if (deps.fetchBook) {
      doFetch = deps.fetchBook;
      base = "https://book";
    } else if (binding) {
      doFetch = (u, i) => binding.fetch(u, i);
      base = "https://book";
      if (this.env.ORDERBOOK_BINDING_KEY) {
        headers["x-orderbook-binding-key"] = this.env.ORDERBOOK_BINDING_KEY;
        headers["x-orderbook-client-ip"] = wcfg.orderbookClientIp;
      }
    } else if (wcfg.orderbookUrl) {
      doFetch = (u, i) => fetch(u, i);
      base = wcfg.orderbookUrl;
    } else {
      throw new Error("no orderbook: bind ORDERBOOK or set ORDERBOOK_URL");
    }
    const counted = (u: string, i?: RequestInit) => {
      this.meter.used++;
      return doFetch(u, i);
    };
    return { doFetch: counted, base, headers };
  }

  private async fetchEntries(wcfg: WorkerConfig): Promise<BookEntry[]> {
    const { doFetch, base, headers } = this.bookTransport(wcfg);
    const { entries } = await fetchOrders(base, doFetch, { maxPages: wcfg.intakeMaxPages, pageSize: wcfg.intakePageSize, headers });
    return entries;
  }

  private async doTick(source: string): Promise<TickSummary> {
    const ws = await this.state();
    const started = Date.now();
    const summary: TickSummary = { at: deps.now(), source, errors: [] };
    const wcfg = this.wcfg;
    try {
      if (!wcfg) {
        summary.skipped = `worker misconfigured: ${this.wcfgError}`;
        return summary;
      }
      let engine: Engine;
      try {
        engine = await this.getEngine(true);
      } catch (e) {
        summary.skipped = `filler misconfigured: ${errMsg(e)}`;
        return summary;
      }
      if (!isConfigured(engine.cfg)) {
        summary.skipped = "not configured: SETTLEMENT / PERMIT3 / LENS are placeholders";
        return summary;
      }
      this.meter.used = 0;
      const deadline = Date.now() + wcfg.tickBudgetMs;
      const canContinue = () =>
        !ws.paused && Date.now() < deadline && this.meter.used + wcfg.subrequestsPerOrder <= wcfg.maxSubrequestsPerTick;
      try {
        await engine.chain.pub.getBlockNumber();
      } catch (e) {
        ws.rpcErrorStreak++;
        summary.errors.push(`rpc: ${errMsg(e)}`);
        await this.monitor(engine, undefined, ws, summary);
        return summary;
      }
      const report = await engine.tick({
        fetchEntries: () => this.fetchEntries(wcfg),
        limits: { maxOrders: wcfg.maxOrdersPerTick, canContinue },
        paused: ws.paused,
        rebalance: ws.lastRebalanceAt === undefined || deps.now() - ws.lastRebalanceAt >= wcfg.rebalanceMs,
      });
      if (report.rebalanced) ws.lastRebalanceAt = deps.now();
      this.summarise(summary, report);
      const intakeErr = report.errors.some((x) => x.startsWith("intake:"));
      ws.intakeErrorStreak = intakeErr ? ws.intakeErrorStreak + 1 : report.entries !== undefined ? 0 : ws.intakeErrorStreak;
      ws.rpcErrorStreak = report.errors.some((x) => !x.startsWith("intake:")) ? ws.rpcErrorStreak + 1 : 0;
      await this.monitor(engine, report, ws, summary);
      return summary;
    } catch (e) {
      // Anything the engine did not catch itself.
      summary.errors.push(`tick: ${errMsg(e)}`);
      ws.lastError = errMsg(e);
      try {
        await this.alerter(ws)?.raise("tick-exception", `tick exception: ${errMsg(e)}`, deps.now());
      } catch {
        // alerting is best effort
      }
      return summary;
    } finally {
      summary.errors = summary.errors.map((x) => redact(x, rpcUrls(this.env)));
      summary.durationMs = Date.now() - started;
      summary.subrequests = this.meter.used;
      ws.lastTickAt = deps.now();
      ws.lastTickMs = summary.durationMs;
      ws.lastSummary = summary;
      if (summary.errors.length) ws.lastError = summary.errors[summary.errors.length - 1];
      if (ws.lastError) ws.lastError = redact(ws.lastError, rpcUrls(this.env));
      ws.ticks++;
      await this.saveState();
    }
  }

  /** A recent engine event with its `reason` redacted like every other outward string. */
  private redactEvent(e: RecentEvent): RecentEvent {
    return e.reason ? { ...e, reason: redact(e.reason, rpcUrls(this.env)) } : e;
  }

  private summarise(s: TickSummary, r: TickReport): void {
    s.entries = r.entries;
    s.evaluated = r.evaluated;
    if (r.held) s.held = r.held;
    s.bounded = r.bounded;
    s.pending = r.pending;
    s.paused = r.paused;
    if (r.resolution && r.resolution.status !== "waiting") s.resolution = { status: r.resolution.status, tx: r.resolution.pending.hash, kind: r.resolution.pending.kind };
    if (r.sent) s.sent = { tx: r.sent.hash, kind: r.sent.kind, strategy: r.sent.strategy, ...(r.sent.orderHash ? { orderHash: r.sent.orderHash } : {}) };
    // Reasons are provider/viem messages first lines: redacted like `errors`, so
    // a keyed RPC URL quoted on line 1 never reaches /status or the /tick reply.
    const urls = rpcUrls(this.env);
    if (r.rebalance) s.rebalance = { action: r.rebalance.action, status: r.rebalance.status, ...(r.rebalance.reason ? { reason: redact(r.rebalance.reason, urls) } : {}) };
    s.outcomes = r.outcomes.slice(0, 20).map((o) => ({ orderHash: o.orderHash, status: o.status, ...(o.strategy ? { strategy: o.strategy } : {}), ...(o.reason ? { reason: redact(o.reason, urls) } : {}) }));
    s.errors.push(...r.errors);
  }

  /** The alert checks, once per tick. */
  private async monitor(engine: Engine, report: TickReport | undefined, ws: WorkerState, summary: TickSummary): Promise<void> {
    const a = this.alerter(ws);
    const wcfg = this.wcfg;
    if (!a || !wcfg) return;
    const ac = wcfg.alerts;
    const now = deps.now();
    if (ws.rpcErrorStreak >= ac.rpcErrorStreak) await a.raise("rpc", `RPC failing for ${ws.rpcErrorStreak} consecutive ticks (${summary.errors[summary.errors.length - 1] ?? "?"})`, now);
    if (ws.intakeErrorStreak >= ac.rpcErrorStreak) await a.raise("intake", `orderbook intake failing for ${ws.intakeErrorStreak} consecutive ticks`, now);
    // Independent of the filler's own RPC: checked on failing ticks too.
    await this.checkBook(wcfg, ws, a, now);
    if (!report) return;
    const reasons = [...report.outcomes.map((o) => o.reason ?? ""), report.rebalance?.reason ?? ""];
    if (reasons.some((r) => /hourly gas budget exhausted/.test(r))) {
      await a.raise("gas-budget", `hourly gas budget exhausted: ${formatEther(engine.budgetsLeft(now).gasWei)} of ${formatEther(engine.cfg.gas.hourlyWei)} RBTC left`, now);
    }
    const reverts = countSince(this.sql, "reverted", now - 3_600_000);
    if (reverts >= ac.revertsPerHour) await a.raise("reverts", `${reverts} reverted transaction(s) in the last hour`, now);
    const p = engine.pending;
    if (p && now - p.sentAt >= ac.pendingTxMs) {
      await a.raise(`pending:${p.hash}`, `tx ${p.hash} (${p.strategy} ${p.kind}) pending for ${Math.round((now - p.sentAt) / 60_000)} min — nothing else is sent until it resolves`, now);
    }
    // Sends refused because the account's pending nonce is ahead of its mined one (a
    // tx we do not track is in flight): as blocking as a stuck tx of our own. Only
    // while the refusals are current (a streak nobody retried since says nothing).
    const u = engine.guard.untracked;
    if (u && now - u.since >= ac.pendingTxMs && now - u.lastAt <= Math.max(120_000, 3 * wcfg.tickMs)) {
      await a.raise(
        "untracked",
        `sends refused for ${Math.round((now - u.since) / 60_000)} min: the account has ${u.count} tx(s) in flight that this filler does not track (pending nonce ahead of the mined one — another host on the same key, a hand-sent tx?); nothing is sent until they mine`,
        now,
      );
    }

    const moc = engine.rebalancer.pendingRedemption(now);
    if (moc && moc.ageMs >= ac.mocPendingMs) await a.raise(`moc:${moc.opId}`, `MoC redemption op ${moc.opId} not executed after ${Math.round(moc.ageMs / 60_000)} min`, now);
    if (ws.lastBalanceCheck === undefined || now - ws.lastBalanceCheck >= wcfg.balanceCheckMs) {
      ws.lastBalanceCheck = now;
      try {
        const cfg = engine.cfg;
        const rbtc = await engine.chain.pub.getBalance({ address: engine.chain.me });
        const bal: Record<string, string> = { RBTC: formatEther(rbtc) };
        if (rbtc < ac.minRbtcWei) await a.raise("low:RBTC", `low RBTC: ${formatEther(rbtc)} < ${formatEther(ac.minRbtcWei)} (gas)`, now);
        if (cfg.strategies.inventory && cfg.policy.buyUsdrif && ac.minUsdt0 > 0n) {
          const v = await balanceOf(engine.chain, cfg.tokens.usdt0);
          bal.USDT0 = fmtUnits(v, 6);
          if (v < ac.minUsdt0) await a.raise("low:USDT0", `low USDT0 inventory: ${fmtUnits(v, 6)} < ${fmtUnits(ac.minUsdt0, 6)}`, now);
        }
        if (cfg.strategies.inventory && cfg.policy.sellUsdrif && ac.minUsdrif > 0n) {
          const v = await balanceOf(engine.chain, cfg.tokens.usdrif);
          bal.USDRIF = fmtUnits(v, 18);
          if (v < ac.minUsdrif) await a.raise("low:USDRIF", `low USDRIF inventory: ${fmtUnits(v, 18)} < ${fmtUnits(ac.minUsdrif, 18)}`, now);
        }
        ws.balances = bal;
      } catch (e) {
        summary.errors.push(`balances: ${errMsg(e)}`);
      }
    }
  }

  /**
   * Every BOOK_HEALTH_SECONDS: read the orderbook's /health over the ORDERBOOK
   * binding and alert on a stale alarm loop (`lastAlarm` older than 3 × its alarm
   * interval) or a failing log scan — above all an RPC that does not serve
   * `eth_getLogs` (Rootstock's public node), which silently freezes the fill index
   * and on-chain cancels. An unreachable book is the intake alert's job.
   */
  private async checkBook(wcfg: WorkerConfig, ws: WorkerState, a: Alerter, now: number): Promise<void> {
    const last = ws.bookHealth;
    const inconclusive = !last || last.error !== undefined || last.lastAlarm === null || last.lastAlarm === undefined;
    const every = inconclusive ? Math.min(wcfg.bookHealthMs, BOOK_HEALTH_RETRY_MS) : wcfg.bookHealthMs;
    if (ws.lastBookHealthAt !== undefined && now - ws.lastBookHealthAt < every) return;
    ws.lastBookHealthAt = now;
    let h: Record<string, unknown>;
    try {
      const { doFetch, base, headers } = this.bookTransport(wcfg);
      const res = await doFetch(`${base}/health`, { headers: { accept: "application/json", ...headers } });
      if (!res.ok) throw new Error(`orderbook answered ${res.status} for GET /health`);
      h = (await res.json()) as Record<string, unknown>;
    } catch (e) {
      ws.bookHealth = { at: now, error: errMsg(e) };
      return;
    }
    const logs = (h.logs ?? {}) as { ok?: unknown; lastError?: unknown };
    const interval = Number(h.alarmIntervalSeconds) > 0 ? Number(h.alarmIntervalSeconds) : 20;
    const lastAlarm = h.lastAlarm === null || h.lastAlarm === undefined ? null : Number(h.lastAlarm);
    const view: BookHealthView = {
      at: now,
      lastAlarm,
      alarmIntervalSeconds: interval,
      logsUnsupported: h.logsUnsupported === true,
      ...(typeof logs.ok === "boolean" ? { logsOk: logs.ok } : {}),
      logsError: typeof logs.lastError === "string" ? sanitize(logs.lastError, 200) : null,
      ...(typeof h.rpc === "string" ? { rpc: sanitize(h.rpc, 40) } : {}),
    };
    ws.bookHealth = view;
    const staleS = 3 * interval;
    if (h.configured !== false) {
      if (lastAlarm === null || !Number.isFinite(lastAlarm)) {
        ws.bookNoAlarmSince ??= now;
        if (now - ws.bookNoAlarmSince > staleS * 1000) {
          await a.raise("book:stale", `orderbook alarm loop has not run for ${Math.round((now - ws.bookNoAlarmSince) / 1000)} s (> 3 × ${interval} s): fills, cancels and expiries are not being applied`, now);
        }
      } else {
        ws.bookNoAlarmSince = undefined;
        const age = Math.floor(now / 1000) - lastAlarm;
        if (age > staleS) {
          await a.raise("book:stale", `orderbook alarm loop stale: last alarm ${age} s ago (> 3 × ${interval} s) — fills, cancels and expiries are not being applied`, now);
        }
      }
    }
    if (view.logsUnsupported) {
      await a.raise(
        "book:logs-unsupported",
        "orderbook RPC does not serve eth_getLogs (JSON-RPC -32601): its fill index and on-chain cancels are frozen — set RPC_URL_SECRET on orderbook-1delta-rsk to a provider that serves eth_getLogs",
        now,
      );
    } else if (view.logsOk === false) {
      await a.raise("book:logs", `orderbook log scan failing: ${view.logsError ?? "unknown error"}`, now);
    }
  }

  // ──────────────────── alarm / cron ────────────────────

  async alarm(): Promise<void> {
    let next = this.wcfg?.tickMs ?? 5_000;
    try {
      const s = await this.runTick("alarm");
      if (s.pending && this.wcfg) next = this.wcfg.pendingTickMs;
    } finally {
      // Self-rescheduling, even after a failure.
      await this.ctx.storage.setAlarm(Date.now() + next);
    }
  }

  /** RPC entry for the cron trigger: make sure the alarm loop is alive. */
  async kick(): Promise<void> {
    await this.ensureAlarm();
  }

  private async ensureAlarm(): Promise<void> {
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + (this.wcfg?.tickMs ?? 5_000));
  }

  // ──────────────────── admin API (auth is checked by the entry worker) ────────────────────

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    try {
      await this.ensureAlarm();
      const ws = await this.state();
      if (path === "/health") {
        const age = ws.lastTickAt === undefined ? null : Math.max(0, Math.round((deps.now() - ws.lastTickAt) / 1000));
        const limit = Math.max(120, 3 * ((this.wcfg?.tickMs ?? 5_000) / 1000));
        return json({ ok: age !== null && age <= limit, lastTickAgeSeconds: age });
      }
      if (path === "/status" && method === "GET") return json(await this.status());
      if (path === "/pause" && method === "POST") {
        ws.paused = true;
        await this.saveState();
        this.log("admin: paused");
        return json({ paused: true });
      }
      if (path === "/resume" && method === "POST") {
        ws.paused = false;
        await this.saveState();
        this.log("admin: resumed");
        return json({ paused: false });
      }
      if (path === "/dry-run" && method === "POST") {
        const text = await request.text();
        if (text.length > 1024) return json({ error: "body too large" }, 413);
        let body: unknown;
        try {
          body = JSON.parse(text);
        } catch {
          return json({ error: 'body must be JSON {"on": true|false}' }, 400);
        }
        const on = (body as { on?: unknown } | null)?.on;
        if (typeof on !== "boolean") return json({ error: 'body must be JSON {"on": true|false}' }, 400);
        ws.dryRun = on;
        await this.saveState();
        this.log(`admin: dry run ${on ? "ON" : "OFF — LIVE"}`);
        return json({ dryRun: on });
      }
      if (path === "/tick" && method === "POST") return json(await this.runTick("manual"));
      if (path === "/fills" && method === "GET") return this.fills(url);
      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: `internal error: ${errMsg(e)}` }, 500);
    }
  }

  private fills(url: URL): Response {
    const q = url.searchParams;
    const limitRaw = q.get("limit");
    const limit = limitRaw === null ? 100 : Number(limitRaw);
    if (!Number.isInteger(limit) || limit <= 0) return json({ error: "limit must be a positive integer" }, 400);
    let since: number | undefined;
    const sinceRaw = q.get("since");
    if (sinceRaw !== null) {
      since = /^\d+$/.test(sinceRaw) ? Number(sinceRaw) : Date.parse(sinceRaw);
      if (!Number.isFinite(since)) return json({ error: "since must be ms since epoch or an ISO date" }, 400);
    }
    const kind = q.get("kind") ?? undefined;
    const status = q.get("status") ?? undefined;
    const rows = listFills(this.sql, { limit: Math.min(limit, 5_000), ...(since !== undefined ? { since } : {}), ...(kind ? { kind } : {}), ...(status ? { status } : {}) });
    if (q.get("format") === "csv") {
      return new Response(toCsv(rows), { headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": 'attachment; filename="fills.csv"', "cache-control": "no-store" } });
    }
    return json({ fills: rows });
  }

  private async status(): Promise<Record<string, unknown>> {
    const ws = await this.state();
    const now = deps.now();
    const base: Record<string, unknown> = {
      paused: ws.paused,
      dryRunOverride: ws.dryRun ?? null,
      lastTick: ws.lastTickAt === undefined ? null : { at: new Date(ws.lastTickAt).toISOString(), ageSeconds: Math.round((now - ws.lastTickAt) / 1000), durationMs: ws.lastTickMs, summary: ws.lastSummary },
      ticks: ws.ticks,
      lastError: ws.lastError ?? null,
      rpcErrorStreak: ws.rpcErrorStreak,
      intakeErrorStreak: ws.intakeErrorStreak,
      orderbook: ws.bookHealth ?? null,
      alerts: ws.alerts.log.slice(-20).reverse(),
      worker: this.wcfg ? { ...this.wcfg, alerts: { ...this.wcfg.alerts, webhookUrl: this.wcfg.alerts.webhookUrl ? "(set)" : "(unset)" } } : { error: this.wcfgError },
    };
    let engine: Engine;
    try {
      engine = await this.getEngine();
    } catch (e) {
      return { ...base, configError: errMsg(e) };
    }
    if (ws.dryRun !== undefined && ws.dryRun !== engine.cfg.dryRun) base.dryRunTakesEffect = "next tick";
    const cfg = engine.cfg;
    const left = engine.budgetsLeft(now);
    const p = engine.pending;
    const moc = engine.rebalancer.pendingRedemption(now);
    let balances: Record<string, string> | { error: string };
    try {
      const me = engine.chain.me;
      const tok = async (t: Address, d: number) => fmtUnits(await balanceOf(engine.chain, t), d);
      const [rbtc, usdt0, usdrif, rif, wrbtc, weth] = await Promise.all([
        engine.chain.pub.getBalance({ address: me }).then(formatEther),
        tok(cfg.tokens.usdt0, 6),
        tok(cfg.tokens.usdrif, 18),
        tok(cfg.tokens.rif, 18),
        tok(cfg.wrbtc, 18),
        tok(ROOTSTOCK.weth as Address, 18),
      ]);
      balances = { RBTC: rbtc, USDT0: usdt0, USDRIF: usdrif, RIF: rif, WRBTC: wrbtc, WETH: weth };
    } catch (e) {
      balances = { error: errMsg(e) };
    }
    let rpcOrigin = "(unparseable)";
    try {
      rpcOrigin = new URL(cfg.rpcUrl).origin;
    } catch {
      // keep the placeholder; never echo the raw URL (it may carry an API key)
    }
    const recent = engine.recent;
    return {
      ...base,
      address: engine.chain.me,
      chainId: cfg.chainId,
      configured: isConfigured(cfg),
      dryRun: cfg.dryRun,
      balances,
      budgets: {
        gasRbtcLeft: formatEther(left.gasWei),
        gasRbtcPerHour: formatEther(cfg.gas.hourlyWei),
        usdt0Left: fmtUnits(left.usdt0, 6),
        usdrifLeft: fmtUnits(left.usdrif, 18),
        routeFillsLeft: left.routeFills.toString(),
      },
      pending: p
        ? (({ raw, ...rest }) => ({ ...rest, rawKept: !!raw, ageSeconds: Math.round((now - p.sentAt) / 1000), sentAt: new Date(p.sentAt).toISOString() }))(p)
        : null,
      mocRedemption: moc ? { opId: moc.opId.toString(), ageSeconds: Math.round(moc.ageMs / 1000) } : null,
      recent: {
        fills: listFills(this.sql, { limit: 20, status: "filled" }),
        reverts: listFills(this.sql, { limit: 20, status: "reverted" }),
        skips: recent.filter((e) => e.type === "skip").slice(0, 30).map((e) => this.redactEvent(e)),
        events: recent.slice(0, 30).map((e) => this.redactEvent(e)),
      },
      backoff: engine.guard.blocked(now).map((b) => ({ ...b, until: new Date(b.until).toISOString() })),
      untrackedInFlight: engine.guard.untracked ? { ...engine.guard.untracked, sinceSeconds: Math.round((now - engine.guard.untracked.since) / 1000) } : null,
      config: {
        rpc: rpcOrigin,
        rpcSource: cfg.rpcSource,
        settlement: cfg.settlement,
        permit3: cfg.permit3,
        lens: cfg.lens,
        orderbook: deps.fetchBook ? "(injected)" : this.env.ORDERBOOK ? "service binding ORDERBOOK" : this.wcfg?.orderbookUrl || "(none)",
        strategies: cfg.strategies,
        solver: cfg.route?.solver ?? null,
        profitRecipient: cfg.route?.profitRecipient ?? null,
        gas: { hourlyRbtc: formatEther(cfg.gas.hourlyWei), maxGasPriceWei: cfg.gas.maxGasPriceWei.toString(), receiptTimeoutMs: cfg.gas.receiptTimeoutMs },
        policy: Object.fromEntries(Object.entries(cfg.policy).map(([k, v]) => [k, String(v)])),
        sushi: cfg.route ? { enabled: cfg.route.sushi.enabled, executorsPinned: cfg.route.sushi.executors.length } : null,
      },
      logTail: this.logTail.slice(-50),
    };
  }
}

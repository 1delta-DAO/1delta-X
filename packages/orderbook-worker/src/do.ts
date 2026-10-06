import { DurableObject } from "cloudflare:workers";
import { CancelVerifier, Verifier } from "@1delta-x/orderbook/pure";
import { createPublicClient, http, type PublicClient } from "viem";

import { viemChainReader } from "./chain";
import { loadConfig, RPC_TIMEOUT_MS, type Env, type WorkerConfig } from "./config";
import { json, OrderBookCore, type CoreDeps } from "./core";

/** Header the entry worker sets with the client address it resolved. Only the entry worker can reach the DO. */
export const CLIENT_IP_HEADER = "x-ob-client-ip";

export type DepsFactory = (cfg: WorkerConfig) => CoreDeps;

/**
 * Production deps: viem over `RPC_URL_SECRET` / `RPC_URL`, the library's Layer 1/2 and
 * soft-cancel verifiers. Every RPC call has an explicit 8 s timeout (one retry), and
 * a lens re-check sweep is bounded in calls AND wall-clock time (`cfg.verifier`), so
 * a hanging RPC cannot hold an alarm for minutes.
 */
export const defaultDeps: DepsFactory = (cfg) => {
  let client: PublicClient | undefined;
  const getClient = (): PublicClient =>
    (client ??= createPublicClient({ transport: http(cfg.chain.rpcUrl, { batch: false, retryCount: 1, timeout: RPC_TIMEOUT_MS }) }) as PublicClient);
  return {
    verifier: new Verifier(getClient(), cfg.chain, { maxRecheckCalls: cfg.verifier.maxRecheckCalls, maxSweepMs: cfg.verifier.maxSweepMs }),
    cancelVerifier: new CancelVerifier(getClient, cfg.chain),
    chain: viemChainReader(getClient(), cfg.chain.settlement, cfg.ocoModules),
    now: () => Math.floor(Date.now() / 1000),
    nowMs: () => Date.now(),
  };
};

let depsFactory: DepsFactory = defaultDeps;

/**
 * Swap the deps factory (tests: a stub verifier and mocked chain). Module state,
 * so it survives an eviction of the object within the isolate. Not reachable
 * from any request.
 */
export function setDepsFactory(f: DepsFactory): void {
  depsFactory = f;
}

/**
 * One SQLite-backed Durable Object per chain id (the entry worker addresses it by
 * `idFromName(CHAIN_ID)`). All book state lives in its storage, so a restart or
 * an eviction loses nothing; the in-memory part is only the verifier's short
 * verdict cache.
 *
 * Maintenance runs on the object's alarm, which re-arms itself every pass
 * (`ALARM_INTERVAL_SECONDS`, or 1s while the log cursor catches up). Any request
 * — and the cron trigger, through {@link kick} — re-arms a missing alarm.
 */
export class OrderBookDO extends DurableObject<Env> {
  private core: OrderBookCore | undefined;
  private cfg: WorkerConfig | undefined;
  private configError: string | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    try {
      this.cfg = loadConfig(env);
    } catch (err) {
      this.configError = err instanceof Error ? err.message : String(err);
    }
  }

  private getCore(): OrderBookCore | undefined {
    if (!this.cfg) return undefined;
    return (this.core ??= new OrderBookCore(this.ctx.storage.sql as never, this.cfg, depsFactory(this.cfg)));
  }

  async fetch(request: Request): Promise<Response> {
    const core = this.getCore();
    if (!core) return json({ error: `orderbook misconfigured: ${this.configError ?? "unknown"}` }, 500);
    await this.ensureAlarm();
    return core.handle(request, request.headers.get(CLIENT_IP_HEADER) ?? "unknown");
  }

  async alarm(): Promise<void> {
    const core = this.getCore();
    if (!core) return;
    let next = this.cfg!.alarmIntervalMs;
    try {
      next = await core.maintain();
    } finally {
      // Self-rescheduling, even after a failure (maintain records its own errors).
      await this.ctx.storage.setAlarm(Date.now() + next);
    }
  }

  /** RPC entry for the cron trigger: make sure the alarm loop is alive. */
  async kick(): Promise<void> {
    await this.ensureAlarm();
  }

  private async ensureAlarm(): Promise<void> {
    if (!this.cfg) return;
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + this.cfg.alarmIntervalMs);
  }
}

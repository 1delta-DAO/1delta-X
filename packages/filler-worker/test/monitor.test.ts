import { beforeEach, describe, expect, it } from "vitest";

import { Alerter, emptyAlertState } from "../src/alerts";
import { loadFillerConfig, loadWorkerConfig, locationHint, rpcUrls } from "../src/config";
import { redact, setDeps } from "../src/do";
import * as entry from "../src/index";
import worker from "../src/index";
import { doCall, freshFiller, healthyBook, resetWorld, seedBook, testDeps, testEnv, tick, world } from "./helpers";

beforeEach(() => resetWorld());

const alertsMatching = (re: RegExp) => world.alerts.filter((a) => re.test(String(a.body.text)));

describe("entry module", () => {
  // workerd refuses to start a script whose main module exports anything but
  // entrypoints ("Incorrect type for map entry …: not of type 'function or
  // ExportedHandler'"); vitest-pool-workers does not apply that startup check.
  it("exports only Workers entrypoints (functions / handler objects)", () => {
    const bad = Object.entries(entry)
      .filter(([, v]) => !(typeof v === "function" || (typeof v === "object" && v !== null)))
      .map(([k, v]) => `${k}: ${typeof v}`);
    expect(bad).toEqual([]);
    expect(Object.keys(entry).sort()).toEqual(["FillerDO", "default"]);
  });
});

describe("untracked tx in flight (M3)", () => {
  it("alerts once the 'untracked tx(s) in flight' refusal has persisted for ALERT_PENDING_TX_SECONDS", async () => {
    const stub = freshFiller();
    seedBook(1);
    world.inFlightExtra = 1; // a tx this filler does not track holds the next nonce
    const s1 = await tick(stub);
    expect(s1.outcomes?.[0]?.reason).toMatch(/untracked tx/);
    expect(alertsMatching(/does not track/)).toHaveLength(0);
    world.offset = 5 * 60_000;
    await tick(stub);
    expect(alertsMatching(/does not track/)).toHaveLength(0);
    world.offset = 11 * 60_000; // > 600 s
    await tick(stub);
    expect(alertsMatching(/does not track/)).toHaveLength(1);
    expect(String(alertsMatching(/does not track/)[0]!.body.text)).toMatch(/sends refused for 11 min/);
    const st = (await doCall(stub, "GET", "/status")).body as Record<string, any>;
    expect(st.untrackedInFlight).toMatchObject({ count: 1 });
    // It mines: the next send passes the check and the streak is cleared.
    world.inFlightExtra = 0;
    world.offset = 12 * 60_000;
    expect((await tick(stub)).sent).toBeDefined();
    expect(((await doCall(stub, "GET", "/status")).body as Record<string, any>).untrackedInFlight).toBeNull();
  });
});

describe("orderbook health (B3d)", () => {
  it("reads the book's /health every BOOK_HEALTH_SECONDS, not every tick; healthy = no alert", async () => {
    const stub = freshFiller();
    await tick(stub);
    await tick(stub);
    expect(world.healthFetches).toBe(1);
    world.offset = 301_000;
    await tick(stub);
    expect(world.healthFetches).toBe(2);
    expect(world.alerts.filter((a) => /orderbook/.test(String(a.body.text)))).toEqual([]);
    const st = (await doCall(stub, "GET", "/status")).body as Record<string, any>;
    expect(st.orderbook).toMatchObject({ logsUnsupported: false, logsOk: true, alarmIntervalSeconds: 20, rpc: "RPC_URL_SECRET" });
  });

  it("an inconclusive read (the book's alarm has not run yet) is retried after 60 s, not 300 s", async () => {
    // Right after a deploy the filler's first tick can beat the book's first alarm.
    const stub = freshFiller();
    world.bookHealth = healthyBook({ lastAlarm: null });
    await tick(stub);
    expect(world.healthFetches).toBe(1);
    world.offset = 30_000;
    await tick(stub);
    expect(world.healthFetches).toBe(1);
    // By now the book's first alarm ran — and found an RPC without eth_getLogs.
    world.bookHealth = healthyBook({ logsUnsupported: true, logs: { ok: false, unsupported: true, lastError: "RPC_URL does not serve eth_getLogs" } });
    world.offset = 61_000;
    await tick(stub);
    expect(world.healthFetches).toBe(2);
    expect(alertsMatching(/does not serve eth_getLogs/)).toHaveLength(1);
    // A conclusive read: back to every BOOK_HEALTH_SECONDS.
    world.offset = 150_000;
    await tick(stub);
    expect(world.healthFetches).toBe(2);
  });

  it("an RPC without eth_getLogs (logsUnsupported) alerts, once per cooldown", async () => {
    const stub = freshFiller();
    world.bookHealth = healthyBook({ logsUnsupported: true, logs: { ok: false, unsupported: true, lastError: "RPC_URL does not serve eth_getLogs" }, rpc: "RPC_URL" });
    await tick(stub);
    expect(alertsMatching(/does not serve eth_getLogs.*RPC_URL_SECRET/)).toHaveLength(1);
    world.offset = 301_000;
    world.bookHealth = healthyBook({ logsUnsupported: true, logs: { ok: false, unsupported: true } });
    await tick(stub);
    expect(alertsMatching(/does not serve eth_getLogs/)).toHaveLength(1); // de-duplicated (cooldown 1 h)
  });

  it("a stale alarm loop (lastAlarm older than 3 × the alarm interval) alerts", async () => {
    const stub = freshFiller();
    world.bookHealth = healthyBook({ lastAlarm: String(Math.floor(Date.now() / 1000) - 61) });
    await tick(stub);
    expect(alertsMatching(/orderbook alarm loop stale: last alarm 6\d s ago \(> 3 × 20 s\)/)).toHaveLength(1);
  });

  it("an alarm that just ran is not stale; a failing log scan (not -32601) alerts as such", async () => {
    const stub = freshFiller();
    world.bookHealth = healthyBook({ lastAlarm: String(Math.floor(Date.now() / 1000) - 50), logs: { ok: false, unsupported: false, lastError: "query exceeds max block range 1000" } });
    await tick(stub);
    expect(alertsMatching(/stale/)).toHaveLength(0);
    expect(alertsMatching(/orderbook log scan failing: query exceeds max block range 1000/)).toHaveLength(1);
  });

  it("an unreachable /health is recorded, not alerted (the intake streak covers a dead book)", async () => {
    const stub = freshFiller();
    // Without the injected book, the vitest ORDERBOOK service binding answers: it serves no /health (404).
    const { fetchBook: _book, ...noBook } = testDeps;
    void _book;
    setDeps(noBook);
    try {
      await tick(stub);
      const st = (await doCall(stub, "GET", "/status")).body as Record<string, any>;
      expect(st.orderbook.error).toMatch(/404/);
      expect(world.alerts.filter((a) => /orderbook/.test(String(a.body.text)))).toEqual([]);
    } finally {
      setDeps(testDeps);
    }
  });
});

describe("alert webhook timeout", () => {
  it("a webhook that never answers is aborted (AbortSignal.timeout) and recorded, not awaited forever", async () => {
    const cfg = loadWorkerConfig(testEnv).alerts;
    const hanging = (_u: string, init: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener("abort", () => reject(init.signal!.reason));
      });
    const a = new Alerter({ ...cfg, webhookUrl: "https://hooks.test/slow" }, emptyAlertState(), hanging, () => {}, 50);
    const t0 = Date.now();
    expect(await a.raise("k", "hello", Date.now())).toBe(false);
    expect(Date.now() - t0).toBeLessThan(2_000);
    expect(a.state.log[0]).toMatchObject({ key: "k", delivered: false, suppressed: expect.stringMatching(/^webhook: /) });
  });
});

describe("RPC_URL_SECRET (B3a)", () => {
  const SECRET = "https://rootstock-mainnet.example-provider.io/v2/sk_live_ABC123";
  it("is preferred over the RPC_URL var, and both are redacted from anything that leaves the worker", () => {
    const env = { ...testEnv, RPC_URL: "https://public-node.rsk.co", RPC_URL_SECRET: SECRET };
    const cfg = loadFillerConfig(env);
    expect(cfg.rpcUrl).toBe(SECRET);
    expect(cfg.rpcSource).toBe("RPC_URL_SECRET");
    expect(loadFillerConfig({ ...testEnv, RPC_URL: "https://public-node.rsk.co" }).rpcSource).toBe("RPC_URL");
    const text = `HTTP request failed. URL: ${SECRET} … and https://public-node.rsk.co/ answered 429; host rootstock-mainnet.example-provider.io`;
    const out = redact(text, rpcUrls(env));
    expect(out).not.toContain("sk_live_ABC123");
    expect(out).not.toContain("example-provider.io");
    expect(out).not.toContain("public-node.rsk.co");
  });
});

describe("outcome reasons in /status and /tick are redacted (review 2026-10-05 §6)", () => {
  it("a strategy failure quoting the RPC URL reaches neither the tick summary nor /status", async () => {
    const stub = freshFiller();
    seedBook(1);
    // A provider error that quotes the configured RPC (RPC_URL = http://rpc.invalid; a keyed
    // RPC_URL_SECRET is redacted the same way, see the B3a test above).
    world.callError = `HTTP request failed. URL: ${testEnv.RPC_URL} status 500`;
    const s = await tick(stub);
    expect(world.sent).toHaveLength(0);
    expect(s.outcomes?.[0]?.reason).toBeTruthy(); // the failure carries a reason …
    const st = (await doCall(stub, "GET", "/status")).body as Record<string, any>;
    expect(st.lastTick.summary.outcomes[0].reason).toBeTruthy();
    expect(st.recent.events.some((e: { reason?: string }) => e.reason)).toBe(true);
    // … and neither the /tick reply nor /status quotes the URL or its host.
    // (`config.rpc` shows the origin of the public var on purpose; never a secret's.)
    const { config: _config, ...rest } = st;
    for (const text of [JSON.stringify(s), JSON.stringify(rest)]) expect(text).not.toContain("rpc.invalid");
    expect(JSON.stringify(s.outcomes)).toMatch(/<RPC_URL>|<rpc-host>/);
  });
});

describe("DO location hint", () => {
  it("accepts Cloudflare's hints, ignores anything else (an unknown hint must not break get())", async () => {
    expect(locationHint({ DO_LOCATION_HINT: "wnam" })).toBe("wnam");
    expect(locationHint({ DO_LOCATION_HINT: " WEUR " })).toBe("weur");
    expect(locationHint({ DO_LOCATION_HINT: "mars" })).toBeUndefined();
    expect(locationHint({ DO_LOCATION_HINT: "" })).toBeUndefined();
    for (const hint of ["wnam", "mars"]) {
      const res = await worker.fetch(new Request("https://filler.example.com/health"), { ...testEnv, DO_LOCATION_HINT: hint });
      expect(res.status).toBe(200);
    }
  });
});

describe("alert cap × cooldown (review 2026-10-05, M1)", () => {
  it("a key first raised while the hourly cap is saturated is not put on cooldown", async () => {
    const cfg = { ...loadWorkerConfig(testEnv).alerts, webhookUrl: "https://hooks.test/ok", maxPerHour: 1, cooldownMs: 3_600_000 };
    const ok = async () => new Response("ok", { status: 200 });
    const a = new Alerter(cfg, emptyAlertState(), ok, () => {});
    const t0 = 1_000_000;
    expect(await a.raise("rpc", "brownout", t0)).toBe(true); // fills the cap
    expect(await a.raise("low:RBTC", "balance low", t0 + 1_000)).toBe(false); // rate-limited
    expect(a.state.log.at(-1)).toMatchObject({ key: "low:RBTC", suppressed: "rate limit" });
    expect(a.state.lastSent["low:RBTC"]).toBeUndefined();
    // The cap window clears after an hour; the condition is still true and still
    // within what WAS a cooldown stamped at the suppressed attempt — it must fire.
    expect(await a.raise("low:RBTC", "balance low", t0 + 3_600_001)).toBe(true);
    // And the cooldown is real for a key that was actually sent.
    expect(await a.raise("low:RBTC", "balance low", t0 + 3_600_002)).toBe(false);
    expect(a.state.log.filter((l) => l.key === "low:RBTC" && l.delivered)).toHaveLength(1);
  });
});

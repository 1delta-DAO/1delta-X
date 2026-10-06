/**
 * Staging-harness SOAK (LOCAL ONLY, not part of CI) — `staging.sh soak`, against a
 * running stack (normally after `staging.sh load`).
 *
 *  1. RESTING BOOK (SOAK_RESTING_S, default 180): whatever unprofitable orders the
 *     load left live stay in the book, topped up to SOAK_RESTING_TARGET (default 31,
 *     the 2026-10-05 baseline's count) with fresh never-profitable ones, so runs of any
 *     load size compare. RPC calls are counted per tick: what a book of resting limit
 *     orders costs.
 *  2. Every live order is soft-cancelled by its maker → empty book.
 *  3. IDLE (SOAK_IDLE_S, default 600 = 10 min): no orders, no admin polling. RPC calls
 *     per worker and method (proxy), alarms and their subrequests (the runtime's
 *     trace store) — extrapolated to a day at the configured cadence.
 */
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";

import { encodeFunctionData, erc20Abi, maxUint256 } from "viem";

import { PERMIT3_ABI, USDRIF, USDT0, WRBTC, admin, book, buildOrder, deal, dist, explorer, json, loadEnv, nowS, obDirect, proxy, publicClient, quote, readTimeline, segmentTicks, setBalance, signedSoftCancel, sleep, testKey, walletClient, writeResult, type ProxyStats } from "./lib";

const env = loadEnv();
const ex = explorer(env);
const px = proxy(env);
const RESTING_S = Number(process.env.SOAK_RESTING_S ?? 180);
const IDLE_S = Number(process.env.SOAK_IDLE_S ?? 600);
const MAKERS = Number(process.env.MAKERS ?? 20);
const RESTING_TARGET = Number(process.env.SOAK_RESTING_TARGET ?? 31);
/** Orders per top-up maker (the book bills a maker 10 tokens per order: capacity 120, refill 1/s). */
const PER_RESTER = 10;
const log = (m: string) => console.log(`[soak ${new Date().toISOString().slice(11, 19)}] ${m}`);
const DAY = 86_400;

async function window(seconds: number, what: string) {
  await px.reset();
  const from = Date.now();
  log(`${what}: ${seconds} s`);
  // The platform's minute cron, dispatched as Cloudflare would (it only re-arms alarms: zero RPC).
  let cronOk = 0;
  let cronCalls = 0;
  const end = from + seconds * 1000;
  while (Date.now() < end) {
    await sleep(Math.min(60_000, end - Date.now()));
    if (Date.now() >= end) break;
    for (const w of ["orderbook-1delta-rsk", "filler-1delta-rsk"]) {
      cronCalls++;
      if ((await ex.scheduled(w).catch(() => ({ outcome: "error" }))).outcome === "ok") cronOk++;
    }
  }
  const to = Date.now();
  const stats: ProxyStats = await px.stats();
  const spans = await ex.obs(
    `SELECT r.service AS service, r.name AS name, r.start_ms AS start, r.duration_ms AS ms,
            (SELECT count(*) FROM spans c WHERE c.trace_id = r.trace_id AND c.name = 'fetch') AS fetches,
            (SELECT count(*) FROM spans c WHERE c.trace_id = r.trace_id AND c.name = 'fetch' AND json_extract(c.attributes, '$."url.full"') LIKE 'http://127.0.0.1:%') AS rpc
       FROM spans r WHERE r.parent_id IS NULL AND r.start_ms >= ? AND r.start_ms < ? AND r.duration_ms IS NOT NULL ORDER BY r.start_ms`,
    [from, to],
  );
  const secs = (to - from) / 1000;
  // Exact tick count and RPC per tick from the proxy timeline (the trace store is a cross-check).
  const fillerSegs = segmentTicks(readTimeline(env.runDir, from, to, "filler"));
  const obAlarms = readTimeline(env.runDir, from, to, "ob").filter((c) => c.m === "eth_blockNumber").length;
  const per = (svc: string) => {
    const alarms = spans.filter((s) => s.service === svc && s.name === "alarm");
    const calls = stats.tags[svc === "filler-1delta-rsk" ? "filler" : "ob"]?.calls ?? 0;
    const fetches = alarms.reduce((a, s) => a + Number(s.fetches), 0);
    return {
      seconds: secs,
      alarms: alarms.length,
      alarmEveryS: alarms.length ? secs / alarms.length : null,
      wallMs: dist(alarms.map((s) => Number(s.ms))),
      subrequestsPerAlarm: dist(alarms.map((s) => Number(s.fetches))),
      rpcPerAlarm: dist(alarms.map((s) => Number(s.rpc))),
      proxyCalls: calls,
      proxyCallsPerS: calls / secs,
      subrequestsTotal: fetches,
      perDay: { rpcCalls: Math.round((calls / secs) * DAY), subrequests: Math.round((fetches / secs) * DAY), alarms: Math.round((alarms.length / secs) * DAY) },
      byMethod: stats.tags[svc === "filler-1delta-rsk" ? "filler" : "ob"]?.byMethod ?? {},
      otherInvocations: spans.filter((s) => s.service === svc && s.name !== "alarm").map((s) => s.name),
    };
  };
  return {
    from,
    to,
    crons: { dispatched: cronCalls, ok: cronOk },
    timeline: { fillerTicksWithRpc: fillerSegs.length, fillerRpcPerTick: dist(fillerSegs.map((x) => x.calls)), orderbookAlarms: obAlarms },
    filler: per("filler-1delta-rsk"),
    orderbook: per("orderbook-1delta-rsk"),
  };
}

// ── isolated-order latency probe: one profitable order at a time, nothing queued ahead
//    of it — the latency a single beta user sees (post → tx sent → mined). ──
const pub = publicClient(env);
const PROBE_ORDERS = Number(process.env.PROBE_ORDERS ?? 5);
const prober = privateKeyToAccount(testKey(`${env.label}:probe-maker`, 0));
let proberReady = false;
async function probe(what: string): Promise<Record<string, unknown>> {
  if (!proberReady) {
    await setBalance(pub, prober.address, 10n ** 18n);
    await deal(pub, WRBTC, prober.address, 10n ** 17n);
    const w = walletClient(env, prober);
    for (const [to, data] of [
      [WRBTC, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [env.permit3, maxUint256] })],
      [env.permit3, encodeFunctionData({ abi: PERMIT3_ABI, functionName: "approveToken", args: [env.settlement, WRBTC, (1n << 160n) - 1n, 0] })],
    ] as const) {
      const h = await w.sendTransaction({ to, data, gas: 120_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" });
      await pub.waitForTransactionReceipt({ hash: h, pollingInterval: 500 });
    }
    proberReady = true;
  }
  const rows: Array<{ postToSendMs: number | null; postToMinedMs: number | null }> = [];
  for (let i = 0; i < PROBE_ORDERS; i++) {
    // Wait for an idle filler (no tx in flight), then a random phase within the tick.
    for (let k = 0; k < 60 && (await admin(env).get<{ pending?: unknown }>("/status")).body.pending; k++) await sleep(1000);
    await sleep(Math.random() * 5000);
    const amountIn = 15n * 10n ** 14n;
    const q = await quote(pub, [WRBTC, USDT0], [3000], amountIn);
    const o = await buildOrder(env, { maker: prober, tokenIn: WRBTC, tokenOut: USDT0, amountIn, owed: (q * 95n) / 100n, expiry: BigInt(nowS() + 600) });
    const txsBefore = (await px.txs()).length;
    const r = await book(env, "10.6.0.1").post("/orders", o.body);
    const postAt = r.at + r.ms;
    // Follow the operator's txs after the post; the one whose receipt carries an
    // OrderFilled for this hash is the fill (a rebalancer tx may go first).
    const FILLED_TOPIC = "0x" + o.hash.slice(2).toLowerCase();
    let sentAt: number | null = null;
    let minedAt: number | null = null;
    const seen = new Set<string>();
    for (let k = 0; k < 480 && minedAt === null; k++) {
      await sleep(250);
      for (const t of (await px.txs()).slice(txsBefore).filter((x) => x.from?.toLowerCase() === env.operator.toLowerCase() && !seen.has(x.hash))) {
        const rc = await pub.getTransactionReceipt({ hash: t.hash }).catch(() => undefined);
        if (!rc) continue;
        seen.add(t.hash);
        if (rc.logs.some((l) => l.address.toLowerCase() === env.settlement.toLowerCase() && l.topics[1]?.toLowerCase() === FILLED_TOPIC)) {
          sentAt = t.at;
          minedAt = Number((await pub.getBlock({ blockNumber: rc.blockNumber })).timestamp) * 1000;
        }
      }
    }
    rows.push({ postToSendMs: sentAt === null ? null : sentAt - postAt, postToMinedMs: minedAt === null ? null : Math.max(0, minedAt - postAt) });
  }
  const ok = rows.filter((x) => x.postToMinedMs !== null);
  const res = { what, orders: rows.length, filled: ok.length, postToSendMs: dist(ok.map((x) => x.postToSendMs ?? 0)), postToMinedMs: dist(ok.map((x) => x.postToMinedMs!)), rows };
  log(`probe (${what}): ${ok.length}/${rows.length} filled; post→send p50 ${res.postToSendMs.p50} ms, post→mined p50 ${res.postToMinedMs.p50} ms`);
  return res;
}

/**
 * Top the book up to `target` live orders with fresh NEVER-profitable ones (half
 * USDRIF→USDT0 at $1.000–1.008, above MAX_BUY_PRICE 0.995; half WRBTC→USDT0 at
 * 101–102% of the pool quote, which no route covers), from funded test makers.
 */
async function topUpResting(have: number): Promise<number> {
  const want = RESTING_TARGET - have;
  if (want <= 0) return 0;
  let posted = 0;
  for (let k = 0; posted < want && k < Math.ceil(want / PER_RESTER) + 2; k++) {
    const maker = privateKeyToAccount(testKey(`${env.label}:rester`, k));
    await setBalance(pub, maker.address, 10n ** 18n);
    await deal(pub, WRBTC, maker.address, 10n ** 17n);
    await deal(pub, USDRIF, maker.address, 10_000n * 10n ** 18n);
    const w = walletClient(env, maker);
    for (const token of [WRBTC, USDRIF]) {
      for (const [to, data] of [
        [token, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [env.permit3, maxUint256] })],
        [env.permit3, encodeFunctionData({ abi: PERMIT3_ABI, functionName: "approveToken", args: [env.settlement, token, (1n << 160n) - 1n, 0] })],
      ] as const) {
        const h = await w.sendTransaction({ to, data, gas: 120_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" });
        await pub.waitForTransactionReceipt({ hash: h, pollingInterval: 500 });
      }
    }
    for (let i = 0; i < PER_RESTER && posted < want; i++) {
      const n = k * PER_RESTER + i;
      let o: Awaited<ReturnType<typeof buildOrder>>;
      if (n % 2 === 0) {
        const amountIn = BigInt(50 + (n % 7) * 20) * 10n ** 18n;
        const owed = (amountIn * BigInt(1_000_000 + (n % 5) * 2_000)) / 10n ** 18n; // $1.000–1.008 per USDRIF (6-dec USDT0)
        o = await buildOrder(env, { maker, tokenIn: USDRIF, tokenOut: USDT0, amountIn, owed, expiry: BigInt(nowS() + 3600) });
      } else {
        const amountIn = BigInt(1 + (n % 3)) * 10n ** 15n;
        const q = await quote(pub, [WRBTC, USDT0], [3000], amountIn);
        o = await buildOrder(env, { maker, tokenIn: WRBTC, tokenOut: USDT0, amountIn, owed: (q * BigInt(1010 + (n % 10))) / 1000n, expiry: BigInt(nowS() + 3600) });
      }
      const r = await book(env, `10.7.${k}.${i + 1}`).post("/orders", o.body);
      if (r.status === 202) posted++;
      else log(`top-up order refused: ${r.status} ${JSON.stringify(r.body).slice(0, 120)}`);
    }
  }
  return posted;
}

async function liveOrders(): Promise<Array<{ orderHash: Hex; order: { maker: string } }>> {
  const out: Array<{ orderHash: Hex; order: { maker: string } }> = [];
  let cursor: string | undefined;
  for (let i = 0; i < 20; i++) {
    const r = await book(env, `10.5.0.${i + 1}`).get<{ orders: Array<{ orderHash: Hex; order: { maker: string } }>; nextCursor?: string }>(`/orders?limit=500${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
    out.push(...(r.body.orders ?? []));
    cursor = r.body.nextCursor;
    if (!cursor) break;
  }
  return out;
}

async function main(): Promise<void> {
  const left = (await liveOrders()).length;
  const topped = await topUpResting(left);
  // Let the filler see (and pass on) the top-up once before the window opens.
  if (topped) await sleep(30_000);
  const resting = await liveOrders();
  log(`book holds ${resting.length} live order(s) (${left} left by the load, ${topped} topped up)`);
  const restingWin = resting.length && RESTING_S > 0 ? await window(RESTING_S, `resting-book soak (${resting.length} live orders)`) : null;
  const probeResting = PROBE_ORDERS > 0 ? await probe(`${resting.length} resting orders in the book`) : null;

  // Soft-cancel everything that is left, as each maker.
  const keys = new Map<string, ReturnType<typeof privateKeyToAccount>>();
  for (const label of [`${env.label}:maker`, `${env.label}:restart-maker`, `${env.label}:rester`]) {
    for (let i = 0; i < Math.max(MAKERS, 1); i++) {
      const a = privateKeyToAccount(testKey(label, i));
      keys.set(a.address.toLowerCase(), a);
    }
  }
  const byMaker = new Map<string, Hex[]>();
  for (const o of await liveOrders()) byMaker.set(o.order.maker.toLowerCase(), [...(byMaker.get(o.order.maker.toLowerCase()) ?? []), o.orderHash]);
  let cancelled = 0;
  for (const [m, hashes] of byMaker) {
    const k = keys.get(m);
    if (!k) {
      log(`no key for maker ${m} (${hashes.length} orders stay)`);
      continue;
    }
    const r = await book(env, "10.5.1.1").post("/cancels", await signedSoftCancel(env, k, hashes));
    cancelled += Number((r.body as { evicted?: unknown[] }).evicted?.length ?? 0);
  }
  const health = (await obDirect(env).get<{ orders: number }>("/health")).body;
  log(`soft-cancelled ${cancelled}; book now holds ${health.orders} order(s)`);
  await sleep(15_000); // let the in-flight tick finish
  const probeEmpty = PROBE_ORDERS > 0 ? await probe("empty book") : null;
  // The probe's own orders are filled; drop anything left so the idle phase is idle.
  for (const o of await liveOrders()) {
    const k = o.order.maker.toLowerCase() === prober.address.toLowerCase() ? prober : keys.get(o.order.maker.toLowerCase());
    if (k) await book(env, "10.5.1.2").post("/cancels", await signedSoftCancel(env, k, [o.orderHash]));
  }
  await sleep(10_000);

  // RPC brownout: refuse ONLY the filler's RPC for BROWNOUT_S, so ticks fail; the
  // RPC-error-streak alert must reach the webhook, and the filler must recover after.
  const BROWNOUT_S = Number(process.env.BROWNOUT_S ?? 45);
  let brownout: Record<string, unknown> | null = null;
  if (BROWNOUT_S > 0) {
    const hooksBefore = (await px.webhooks()).length;
    log(`brownout: every filler RPC call refused (HTTP 429) for ${BROWNOUT_S} s`);
    await px.config({ rateLimit: { perSecond: 0, burst: 0, tags: ["filler"] } });
    await sleep(BROWNOUT_S * 1000);
    await px.config({ rateLimit: null });
    const during = (await admin(env).get<Record<string, unknown>>("/status")).body;
    await sleep(15_000);
    const after = (await admin(env).get<Record<string, unknown>>("/status")).body;
    const hooks = (await px.webhooks()).slice(hooksBefore);
    brownout = {
      seconds: BROWNOUT_S,
      rpcErrorStreakAtEnd: during.rpcErrorStreak,
      rpcErrorStreakAfterRecovery: after.rpcErrorStreak,
      lastErrorDuring: during.lastError,
      alertsDuring: ((during.alerts as unknown[]) ?? []).slice(0, 5),
      webhooksDelivered: hooks.map((h) => h.body),
    };
    log(`brownout: streak ${during.rpcErrorStreak} → ${after.rpcErrorStreak} after recovery; ${hooks.length} webhook(s): ${json(hooks.map((h) => h.body)).slice(0, 300)}`);
  }

  const idle = await window(IDLE_S, "idle soak (empty book, no admin polling)");
  // Per day: measured calls per second × 86,400 (independent of how ticks are counted).
  // Ticks: the larger of the trace-store count and the RPC-timeline segmentation.
  const ticksOf = (w: NonNullable<typeof restingWin>) => Math.max(w.filler.alarms, w.timeline.fillerTicksWithRpc);
  const idleTicks = ticksOf(idle);
  const extrap = {
    fillerTicks: idleTicks,
    fillerTickEveryS: idle.filler.seconds / Math.max(1, idleTicks),
    fillerRpcPerTick: idle.filler.proxyCalls / Math.max(1, idleTicks),
    fillerRpcPerDay: Math.round(idle.filler.proxyCallsPerS * DAY),
    // Each non-pending tick also fetches the book once over the service binding (a subrequest, not RPC).
    fillerSubrequestsPerDay: Math.round(idle.filler.proxyCallsPerS * DAY + (idleTicks / idle.filler.seconds) * DAY),
    orderbookAlarms: Math.max(idle.orderbook.alarms, idle.timeline.orderbookAlarms),
    orderbookRpcPerDay: Math.round(idle.orderbook.proxyCallsPerS * DAY),
    restingOrders: resting.length,
    restingRpcPerTick: restingWin ? restingWin.filler.proxyCalls / Math.max(1, ticksOf(restingWin)) : null,
    restingRpcPerDay: restingWin ? Math.round(restingWin.filler.proxyCallsPerS * DAY) : null,
    traceStoreComplete: idle.filler.alarms >= idle.timeline.fillerTicksWithRpc,
  };
  const out = { resting: restingWin, probeResting, probeEmpty, brownout, idle, extrapolation: extrap };
  writeResult("soak", out);
  console.log(`\n════════ soak ════════\n${json(extrap)}`);
}

await main();
process.exit(0);

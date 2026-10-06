/**
 * Staging-harness REPORT (LOCAL ONLY): one markdown summary over one or more run
 * directories — the load metrics side by side, the restart test, the soak, and the
 * extrapolation to Rootstock's real block time.
 *
 *   tsx e2e/report.ts <runDir> [<runDir> …]      (staging.sh report / all)
 *
 * Writes <last runDir>/results/REPORT.md and prints it.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type J = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const dirs = process.argv.slice(2);
if (!dirs.length) throw new Error("usage: report.ts <runDir> [<runDir> …]");
const read = (d: string, f: string): J | undefined => (existsSync(join(d, "results", f)) ? (JSON.parse(readFileSync(join(d, "results", f), "utf8")) as J) : undefined);
const envOf = (d: string): J => JSON.parse(readFileSync(join(d, "env.json"), "utf8")) as J;

/** Worker / dev-server error lines by message, straight from the run's wrangler.log. */
function errorCountsOf(d: string): Record<string, number> {
  const out: Record<string, number> = {};
  if (!existsSync(join(d, "wrangler.log"))) return out;
  for (const l of readFileSync(join(d, "wrangler.log"), "utf8").split("\n")) {
    const plain = l.replace(/\u001b\[[0-9;]*m/g, "");
    const m = /(Uncaught [^\n]{0,120}|Error inside ProxyWorker[^:]*|NOSENTRY reporting trace with exceptions[^;]*)/.exec(plain);
    if (m) {
      const k = m[1]!.replace(/https?:\/\/\S+/g, "URL").trim();
      out[k] = (out[k] ?? 0) + 1;
    }
  }
  return out;
}
const runs = dirs.map((d) => {
  const load = read(d, "load.json");
  if (load && !load.errorCounts) load.errorCounts = errorCountsOf(d);
  return { dir: d, env: envOf(d), load, restart: read(d, "restart.json"), soak: read(d, "soak.json") };
});
const s = (x: unknown, d = 0) => (typeof x === "number" && Number.isFinite(x) ? x.toFixed(d) : x === undefined || x === null ? "–" : String(x));
const ms = (x: unknown) => (typeof x === "number" && Number.isFinite(x) ? (x >= 10_000 ? `${(x / 1000).toFixed(1)} s` : `${x.toFixed(0)} ms`) : "–");
const pp = (d: J | undefined) => (d ? `${ms(d.p50)} / ${ms(d.p95)}` : "–");
const out: string[] = [];
const row = (label: string, f: (l: J, r: (typeof runs)[number]) => string) => out.push(`| ${label} | ${runs.map((r) => (r.load ? f(r.load, r) : "–")).join(" | ")} |`);

out.push("# Rootstock beta workers — local staging + load test\n");
const e0 = runs[0]!.env;
out.push("## Environment\n");
out.push(`- anvil fork of \`${e0.forkUrl}\` at block ${e0.forkBlock}, \`--block-time ${e0.blockTimeS}\`, gas price ${e0.gasPriceWei} wei (Rootstock's, served by the proxy), chain clock synced to the host`);
out.push(`- contracts via \`make deploy-core\` + \`make deploy-aggregator-fill\`: Settlement \`${e0.settlement}\`, Lens \`${e0.lens}\`, Permit3 \`${e0.permit3}\`, AggregatorFillSolver \`${e0.solver}\` (operator = anvil dev key #1 \`${e0.operator}\`), profit recipient (treasury) \`${e0.treasury}\``);
out.push(`- both workers + the harness edge in ONE \`wrangler dev --local\` (3 \`-c\` configs; committed wrangler.toml files verbatim, overrides in generated .dev.vars); RPC through the counting proxy; RBTC priced at $${e0.rbtcUsd}`);
out.push("");

out.push("## Load runs\n");
out.push(`| metric | ${runs.map((r) => `${r.env.label} (${r.env.latencyMs}±${r.env.jitterMs} ms RPC)`).join(" | ")} |`);
out.push(`|---|${runs.map(() => "---").join("|")}|`);
row("posts (accepted / total)", (l) => `${l.posts.accepted} / ${l.posts.total}`);
row("bad posts → status", (l) => Object.entries(l.posts.bad as J).map(([k, v]) => `${k.split(" {")[0]} ×${v}`).join("<br>"));
row("duplicates → status", (l) => Object.entries(l.posts.duplicates as J).map(([k, v]) => `${k.split(" {")[0]} ×${v}`).join("<br>"));
row("expected fills filled (exactly once)", (l) => `${l.fills.expectedFillFilled} / ${l.fills.expectedFill}`);
row("short-expiry profitable filled before expiry", (l) => `${l.fills.shortProfFilled} / ${l.fills.shortProf}`);
row("never-fill orders filled", (l) => `${l.fills.neverFilled} (cancel races ${l.fills.cancelRaces})`);
row("fills on-chain (inventory / route)", (l) => `${l.fills.onChain} (${l.fills.inventory} / ${l.fills.route})`);
row("post → tx sent p50 / p95", (l) => pp(l.latencyMs.postToSend));
row("tx sent → mined p50 / p95", (l) => pp(l.latencyMs.sendToMined));
row("**post → mined p50 / p95**", (l) => pp(l.latencyMs.postToMined));
row("mined → book shows filled p50 / p95", (l) => pp(l.latencyMs.minedToIndexed));
row("fills/min active avg · busiest 60 s · ceiling", (l) => `${s(l.throughput.fillsPerMinActive, 1)} · ${l.throughput.busiest60s} · ${l.throughput.ceilingPerMin}`);
row("filler ticks seen (RPC timeline)", (l) => s(l.ticks.filler.fromTimeline.ticks));
row("filler RPC calls/tick p50 / p95 / max", (l) => `${s(l.ticks.filler.fromTimeline.rpcPerTick.p50)} / ${s(l.ticks.filler.fromTimeline.rpcPerTick.p95)} / ${s(l.ticks.filler.fromTimeline.rpcPerTick.max)}`);
row("filler tick RPC span p50 / p95 / max", (l) => `${ms(l.ticks.filler.fromTimeline.rpcSpanMs.p50)} / ${ms(l.ticks.filler.fromTimeline.rpcSpanMs.p95)} / ${ms(l.ticks.filler.fromTimeline.rpcSpanMs.max)}`);
row("/status lastTick samples: subrequests p50 / max (limit 500)", (l) => `${s(l.ticks.filler.fromStatus.subrequests.p50)} / ${s(l.ticks.filler.fromStatus.subrequests.max)} (n=${l.ticks.filler.fromStatus.samples})`);
row("/status lastTick samples: duration p50 / max (budget 20 s)", (l) => `${ms(l.ticks.filler.fromStatus.durationMs.p50)} / ${ms(l.ticks.filler.fromStatus.durationMs.max)}`);
row("book alarms · interval p50 · traced wall max", (l) => `${l.ticks.orderbook.alarms} · ${s(l.ticks.orderbook.intervalS.p50, 1)} s · ${ms(l.ticks.orderbook.fromTraces.wallMs.max)}`);
row("filler RPC calls per fill", (l) => s(l.rpcPerFill, 1));
row("rebalancer txs", (l) => Object.entries((l.rebalanceTxs ?? {}) as J).map(([k, v]) => `${k} ×${v}`).join(", ") || "none");
row("re-evaluations of already-filled orders (✗ lines)", (l) => s(l.filledOrdersReEvaluatedFailures));
for (const ep of ["GET /orders?maker", "GET /orders/:hash/status", "GET /fills?maker"]) {
  row(`read ${ep} p50 / p95 (200s)`, (l) => pp(l.reads[ep]?.ok));
}
row("readers: 429 share", (l) => `${l.rateLimit.readers429} / ${l.rateLimit.readersTotal}`);
row("abuser: req/s, 429 share", (l) => `${s(l.rateLimit.abuser.perSecond)} /s, ${l.rateLimit.abuser.statuses["429"] ?? 0} / ${l.rateLimit.abuser.requests}`);
row("honest POST p50 / p95 during vs outside abuse", (l) => `${pp(l.rateLimit.honestPosts.latencyDuringAbuse)} vs ${pp(l.rateLimit.honestPosts.latencyOutsideAbuse)}`);
row("honest posts 429", (l) => s(l.rateLimit.honestPosts.statuses["429"] ?? 0));
row("operator txs · reverts · nonce clashes", (l) => `${l.txs.operator} · ${l.txs.reverts.length} · ${l.txs.nonceClashes.length}`);
row("fill index: chain / book / amounts ok", (l) => `${l.fillIndex.chain} / ${l.fillIndex.book} / ${l.fillIndex.amountsChecked}`);
row("gas: chain = filler log = RBTC spent", (l) => `${l.accounting.chainGasWei === l.accounting.fillerLoggedGasWei && l.accounting.rbtcSpentWei === String(BigInt(l.accounting.chainGasWei) + BigInt(l.accounting.valueWei)) ? "yes" : "NO"} (${(Number(l.accounting.chainGasWei) / 1e18).toFixed(8)} RBTC)`);
row("USDT0 outflow = Σ inventory paid", (l) => (l.accounting.usdt0Outflow === l.accounting.inventoryPaidLogged ? `yes (${(Number(l.accounting.usdt0Outflow) / 1e6).toFixed(2)})` : "NO"));
row("treasury spread (USDT0 · WRBTC)", (l) => `${(Number(l.accounting.treasuryDelta.usdt0) / 1e6).toFixed(2)} · ${(Number(l.accounting.treasuryDelta.wrbtc) / 1e18).toFixed(6)}`);
row("book DO rows at end", (l) => Object.entries(l.storage.orderbook.rows as J).map(([k, v]) => `${k} ${v}`).join(", "));
row("cron dispatches ok", (l) => `${l.crons?.ok ?? "–"} / ${l.crons?.dispatched ?? "–"}`);
row("alerts fired", (l) => s((l.alerts.status as unknown[]).length));
row("worker/dev-server errors by message", (l) => Object.entries((l.errorCounts ?? {}) as J).map(([k, v]) => `${k} ×${v}`).join("<br>") || "none");
row("**harness failures**", (l) => `**${(l.failures as unknown[]).length}**`);
out.push("");

for (const r of runs) {
  if (!r.load) continue;
  out.push(`### ${r.env.label}: per order kind\n`);
  out.push("| kind | expect | posted | accepted | filled |");
  out.push("|---|---|---|---|---|");
  for (const [k, v] of Object.entries(r.load.byKind as J)) out.push(`| ${k} | ${v.expect} | ${v.posted} | ${v.accepted} | ${v.filled} |`);
  out.push("");
  if ((r.load.failures as string[]).length) {
    out.push("Failures:\n");
    for (const f of r.load.failures as string[]) out.push(`- ${f}`);
    out.push("");
  }
  if ((r.load.txs.reverts as unknown[]).length) {
    out.push("Reverts:\n");
    for (const x of r.load.txs.reverts as J[]) out.push(`- ${x.tx}: ${x.reason} (${x.kind ?? "-"})`);
    out.push("");
  }
}

// ── extrapolation to Rootstock ──
// Inputs, all measured: the isolated-order probe (one order at a time, nothing queued
// ahead; soak.ts) for post → tx sent at the run's RPC latency, and the load runs for the
// one-tx-in-flight behaviour. The block wait is then swapped for Rootstock's: a tx sent at
// a random moment waits U(0, B) for the next block if blocks were regular, Exp(mean B) if
// block intervals are memoryless (PoW / merged mining) — p50 B·ln2, p95 B·ln20.
const B = 30;
const withProbe = runs.find((r) => r.soak?.probeEmpty) ?? runs.find((r) => r.soak);
const lastLoad = [...runs].reverse().find((r) => r.load);
if (withProbe?.soak || lastLoad?.load) {
  out.push(`## Extrapolation to Rootstock (≈${B} s blocks)\n`);
  const l = lastLoad?.load;
  if (l) {
    out.push(`- **Throughput ceiling**: one tx in flight ⇒ at most one fill per block ⇒ **≈${(60 / B).toFixed(0)} fills/min = ${(3600 / B).toFixed(0)}/h**. On anvil (${l.blockTimeS} s blocks, ceiling ${l.throughput.ceilingPerMin}/min) the busiest minute reached ${l.throughput.busiest60s} fills at ${runs.find((r) => r.load === l)?.env.latencyMs} ms RPC latency (each fill needs ~${s(l.rpcPerFill, 0)} sequential RPC calls, so at 150 ms the next send misses the next 2 s block; at ${B} s blocks it fits inside one block interval). With memoryless block intervals the send after a receipt still lands in the next block, so ≈1 fill/block holds.`);
    out.push(`- **Queueing**: a burst drains at ≈${(60 / B).toFixed(0)}/min. This load profile offered ${((l.posts.accepted / l.durations.postingS) * 60).toFixed(0)} orders/min (${l.fills.expectedFill} fillable in ${s(l.durations.postingS)} s); on Rootstock the last of them would be filled ≈ ${((l.fills.expectedFill * B) / 60).toFixed(0)} min after the burst started (anvil, measured post → mined p50 / p95: ${pp(l.latencyMs.postToMined)}). The production caps are lower still: ROUTE_HOURLY_FILLS 60/h and HOURLY_USDT0 2,000/h.`);
  }
  for (const r of runs) {
    for (const [name, pr] of [["empty book", r.soak?.probeEmpty], ["resting book", r.soak?.probeResting]] as const) {
      if (!pr || !pr.filled) continue;
      const send50 = pr.postToSendMs.p50 as number;
      const send95 = pr.postToSendMs.p95 as number;
      out.push(`- **Isolated order, ${pr.what} (${r.env.latencyMs} ms RPC; ${pr.filled}/${pr.orders} probes)**: measured post → tx sent p50 ${ms(send50)} / p95 ${ms(send95)}, post → mined ${pp(pr.postToMinedMs)} on anvil. On Rootstock: regular ${B} s blocks ⇒ post → mined ≈ ${ms(send50 + (B * 1000) / 2)} p50 / ${ms(send95 + 0.95 * B * 1000)} p95; memoryless ${B} s blocks ⇒ ≈ ${ms(send50 + B * 1000 * Math.LN2)} p50 / ${ms(send95 + B * 1000 * Math.log(20))} p95 (sums of percentiles: an upper-ish estimate).`);
    }
  }
  if (l) out.push(`- **Book shows filled**: CONFIRMATIONS 2 × ${B} s + ≤ one 20 s alarm ⇒ ≈ 60–80 s after inclusion (measured on anvil with CONFIRMATIONS=1 and 2 s blocks: ${pp(l.latencyMs.minedToIndexed)}).`);
  out.push(`- **RPC load does not scale with block time**: ticks are wall-clock (5 s; PENDING_TICK_SECONDS = 3 s while a tx is pending, so each fill on Rootstock costs ≈ ${B / 3} pending ticks × ~1.3 calls of receipt polling ≈ ${Math.round((B / 3) * 1.3)} extra calls).`);
  out.push("");
}

for (const r of runs) {
  if (r.restart) {
    const A = r.restart.A;
    const Bx = r.restart.B;
    out.push(`## Restart test (${r.env.label})\n`);
    out.push(`- A (tx in the mempool at the crash — ${A.inFlightKind ?? "fill"}): ${A.revived}; pending ${A.tx} (nonce ${A.nonce}) resolved → ${A.resolvedRow?.status ?? "?"}; sends with that nonce: 1; budgets before → after: gas ${A.budgetsBefore.gasRbtcLeft} → ${A.budgetsAfter.gasRbtcLeft} RBTC, USDT0 ${A.budgetsBefore.usdt0Left} → ${A.budgetsAfter.usdt0Left}, route fills ${A.budgetsBefore.routeFillsLeft} → ${A.budgetsAfter.routeFillsLeft}; backoff entries ${A.backoffBefore} → ${A.backoffAfter}; down ${ms(A.downMs)}.`);
    if (Bx.autoRebroadcast !== undefined) {
      out.push(`- B (broadcast lost in flight): pending record (with the signed bytes) survived: ${Bx.pendingSurvived}; ${Bx.revived}; **the filler re-broadcast the same bytes itself: ${Bx.autoRebroadcast}** (${ms(Bx.rebroadcastAfterLostSendMs)} after the lost send, ${ms(Bx.rebroadcastAfterRestartMs)} after the restart; ${Bx.resends} re-send(s), same hash and nonce); mined ${Bx.minedStatus} ${ms(Bx.minedAfterLostSendMs)} after the lost send; ${Bx.sendsDuringStall} other sends meanwhile; manual re-send needed: ${Bx.manualRebroadcast}; row ${Bx.resolvedRow?.status ?? "?"}.`);
    } else {
      out.push(`- B (broadcast lost in flight): pending record survived: ${Bx.pendingSurvived}; ${Bx.revived}; over ${Bx.observedS} s: timed out (RECEIPT_TIMEOUT_MS) ${Bx.timedOutSeen}, ${Bx.alarmsDuringStall} ticks, **${Bx.sendsDuringStall} sends** (nothing else goes out until the 15-min drop rule); manual re-broadcast of the recorded bytes → ${Bx.manualRebroadcastMined}, row ${Bx.resolvedRow?.status ?? "?"}.`);
    }
    out.push(`- failures: ${(r.restart.failures as string[]).length ? (r.restart.failures as string[]).join("; ") : "none"}`);
    out.push("");
  }
  if (r.soak) {
    const x = r.soak.extrapolation;
    const idle = r.soak.idle;
    out.push(`## Soak (${r.env.label})\n`);
    out.push(`- idle ${s(idle.filler.seconds)} s, empty book, no admin polling: filler ${x.fillerTicks} ticks (every ${s(x.fillerTickEveryS, 1)} s), ${s(x.fillerRpcPerTick, 2)} RPC calls/tick (${Object.entries(idle.filler.byMethod as J).map(([k, v]) => `${k} ${v}`).join(", ")}), traced subrequests/tick p50 ${s(idle.filler.subrequestsPerAlarm.p50)} max ${s(idle.filler.subrequestsPerAlarm.max)}, traced wall p50 ${ms(idle.filler.wallMs.p50)} max ${ms(idle.filler.wallMs.max)}`);
    out.push(`- orderbook ${x.orderbookAlarms} alarms (every ${s(idle.orderbook.seconds / Math.max(1, x.orderbookAlarms), 1)} s), ${s(idle.orderbook.proxyCalls / Math.max(1, x.orderbookAlarms), 2)} RPC calls/alarm (${Object.entries(idle.orderbook.byMethod as J).map(([k, v]) => `${k} ${v}`).join(", ")}); cron dispatches ok ${idle.crons?.ok ?? "–"}/${idle.crons?.dispatched ?? "–"}`);
    out.push(`- **per day at the 5 s cadence (idle)**: filler ≈ ${x.fillerRpcPerDay?.toLocaleString("en")} RPC calls + one book fetch per tick ≈ ${x.fillerSubrequestsPerDay?.toLocaleString("en")} subrequests; orderbook ≈ ${x.orderbookRpcPerDay?.toLocaleString("en")} RPC calls`);
    if (r.soak.brownout) {
      const b = r.soak.brownout;
      out.push(`- **RPC brownout** (every filler RPC call refused with HTTP 429 for ${b.seconds} s): error streak ${b.rpcErrorStreakAtEnd} → ${b.rpcErrorStreakAfterRecovery} after recovery; webhook deliveries: ${(b.webhooksDelivered as unknown[]).length} ${JSON.stringify(b.webhooksDelivered).slice(0, 200)}`);
    }
    if (r.soak.resting) out.push(`- **resting book** (${x.restingOrders} unprofitable orders live): filler ${s(x.restingRpcPerTick, 1)} RPC calls/tick (${s(x.restingRpcPerTick / Math.max(1, x.restingOrders), 2)} per resting order) ⇒ ≈ ${x.restingRpcPerDay?.toLocaleString("en")}/day (${Object.entries(r.soak.resting.filler.byMethod as J).map(([k, v]) => `${k} ${v}`).join(", ")})`);
    out.push("");
  }
}

const text = out.join("\n");
writeFileSync(join(dirs[dirs.length - 1]!, "results", "REPORT.md"), text);
console.log(text);

/**
 * Staging-harness RESTART TEST (LOCAL ONLY, not part of CI) — `staging.sh restart`,
 * against a running stack (normally right after `staging.sh load`, so budgets and
 * backoffs carry real state).
 *
 * A. TX IN THE MEMPOOL. Mining is paused on anvil, a profitable order is posted,
 *    the filler sends its fill (seen at the proxy), wrangler dev is SIGKILLed (the
 *    whole process group: a crash, not a shutdown), mining resumes so the tx lands
 *    while the worker is down, and wrangler dev restarts on the same persisted state.
 *    Verified: the persisted alarm (or the cron) revives the filler, the pending tx
 *    resolves to `filled`, no second tx goes out for that nonce or order, and
 *    budgets and backoffs survive.
 * B. BROADCAST LOST IN FLIGHT. The proxy holds the filler's next eth_sendRawTransaction
 *    and drops it; wrangler dev is killed during the hold and restarted. The pending
 *    record (with the signed bytes) survives and the node never saw the tx. Verified:
 *    once the node has not known it for REBROADCAST.afterMs (60 s) the filler
 *    RE-BROADCASTS THE SAME BYTES (same hash, same nonce) by itself, the tx mines and
 *    resolves `filled`, and no other tx goes out meanwhile. (Before 2026-10-05 it sent
 *    nothing until the 15-minute drop rule; the harness then re-sent the bytes by hand.)
 */
import { execFileSync } from "node:child_process";
import { join } from "node:path";

import { encodeFunctionData, erc20Abi, maxUint256, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { PERMIT3_ABI, USDT0, WRBTC, admin, book, buildOrder, deal, explorer, json, loadEnv, nowS, proxy, publicClient, quote, rpc, setBalance, sleep, testKey, walletClient, writeResult, type ProxyTx } from "./lib";

const env = loadEnv();
const pub = publicClient(env);
const adm = admin(env);
const px = proxy(env);
const ex = explorer(env);
const STAGING = join(import.meta.dirname, "staging.sh");
const LOST_OBSERVE_S = Number(process.env.LOST_OBSERVE_S ?? 150);
const log = (m: string) => console.log(`[restart ${new Date().toISOString().slice(11, 19)}] ${m}`);
const failures: string[] = [];
const notes: string[] = [];

function wrangler(cmd: "kill" | "start"): void {
  execFileSync("bash", [STAGING, "wrangler", cmd], { stdio: "inherit", env: { ...process.env, RUN_DIR: env.runDir } });
}

type Status = { pending?: { hash: Hex; nonce: number; orderHash?: Hex; timedOut?: boolean } | null; budgets?: Record<string, string>; backoff?: Array<{ key: string; scope: string; until: string; strikes?: number; fails?: number }>; recent?: { events?: Array<Record<string, unknown>> }; lastTick?: { at: string } | null };
const status = async () => (await adm.get<Status>("/status")).body;

const maker = privateKeyToAccount(testKey(`${env.label}:restart-maker`, 0));

async function fundMaker(): Promise<void> {
  await setBalance(pub, maker.address, 10n ** 18n);
  await deal(pub, WRBTC, maker.address, 10n ** 17n);
  const w = walletClient(env, maker);
  for (const data of [
    encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [env.permit3, maxUint256] }),
    encodeFunctionData({ abi: PERMIT3_ABI, functionName: "approveToken", args: [env.settlement, WRBTC, (1n << 160n) - 1n, 0] }),
  ]) {
    const to = data.startsWith("0x095ea7b3") ? WRBTC : env.permit3;
    const h = await w.sendTransaction({ to, data, gas: 120_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" });
    await pub.waitForTransactionReceipt({ hash: h, pollingInterval: 500 });
  }
}

async function postProfitable(tag: string): Promise<Hex> {
  const amountIn = 2n * 10n ** 15n;
  const q = await quote(pub, [WRBTC, USDT0], [3000], amountIn);
  const o = await buildOrder(env, { maker, tokenIn: WRBTC, tokenOut: USDT0, amountIn, owed: (q * 94n) / 100n, expiry: BigInt(nowS() + 3600) });
  const r = await book(env, "10.4.0.1").post("/orders", o.body);
  if (r.status !== 202) throw new Error(`${tag}: post ${r.status} ${JSON.stringify(r.body)}`);
  log(`${tag}: posted ${o.hash}`);
  return o.hash;
}

async function waitSend(since: number, timeoutMs: number): Promise<ProxyTx> {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const t = (await px.txs()).slice(since).find((x) => x.from?.toLowerCase() === env.operator.toLowerCase());
    if (t) return t;
    await sleep(200);
  }
  throw new Error("the filler sent nothing");
}

/** Root spans of the filler since `t` (did an alarm / a cron fire?). */
async function fillerInvocations(t: number) {
  try {
    return await ex.obs(`SELECT name, start_ms, duration_ms FROM spans WHERE parent_id IS NULL AND service = 'filler-1delta-rsk' AND name IN ('alarm','scheduled') AND start_ms >= ? ORDER BY start_ms`, [t]);
  } catch {
    return [];
  }
}

async function revive(t: number): Promise<string> {
  // Does the persisted alarm fire by itself after the restart? Production would also
  // have the minute cron; locally the cron only fires when dispatched.
  for (let i = 0; i < 20; i++) {
    if ((await fillerInvocations(t)).some((s) => s.name === "alarm")) return "persisted alarm fired on its own";
    await sleep(1000);
  }
  const r = await ex.scheduled("filler-1delta-rsk");
  for (let i = 0; i < 15; i++) {
    if ((await fillerInvocations(t)).some((s) => s.name === "alarm")) return `alarm did not fire on its own within 20 s; the cron (dispatched: ${r.outcome}) re-armed it`;
    await sleep(1000);
  }
  return "no alarm after restart + cron";
}

async function main(): Promise<void> {
  await fundMaker();
  const blockTime = env.blockTimeS;

  // ── A: tx in the mempool at the crash ──
  log("A: pausing anvil mining; waiting for the filler to send a fill");
  let st = await status();
  for (let i = 0; i < 60 && st.pending; i++) {
    await sleep(1000);
    st = await status();
  }
  const txsBefore = (await px.txs()).length;
  await rpc(pub, "evm_setIntervalMining", [0]);
  await rpc(pub, "evm_setAutomine", [false]);
  const nonceBefore = await pub.getTransactionCount({ address: env.operator, blockTag: "latest" });
  const orderA = await postProfitable("A");
  const sent = await waitSend(txsBefore, 120_000);
  log(`A: filler sent ${sent.hash} (nonce ${sent.nonce}) — tx is in anvil's mempool, unmined`);
  await sleep(1500);
  const before = await status();
  if (before.pending?.hash?.toLowerCase() !== sent.hash.toLowerCase()) failures.push(`A: /status before the kill does not show the sent tx as pending (${json(before.pending)})`);
  const killAt = Date.now();
  wrangler("kill");
  log("A: wrangler dev SIGKILLed; resuming mining");
  await rpc(pub, "evm_setIntervalMining", [blockTime]);
  const rc = await pub.waitForTransactionReceipt({ hash: sent.hash, pollingInterval: 500, timeout: 60_000 });
  log(`A: the pending tx mined while the worker was down (block ${rc.blockNumber}, ${rc.status})`);
  const restartAt = Date.now();
  wrangler("start");
  const revivedA = await revive(restartAt);
  log(`A: ${revivedA}`);
  let after = await status();
  for (let i = 0; i < 30 && after.pending; i++) {
    await sleep(1000);
    after = await status();
  }
  if (after.pending) failures.push(`A: pending tx not resolved after the restart: ${json(after.pending)}`);
  let fills = (await adm.get<{ fills: Array<Record<string, unknown>> }>(`/fills?limit=50`)).body.fills ?? [];
  // The tx in flight at the crash is whatever the filler sent first: usually the fill of
  // order A, but after a busy run it can be a rebalancer tx (redeem / approval) — the
  // crash semantics are the same: resolved from its receipt, never sent twice.
  const row = fills.find((f) => String(f.tx).toLowerCase() === sent.hash.toLowerCase());
  const wantStatus = row?.kind === "fill" ? "filled" : "mined";
  if (!row || row.status !== wantStatus) failures.push(`A: the fills log has no '${wantStatus}' row for ${sent.hash} (${json(row)})`);
  if (row && row.kind !== "fill") notes.push(`A: the tx in flight at the crash was a ${row.strategy} ${row.kind} (${row.note ?? ""}), resolved '${row.status}' after the restart`);
  // Order A itself must end up filled exactly once (later, if the crash caught another tx).
  for (let i = 0; i < 90 && !fills.some((f) => String(f.order_hash ?? "").toLowerCase() === orderA.toLowerCase() && f.status === "filled"); i++) {
    await sleep(1000);
    fills = (await adm.get<{ fills: Array<Record<string, unknown>> }>(`/fills?limit=50`)).body.fills ?? [];
  }
  const sendsA = (await px.txs()).slice(txsBefore).filter((t) => t.from?.toLowerCase() === env.operator.toLowerCase());
  // Distinct txs at that nonce (a re-broadcast of the same signed bytes is the same tx).
  const sameNonce = [...new Set(sendsA.filter((t) => t.nonce === sent.nonce).map((t) => t.hash.toLowerCase()))];
  if (sameNonce.length !== 1) failures.push(`A: ${sameNonce.length} distinct txs with nonce ${sent.nonce}: ${sameNonce.join(", ")}`);
  const sameOrder = fills.filter((f) => String(f.order_hash ?? "").toLowerCase() === orderA.toLowerCase());
  if (sameOrder.length !== 1 || sameOrder[0]!.status !== "filled") failures.push(`A: ${sameOrder.length} fill rows for order ${orderA} (${json(sameOrder.map((f) => f.status))})`);
  const nonceAfter = await pub.getTransactionCount({ address: env.operator, blockTag: "latest" });
  const budgetsBefore = before.budgets ?? {};
  const budgetsAfter = after.budgets ?? {};
  // The gas charge settles from limit × price down to the receipt; nothing else may move except by new sends.
  const newSendsA = sendsA.length - 1;
  if (newSendsA === 0) {
    for (const k of ["usdt0Left", "usdrifLeft", "routeFillsLeft"]) if (budgetsBefore[k] !== budgetsAfter[k]) failures.push(`A: budget ${k} changed across the restart: ${budgetsBefore[k]} → ${budgetsAfter[k]}`);
    if (Number(budgetsAfter.gasRbtcLeft) < Number(budgetsBefore.gasRbtcLeft)) failures.push(`A: gas budget fell across the restart: ${budgetsBefore.gasRbtcLeft} → ${budgetsAfter.gasRbtcLeft}`);
  } else notes.push(`A: ${newSendsA} further send(s) after the restart (book had more work) — budget comparison skipped`);
  const keys = (s: Status) => new Set((s.backoff ?? []).filter((b) => Date.parse(b.until) > Date.now() + 5_000).map((b) => `${b.scope}:${b.key}`));
  const lost = [...keys(before)].filter((k) => !keys(after).has(k));
  if (lost.length) failures.push(`A: backoff entries lost across the restart: ${lost.join(", ")}`);
  const resultA = { order: orderA, inFlightKind: row ? `${row.strategy} ${row.kind}` : "?", tx: sent.hash, nonce: sent.nonce, nonceBefore, nonceAfter, killAt, restartAt, downMs: restartAt - killAt, revived: revivedA, resolvedRow: row ?? null, budgetsBefore, budgetsAfter, backoffBefore: before.backoff?.length ?? 0, backoffAfter: after.backoff?.length ?? 0, sendsAfterRestart: sendsA.length };
  log(`A: ${json({ revived: revivedA, budgetsBefore, budgetsAfter, backoff: [resultA.backoffBefore, resultA.backoffAfter] })}`);

  // ── B: broadcast lost in flight ──
  log("B: proxy will HOLD then DROP the filler's next raw tx; killing wrangler during the hold");
  for (let i = 0; i < 60 && (await status()).pending; i++) await sleep(1000);
  const txsBeforeB = (await px.txs()).length;
  await px.config({ sendRaw: "hold-drop", holdMs: 8000 });
  const orderB = await postProfitable("B");
  const held = await waitSend(txsBeforeB, 120_000);
  log(`B: filler is broadcasting ${held.hash} (nonce ${held.nonce}); killing wrangler during the hold`);
  wrangler("kill");
  await sleep(9000);
  await px.config({ sendRaw: "pass", holdMs: 0 });
  const knownToNode = await pub.getTransaction({ hash: held.hash }).then(() => true).catch(() => false);
  if (knownToNode) failures.push("B: the node knows the dropped tx (the proxy should have dropped it)");
  const restartB = Date.now();
  wrangler("start");
  const revivedB = await revive(restartB);
  const stB = await status();
  if (stB.pending?.hash?.toLowerCase() !== held.hash.toLowerCase()) failures.push(`B: the pending record did not survive the crash (${json(stB.pending)})`);
  log(`B: ${revivedB}; pending after restart: ${stB.pending?.hash ?? "none"} — waiting up to ${LOST_OBSERVE_S} s for the filler to re-broadcast the same bytes`);
  const heldHash = held.hash.toLowerCase();
  let rebroadcastAt: number | undefined;
  let rcB: Awaited<ReturnType<typeof pub.getTransactionReceipt>> | undefined;
  let timedOutSeen = false;
  const observeEnd = Date.now() + LOST_OBSERVE_S * 1000;
  while (Date.now() < observeEnd && !rcB) {
    await sleep(2000);
    const again = (await px.txs()).slice(txsBeforeB).filter((t) => t.hash.toLowerCase() === heldHash && t.mode === "pass");
    if (again.length && rebroadcastAt === undefined) {
      rebroadcastAt = again[0]!.at;
      log(`B: the filler re-broadcast ${held.hash} by itself, ${((rebroadcastAt - held.at) / 1000).toFixed(1)} s after the lost send (${again.length} re-send(s) so far)`);
    }
    if ((await status()).pending?.timedOut) timedOutSeen = true;
    if (rebroadcastAt !== undefined) rcB = await pub.getTransactionReceipt({ hash: held.hash }).catch(() => undefined);
  }
  let manual = false;
  if (!rebroadcastAt) {
    failures.push(`B: no automatic re-broadcast of the lost tx within ${LOST_OBSERVE_S} s`);
    // Recover the stack for whatever runs next: push the recorded bytes by hand.
    manual = true;
    await pub.request({ method: "eth_sendRawTransaction" as never, params: [held.raw] as never });
  }
  rcB ??= await pub.waitForTransactionReceipt({ hash: held.hash, pollingInterval: 500, timeout: 60_000 });
  const opSends = (await px.txs()).slice(txsBeforeB).filter((t) => t.from?.toLowerCase() === env.operator.toLowerCase());
  const resends = opSends.filter((t) => t.hash.toLowerCase() === heldHash).length - 1;
  // Nothing else may go out while the lost tx is pending: no other hash before it mined, never its nonce.
  const minedAt = Number((await pub.getBlock({ blockNumber: rcB.blockNumber })).timestamp) * 1000;
  const sendsDuringStall = opSends.filter((t) => t.hash.toLowerCase() !== heldHash && t.at < minedAt);
  if (sendsDuringStall.length) failures.push(`B: ${sendsDuringStall.length} other tx(s) sent while the lost tx was pending`);
  const nonceClash = opSends.filter((t) => t.nonce === held.nonce && t.hash.toLowerCase() !== heldHash);
  if (nonceClash.length) failures.push(`B: another tx at the lost tx's nonce ${held.nonce}: ${nonceClash.map((t) => t.hash).join(", ")}`);
  const stallInvocations = (await fillerInvocations(restartB)).filter((x) => x.name === "alarm").length;
  let afterB = await status();
  for (let i = 0; i < 30 && afterB.pending; i++) {
    await sleep(1000);
    afterB = await status();
  }
  if (afterB.pending) failures.push(`B: still pending after the re-broadcast mined: ${json(afterB.pending)}`);
  const fillsB = (await adm.get<{ fills: Array<Record<string, unknown>> }>(`/fills?limit=50`)).body.fills ?? [];
  const rowB = fillsB.find((f) => String(f.tx).toLowerCase() === heldHash);
  const wantB = rowB?.kind === "fill" ? "filled" : "mined";
  if (!rowB || rowB.status !== wantB) failures.push(`B: the fills log has no '${wantB}' row for ${held.hash} (${json(rowB)})`);
  const resultB = {
    order: orderB,
    tx: held.hash,
    nonce: held.nonce,
    revived: revivedB,
    pendingSurvived: stB.pending?.hash?.toLowerCase() === heldHash,
    observedS: LOST_OBSERVE_S,
    autoRebroadcast: rebroadcastAt !== undefined,
    rebroadcastAfterLostSendMs: rebroadcastAt !== undefined ? rebroadcastAt - held.at : null,
    rebroadcastAfterRestartMs: rebroadcastAt !== undefined ? rebroadcastAt - restartB : null,
    resends,
    minedStatus: rcB.status,
    minedAfterLostSendMs: minedAt - held.at,
    timedOutSeen,
    alarmsDuringStall: stallInvocations,
    sendsDuringStall: sendsDuringStall.length,
    manualRebroadcast: manual,
    resolvedRow: rowB ?? null,
  };
  log(`B: ${json({ autoRebroadcast: resultB.autoRebroadcast, afterLostSendS: resultB.rebroadcastAfterLostSendMs === null ? null : resultB.rebroadcastAfterLostSendMs / 1000, resends, mined: rcB.status, sendsDuringStall: sendsDuringStall.length, row: rowB?.status })}`);

  const out = { A: resultA, B: resultB, failures, notes };
  writeResult("restart", out);
  console.log(`\n════════ restart: ${failures.length ? "FAIL" : "PASS"} ════════`);
  for (const f of failures) console.log(`  ✗ ${f}`);
  for (const n of notes) console.log(`  · ${n}`);
  if (failures.length) process.exitCode = 1;
}

await main();
process.exit(process.exitCode ?? 0);

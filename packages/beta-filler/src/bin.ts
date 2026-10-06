import { erc20Abi, formatEther } from "viem";

import { balanceOf, connect } from "./chain";
import { loadConfig, parseFixed } from "./config";
import { dispatch } from "./dispatch";
import { Engine } from "./engine";
import type { FillOutcome } from "./filler";
import { entryFromFile, FileStateStore } from "./fileStore";
import { GAS, type Resolution } from "./guard";
import { fetchOrders, type BookEntry } from "./intake";
import { fmtUnits } from "./policy";
import type { RebalanceOutcome } from "./rebalance";

const cfg = loadConfig(process.env);
const chain = connect(cfg);
const log = (m: string) => console.log(`${new Date().toISOString()} ${m}`);
/** STATE_FILE: inventory outflows, route fill counter, shared gas spends, per-order backoff, the pending tx. */
const engine = await Engine.create({ cfg, chain, store: new FileStateStore(cfg.stateFile), log });

/** How often the CLI polls an outstanding tx's receipt, ms. */
const RECEIPT_POLL_MS = 1_000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const json = (v: unknown) => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x));

/**
 * Resolve the outstanding tx, polling every second until it is settled (mined,
 * or dropped by the 15-minute rule). Returns the final resolution, if any.
 */
async function settle(): Promise<Resolution | undefined> {
  let last: Resolution | undefined;
  while (engine.pending) {
    const r = await engine.resolvePending();
    if (r) last = r;
    if (!engine.pending) break;
    await sleep(RECEIPT_POLL_MS);
  }
  return last;
}

async function status() {
  const [usdt0, usdrif, rif, rbtc] = await Promise.all([
    balanceOf(chain, cfg.tokens.usdt0),
    balanceOf(chain, cfg.tokens.usdrif),
    balanceOf(chain, cfg.tokens.rif),
    chain.pub.getBalance({ address: chain.me }),
  ]);
  const allow = async (t: `0x${string}`) =>
    chain.pub.readContract({ address: t, abi: erc20Abi, functionName: "allowance", args: [chain.me, cfg.settlement] });
  const left = engine.budgetsLeft(Date.now());
  console.log(`filler     ${chain.me}  (chain ${cfg.chainId}, ${cfg.dryRun ? "DRY RUN" : "LIVE"})`);
  console.log(`RBTC       ${formatEther(rbtc)}`);
  console.log(`USDT0      ${fmtUnits(usdt0, 6)}   settlement allowance ${fmtUnits(await allow(cfg.tokens.usdt0), 6)}   hourly left ${fmtUnits(left.usdt0, 6)}`);
  console.log(`USDRIF     ${fmtUnits(usdrif, 18)}   settlement allowance ${fmtUnits(await allow(cfg.tokens.usdrif), 18)}   hourly left ${fmtUnits(left.usdrif, 18)}`);
  console.log(`RIF        ${fmtUnits(rif, 18)}`);
  console.log(`gas        ${formatEther(engine.guard.gas.remaining(GAS, Date.now()))} of ${formatEther(cfg.gas.hourlyWei)} RBTC/h left (both strategies + rebalancer), max gas price ${cfg.gas.maxGasPriceWei} wei`);
  const p = engine.pending;
  console.log(`pending tx ${p ? `${p.hash} (${p.strategy} ${p.kind}${p.orderHash ? ` ${p.orderHash}` : ""}, nonce ${p.nonce}, sent ${new Date(p.sentAt).toISOString()}${p.timedOut ? ", timed out" : ""})` : "none"}`);
  const moc = engine.rebalancer.pendingRedemption();
  if (moc) console.log(`MoC op     ${moc.opId} waiting ${Math.round(moc.ageMs / 1000)} s`);
  console.log(`strategies: inventory ${cfg.strategies.inventory ? "on" : "off"}, route ${cfg.strategies.route ? "on" : "off"}`);
  if (cfg.route) {
    console.log(`route      solver ${cfg.route.solver}  fills left ${left.routeFills}/h  max gas ${cfg.route.maxGas}`);
    if (engine.route) await engine.route.init();
  }
  console.log(`buy side ${cfg.policy.buyUsdrif ? "on" : "off"} (max price ${fmtUnits(cfg.policy.maxBuyPrice, 18)}), sell side ${cfg.policy.sellUsdrif ? "on" : "off"} (min price ${fmtUnits(cfg.policy.minSellPrice, 18)})`);
}

/** A fill resolution as the {@link FillOutcome} `fill-json` prints. */
function outcomeOf(r: Resolution, sent: FillOutcome): FillOutcome {
  const p = r.pending;
  if (r.status === "success") return { ...sent, status: "filled", tx: p.hash };
  return { ...sent, status: "failed", tx: p.hash, reason: `tx ${r.status}`, final: true };
}

/**
 * Feed one signed order straight to the strategies, bypassing the orderbook, and
 * drive it to its end: a sent approval is awaited and the fill retried; a sent
 * fill is awaited and its resolution printed.
 */
async function fillJson(file: string) {
  const entry: BookEntry = entryFromFile(file);
  log(`beta-filler ${chain.me} ${cfg.dryRun ? "DRY RUN" : "LIVE"} — one order from ${file}: ${entry.orderHash}`);
  if (engine.pending) log(`waiting for the outstanding tx ${engine.pending.hash} first`);
  await settle();
  let out: FillOutcome | undefined;
  for (let round = 0; round < 4; round++) {
    engine.beginSweep();
    out = await dispatch(entry, engine.strategies);
    await engine.saveIfDirty();
    if (!out || out.status !== "pending") break;
    const kind = engine.pending?.kind;
    const r = await settle();
    if (kind === "fill") {
      out = r ? outcomeOf(r, out) : out;
      break;
    }
    // An approval (or a reset) was mined: try the fill again.
  }
  log(`outcome: ${json(out)}`);
  if (!out || out.status === "failed" || out.status === "pending") process.exitCode = 1;
}

/** Run one rebalancer action to its end (approval first if needed, then the action, each awaited). */
async function rebalanceAction(act: () => Promise<RebalanceOutcome | undefined>) {
  await settle();
  for (let round = 0; round < 4; round++) {
    const r = await act();
    await engine.saveIfDirty();
    if (!r || r.status !== "sent") {
      log(`rebalance: ${json(r ?? { status: "nothing to do" })}`);
      if (r?.status === "failed") process.exitCode = 1;
      return;
    }
    const res = await settle();
    if (!r.approval) {
      log(`rebalance: ${r.action} ${res?.status ?? "?"} (tx ${r.tx})`);
      if (res?.status !== "success") process.exitCode = 1;
      return;
    }
  }
}

async function run() {
  if (engine.route) await engine.route.init();
  log(`beta-filler ${chain.me} ${cfg.dryRun ? "DRY RUN (set DRY_RUN=0 to broadcast)" : "LIVE"} — book ${cfg.orderbookUrl}`);
  await status();
  let lastCount = -1;
  // One tick at a time: resolve the outstanding tx; if none, one pass over the
  // book (each order previewed on the lens and simulated before anything is
  // sent — the book is only a candidate list), stopping at the first tx sent;
  // else one rebalancer step. Every POLL_MS, or every second while a tx is pending.
  const fetchEntries = async () => {
    const { entries, skipped } = await fetchOrders(cfg.orderbookUrl);
    if (entries.length !== lastCount) {
      log(`book: ${entries.length} fillable order(s)${skipped ? `, ${skipped} skipped` : ""}`);
      lastCount = entries.length;
    }
    return entries;
  };
  for (;;) {
    let pending = false;
    try {
      const rep = await engine.tick({ fetchEntries });
      for (const e of rep.errors) log(`tick: ${e}`);
      pending = rep.pending;
    } catch (e) {
      log(`tick: ${e instanceof Error ? e.message.split("\n")[0] : e}`);
    }
    await sleep(pending ? RECEIPT_POLL_MS : cfg.pollMs);
  }
}

const [cmd = "run", arg] = process.argv.slice(2);
switch (cmd) {
  case "run":
    await run();
    break;
  case "status":
    await status();
    break;
  case "fill-json":
    if (!arg) throw new Error("usage: fill-json <file with {order, sig, fillAmount?}>");
    await fillJson(arg);
    break;
  case "redeem":
    await rebalanceAction(() => engine.rebalancer.redeemIfNeeded(true));
    break;
  case "sell-rif":
    await rebalanceAction(() => engine.rebalancer.sellRifIfNeeded(true));
    break;
  case "mint":
    if (!arg) throw new Error("usage: mint <USDRIF amount, e.g. 250>");
    await rebalanceAction(() => engine.rebalancer.mint(parseFixed(arg, 18)));
    break;
  case "settle": {
    // Resolve a leftover outstanding tx (e.g. after a crash) without sending anything.
    const r = await settle();
    log(r ? `tx ${r.pending.hash}: ${r.status}` : "no pending tx");
    break;
  }
  default:
    throw new Error(`unknown command ${cmd} (run | status | fill-json <file> | redeem | sell-rif | mint <amount> | settle)`);
}

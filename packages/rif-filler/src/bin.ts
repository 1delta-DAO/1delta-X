import { existsSync, readFileSync, writeFileSync } from "node:fs";

import { erc20Abi, formatEther } from "viem";

import { balanceOf, connect } from "./chain";
import { loadConfig, parseFixed } from "./config";
import { Filler } from "./filler";
import { fetchOrders } from "./intake";
import { Budget, fmtUnits } from "./policy";
import { Rebalancer } from "./rebalance";

const cfg = loadConfig();
const chain = connect(cfg);
const log = (m: string) => console.log(`${new Date().toISOString()} ${m}`);

function loadBudget(): Budget {
  const caps = {
    [cfg.tokens.usdt0.toLowerCase()]: cfg.policy.hourlyUsdt0,
    [cfg.tokens.usdrif.toLowerCase()]: cfg.policy.hourlyUsdrif,
  };
  const spends = existsSync(cfg.stateFile) ? (JSON.parse(readFileSync(cfg.stateFile, "utf8")).spends ?? []) : [];
  return new Budget(caps, spends);
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
  const budget = loadBudget();
  console.log(`filler     ${chain.me}  (chain ${cfg.chainId}, ${cfg.dryRun ? "DRY RUN" : "LIVE"})`);
  console.log(`RBTC       ${formatEther(rbtc)}`);
  console.log(`USDT0      ${fmtUnits(usdt0, 6)}   settlement allowance ${fmtUnits(await allow(cfg.tokens.usdt0), 6)}   hourly left ${fmtUnits(budget.remaining(cfg.tokens.usdt0, Date.now()), 6)}`);
  console.log(`USDRIF     ${fmtUnits(usdrif, 18)}   settlement allowance ${fmtUnits(await allow(cfg.tokens.usdrif), 18)}   hourly left ${fmtUnits(budget.remaining(cfg.tokens.usdrif, Date.now()), 18)}`);
  console.log(`RIF        ${fmtUnits(rif, 18)}`);
  console.log(`buy side ${cfg.policy.buyUsdrif ? "on" : "off"} (max price ${fmtUnits(cfg.policy.maxBuyPrice, 18)}), sell side ${cfg.policy.sellUsdrif ? "on" : "off"} (min price ${fmtUnits(cfg.policy.minSellPrice, 18)})`);
}

async function run() {
  const budget = loadBudget();
  const persist = () => writeFileSync(cfg.stateFile, JSON.stringify({ spends: budget.toJSON() }, null, 1));
  const filler = new Filler(cfg, chain, budget, log, persist);
  const rebalancer = new Rebalancer(cfg, chain, log);

  // One pass over the whole book, serially: each fill changes our balances and budget.
  // The book is polled as JSON (`GET /orders`); every order is previewed on the lens
  // and simulated before anything is sent, so the book's word is only a candidate list.
  let sweeping = false;
  let lastCount = -1;
  const sweep = async () => {
    if (sweeping) return;
    sweeping = true;
    try {
      const { entries, skipped } = await fetchOrders(cfg.orderbookUrl);
      if (entries.length !== lastCount) {
        log(`book: ${entries.length} fillable order(s)${skipped ? `, ${skipped} skipped` : ""}`);
        lastCount = entries.length;
      }
      for (const e of entries) await filler.consider(e);
      await rebalancer.tick();
    } catch (e) {
      log(`sweep: ${e instanceof Error ? e.message.split("\n")[0] : e}`);
    } finally {
      sweeping = false;
    }
  };

  log(`rif-filler ${chain.me} ${cfg.dryRun ? "DRY RUN (set DRY_RUN=0 to broadcast)" : "LIVE"} — book ${cfg.orderbookUrl}`);
  await status();
  await sweep();
  setInterval(() => void sweep(), cfg.pollMs);
}

const [cmd = "run", arg] = process.argv.slice(2);
const rebalancer = () => new Rebalancer(cfg, chain, log);
switch (cmd) {
  case "run":
    await run();
    break;
  case "status":
    await status();
    break;
  case "redeem":
    await rebalancer().redeemIfNeeded(true);
    break;
  case "sell-rif":
    await rebalancer().sellRifIfNeeded(true);
    break;
  case "mint":
    if (!arg) throw new Error("usage: mint <USDRIF amount, e.g. 250>");
    await rebalancer().mint(parseFixed(arg, 18));
    break;
  default:
    throw new Error(`unknown command ${cmd} (run | status | redeem | sell-rif | mint <amount>)`);
}

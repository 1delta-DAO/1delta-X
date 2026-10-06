/**
 * App-shape e2e (LOCAL ONLY, not part of CI) — run by `staging.sh app-shape` against a
 * stack started with PRODUCTION gates (`GATES=production staging.sh up`).
 *
 * The one check that would have caught the 2026-10-05 TTL triangle (tasks/03): it signs
 * EXACTLY what the app's own code produces — `planTicket` (app/src/lib/plan.ts) →
 * `buildOrder` (app/src/lib/order.ts), with the deployment parsed by the app's
 * `parseDeployments` / `solverForMarket`, the funding from the app's `planFunding` /
 * `fundingCalls`, and the POST from the app's `postOrder` — and posts it through the
 * app's Pages worker to a book running the production `MIN_TTL_SECONDS`, while the
 * filler runs the production `EXPIRY_MARGIN_SECONDS` / `TICK_SECONDS`.
 *
 * Tickets (one fresh maker each):
 *   market-sell   rsk-30-wrbtc-usd0  SELL WRBTC, decaying output leg, direct (bit 104, exclusiveFiller = solver)
 *   market-buy    rsk-30-wrbtc-usd0  BUY  WRBTC, rising input leg,     direct
 *   market-usdrif rsk-30-usdrif-usd0 SELL USDRIF, decaying output leg, pull (exclusiveFiller = 0)
 *   limit         rsk-30-wrbtc-usd0  resting limit SELL (24 h, fixed)
 *   twap          rsk-30-wrbtc-usd0  TWAP slice 1 (fixed)
 *
 * Acceptance (exit 1 on any failure):
 *   - every ticket's POST /orders answers 202;
 *   - each market order is filled on-chain by the time its auction has reached the
 *     floor plus the filler's first re-quote (the auction hold cap + one tick + landing),
 *     and in every case before `expiry − EXPIRY_MARGIN_SECONDS`;
 *   - the direct market lands as `direct` (route strategy, tx to the solver), the USDRIF
 *     market as `pull` (exclusiveFiller 0; inventory EOA → Settlement, or route pull);
 *   - each maker received at least its floor.
 *
 * Perturbations (to prove the run fails on an inconsistent triangle): the book / filler
 * gates via `MIN_TTL_SECONDS` / `EXPIRY_MARGIN_SECONDS` on `staging.sh app-shape`, the
 * app's life via `APP_MARKET_TTL_SECONDS` (replaces the plan's `MARKET_TTL_SECONDS`).
 *
 * The ladder the app would quote from is reduced to one rung at the pool's on-chain mid
 * on each side (the Oku tick feed the app walks is not on the fork), passed through the
 * app's own `applyPoolFee` with the market's primary pool fee tier — the same step
 * `buildLadder` applies to every venue rung (task 15), so the quote and the
 * MARKET_SLIPPAGE_BPS floor are relative to the price the pool executes.
 *
 * For a direct fill the report decodes the sent `executeFill` plan: whether the route
 * patched the LIVE owed in (`amountOutOffset`, task 05) and the decay that kept on the
 * filler's side = the filler's previewed owed − what the maker got.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { AGGREGATOR_FILL_SOLVER_ABI, NO_PATCH, signOrder, unpackTiming, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, parseAbiItem, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { postOrder, OrderbookHttpError } from "../../app/src/backend/remote";
import { parseDeployments, solverForMarket, type DeploymentConfig } from "../../app/src/config/deploymentConfig";
import { assertPoolTokens, marketById, pinnedToken } from "../../app/src/config/markets";
import { fundingCalls, planFunding } from "../../app/src/lib/funding";
import { quote as appQuote } from "../../app/src/lib/ladder";
import { buildOrder } from "../../app/src/lib/order";
import { MARKET_DECAY_SECONDS, MARKET_SLIPPAGE_BPS, MARKET_TTL_SECONDS, planTicket, requiredInputWei, sliceCap, type TicketPlan } from "../../app/src/lib/plan";
import type { Level, Side } from "../../app/src/lib/types";
import { applyPoolFee, priceFromSqrt } from "../../app/src/lib/univ3";
import { AUCTION_RECHECK_MS } from "../../beta-filler/src/config";
import { admin, balanceOf, deal, loadEnv, nowS, publicClient, setBalance, sleep, testKey, walletClient, writeResult } from "./lib";

const env = loadEnv();
const pub = publicClient(env);
const HERE = new URL(".", import.meta.url).pathname;
const PACKAGES = join(HERE, "..", "..");

const log = (m: string) => console.log(`[app-shape ${new Date().toISOString().slice(11, 19)}] ${m}`);
const failures: string[] = [];
const fail = (m: string) => {
  failures.push(m);
  log(`FAIL ${m}`);
};

// ──────────────────── the three constants ────────────────────

/** A `KEY = "value"` line of a committed wrangler.toml — the PRODUCTION value. */
function tomlVar(file: string, key: string): number {
  const m = new RegExp(`^${key}\\s*=\\s*"([^"]*)"`, "m").exec(readFileSync(file, "utf8"));
  if (!m) throw new Error(`${key} not found in ${file}`);
  return Number(m[1]);
}
const OB_TOML = join(PACKAGES, "orderbook-worker", "wrangler.toml");
const FILLER_TOML = join(PACKAGES, "filler-worker", "wrangler.toml");
const prod = {
  minTtl: tomlVar(OB_TOML, "MIN_TTL_SECONDS"),
  margin: tomlVar(FILLER_TOML, "EXPIRY_MARGIN_SECONDS"),
  tick: tomlVar(FILLER_TOML, "TICK_SECONDS"),
  appTtl: MARKET_TTL_SECONDS,
};
// What the stack actually runs: the generated .dev.vars (recorded in env.json) override
// the committed file; anything not overridden is the committed (production) value.
const ov = (w: "orderbook" | "filler", k: string) => env.workerVars[w]?.[k];
const eff = {
  minTtl: Number(ov("orderbook", "MIN_TTL_SECONDS") ?? prod.minTtl),
  margin: Number(ov("filler", "EXPIRY_MARGIN_SECONDS") ?? prod.margin),
  tick: Number(ov("filler", "TICK_SECONDS") ?? prod.tick),
  appTtl: process.env.APP_MARKET_TTL_SECONDS ? Number(process.env.APP_MARKET_TTL_SECONDS) : MARKET_TTL_SECONDS,
};
/**
 * The market floor. Default: the app's MARKET_SLIPPAGE_BPS. `MARKET_SLIPPAGE_BPS=<bps>`
 * widens it — an ECONOMICS override, not a timing one: on the 0.3 % WRBTC/USD0 pool the
 * app's 50 bps floor sits below pool fee + the filler's ROUTE_SLIPPAGE_BPS haircut + gas,
 * so the production filler never finds the order profitable (see tasks/done/03).
 */
const slippageBps = process.env.MARKET_SLIPPAGE_BPS ? Number(process.env.MARKET_SLIPPAGE_BPS) : MARKET_SLIPPAGE_BPS;
const perturbed = (Object.keys(prod) as Array<keyof typeof prod>).filter((k) => prod[k] !== eff[k]);

// ──────────────────── the app's view ────────────────────

/** The production VITE_DEPLOYMENTS shape: the gated solver deployment-wide, USDRIF on pull. */
const deployment: DeploymentConfig = parseDeployments(
  JSON.stringify({
    30: { settlement: env.settlement, permit3: env.permit3, lens: env.lens, solver: env.solver, marketSolvers: { "rsk-30-usdrif-usd0": "pull" } },
  }),
)[30]!;
if (!deployment) throw new Error("parseDeployments dropped the staging deployment");

const POOL_ABI = [
  { type: "function", name: "slot0", stateMutability: "view", inputs: [], outputs: [{ type: "uint160" }, { type: "int24" }, { type: "uint16" }, { type: "uint16" }, { type: "uint16" }, { type: "uint8" }, { type: "bool" }] },
  { type: "function", name: "token0", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "token1", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

/** Mid of a market's primary pool, quote per base, as the app's ladder prices it. */
async function midOf(marketId: string): Promise<number> {
  const m = marketById(marketId);
  const pool = m.pools[0]!.address;
  const [slot0, t0, t1] = await Promise.all([
    pub.readContract({ address: pool, abi: POOL_ABI, functionName: "slot0" }),
    pub.readContract({ address: pool, abi: POOL_ABI, functionName: "token0" }),
    pub.readContract({ address: pool, abi: POOL_ABI, functionName: "token1" }),
  ]);
  const { baseIsToken0 } = assertPoolTokens(m, pool, t0, t1);
  const base = pinnedToken(30, m.base)!;
  const quoteT = pinnedToken(30, m.quote)!;
  const p0in1 = priceFromSqrt(slot0[0], baseIsToken0 ? base.decimals : quoteT.decimals, baseIsToken0 ? quoteT.decimals : base.decimals);
  return baseIsToken0 ? p0in1 : 1 / p0in1;
}

interface Ticket {
  id: string;
  marketId: string;
  mode: "market" | "limit" | "twap";
  side: Side;
  /** PAY-token amount the ticket is worth (app units). */
  amount: number;
  /** Limit price as a multiple of mid (limit ticket only). */
  limitX?: number;
  slices?: number;
  everyMin?: number;
}

const TICKETS: Ticket[] = [
  { id: "market-sell", marketId: "rsk-30-wrbtc-usd0", mode: "market", side: "sell", amount: Number(process.env.SELL_WRBTC ?? "0.01") },
  { id: "market-buy", marketId: "rsk-30-wrbtc-usd0", mode: "market", side: "buy", amount: Number(process.env.BUY_USDT0 ?? "800") },
  { id: "market-usdrif", marketId: "rsk-30-usdrif-usd0", mode: "market", side: "sell", amount: Number(process.env.SELL_USDRIF ?? "300") },
  { id: "limit", marketId: "rsk-30-wrbtc-usd0", mode: "limit", side: "sell", amount: 0.005, limitX: 1.25 },
  { id: "twap", marketId: "rsk-30-wrbtc-usd0", mode: "twap", side: "sell", amount: 0.008, slices: 4, everyMin: 5 },
];

interface Posted {
  t: Ticket;
  maker: PrivateKeyAccount;
  plan: TicketPlan;
  order: Order;
  hash: Hex;
  pay: Address;
  recv: Address;
  status: number;
  error?: string;
  recvBefore: bigint;
  payBefore: bigint;
  postedAt: number;
}

const tokenOf = (sym: string) => pinnedToken(30, sym)!;

async function prepareAndPost(t: Ticket, i: number): Promise<Posted> {
  const market = marketById(t.marketId);
  const mid = await midOf(t.marketId);
  // One rung at mid each side, sized far beyond the ticket (it crosses in full), priced
  // net of the primary pool's fee by the app's own applyPoolFee (task 15).
  const feeTier = market.pools[0]!.feeBps;
  const lad = applyPoolFee({ bids: [{ price: mid, size: 1e12 }], asks: [{ price: mid, size: 1e12 }], mid }, feeTier);
  const tag = (r: { price: number; size: number }): Level => ({ ...r, source: "UNI", pool: market.pools[0]!.address, feeBps: feeTier });
  const limit = t.limitX ? mid * t.limitX : null;
  const q = appQuote({ bids: lad.bids.map(tag), asks: lad.asks.map(tag), side: t.side, amountIn: t.amount, limit: t.mode === "market" ? null : limit, slippageBps });
  let plan = planTicket({ q, mid, mode: t.mode, side: t.side, amount: t.amount, limit: t.mode === "market" ? null : limit, slices: t.slices ?? 1, everyMin: t.everyMin ?? 1 });
  if (!plan) throw new Error(`${t.id}: planTicket returned null`);
  if (plan.kind === "market" && eff.appTtl !== plan.ttlSeconds) plan = { ...plan, ttlSeconds: eff.appTtl, fundingTtlSeconds: eff.appTtl }; // APP_MARKET_TTL_SECONDS perturbation

  // App.tsx#signDraft: pay/recv from the pinned config, solver from the deployment.
  const paySym = t.side === "sell" ? market.base : market.quote;
  const recvSym = t.side === "sell" ? market.quote : market.base;
  const pay = tokenOf(paySym);
  const recv = tokenOf(recvSym);
  const maker = privateKeyToAccount(testKey(`${env.label}:app-shape`, i));

  // Balance: the ticket's exact input (as the app sees it), dealt by storage write.
  const need = requiredInputWei(plan, pay.decimals, undefined);
  await setBalance(pub, maker.address, 10n ** 17n);
  await deal(pub, pay.address as Address, maker.address, need);
  const raw = await balanceOf(pub, pay.address as Address, maker.address);

  // Funding exactly as the app plans it (ERC-20 approve to Permit3 + the Permit3 book grant
  // to Settlement), from a fresh maker's zero state.
  const required = requiredInputWei(plan, pay.decimals, raw);
  const fp = planFunding({ erc20Allowance: 0n, grantAmount: 0n, grantExpiration: 0 }, required, plan.fundingTtlSeconds, nowS());
  const w = walletClient(env, maker);
  for (const c of fundingCalls(fp.steps, { token: pay.address as Address, permit3: deployment.permit3, settlement: deployment.settlement })) {
    const h = await w.sendTransaction({ to: c.to, data: c.data, gas: 150_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" });
    const rc = await pub.waitForTransactionReceipt({ hash: h, pollingInterval: 500, timeout: 120_000 });
    if (rc.status !== "success") throw new Error(`${t.id}: funding tx ${h} reverted`);
  }

  const draft = buildOrder({
    maker: maker.address,
    side: t.side,
    pay: pay as { address: Address; decimals: number },
    recv: recv as { address: Address; decimals: number },
    solver: solverForMarket(deployment, t.marketId),
    amountIn: plan.amountIn,
    targetOut: plan.targetOut,
    minOut: plan.minOut,
    ttlSeconds: plan.ttlSeconds,
    decaySeconds: plan.decaySeconds,
    maxIn: sliceCap(raw, plan.orders, 0),
    minValidNonce: 0n,
  });
  const sig = await signOrder(maker, draft.order, { chainId: 30, settlement: deployment.settlement, permit3: deployment.permit3 });

  const [recvBefore, payBefore] = await Promise.all([balanceOf(pub, recv.address as Address, maker.address), balanceOf(pub, pay.address as Address, maker.address)]);
  let status = 0;
  let error: string | undefined;
  // The app's own client, through the app's Pages worker (`/api/book`), as its own visitor IP.
  const ip = `10.77.0.${i + 1}`;
  const doFetch = async (url: string, init?: RequestInit) => {
    const r = await fetch(url, { ...init, headers: { ...(init?.headers as Record<string, string>), "x-sim-ip": ip } });
    status = r.status;
    return r;
  };
  const postedAt = nowS();
  try {
    await postOrder(doFetch, `${env.gatewayUrl}/api/book`, { order: draft.order, sig, hash: draft.hash });
  } catch (e) {
    error = e instanceof OrderbookHttpError ? `${e.status} ${e.reason}` : (e as Error).message;
  }
  return { t, maker, plan, order: draft.order, hash: draft.hash.toLowerCase() as Hex, pay: pay.address as Address, recv: recv.address as Address, status, error, recvBefore, payBefore, postedAt };
}

// ──────────────────── the run ────────────────────

const ORDER_FILLED = parseAbiItem("event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed solver)");
const startOf = (o: Order) => unpackTiming(o.timing).decayStartTime;

async function main(): Promise<void> {
  const block = await pub.getBlockNumber();
  log(`stack ${env.runDir} (fork block ${env.forkBlock}, ${env.blockTimeS} s blocks), Settlement ${env.settlement}, solver ${env.solver}`);
  log(`triangle  app MARKET_TTL_SECONDS ${eff.appTtl}  book MIN_TTL_SECONDS ${eff.minTtl}  filler EXPIRY_MARGIN_SECONDS ${eff.margin}  TICK_SECONDS ${eff.tick}  (auction ${MARKET_DECAY_SECONDS} s, slippage ${slippageBps} bps${slippageBps !== MARKET_SLIPPAGE_BPS ? ` — ECONOMICS OVERRIDE, app ${MARKET_SLIPPAGE_BPS}` : ""})`);
  log(`production app ${prod.appTtl} / book ${prod.minTtl} / filler ${prod.margin} / tick ${prod.tick} — ${perturbed.length ? `PERTURBED: ${perturbed.map((k) => `${k} ${prod[k]}→${eff[k]}`).join(", ")}` : "running the production values"}`);

  const posted: Posted[] = [];
  for (const [i, t] of TICKETS.entries()) {
    const p = await prepareAndPost(t, i);
    posted.push(p);
    const o = p.order;
    const direct = ((o.timing >> 104n) & 1n) === 1n;
    log(
      `${t.id.padEnd(13)} POST /orders → ${p.status}${p.error ? ` (${p.error})` : ""}  ${p.hash.slice(0, 12)}  ttl ${p.plan.ttlSeconds}s decay ${p.plan.decaySeconds}s  ` +
        `in ${o.legsIn[0]!.start}${o.legsIn[0]!.end ? `→${o.legsIn[0]!.end}` : ""}  out ${o.legsOut[0]!.start}${o.legsOut[0]!.end ? `→${o.legsOut[0]!.end}` : ""}  ` +
        `bit104 ${direct ? 1 : 0}  exclusiveFiller ${o.exclusiveFiller === zeroAddress ? "0" : o.exclusiveFiller.slice(0, 10)}`,
    );
    if (p.status !== 202) fail(`${t.id}: book answered ${p.status} (${p.error ?? "?"}), want 202`);
  }

  // Shape checks: the app's code must produce the shapes tasks/03 names.
  const by = Object.fromEntries(posted.map((p) => [p.t.id, p]));
  const shape = (id: string, ok: boolean, what: string) => (ok ? undefined : fail(`${id}: shape — ${what}`));
  const ms = by["market-sell"]!.order, mb = by["market-buy"]!.order, mu = by["market-usdrif"]!.order;
  shape("market-sell", ms.legsOut[0]!.end !== 0n && ms.legsOut[0]!.end < ms.legsOut[0]!.start, "decaying output leg");
  shape("market-sell", ((ms.timing >> 104n) & 1n) === 1n && ms.exclusiveFiller.toLowerCase() === env.solver.toLowerCase(), "bit 104 + exclusiveFiller = solver");
  shape("market-buy", mb.legsIn[0]!.end > mb.legsIn[0]!.start, "rising input leg");
  shape("market-usdrif", ((mu.timing >> 104n) & 1n) === 0n && mu.exclusiveFiller === zeroAddress, "pull, exclusiveFiller = 0");

  // Wait for the market orders.
  const markets = posted.filter((p) => p.t.mode === "market" && p.status === 202);
  const hold = AUCTION_RECHECK_MS / 1000;
  const landing = 2 * env.blockTimeS + 5;
  const plan = markets.map((p) => {
    const start = startOf(p.order);
    const floorAt = start + p.plan.decaySeconds;
    const expiry = Number(p.order.expiry);
    return { p, start, floorAt, expiry, quoteBy: floorAt + hold + eff.tick + landing, lastSend: expiry - eff.margin };
  });
  const until = Math.max(0, ...plan.map((x) => x.expiry)) + 10;
  const fills = new Map<string, { tx: Hex; block: bigint; at: number; solver: Address }>();
  if (markets.length) log(`waiting for ${markets.length} market fill(s) (floor +${MARKET_DECAY_SECONDS} s, first re-quote ≤ floor + hold ${hold} s + tick ${eff.tick} s + landing ${landing} s; give up at expiry ${until - nowS()} s from now)`);
  while (nowS() < until && fills.size < markets.length) {
    const logs = await pub.getLogs({ address: env.settlement, event: ORDER_FILLED, fromBlock: block, toBlock: "latest" });
    for (const l of logs) {
      const h = (l.args.orderHash as Hex).toLowerCase();
      if (fills.has(h) || !markets.some((m) => m.hash === h)) continue;
      const b = await pub.getBlock({ blockNumber: l.blockNumber! });
      fills.set(h, { tx: l.transactionHash!, block: l.blockNumber!, at: Number(b.timestamp), solver: l.args.solver as Address });
      const m = markets.find((x) => x.hash === h)!;
      log(`${m.t.id} filled in block ${l.blockNumber} at t+${Number(b.timestamp) - startOf(m.order)} s (tx ${l.transactionHash})`);
    }
    await sleep(2000);
  }

  const rows = ((await admin(env).get<{ fills?: Array<Record<string, unknown>> }>("/fills?limit=200")).body.fills ?? []) as Array<Record<string, unknown>>;
  const wlog = (() => {
    try {
      return readFileSync(join(env.runDir, "wrangler.log"), "utf8").split("\n");
    } catch {
      return [];
    }
  })();
  const summary: Array<Record<string, unknown>> = [];
  for (const x of plan) {
    const { p } = x;
    const f = fills.get(p.hash);
    const row = rows.find((r) => String(r.order_hash ?? "").toLowerCase() === p.hash && r.kind === "fill");
    const isDirectOrder = ((p.order.timing >> 104n) & 1n) === 1n;
    const rec: Record<string, unknown> = { id: p.t.id, hash: p.hash, start: x.start, floorAt: x.floorAt, expiry: x.expiry, quoteBy: x.quoteBy, lastSend: x.lastSend };
    if (!f) {
      fail(`${p.t.id}: not filled by expiry (floor at t+${p.plan.decaySeconds} s, filler margin ${eff.margin} s ⇒ last send at t+${x.lastSend - x.start} s)`);
      const lines = wlog.filter((l) => l.includes(p.hash.slice(2, 12)) || l.includes(p.hash.slice(0, 12))).slice(-4);
      for (const l of lines) log(`   filler: ${l.slice(0, 400)}`);
      summary.push({ ...rec, filled: false, fillerLog: lines });
      continue;
    }
    const tx = await pub.getTransaction({ hash: f.tx });
    const note = String(row?.note ?? "");
    const strategy = String(row?.strategy ?? "?");
    const delivery = strategy === "inventory" ? "pull" : note.startsWith("direct") ? "direct" : note.startsWith("pull") ? "pull" : "?";
    const [recvAfter, payAfter] = await Promise.all([balanceOf(pub, p.recv, p.maker.address), balanceOf(pub, p.pay, p.maker.address)]);
    const got = recvAfter - p.recvBefore;
    const paid = p.payBefore - payAfter;
    const floorOut = p.order.legsOut[0]!.end !== 0n ? p.order.legsOut[0]!.end : p.order.legsOut[0]!.start;
    const ceilIn = p.order.legsIn[0]!.end !== 0n ? p.order.legsIn[0]!.end : p.order.legsIn[0]!.start;
    Object.assign(rec, { filled: true, tx: f.tx, at: f.at, sinceStart: f.at - x.start, sinceFloor: f.at - x.floorAt, to: tx.to, strategy, delivery, note: note.slice(0, 160), got, floorOut, paid, ceilIn });
    // Task 05: did the direct route patch the live owed in, and how much decay did that keep?
    let live = "";
    if (isDirectOrder && tx.to?.toLowerCase() === env.solver.toLowerCase()) {
      try {
        const d = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: tx.input });
        const off = (d.args[3] as { amountOutOffset: bigint }).amountOutOffset;
        const previewOwed = /owed (\d+)/.exec(note)?.[1];
        const decayKept = previewOwed && p.t.side === "sell" ? BigInt(previewOwed) - got : undefined;
        Object.assign(rec, { amountOutOffset: off === NO_PATCH ? "NO_PATCH" : off, previewOwed, decayKept });
        live = `; amountOutOffset ${off === NO_PATCH ? "NO_PATCH" : off}${previewOwed ? `, previewed owed ${previewOwed}` : ""}${decayKept !== undefined ? `, decay kept by the filler ${decayKept}` : ""}`;
      } catch (e) {
        live = `; (could not decode the plan: ${(e as Error).message.split("\n")[0]})`;
      }
    }
    summary.push(rec);
    log(`${p.t.id}: filled t+${f.at - x.start} s (${f.at - x.floorAt >= 0 ? `${f.at - x.floorAt} s after` : `${x.floorAt - f.at} s before`} the floor), ${delivery} via ${strategy} → ${tx.to}; maker got ${got} (floor ${floorOut}), paid ${paid} (cap ${ceilIn})${live}`);
    if (f.at > x.quoteBy) fail(`${p.t.id}: filled ${f.at - x.floorAt} s after the floor, past the first re-quote bound (${x.quoteBy - x.floorAt} s)`);
    if (f.at > x.lastSend + landing) fail(`${p.t.id}: filled after expiry − EXPIRY_MARGIN_SECONDS`);
    if (got < floorOut) fail(`${p.t.id}: maker got ${got} < floor ${floorOut}`);
    if (paid > ceilIn) fail(`${p.t.id}: maker paid ${paid} > cap ${ceilIn}`);
    if (isDirectOrder) {
      if (delivery !== "direct" || tx.to?.toLowerCase() !== env.solver.toLowerCase()) fail(`${p.t.id}: direct order landed as ${delivery} via ${tx.to}`);
    } else if (delivery !== "pull") fail(`${p.t.id}: pull order landed as ${delivery}`);
  }

  const result = { prod, eff, perturbed, slippageBps, appSlippageBps: MARKET_SLIPPAGE_BPS, posted: posted.map((p) => ({ id: p.t.id, status: p.status, error: p.error, hash: p.hash, ttl: p.plan.ttlSeconds, decay: p.plan.decaySeconds })), markets: summary, failures };
  log(`results → ${writeResult("app-shape", result)}`);
  if (failures.length) {
    log(`FAILED (${failures.length}):`);
    for (const f of failures) log(`  - ${f}`);
    process.exit(1);
  }
  log(`PASSED: ${posted.length} tickets booked (202), ${fills.size} market fills inside the window`);
}

await main();

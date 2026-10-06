/**
 * Staging-harness LOAD TEST (LOCAL ONLY, not part of CI) — run by `staging.sh load`
 * against a stack started by `staging.sh up`.
 *
 * ~MAKERS makers post ~ORDERS orders over WINDOW_S seconds through the app's Pages
 * worker (each maker its own visitor IP), while READERS read clients poll the book,
 * one abusive client hammers POST /orders, and the admin API pauses and resumes the
 * filler mid-run. Then it drains, verifies everything against the chain, and writes
 * $RUN_DIR/results/load.json (+ load-records.json).
 *
 * Order mix (fractions of ORDERS; duplicates and bad posts come on top):
 *   inv        profitable USDRIF→USDT0 pull            → filled (inventory)
 *   routePull  profitable WRBTC→USDT0 pull             → filled (route)
 *   direct     WRBTC→USDT0 delta-verify naming solver  → filled (route, direct)
 *   unprof     overpriced / dust (3 shapes)            → never filled
 *   short      TTL 16–25 s, half profitable            → filled before expiry or expired, never after
 *   cancel     soft / on-chain cancelled, live + during the admin pause → never filled (live: race reported)
 *   dup        re-posts                                → 202 duplicate (live) / 422 (dead)
 *   bad        malformed / bad sig / unfunded / …      → 400 / 413 / 415 / 422
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { AGGREGATOR_FILL_SOLVER_ABI, SETTLEMENT_ABI, encodeCancelOrder, orderFromJson, orderToJson, type Order } from "@1delta-x/sdk";
import { decodeErrorResult, decodeEventLog, encodeFunctionData, erc20Abi, maxUint256, parseAbiItem, parseUnits, type Address, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import {
  PERMIT3_ABI,
  USDRIF,
  USDT0,
  WETH,
  WRBTC,
  admin,
  balanceOf,
  book,
  buildOrder,
  deal,
  dist,
  explorer,
  json,
  loadEnv,
  nowS,
  proxy,
  publicClient,
  quote,
  readTimeline,
  segmentTicks,
  setBalance,
  TraceCollector,
  signedSoftCancel,
  sleep,
  testKey,
  walletClient,
  writeResult,
  type ProxyTx,
  type StagingEnv,
  type Timed,
} from "./lib";

// ──────────────────── profile ────────────────────

const int = (k: string, d: number) => (process.env[k] ? Number(process.env[k]) : d);
const P = {
  makers: int("MAKERS", 20),
  orders: int("ORDERS", 200),
  windowS: int("WINDOW_S", 360),
  readers: int("READERS", 20),
  readerMinMs: int("READER_MIN_MS", 1000),
  readerMaxMs: int("READER_MAX_MS", 2000),
  abuseFromS: int("ABUSE_FROM_S", 30),
  abuseToS: int("ABUSE_TO_S", 120),
  abuseConcurrency: int("ABUSE_CONCURRENCY", 4),
  pauseAtS: int("PAUSE_AT_S", 150),
  resumeAtS: int("RESUME_AT_S", 200),
  drainS: int("DRAIN_S", 600),
  cronEveryS: int("CRON_EVERY_S", 60),
  /** Wait after the drain before verifying (book indexing: CONFIRMATIONS + one alarm). */
  settleS: int("SETTLE_S", 30),
  statusEveryS: int("STATUS_EVERY_S", 5),
  seed: int("SEED", 7),
  label: process.env.LOAD_LABEL ?? "load",
};
const MIX = { inv: 0.25, routePull: 0.2, direct: 0.15, unprof: 0.15, short: 0.1, cancel: 0.15 };

// Seeded RNG for the plan (amounts, prices, timing): runs are comparable.
let rngState = P.seed >>> 0;
function rnd(): number {
  rngState = (rngState + 0x6d2b79f5) >>> 0;
  let t = rngState;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const uni = (a: number, b: number) => a + (b - a) * rnd();
const pick = <T>(xs: readonly T[]): T => xs[Math.floor(rnd() * xs.length)]!;

// ──────────────────── types ────────────────────

type Kind =
  | "inv"
  | "routePull"
  | "direct"
  | "unprof-usdrif-over"
  | "unprof-usdrif-dust"
  | "unprof-wrbtc-over"
  | "short-prof"
  | "short-unprof"
  | "cancel-soft"
  | "cancel-chain"
  | "cancel-paused-soft"
  | "cancel-paused-chain";

type Expect = "fill" | "never" | "maybe";
const EXPECT: Record<Kind, Expect> = {
  inv: "fill",
  routePull: "fill",
  direct: "fill",
  "unprof-usdrif-over": "never",
  "unprof-usdrif-dust": "never",
  "unprof-wrbtc-over": "never",
  "short-prof": "maybe",
  "short-unprof": "never",
  "cancel-soft": "never",
  "cancel-chain": "never",
  "cancel-paused-soft": "never",
  "cancel-paused-chain": "never",
};

interface Planned {
  id: number;
  kind: Kind;
  maker: number;
  atS: number;
  tokenIn: Address;
  amountIn: bigint;
  /** USDRIF price (USDT0 per USDRIF) or the % of the live WRBTC quote. */
  price: number;
  ttlS: number;
  direct: boolean;
  /** Seconds after the 202 to cancel. */
  cancelAfterS?: number;
}

interface Posted {
  id: number;
  kind: Kind;
  expect: Expect;
  maker: Address;
  makerIdx: number;
  hash: Hex;
  order: Order;
  body: string;
  owed: bigint;
  amountIn: bigint;
  tokenIn: Address;
  quoteOut?: bigint;
  postAt: number;
  status: number;
  ms: number;
  error?: string;
  cancelAt?: number;
  cancelStatus?: number;
  cancelTx?: Hex;
  cancelMinedBlock?: number;
}

interface HttpRec {
  who: string;
  ep: string;
  status: number;
  ms: number;
  at: number;
  err?: string;
}

// ──────────────────── setup ────────────────────

const env: StagingEnv = loadEnv();
const pub: PublicClient = publicClient(env);
const ex = explorer(env);
const adm = admin(env);
const px = proxy(env);
const log = (m: string) => console.log(`[load ${new Date().toISOString().slice(11, 19)}] ${m}`);

const makers: PrivateKeyAccount[] = Array.from({ length: P.makers }, (_, i) => privateKeyToAccount(testKey(`${env.label}:maker`, i)));
/** The last two makers are never funded (the "unfunded" bad posts). */
const funded = makers.slice(0, Math.max(1, P.makers - 2));
const unfunded = makers.slice(funded.length);
const makerIp = (i: number) => `10.1.${Math.floor(i / 250)}.${(i % 250) + 1}`;

function plan(): Planned[] {
  const n = P.orders;
  const counts: Array<[string, number]> = Object.entries(MIX).map(([k, f]) => [k, Math.round(n * f)]);
  const out: Planned[] = [];
  let id = 0;
  const add = (kind: Kind, p: Omit<Planned, "id" | "kind" | "maker" | "atS"> & { atS?: number }) =>
    out.push({ id: id++, kind, maker: Math.floor(rnd() * funded.length), atS: p.atS ?? uni(0, P.windowS), ...p });
  const usdrif = (lo: number, hi: number) => parseUnits(String(Math.round(uni(lo, hi))), 18);
  const wrbtc = (lo: number, hi: number) => BigInt(Math.round(uni(lo, hi) * 1e6)) * 10n ** 12n;
  for (const [cat, c] of counts) {
    for (let i = 0; i < c; i++) {
      switch (cat) {
        case "inv":
          add("inv", { tokenIn: USDRIF, amountIn: usdrif(80, 300), price: uni(0.95, 0.975), ttlS: 3600, direct: false });
          break;
        case "routePull":
          add("routePull", { tokenIn: WRBTC, amountIn: wrbtc(0.001, 0.003), price: uni(0.94, 0.97), ttlS: 3600, direct: false });
          break;
        case "direct":
          add("direct", { tokenIn: WRBTC, amountIn: wrbtc(0.001, 0.003), price: uni(0.94, 0.97), ttlS: 3600, direct: true });
          break;
        case "unprof": {
          const s = i % 3;
          if (s === 0) add("unprof-usdrif-over", { tokenIn: USDRIF, amountIn: usdrif(50, 200), price: uni(0.999, 1.01), ttlS: 3600, direct: false });
          else if (s === 1) add("unprof-usdrif-dust", { tokenIn: USDRIF, amountIn: usdrif(7, 9), price: 0.99, ttlS: 3600, direct: false });
          else add("unprof-wrbtc-over", { tokenIn: WRBTC, amountIn: wrbtc(0.001, 0.003), price: uni(1.003, 1.02), ttlS: 3600, direct: false });
          break;
        }
        case "short":
          if (i % 2 === 0) add("short-prof", { tokenIn: WRBTC, amountIn: wrbtc(0.001, 0.002), price: uni(0.94, 0.96), ttlS: Math.round(uni(16, 25)), direct: false });
          else add("short-unprof", { tokenIn: USDRIF, amountIn: usdrif(50, 150), price: uni(1.0, 1.01), ttlS: Math.round(uni(16, 25)), direct: false });
          break;
        case "cancel": {
          // Half live (racing the filler: outcome reported), half inside the admin pause (deterministic).
          const paused = i % 2 === 1;
          const soft = i % 4 < 2;
          const inv = rnd() < 0.5;
          const kind: Kind = paused ? (soft ? "cancel-paused-soft" : "cancel-paused-chain") : soft ? "cancel-soft" : "cancel-chain";
          add(kind, {
            tokenIn: inv ? USDRIF : WRBTC,
            amountIn: inv ? usdrif(80, 200) : wrbtc(0.001, 0.002),
            price: inv ? uni(0.95, 0.97) : uni(0.94, 0.96),
            ttlS: 3600,
            direct: false,
            cancelAfterS: soft ? uni(0.2, 2) : uni(0.3, 1.5),
            ...(paused ? { atS: uni(P.pauseAtS + 3, P.pauseAtS + Math.max(4, (P.resumeAtS - P.pauseAtS) * 0.4)) } : {}),
          });
          break;
        }
      }
    }
  }
  return out.sort((a, b) => a.atS - b.atS);
}

async function fundMakers(planned: Planned[]): Promise<void> {
  const need = new Map<number, { usdrif: bigint; wrbtc: bigint }>();
  for (const p of planned) {
    const n = need.get(p.maker) ?? { usdrif: 0n, wrbtc: 0n };
    if (p.tokenIn === USDRIF) n.usdrif += p.amountIn;
    else n.wrbtc += p.amountIn;
    need.set(p.maker, n);
  }
  const t0 = Date.now();
  const hashes: Hex[] = [];
  for (let i = 0; i < funded.length; i++) {
    const m = funded[i]!;
    const n = need.get(i) ?? { usdrif: 0n, wrbtc: 0n };
    await setBalance(pub, m.address, 2n * 10n ** 18n);
    // Balances by storage write (instant), 10% headroom over everything this maker posts.
    await deal(pub, USDRIF, m.address, (n.usdrif * 11n) / 10n + 10n ** 18n);
    await deal(pub, WRBTC, m.address, (n.wrbtc * 11n) / 10n + 10n ** 15n);
    const w = walletClient(env, m);
    let nonce = await pub.getTransactionCount({ address: m.address, blockTag: "pending" });
    const txs: Array<{ to: Address; data: Hex }> = [
      { to: USDRIF, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [env.permit3, maxUint256] }) },
      { to: WRBTC, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [env.permit3, maxUint256] }) },
      { to: env.permit3, data: encodeFunctionData({ abi: PERMIT3_ABI, functionName: "approveToken", args: [env.settlement, USDRIF, (1n << 160n) - 1n, 0] }) },
      { to: env.permit3, data: encodeFunctionData({ abi: PERMIT3_ABI, functionName: "approveToken", args: [env.settlement, WRBTC, (1n << 160n) - 1n, 0] }) },
    ];
    for (const t of txs) hashes.push(await w.sendTransaction({ ...t, nonce: nonce++, gas: 120_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" }));
  }
  for (const u of unfunded) await setBalance(pub, u.address, 10n ** 17n);
  for (const h of hashes) {
    const r = await pub.waitForTransactionReceipt({ hash: h, pollingInterval: 500, timeout: 120_000 });
    if (r.status !== "success") throw new Error(`maker funding tx ${h} reverted`);
  }
  log(`funded ${funded.length} makers (${hashes.length} approval txs) in ${((Date.now() - t0) / 1000).toFixed(1)} s; ${unfunded.length} left unfunded`);
}

// ──────────────────── chain watch ────────────────────

interface ChainFill {
  orderHash: Hex;
  maker: Address;
  solver: Address;
  txHash: Hex;
  blockNumber: number;
  logIndex: number;
  blockTime: number;
}

const ORDER_FILLED = parseAbiItem("event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed solver)");
const CANCELLED_BY_HASH = parseAbiItem("event OrderCancelledByHash(address indexed maker, bytes32 indexed orderHash)");
const blockTimes = new Map<number, number>();
async function blockTime(n: number): Promise<number> {
  let t = blockTimes.get(n);
  if (t === undefined) {
    t = Number((await pub.getBlock({ blockNumber: BigInt(n) })).timestamp);
    blockTimes.set(n, t);
  }
  return t;
}

async function chainFills(from: number, to: number): Promise<ChainFill[]> {
  const logs = await pub.getLogs({ address: env.settlement, event: ORDER_FILLED, fromBlock: BigInt(from), toBlock: BigInt(to) });
  const out: ChainFill[] = [];
  for (const l of logs) {
    out.push({
      orderHash: (l.args.orderHash as Hex).toLowerCase() as Hex,
      maker: l.args.maker as Address,
      solver: l.args.solver as Address,
      txHash: l.transactionHash as Hex,
      blockNumber: Number(l.blockNumber),
      logIndex: Number(l.logIndex),
      blockTime: await blockTime(Number(l.blockNumber)),
    });
  }
  return out;
}

// ──────────────────── the run ────────────────────

async function main(): Promise<void> {
  log(`profile ${json(P)}`);
  const planned = plan();
  await fundMakers(planned);

  await px.reset();
  const proxyTxsBefore = (await px.txs()).length;
  const startBlock = Number(await pub.getBlockNumber());
  const operatorStart = {
    rbtc: await pub.getBalance({ address: env.operator }),
    usdt0: await balanceOf(pub, USDT0, env.operator),
    usdrif: await balanceOf(pub, USDRIF, env.operator),
  };
  const treasuryStart = { usdt0: await balanceOf(pub, USDT0, env.treasury), wrbtc: await balanceOf(pub, WRBTC, env.treasury), usdrif: await balanceOf(pub, USDRIF, env.treasury) };
  const head = await pub.getBlock();
  const clockSkewS = Number(head.timestamp) - nowS();
  log(`start block ${startBlock}; anvil clock skew ${clockSkewS} s`);

  const posted: Posted[] = [];
  const http: HttpRec[] = [];
  const statusSamples: Array<{ at: number; body: Record<string, unknown> }> = [];
  const events: Array<{ at: number; what: string }> = [];
  const t0 = Date.now();
  const at = (s: number) => t0 + s * 1000;
  let stop = false;
  const paused = { from: 0, to: 0 };

  // Watch fills as they land (for latency; the final verification re-reads everything).
  const seenFill = new Map<string, number>();
  let watchBlock = startBlock;
  const watcher = (async () => {
    while (!stop) {
      try {
        const head = Number(await pub.getBlockNumber());
        if (head > watchBlock) {
          for (const f of await chainFills(watchBlock + 1, head)) if (!seenFill.has(f.orderHash)) seenFill.set(f.orderHash, Date.now());
          watchBlock = head;
        }
      } catch {
        // transient
      }
      await sleep(1000);
    }
  })();

  // Admin poller: /status samples (each costs the filler 6 RPC reads — subtracted later).
  let statusCalls = 0;
  const poller = (async () => {
    while (!stop) {
      const r = await adm.get<Record<string, unknown>>("/status");
      statusCalls++;
      statusSamples.push({ at: Date.now(), body: r.body });
      http.push({ who: "admin", ep: "GET /status", status: r.status, ms: r.ms, at: r.at });
      await sleep(P.statusEveryS * 1000);
    }
  })();

  // Cloudflare fires both workers' `* * * * *` cron every minute; wrangler dev does not,
  // so dispatch it through the local explorer API like the platform would.
  const crons: Array<{ at: number; worker: string; outcome: string }> = [];
  const cronLoop = (async () => {
    while (!stop) {
      for (let i = 0; i < P.cronEveryS && !stop; i++) await sleep(1000);
      if (stop) break;
      for (const w of ["orderbook-1delta-rsk", "filler-1delta-rsk"]) {
        const r = await ex.scheduled(w).catch((e: Error) => ({ outcome: `error ${e.message.slice(0, 80)}` }));
        crons.push({ at: Date.now(), worker: w, outcome: r.outcome });
      }
    }
  })();

  // Best-effort trace sampling (the store drops spans under load; see TraceCollector).
  const traces = new TraceCollector(ex, t0);
  const traceLoop = (async () => {
    while (!stop) {
      await traces.poll();
      for (let i = 0; i < 5 && !stop; i++) await sleep(1000);
    }
    await traces.poll();
  })();

  // Readers: GET /orders?maker=, /orders/:hash/status, /fills?maker= every 1–2 s, each its own visitor IP.
  const readers = Array.from({ length: P.readers }, (_, i) =>
    (async () => {
      const ip = `10.2.${Math.floor(i / 250)}.${(i % 250) + 1}`;
      const b = book(env, ip);
      const m = funded[i % funded.length]!.address;
      const who = `reader${i}`;
      await sleep(Math.random() * 2000);
      while (!stop) {
        const mine = posted.filter((p) => p.maker === m && p.status === 202);
        const r1 = await b.get(`/orders?maker=${m}&limit=100`);
        http.push({ who, ep: "GET /orders?maker", status: r1.status, ms: r1.ms, at: r1.at });
        if (mine.length) {
          const h = pick(mine).hash;
          const r2 = await b.get(`/orders/${h}/status`);
          http.push({ who, ep: "GET /orders/:hash/status", status: r2.status, ms: r2.ms, at: r2.at });
        }
        const r3 = await b.get(`/fills?maker=${m}&limit=100`);
        http.push({ who, ep: "GET /fills?maker", status: r3.status, ms: r3.ms, at: r3.at });
        await sleep(uni(P.readerMinMs, P.readerMaxMs));
      }
    })(),
  );

  // The abusive client: one IP, as fast as it can, from ABUSE_FROM_S to ABUSE_TO_S.
  const abuseKey = privateKeyToAccount(testKey(`${env.label}:abuser`, 0));
  const abuser = (async () => {
    await sleep(Math.max(0, at(P.abuseFromS) - Date.now()));
    events.push({ at: Date.now(), what: "abuse start" });
    const b = book(env, "10.66.6.6");
    const workers = Array.from({ length: P.abuseConcurrency }, async (_, w) => {
      let k = 0;
      while (Date.now() < at(P.abuseToS) && !stop) {
        k++;
        let r: Timed;
        const shape = (k + w) % 3;
        if (shape === 0) {
          // A fresh, validly signed, UNFUNDED order: costs the book a lens call if it gets past the IP gate.
          const o = await buildOrder(env, { maker: abuseKey, tokenIn: USDRIF, tokenOut: USDT0, amountIn: 10n ** 20n, owed: 99_000_000n, expiry: BigInt(nowS() + 3600) });
          r = await b.post("/orders", o.body);
        } else if (shape === 1) {
          const live = posted.find((p) => p.status === 202);
          r = await b.post("/orders", live ? live.body : "{}");
        } else {
          r = await b.post("/orders", '{"order": {"maker": "0xnope"}, "sig": "0x00"}');
        }
        http.push({ who: "abuser", ep: "POST /orders", status: r.status, ms: r.ms, at: r.at });
      }
    });
    await Promise.all(workers);
    events.push({ at: Date.now(), what: "abuse end" });
  })();

  // Admin: pause → resume mid-run.
  const pauser = (async () => {
    await sleep(Math.max(0, at(P.pauseAtS) - Date.now()));
    const r = await adm.post("/pause");
    paused.from = Date.now();
    events.push({ at: paused.from, what: `admin pause → ${r.status} ${JSON.stringify(r.body)}` });
    http.push({ who: "admin", ep: "POST /pause", status: r.status, ms: r.ms, at: r.at });
    await sleep(Math.max(0, at(P.resumeAtS) - Date.now()));
    const r2 = await adm.post("/resume");
    paused.to = Date.now();
    events.push({ at: paused.to, what: `admin resume → ${r2.status} ${JSON.stringify(r2.body)}` });
    http.push({ who: "admin", ep: "POST /resume", status: r2.status, ms: r2.ms, at: r2.at });
  })();

  // The makers: every planned order at its time (fire-and-forget, concurrent).
  const jobs: Array<Promise<void>> = [];
  for (const p of planned) {
    jobs.push(
      (async () => {
        await sleep(Math.max(0, at(p.atS) - Date.now()));
        const maker = funded[p.maker]!;
        let owed: bigint;
        let quoteOut: bigint | undefined;
        if (p.tokenIn === USDRIF) owed = (p.amountIn * BigInt(Math.round(p.price * 1e6))) / 10n ** 18n;
        else {
          quoteOut = await quote(pub, [WRBTC, USDT0], [3000], p.amountIn);
          owed = (quoteOut * BigInt(Math.round(p.price * 1e6))) / 1_000_000n;
        }
        const o = await buildOrder(env, {
          maker,
          tokenIn: p.tokenIn,
          tokenOut: USDT0,
          amountIn: p.amountIn,
          owed,
          expiry: BigInt(nowS() + p.ttlS),
          direct: p.direct,
          solver: env.solver,
        });
        const r = await book(env, makerIp(p.maker)).post("/orders", o.body);
        http.push({ who: `maker${p.maker}`, ep: "POST /orders", status: r.status, ms: r.ms, at: r.at });
        const rec: Posted = {
          id: p.id,
          kind: p.kind,
          expect: EXPECT[p.kind],
          maker: maker.address,
          makerIdx: p.maker,
          hash: o.hash,
          order: o.order,
          body: o.body,
          owed,
          amountIn: p.amountIn,
          tokenIn: p.tokenIn,
          ...(quoteOut !== undefined ? { quoteOut } : {}),
          postAt: r.at + r.ms,
          status: r.status,
          ms: r.ms,
          ...(r.status !== 202 ? { error: JSON.stringify(r.body).slice(0, 200) } : {}),
        };
        posted.push(rec);
        if (r.status !== 202 || p.cancelAfterS === undefined) return;
        await sleep(p.cancelAfterS * 1000);
        rec.cancelAt = Date.now();
        if (p.kind === "cancel-soft" || p.kind === "cancel-paused-soft") {
          const c = await book(env, makerIp(p.maker)).post("/cancels", await signedSoftCancel(env, maker, [o.hash]));
          rec.cancelStatus = c.status;
          http.push({ who: `maker${p.maker}`, ep: "POST /cancels", status: c.status, ms: c.ms, at: c.at });
        } else {
          const w = walletClient(env, maker);
          rec.cancelTx = await w.sendTransaction({ to: env.settlement, data: encodeCancelOrder(o.order), gas: 200_000n, gasPrice: BigInt(env.gasPriceWei), type: "legacy" });
          const rc = await pub.waitForTransactionReceipt({ hash: rec.cancelTx, pollingInterval: 500, timeout: 120_000 }).catch(() => undefined);
          rec.cancelStatus = rc ? (rc.status === "success" ? 1 : 0) : -1;
          rec.cancelMinedBlock = rc ? Number(rc.blockNumber) : undefined;
        }
      })().catch((e) => {
        log(`order job ${p.id} (${p.kind}) failed: ${(e as Error).message.split("\n")[0]}`);
      }),
    );
  }

  // Duplicates: re-post ~10% of accepted orders 5–60 s later (live → 202 duplicate).
  const dups: Array<{ hash: Hex; at: number; status: number; body: unknown; phase: string }> = [];
  const dupJobs: Array<Promise<void>> = [];
  const nDup = Math.round(P.orders * 0.1);
  for (let i = 0; i < nDup; i++) {
    const delay = uni(20, P.windowS);
    dupJobs.push(
      (async () => {
        await sleep(Math.max(0, at(delay) - Date.now()));
        const candidates = posted.filter((p) => p.status === 202 && p.expect !== "never" && p.kind !== "short-prof");
        if (!candidates.length) return;
        const p = pick(candidates);
        const r = await book(env, makerIp(p.makerIdx)).post("/orders", p.body);
        http.push({ who: `maker${p.makerIdx}`, ep: "POST /orders (dup)", status: r.status, ms: r.ms, at: r.at });
        dups.push({ hash: p.hash, at: r.at, status: r.status, body: r.body, phase: "live" });
      })(),
    );
  }

  // Bad posts: ~10% of ORDERS, spread over the window, from a "bad actor" IP.
  const bad: Array<{ shape: string; status: number; body: unknown; ms: number }> = [];
  const nBad = Math.round(P.orders * 0.1);
  const badShapes = ["malformed-json", "missing-fields", "wrong-content-type", "bad-signature", "garbage-signature", "unfunded", "token-not-allowed", "ttl-too-short", "expired", "oversized"];
  const badJobs = Array.from({ length: nBad }, (_, i) =>
    (async () => {
      await sleep(Math.max(0, at(uni(5, P.windowS)) - Date.now()));
      const shape = badShapes[i % badShapes.length]!;
      const b = book(env, `10.3.0.${(i % 200) + 1}`);
      const m = funded[i % funded.length]!;
      const base = { maker: m, tokenIn: USDRIF, tokenOut: USDT0, amountIn: 10n ** 20n, owed: 95_000_000n, expiry: BigInt(nowS() + 3600) } as const;
      let r: Timed;
      switch (shape) {
        case "malformed-json":
          r = await b.post("/orders", '{"order": {');
          break;
        case "missing-fields":
          r = await b.post("/orders", JSON.stringify({ order: { maker: m.address }, sig: "0x" }));
          break;
        case "wrong-content-type":
          r = await b.post("/orders", (await buildOrder(env, base)).body, "text/plain");
          break;
        case "bad-signature": {
          const o = await buildOrder(env, base);
          const other = await buildOrder(env, { ...base, maker: unfunded[0] ?? makers[0]! });
          r = await b.post("/orders", JSON.stringify({ order: orderToJson(o.order), sig: other.sig }));
          break;
        }
        case "garbage-signature": {
          const o = await buildOrder(env, base);
          r = await b.post("/orders", JSON.stringify({ order: orderToJson(o.order), sig: `0x${"11".repeat(65)}` }));
          break;
        }
        case "unfunded":
          r = await b.post("/orders", (await buildOrder(env, { ...base, maker: unfunded[i % unfunded.length] ?? makers[0]! })).body);
          break;
        case "token-not-allowed": {
          const o = await buildOrder(env, { ...base, tokenOut: "0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5" as Address });
          r = await b.post("/orders", o.body);
          break;
        }
        case "ttl-too-short":
          r = await b.post("/orders", (await buildOrder(env, { ...base, expiry: BigInt(nowS() + 5) })).body);
          break;
        case "expired":
          r = await b.post("/orders", (await buildOrder(env, { ...base, expiry: BigInt(nowS() - 60) })).body);
          break;
        default:
          r = await b.post("/orders", JSON.stringify({ pad: "x".repeat(300_000) }));
      }
      bad.push({ shape, status: r.status, body: r.body, ms: r.ms });
      http.push({ who: "bad", ep: `POST /orders (${shape})`, status: r.status, ms: r.ms, at: r.at });
    })(),
  );

  await Promise.all([...jobs, ...dupJobs, ...badJobs, pauser, abuser]);
  const postsDone = Date.now();
  log(`posting done after ${((postsDone - t0) / 1000).toFixed(0)} s: ${posted.length} orders posted (${posted.filter((p) => p.status === 202).length} accepted)`);

  // Drain: until nothing fillable is left unfilled and no fill landed for 60 s, or DRAIN_S.
  const drainEnd = Date.now() + P.drainS * 1000;
  let lastFillSeen = Date.now();
  let lastCount = seenFill.size;
  while (Date.now() < drainEnd) {
    await sleep(5000);
    if (seenFill.size !== lastCount) {
      lastCount = seenFill.size;
      lastFillSeen = Date.now();
    }
    const open = posted.filter((p) => p.status === 202 && p.expect === "fill" && !seenFill.has(p.hash));
    const st = (await adm.get<{ pending?: unknown }>("/status")).body;
    statusCalls++;
    const pendingTx = !!st?.pending;
    if (open.length === 0 && !pendingTx) break;
    if (!pendingTx && Date.now() - lastFillSeen > 60_000) {
      log(`drain: no fill for 60 s with ${open.length} expected fill(s) open — stopping the drain`);
      break;
    }
  }
  // Let the book index the last fills (CONFIRMATIONS blocks + one alarm interval), and
  // let any last tx (e.g. a rebalancer redeem sent once the book went quiet) resolve.
  await sleep(P.settleS * 1000);
  for (let i = 0; i < 45; i++) {
    const st = (await adm.get<{ pending?: unknown }>("/status")).body;
    statusCalls++;
    if (!st?.pending) break;
    await sleep(2000);
  }
  stop = true;
  await Promise.all([watcher, poller, cronLoop, traceLoop, ...readers]);
  const endAt = Date.now();
  log(`drain done after ${((endAt - postsDone) / 1000).toFixed(0)} s`);

  // Dead re-posts: a filled order and a soft-cancelled order (expect 422).
  for (const want of ["filled", "soft-cancelled"] as const) {
    const p = posted.find((x) => x.status === 202 && (want === "filled" ? seenFill.has(x.hash) : x.kind.endsWith("soft")));
    if (!p) continue;
    const r = await book(env, makerIp(p.makerIdx)).post("/orders", p.body);
    dups.push({ hash: p.hash, at: r.at, status: r.status, body: r.body, phase: `dead:${want}` });
  }

  const records = { P, env: { ...env, operatorKey: "(anvil dev key #1)", deployerKey: "(anvil dev key #0)", adminToken: "(redacted)", bindingKey: "(redacted)" }, t0, endAt, postsDone, paused, events, crons, traces: [...traces.rows.values()], startBlock, clockSkewS, posted, dups, bad, http, statusSamples, statusCalls, operatorStart, treasuryStart, proxyTxsBefore };
  writeResult(`${P.label}-records`, records);
  const verdict = await verify(records);
  writeResult(P.label, verdict);
  printSummary(verdict);
  if (verdict.failures.length) process.exitCode = 1;
}

// ──────────────────── verification ────────────────────

type Records = {
  P: typeof P;
  crons?: Array<{ at: number; worker: string; outcome: string }>;
  traces?: Array<Record<string, unknown>>;
  t0: number;
  endAt: number;
  postsDone: number;
  paused: { from: number; to: number };
  events: Array<{ at: number; what: string }>;
  startBlock: number;
  clockSkewS: number;
  posted: Posted[];
  dups: Array<{ hash: Hex; at: number; status: number; body: unknown; phase: string }>;
  bad: Array<{ shape: string; status: number; body: unknown; ms: number }>;
  http: HttpRec[];
  statusSamples: Array<{ at: number; body: Record<string, unknown> }>;
  statusCalls: number;
  operatorStart: { rbtc: bigint; usdt0: bigint; usdrif: bigint };
  treasuryStart: { usdt0: bigint; wrbtc: bigint; usdrif: bigint };
  proxyTxsBefore: number;
};

const norm = (s: string) => s.replace(/0x[0-9a-fA-F]{6,}/g, "0x…").replace(/\b\d{2,}\b/g, "N").slice(0, 120);

async function revertReason(txHash: Hex): Promise<string> {
  try {
    const t = (await pub.request({ method: "debug_traceTransaction" as never, params: [txHash, { tracer: "callTracer" }] as never })) as { error?: string; output?: Hex; revertReason?: string };
    const data = t.output;
    if (data && data.length >= 10) {
      for (const abi of [SETTLEMENT_ABI, AGGREGATOR_FILL_SOLVER_ABI] as const) {
        try {
          const d = decodeErrorResult({ abi: abi as never, data });
          return `${d.errorName}(${(d.args ?? []).map(String).join(", ")})`;
        } catch {
          // next
        }
      }
      return `${t.error ?? "revert"} ${data.slice(0, 10)}`;
    }
    return t.revertReason ?? t.error ?? "revert (no data)";
  } catch (e) {
    return `trace failed: ${(e as Error).message.split("\n")[0]}`;
  }
}

/** Row counts of every table in the book's Durable Object (wrangler's local explorer). */
export async function bookStorage(): Promise<Record<string, unknown>> {
  const tables = ["orders", "graves", "soft_cancels", "fills", "meta", "buckets", "billed"];
  const res = await ex.doQuery("orderbook-1delta-rsk-OrderBookDO", "chain:30", [
    ...tables.map((t) => ({ sql: `SELECT count(*) AS n FROM ${t}` })),
    { sql: "SELECT reason, count(*) AS n FROM graves GROUP BY reason" },
    { sql: "SELECT key, value FROM meta" },
  ]);
  return {
    rows: Object.fromEntries(tables.map((t, i) => [t, Number(res[i]![0]!.n)])),
    gravesByReason: Object.fromEntries(res[tables.length]!.map((r) => [String(r.reason), Number(r.n)])),
    meta: Object.fromEntries(res[tables.length + 1]!.map((r) => [String(r.key), String(r.value)])),
  };
}

/** The filler's own log lines (wrangler stdout), by order hash: the last skip / failure reason. */
function fillerReasons(): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let text = "";
  try {
    text = readFileSync(join(env.runDir, "wrangler.log"), "utf8");
  } catch {
    return out;
  }
  for (const line of text.split("\n")) {
    const m = /(\[(?:inventory|route)\][^\n]*?)(0x[0-9a-f]{64})(?![0-9a-f])/.exec(line);
    if (!m) continue;
    const h = m[2]!.toLowerCase();
    const arr = out.get(h) ?? [];
    arr.push(line.replace(/^.*?(·|✗|→|✓|\[dry-run\])/, "$1").slice(0, 260));
    out.set(h, arr);
  }
  return out;
}

async function verify(rec: Records) {
  const failures: string[] = [];
  const notes: string[] = [];
  const head = Number(await pub.getBlockNumber());
  const fills = await chainFills(rec.startBlock, head);
  const fillsByOrder = new Map<string, ChainFill[]>();
  for (const f of fills) fillsByOrder.set(f.orderHash, [...(fillsByOrder.get(f.orderHash) ?? []), f]);
  const cancels = await pub.getLogs({ address: env.settlement, event: CANCELLED_BY_HASH, fromBlock: BigInt(rec.startBlock), toBlock: BigInt(head) });
  const cancelBlock = new Map<string, number>();
  for (const c of cancels) cancelBlock.set((c.args.orderHash as Hex).toLowerCase(), Number(c.blockNumber));
  const reasons = fillerReasons();

  // ── posts by outcome ──
  const postsByOutcome: Record<string, number> = {};
  for (const p of rec.posted) {
    const k = p.status === 202 ? `202 ${p.kind}` : `${p.status} ${p.kind}: ${norm(p.error ?? "")}`;
    postsByOutcome[k] = (postsByOutcome[k] ?? 0) + 1;
  }
  const badByOutcome: Record<string, number> = {};
  for (const b of rec.bad) {
    const k = `${b.shape} → ${b.status} ${norm(JSON.stringify(b.body))}`;
    badByOutcome[k] = (badByOutcome[k] ?? 0) + 1;
  }
  const expectBad: Record<string, number[]> = {
    "malformed-json": [400],
    "missing-fields": [400],
    "wrong-content-type": [415],
    "bad-signature": [422],
    "garbage-signature": [422, 400],
    unfunded: [422],
    "token-not-allowed": [422],
    "ttl-too-short": [422],
    expired: [422],
    oversized: [413],
  };
  for (const b of rec.bad) if (!expectBad[b.shape]?.includes(b.status)) failures.push(`bad post ${b.shape}: got ${b.status} ${JSON.stringify(b.body).slice(0, 120)}`);
  const dupByOutcome: Record<string, number> = {};
  for (const d of rec.dups) {
    const k = `${d.phase} → ${d.status} ${norm(JSON.stringify(d.body))}`;
    dupByOutcome[k] = (dupByOutcome[k] ?? 0) + 1;
    if (d.phase === "live" && !(d.status === 202 && (d.body as { duplicate?: boolean })?.duplicate === true)) {
      // A live re-post of an order that was filled meanwhile is legitimately 422.
      if (!(d.status === 422 && fillsByOrder.has(d.hash))) failures.push(`live duplicate ${d.hash}: ${d.status} ${JSON.stringify(d.body).slice(0, 100)}`);
    }
    if (d.phase.startsWith("dead") && d.status !== 422) failures.push(`dead re-post (${d.phase}) ${d.hash}: ${d.status}`);
  }
  const honestRejected = rec.posted.filter((p) => p.status !== 202);
  for (const p of honestRejected) {
    const ok = p.status === 422 && p.kind.startsWith("short") && /expires in/.test(p.error ?? "");
    // wrangler dev's own front-door ProxyWorker occasionally drops its connection to the
    // user worker under load and cannot retry a POST ("Error inside ProxyWorker … Network
    // connection lost"). That component does not exist in production: an environment note.
    const devProxy = p.status === 500 && /Network connection lost/.test(p.error ?? "");
    if (devProxy) notes.push(`dev-server ProxyWorker dropped honest POST of ${p.kind} (wrangler-dev artefact, not the worker)`);
    else if (!ok) failures.push(`honest post rejected: ${p.kind} ${p.status} ${p.error}`);
  }

  // ── fills vs expectations ──
  const accepted = rec.posted.filter((p) => p.status === 202);
  const perOrder: Array<Record<string, unknown>> = [];
  const latency = { postToSend: [] as number[], sendToMined: [] as number[], postToMined: [] as number[], minedToIndexed: [] as number[] };
  const pxTxs: ProxyTx[] = (await px.txs()).slice(rec.proxyTxsBefore);
  const opTxs = pxTxs.filter((t) => t.from?.toLowerCase() === env.operator.toLowerCase());
  const sendAtByTx = new Map(opTxs.map((t) => [t.hash.toLowerCase(), t.at]));
  // The book's own view (DO SQLite through the explorer API).
  const [graves, live, bookFills] = await ex.doQuery("orderbook-1delta-rsk-OrderBookDO", "chain:30", [
    { sql: "SELECT hash, reason, removed_at, tx_hash, summary FROM graves" },
    { sql: "SELECT hash, ok, status, filled FROM orders" },
    { sql: "SELECT tx_hash, log_index, order_hash, maker, solver, block_number, at, cumulative, amount FROM fills" },
  ]);
  const graveBy = new Map(graves!.map((g) => [String(g.hash), g]));
  const liveBy = new Map(live!.map((g) => [String(g.hash), g]));
  const makerReceipts = new Map<string, bigint>();
  let races = 0;
  const unfilled: string[] = [];
  for (const p of accepted) {
    const fs = fillsByOrder.get(p.hash) ?? [];
    const g = graveBy.get(p.hash);
    const row: Record<string, unknown> = { id: p.id, kind: p.kind, hash: p.hash, fills: fs.length, book: g ? g.reason : liveBy.has(p.hash) ? "live" : "unknown" };
    if (fs.length > 1) failures.push(`order ${p.hash} (${p.kind}) filled ${fs.length}× on-chain`);
    const f = fs[0];
    if (f) {
      row.tx = f.txHash;
      // The maker got at least what it is owed: USDT0 Transfer(→ maker) inside the fill tx.
      const rc = await pub.getTransactionReceipt({ hash: f.txHash });
      let got = 0n;
      for (const l of rc.logs) {
        if (l.address.toLowerCase() !== USDT0.toLowerCase()) continue;
        try {
          const d = decodeEventLog({ abi: erc20Abi, data: l.data, topics: l.topics });
          if (d.eventName === "Transfer" && (d.args.to as string).toLowerCase() === p.maker.toLowerCase()) got += d.args.value as bigint;
        } catch {
          // not a Transfer
        }
      }
      makerReceipts.set(p.hash, got);
      row.owed = p.owed.toString();
      row.received = got.toString();
      if (got < p.owed) failures.push(`maker of ${p.hash} (${p.kind}) received ${got} < owed ${p.owed}`);
      if (BigInt(f.blockTime) > p.order.expiry) failures.push(`order ${p.hash} filled after its expiry`);
      const sendAt = sendAtByTx.get(f.txHash.toLowerCase());
      const minedMs = (f.blockTime - rec.clockSkewS) * 1000;
      if (sendAt) {
        latency.postToSend.push(sendAt - p.postAt);
        latency.sendToMined.push(Math.max(0, minedMs - sendAt));
      }
      latency.postToMined.push(Math.max(0, minedMs - p.postAt));
      if (g && g.reason === "filled") latency.minedToIndexed.push(Math.max(0, Number(g.removed_at) * 1000 - minedMs));
      // Book convergence: tombstone 'filled' naming this tx.
      if (!g || g.reason !== "filled") failures.push(`book did not converge to 'filled' for ${p.hash} (${p.kind}): ${g ? g.reason : liveBy.has(p.hash) ? "still live" : "unknown"}`);
      else if (String(g.tx_hash ?? "").toLowerCase() !== f.txHash.toLowerCase()) failures.push(`book tombstone of ${p.hash} names tx ${g.tx_hash}, chain says ${f.txHash}`);
      if (p.expect === "never") {
        const cancelledFirst = p.cancelAt !== undefined && minedMs > p.cancelAt;
        if (p.kind === "cancel-soft" || p.kind === "cancel-chain") {
          // A live cancel racing the filler: a fill mined before (or for a soft cancel: sent before) the cancel is a race, not a bug.
          const sentBeforeCancel = sendAt !== undefined && p.cancelAt !== undefined && sendAt <= p.cancelAt + (p.kind === "cancel-chain" ? 2_500 : 0);
          if (sentBeforeCancel || !cancelledFirst) {
            races++;
            row.race = true;
            notes.push(`race: ${p.kind} ${p.hash} — fill tx sent ${sendAt ? sendAt - (p.cancelAt ?? 0) : "?"} ms vs the cancel`);
          } else failures.push(`cancelled order ${p.hash} (${p.kind}) filled AFTER its cancel (tx ${f.txHash})`);
        } else failures.push(`order ${p.hash} (${p.kind}) must never fill but did (tx ${f.txHash})`);
      }
    } else {
      if (p.expect === "fill") {
        const why = reasons.get(p.hash)?.slice(-1)[0] ?? "(no filler log line)";
        unfilled.push(`${p.kind} ${p.hash}: ${why}`);
        row.why = why;
      }
      const reason = g ? String(g.reason) : liveBy.has(p.hash) ? "live" : "unknown";
      const want: Record<string, string[]> = {
        "cancel-soft": ["soft-cancelled"],
        "cancel-paused-soft": ["soft-cancelled"],
        "cancel-chain": ["cancelled"],
        "cancel-paused-chain": ["cancelled"],
        "short-unprof": ["expired"],
        "short-prof": ["expired"],
      };
      const w = want[p.kind];
      if (w && !w.includes(reason)) failures.push(`book status of ${p.hash} (${p.kind}) is '${reason}', expected ${w.join("/")}`);
      if (p.kind.startsWith("cancel-") && p.kind.includes("chain") && p.cancelStatus !== 1) failures.push(`on-chain cancel of ${p.hash} did not succeed (${p.cancelStatus})`);
    }
    perOrder.push(row);
  }
  for (const u of unfilled) failures.push(`expected fill missing: ${u}`);

  // ── the fill index vs the chain ──
  const chainKeys = new Set(fills.map((f) => `${f.txHash.toLowerCase()}:${f.logIndex}`));
  const bookKeys = new Set(bookFills!.map((f) => `${String(f.tx_hash).toLowerCase()}:${f.log_index}`));
  const missingInBook = [...chainKeys].filter((k) => !bookKeys.has(k));
  const extraInBook = [...bookKeys].filter((k) => !chainKeys.has(k));
  if (missingInBook.length) failures.push(`fill index misses ${missingInBook.length} on-chain fill(s): ${missingInBook.slice(0, 3).join(", ")}`);
  if (extraInBook.length) failures.push(`fill index has ${extraInBook.length} fill(s) not on chain`);
  const byHash = new Map(accepted.map((p) => [p.hash, p]));
  let amountChecked = 0;
  for (const bf of bookFills!) {
    const p = byHash.get(String(bf.order_hash) as Hex);
    if (!p) continue;
    const anchor = p.order.legsIn[0]!.start;
    if (bf.amount === null || BigInt(String(bf.amount)) !== anchor || BigInt(String(bf.cumulative)) !== anchor) {
      failures.push(`fill index amount for ${p.hash}: amount ${bf.amount} cumulative ${bf.cumulative}, anchor ${anchor}`);
    } else amountChecked++;
  }

  // ── the filler's txs: reverts, nonces, resolution ──
  const receipts = new Map<string, { status: string; gasUsed: bigint; effectiveGasPrice: bigint; to: string | null; blockNumber: bigint }>();
  for (const t of opTxs) {
    const rc = await pub.getTransactionReceipt({ hash: t.hash }).catch(() => undefined);
    if (rc) receipts.set(t.hash.toLowerCase(), { status: rc.status, gasUsed: rc.gasUsed, effectiveGasPrice: rc.effectiveGasPrice, to: rc.to, blockNumber: rc.blockNumber });
  }
  const byNonce = new Map<number, Set<string>>();
  const sendsByHash = new Map<string, number>();
  for (const t of opTxs) {
    byNonce.set(t.nonce ?? -1, new Set([...(byNonce.get(t.nonce ?? -1) ?? []), t.hash.toLowerCase()]));
    sendsByHash.set(t.hash.toLowerCase(), (sendsByHash.get(t.hash.toLowerCase()) ?? 0) + 1);
  }
  const nonceClashes = [...byNonce.entries()].filter(([, s]) => s.size > 1).map(([n, s]) => `nonce ${n}: ${[...s].join(", ")}`);
  for (const c of nonceClashes) failures.push(`nonce clash ${c}`);
  const rebroadcasts = [...sendsByHash.entries()].filter(([, n]) => n > 1);
  const unmined = opTxs.filter((t) => !receipts.has(t.hash.toLowerCase()) && t.mode === "pass");
  for (const t of unmined) failures.push(`operator tx ${t.hash} (nonce ${t.nonce}) never mined`);
  const reverts: Array<{ tx: string; reason: string; order?: string; kind?: string }> = [];
  const fillerFillsRes = await adm.get<{ fills: Array<Record<string, string | number | null>> }>("/fills?limit=5000");
  const fillerFills = fillerFillsRes.body.fills ?? [];
  const rowByTx = new Map(fillerFills.map((r) => [String(r.tx).toLowerCase(), r]));
  for (const [h, rc] of receipts) {
    if (rc.status === "success") continue;
    const row = rowByTx.get(h);
    const order = row?.order_hash ? String(row.order_hash) : undefined;
    const p = order ? byHash.get(order as Hex) : undefined;
    const reason = await revertReason(h as Hex);
    reverts.push({ tx: h, reason, ...(order ? { order } : {}), ...(p ? { kind: p.kind } : {}) });
    const explained = p && (p.kind === "cancel-chain" || p.kind.startsWith("short"));
    if (!explained) failures.push(`unexplained revert ${h}: ${reason} (order ${order ?? "-"} ${p?.kind ?? ""})`);
    else notes.push(`explained revert ${h}: ${reason} — ${p!.kind} race`);
  }
  // Two txs for one order (even if one reverted) = a double send.
  const sendsPerOrder = new Map<string, number>();
  for (const r of fillerFills) if (r.kind === "fill" && r.order_hash) sendsPerOrder.set(String(r.order_hash), (sendsPerOrder.get(String(r.order_hash)) ?? 0) + 1);
  const doubleSends = [...sendsPerOrder.entries()].filter(([, n]) => n > 1);
  for (const [h, n] of doubleSends) notes.push(`order ${h}: ${n} fill txs recorded by the filler`);

  // ── accounting: the filler's log vs the chain ──
  const operatorEnd = { rbtc: await pub.getBalance({ address: env.operator }), usdt0: await balanceOf(pub, USDT0, env.operator), usdrif: await balanceOf(pub, USDRIF, env.operator) };
  const treasuryEnd = { usdt0: await balanceOf(pub, USDT0, env.treasury), wrbtc: await balanceOf(pub, WRBTC, env.treasury), usdrif: await balanceOf(pub, USDRIF, env.treasury) };
  let gasChain = 0n;
  let valueSent = 0n;
  for (const t of opTxs) {
    const rc = receipts.get(t.hash.toLowerCase());
    if (rc) gasChain += rc.gasUsed * rc.effectiveGasPrice;
    const tx = await pub.getTransaction({ hash: t.hash }).catch(() => undefined);
    if (tx && rc) valueSent += tx.value;
  }
  let gasLogged = 0n;
  let gasMismatch = 0;
  let invPaid = 0n;
  let invRecv = 0n;
  let routeFillsLogged = 0;
  let invFillsLogged = 0;
  for (const r of fillerFills) {
    const rc = receipts.get(String(r.tx).toLowerCase());
    if (r.gas_cost_wei) gasLogged += BigInt(String(r.gas_cost_wei));
    if (rc && r.gas_cost_wei && BigInt(String(r.gas_cost_wei)) !== rc.gasUsed * rc.effectiveGasPrice) gasMismatch++;
    if (r.status === "filled" && r.strategy === "inventory") {
      invFillsLogged++;
      invPaid += BigInt(String(r.paid ?? 0));
      invRecv += BigInt(String(r.received ?? 0));
    }
    if (r.status === "filled" && r.strategy === "route") routeFillsLogged++;
  }
  const rbtcSpent = rec.operatorStart.rbtc - operatorEnd.rbtc;
  if (gasMismatch) failures.push(`${gasMismatch} filler fill row(s) whose gas_cost_wei ≠ the receipt's gasUsed × price`);
  if (gasChain + valueSent !== rbtcSpent) failures.push(`operator RBTC spent ${rbtcSpent} ≠ chain gas ${gasChain} + value ${valueSent}`);
  if (gasLogged !== gasChain) failures.push(`filler logged gas ${gasLogged} wei ≠ chain gas ${gasChain} wei over its txs`);
  const usdt0Out = rec.operatorStart.usdt0 - operatorEnd.usdt0;
  if (usdt0Out !== invPaid) failures.push(`operator USDT0 outflow ${usdt0Out} ≠ Σ inventory paid ${invPaid}`);
  const chainInvFills = fills.filter((f) => f.solver.toLowerCase() === env.operator.toLowerCase()).length;
  const chainRouteFills = fills.filter((f) => f.solver.toLowerCase() === env.solver.toLowerCase()).length;
  if (chainInvFills !== invFillsLogged) failures.push(`inventory fills: chain ${chainInvFills}, filler log ${invFillsLogged}`);
  if (chainRouteFills !== routeFillsLogged) failures.push(`route fills: chain ${chainRouteFills}, filler log ${routeFillsLogged}`);
  const lastStatus = (await adm.get<Record<string, unknown>>("/status")).body;
  const budgets = lastStatus.budgets as Record<string, string> | undefined;
  if (lastStatus.pending) failures.push(`a tx is still pending at the end: ${JSON.stringify(lastStatus.pending).slice(0, 200)}`);

  // ── per tick. Exact sources: the proxy's RPC timeline (every filler call, segmented
  //    into ticks) and the DO's own /status `lastTick` (subrequests = RPC + book fetch,
  //    durationMs) sampled every STATUS_EVERY_S. The runtime trace store is a lossy
  //    cross-check (it drops spans under heavy request load). ──
  const statusWindows = rec.http.filter((h) => h.ep === "GET /status").map((h) => [h.at, h.at + h.ms] as [number, number]);
  const segs = segmentTicks(readTimeline(env.runDir, rec.t0, rec.endAt, "filler"), statusWindows);
  const sampled = rec.statusSamples
    .map((x) => (x.body as { lastTick?: { at: string; summary?: { subrequests?: number; durationMs?: number; source?: string } } }).lastTick)
    .filter((t): t is { at: string; summary: { subrequests?: number; durationMs?: number; source?: string } } => !!t?.summary);
  const uniq = new Map(sampled.map((t) => [t.at, t.summary]));
  const sampleSubs = [...uniq.values()].map((x) => Number(x.subrequests ?? 0));
  const sampleDur = [...uniq.values()].map((x) => Number(x.durationMs ?? 0));
  const obCalls = readTimeline(env.runDir, rec.t0, rec.endAt, "ob");
  const obAlarms = obCalls.filter((c) => c.m === "eth_blockNumber");
  const obGaps = obAlarms.slice(1).map((c, i) => (c.t - obAlarms[i]!.t) / 1000);
  const obMethods = obCalls.reduce<Record<string, number>>((a, c) => ((a[c.m] = (a[c.m] ?? 0) + 1), a), {});
  const tr = (rec.traces ?? []) as Array<Record<string, unknown>>;
  const trOf = (svc: string, name = "alarm") => tr.filter((t) => t.service === svc && t.name === name);
  const fillerTicks = {
    fromTimeline: { ticks: segs.length, rpcPerTick: dist(segs.map((x) => x.calls)), rpcSpanMs: dist(segs.map((x) => x.end - x.start)), biggest: segs.reduce((a, x) => (x.calls > (a?.calls ?? 0) ? x : a), segs[0]) ?? null },
    fromStatus: { samples: uniq.size, subrequests: dist(sampleSubs), durationMs: dist(sampleDur) },
    fromTraces: { captured: trOf("filler-1delta-rsk").length, wallMs: dist(trOf("filler-1delta-rsk").map((t) => Number(t.ms))), subrequests: dist(trOf("filler-1delta-rsk").map((t) => Number(t.fetches))), notOk: trOf("filler-1delta-rsk").filter((t) => t.outcome !== "ok").length },
  };
  const bookTicks = {
    alarms: obAlarms.length,
    intervalS: dist(obGaps),
    rpcByMethod: obMethods,
    fromTraces: { captured: trOf("orderbook-1delta-rsk").length, wallMs: dist(trOf("orderbook-1delta-rsk").map((t) => Number(t.ms))), subrequests: dist(trOf("orderbook-1delta-rsk").map((t) => Number(t.fetches))), notOk: trOf("orderbook-1delta-rsk").filter((t) => t.outcome !== "ok").length },
  };
  const maxSub = Math.max(fillerTicks.fromStatus.subrequests.max || 0, (fillerTicks.fromTimeline.rpcPerTick.max || 0) + 2);
  if (maxSub > 500) failures.push(`a filler tick made ~${maxSub} subrequests (> MAX_SUBREQUESTS_PER_TICK 500)`);
  const maxDur = Math.max(fillerTicks.fromStatus.durationMs.max || 0, fillerTicks.fromTimeline.rpcSpanMs.max || 0);
  if (maxDur > 30_000) failures.push(`a filler tick ran ${maxDur} ms (TICK_BUDGET_MS 20 s + one order)`);
  if (fillerTicks.fromTraces.notOk) failures.push(`${fillerTicks.fromTraces.notOk} filler alarm(s) did not end ok`);
  if (bookTicks.fromTraces.notOk) failures.push(`${bookTicks.fromTraces.notOk} orderbook alarm(s) did not end ok`);
  const crons = { traced: { filler: trOf("filler-1delta-rsk", "scheduled").length, orderbook: trOf("orderbook-1delta-rsk", "scheduled").length } };

  // ── reads, 429s ──
  const httpBy = (pred: (h: HttpRec) => boolean) => rec.http.filter(pred);
  const statusCounts = (hs: HttpRec[]) => hs.reduce<Record<string, number>>((a, h) => ((a[String(h.status)] = (a[String(h.status)] ?? 0) + 1), a), {});
  const readEps = ["GET /orders?maker", "GET /orders/:hash/status", "GET /fills?maker"];
  const abuseWin = (h: HttpRec) => h.at >= rec.t0 + rec.P.abuseFromS * 1000 && h.at <= rec.t0 + rec.P.abuseToS * 1000;
  const reads = Object.fromEntries(
    readEps.map((ep) => {
      const hs = httpBy((h) => h.ep === ep);
      return [ep, { statuses: statusCounts(hs), ok: dist(hs.filter((h) => h.status === 200).map((h) => h.ms)), okDuringAbuse: dist(hs.filter((h) => h.status === 200 && abuseWin(h)).map((h) => h.ms)) }];
    }),
  );
  const abuse = httpBy((h) => h.who === "abuser");
  const abuseSpan = abuse.length ? (Math.max(...abuse.map((h) => h.at)) - Math.min(...abuse.map((h) => h.at))) / 1000 : 0;
  const honestPosts = httpBy((h) => h.ep === "POST /orders" && h.who.startsWith("maker"));
  const honest429 = honestPosts.filter((h) => h.status === 429).length;
  if (honest429) failures.push(`${honest429} honest maker post(s) got 429`);
  const abuseOk = abuse.filter((h) => h.status !== 429).length;

  // ── DO storage at the end ──
  const bookCounts = await bookStorage();
  const fillerCounts = await ex.doQuery("filler-1delta-rsk-FillerDO", "filler", [{ sql: "SELECT kind, status, strategy, count(*) AS n FROM fills GROUP BY kind, status, strategy" }]);

  // ── errors / alerts ──
  const wlog = readFileSync(join(env.runDir, "wrangler.log"), "utf8").split("\n");
  const errorLines = wlog.filter((l) => /Uncaught|✘ \[ERROR\]|Error:|event hook failed|tick exception|internal error/.test(l)).slice(0, 50);
  // Worker-side uncaught errors and dev-server errors, by message (ANSI codes stripped).
  const errorCounts: Record<string, number> = {};
  for (const l of wlog) {
    const plain = l.replace(/\u001b\[[0-9;]*m/g, "");
    const m = /(Uncaught [^\n]{0,120}|Error inside ProxyWorker[^:]*|NOSENTRY reporting trace with exceptions[^;]*)/.exec(plain);
    if (m) errorCounts[m[1]!.replace(/https?:\/\/\S+/g, "URL").trim()] = (errorCounts[m[1]!.replace(/https?:\/\/\S+/g, "URL").trim()] ?? 0) + 1;
  }
  const alerts = (lastStatus.alerts as unknown[]) ?? [];
  const webhooks = await px.webhooks();
  const proxyStats = await px.stats();

  // ── throughput ──
  const minedTimes = fills.filter((f) => byHash.has(f.orderHash)).map((f) => (f.blockTime - rec.clockSkewS) * 1000).sort((a, b) => a - b);
  const pausedMs = rec.paused.to > rec.paused.from ? rec.paused.to - rec.paused.from : 0;
  const activeMs = minedTimes.length ? minedTimes[minedTimes.length - 1]! - rec.t0 - pausedMs : 0;
  let busiest = 0;
  for (let i = 0; i < minedTimes.length; i++) {
    let j = i;
    while (j < minedTimes.length && minedTimes[j]! - minedTimes[i]! < 60_000) j++;
    busiest = Math.max(busiest, j - i);
  }
  const blocksWithFill = new Set(fills.map((f) => f.blockNumber)).size;

  const byKind: Record<string, { posted: number; accepted: number; filled: number; expect: Expect }> = {};
  for (const p of rec.posted) {
    const k = (byKind[p.kind] ??= { posted: 0, accepted: 0, filled: 0, expect: p.expect });
    k.posted++;
    if (p.status === 202) k.accepted++;
    if (p.status === 202 && fillsByOrder.has(p.hash)) k.filled++;
  }
  const fillerCalls = proxyStats.tags.filler?.calls ?? 0;
  // Rebalancer txs (approve / approval resets / redeems / RIF sales) and how often an
  // order the filler had already filled was evaluated again (the book still served it).
  const rebalanceTxs = fillerFills.filter((r) => r.strategy === "rebalance").reduce<Record<string, number>>((a, r) => {
    const k = `${r.kind}${String(r.note ?? "").includes(" for 0 of ") ? " (reset to 0)" : ""}`;
    a[k] = (a[k] ?? 0) + 1;
    return a;
  }, {});
  const filledSet = new Set<string>(fills.map((f) => f.orderHash));
  let reEvaluated = 0;
  for (const [h, lines] of reasons) if (filledSet.has(h)) reEvaluated += lines.filter((l) => l.startsWith("✗")).length;
  const cronOk = (rec.crons ?? []).filter((c) => c.outcome === "ok").length;
  if ((rec.crons ?? []).some((c) => c.outcome !== "ok")) failures.push(`cron dispatch not ok: ${json((rec.crons ?? []).filter((c) => c.outcome !== "ok")).slice(0, 200)}`);

  return {
    label: rec.P.label,
    byKind,
    rpcPerFill: fills.length ? (fillerCalls - rec.statusCalls * 6) / fills.length : null,
    rebalanceTxs,
    filledOrdersReEvaluatedFailures: reEvaluated,
    crons: { dispatched: (rec.crons ?? []).length, ok: cronOk },
    run: env.label,
    latency: { proxyMs: env.latencyMs, jitterMs: env.jitterMs },
    blockTimeS: env.blockTimeS,
    profile: rec.P,
    durations: { postingS: (rec.postsDone - rec.t0) / 1000, totalS: (rec.endAt - rec.t0) / 1000, pausedS: pausedMs / 1000 },
    posts: { total: rec.posted.length, accepted: accepted.length, byOutcome: postsByOutcome, bad: badByOutcome, duplicates: dupByOutcome },
    fills: {
      onChain: fills.length,
      ofOurOrders: fills.filter((f) => byHash.has(f.orderHash)).length,
      inventory: chainInvFills,
      route: chainRouteFills,
      expectedFill: accepted.filter((p) => p.expect === "fill").length,
      expectedFillFilled: accepted.filter((p) => p.expect === "fill" && fillsByOrder.has(p.hash)).length,
      shortProfFilled: accepted.filter((p) => p.kind === "short-prof" && fillsByOrder.has(p.hash)).length,
      shortProf: accepted.filter((p) => p.kind === "short-prof").length,
      neverFilled: accepted.filter((p) => p.expect === "never" && fillsByOrder.has(p.hash)).length,
      cancelRaces: races,
      unfilled,
      makersOwedOk: [...makerReceipts.entries()].every(([h, got]) => got >= byHash.get(h as Hex)!.owed),
    },
    latencyMs: {
      postToSend: dist(latency.postToSend),
      sendToMined: dist(latency.sendToMined),
      postToMined: dist(latency.postToMined),
      minedToIndexed: dist(latency.minedToIndexed),
    },
    throughput: {
      fillsPerMinActive: activeMs > 0 ? (minedTimes.length / activeMs) * 60_000 : 0,
      busiest60s: busiest,
      ceilingPerMin: 60 / env.blockTimeS,
      blocksWithFill,
      operatorTxs: opTxs.length,
    },
    ticks: { filler: fillerTicks, orderbook: bookTicks, cronInvocations: crons },
    reads,
    rateLimit: {
      abuser: { requests: abuse.length, perSecond: abuseSpan > 0 ? abuse.length / abuseSpan : 0, statuses: statusCounts(abuse), notLimited: abuseOk },
      honestPosts: { total: honestPosts.length, statuses: statusCounts(honestPosts), latencyDuringAbuse: dist(honestPosts.filter(abuseWin).map((h) => h.ms)), latencyOutsideAbuse: dist(honestPosts.filter((h) => !abuseWin(h)).map((h) => h.ms)) },
      readers429: httpBy((h) => h.who.startsWith("reader") && h.status === 429).length,
      readersTotal: httpBy((h) => h.who.startsWith("reader")).length,
    },
    txs: { operator: opTxs.length, reverts, nonceClashes, rebroadcasts: rebroadcasts.length, doubleSendsPerOrder: doubleSends.length, unmined: unmined.length },
    fillIndex: { chain: chainKeys.size, book: bookKeys.size, missingInBook: missingInBook.length, extraInBook: extraInBook.length, amountsChecked: amountChecked },
    accounting: {
      rbtcSpentWei: rbtcSpent.toString(),
      chainGasWei: gasChain.toString(),
      valueWei: valueSent.toString(),
      fillerLoggedGasWei: gasLogged.toString(),
      usdt0Outflow: usdt0Out.toString(),
      inventoryPaidLogged: invPaid.toString(),
      usdrifInflow: (operatorEnd.usdrif - rec.operatorStart.usdrif).toString(),
      inventoryReceivedLogged: invRecv.toString(),
      treasuryDelta: {
        usdt0: (treasuryEnd.usdt0 - rec.treasuryStart.usdt0).toString(),
        wrbtc: (treasuryEnd.wrbtc - rec.treasuryStart.wrbtc).toString(),
        usdrif: (treasuryEnd.usdrif - rec.treasuryStart.usdrif).toString(),
      },
      budgetsAtEnd: budgets ?? null,
    },
    storage: { orderbook: bookCounts, filler: fillerCounts },
    rpc: { proxy: proxyStats, statusPollsDuringRun: rec.statusCalls },
    alerts: { status: alerts, webhooks },
    errorLines,
    errorCounts,
    events: rec.events,
    perOrder,
    failures,
    notes,
  };
}

function printSummary(v: Awaited<ReturnType<typeof verify>>): void {
  const f = (x: number) => (Number.isFinite(x) ? x.toFixed(0) : "-");
  console.log("\n════════ load summary ════════");
  console.log(`run ${v.run} (${v.latency.proxyMs}±${v.latency.jitterMs} ms RPC latency, ${v.blockTimeS} s blocks)`);
  console.log(`posts ${v.posts.total} (accepted ${v.posts.accepted}); bad ${json(v.posts.bad)}`);
  console.log(`fills on-chain ${v.fills.onChain} (inventory ${v.fills.inventory}, route ${v.fills.route}); expected ${v.fills.expectedFill}, filled ${v.fills.expectedFillFilled}; short-prof ${v.fills.shortProfFilled}/${v.fills.shortProf}; never-filled violations ${v.fills.neverFilled}; cancel races ${v.fills.cancelRaces}`);
  console.log(`latency post→mined p50 ${f(v.latencyMs.postToMined.p50)} p95 ${f(v.latencyMs.postToMined.p95)} ms; post→send p50 ${f(v.latencyMs.postToSend.p50)}; send→mined p50 ${f(v.latencyMs.sendToMined.p50)}; mined→indexed p50 ${f(v.latencyMs.minedToIndexed.p50)}`);
  console.log(`throughput ${v.throughput.fillsPerMinActive.toFixed(1)} fills/min active (busiest 60 s: ${v.throughput.busiest60s}; ceiling ${v.throughput.ceilingPerMin}/min)`);
  const ft = v.ticks.filler;
  console.log(`filler ticks (RPC timeline) ${ft.fromTimeline.ticks}: RPC/tick p50 ${f(ft.fromTimeline.rpcPerTick.p50)} p95 ${f(ft.fromTimeline.rpcPerTick.p95)} max ${f(ft.fromTimeline.rpcPerTick.max)}; span max ${f(ft.fromTimeline.rpcSpanMs.max)} ms`);
  console.log(`filler ticks (/status, ${ft.fromStatus.samples} samples): subrequests p50 ${f(ft.fromStatus.subrequests.p50)} max ${f(ft.fromStatus.subrequests.max)}; duration p50 ${f(ft.fromStatus.durationMs.p50)} max ${f(ft.fromStatus.durationMs.max)} ms; traces captured ${ft.fromTraces.captured}`);
  console.log(`book alarms ${v.ticks.orderbook.alarms} (every ${f(v.ticks.orderbook.intervalS.p50)} s); traces captured ${v.ticks.orderbook.fromTraces.captured}, wall max ${f(v.ticks.orderbook.fromTraces.wallMs.max)} ms`);
  console.log(`abuser ${v.rateLimit.abuser.requests} req (${v.rateLimit.abuser.perSecond.toFixed(0)}/s): ${json(v.rateLimit.abuser.statuses)}; readers 429 ${v.rateLimit.readers429}/${v.rateLimit.readersTotal}`);
  console.log(`operator txs ${v.txs.operator}, reverts ${v.txs.reverts.length}, nonce clashes ${v.txs.nonceClashes.length}`);
  console.log(`failures (${v.failures.length}):`);
  for (const x of v.failures.slice(0, 40)) console.log(`  ✗ ${x}`);
  for (const x of v.notes.slice(0, 20)) console.log(`  · ${x}`);
}

/** `load.ts --verify`: re-run the verification on the saved records of LOAD_LABEL. */
async function verifyOnly(): Promise<void> {
  const raw = JSON.parse(readFileSync(join(env.runDir, "results", `${P.label}-records.json`), "utf8")) as Records & { posted: Array<Posted & { order: unknown }> };
  const big = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, BigInt(String(v))])) as never;
  raw.posted = raw.posted.map((p) => ({ ...p, order: orderFromJson(p.order), owed: BigInt(String(p.owed)), amountIn: BigInt(String(p.amountIn)), ...(p.quoteOut !== undefined ? { quoteOut: BigInt(String(p.quoteOut)) } : {}) }));
  raw.operatorStart = big(raw.operatorStart as never);
  raw.treasuryStart = big(raw.treasuryStart as never);
  const verdict = await verify(raw);
  writeResult(P.label, verdict);
  printSummary(verdict);
  if (verdict.failures.length) process.exitCode = 1;
}

if (process.argv.includes("--verify")) await verifyOnly();
else await main();
process.exit(process.exitCode ?? 0);

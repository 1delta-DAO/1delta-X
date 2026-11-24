/**
 * SwaptoX vs the filler's other route sources (LOCAL ONLY, read-only — sends nothing).
 *
 *   SWAPTOX_API_KEY=… npx tsx e2e/swaptox-probe.ts                 # quote matrix (mainnet)
 *   SWAPTOX_API_KEY=… FORK_RPC=http://127.0.0.1:8545 npx tsx e2e/swaptox-probe.ts   # + execution
 *
 * 1. QUOTES. For each pair × ticket size, the REAL route filler (`quoteRoute`, the code
 *    behind the app's `/quote`) prices a PULL ticket with the production config (the
 *    Worker's wrangler.toml [vars]) and one source at a time — pools only, Sushi only,
 *    Nordstern only, SwaptoX only — and then everything together, which is what the app
 *    would show. "net" = gross route output − the fill's cost (gas + min profit) in the
 *    output token. Read against the live beta solver as its operator (no key needed:
 *    nothing is signed). "app shows" runs SwaptoX at its production timeouts (by ticket
 *    size: 2.5 s / 5 s on a quote); "uncapped" and "net swaptox" lift them, to show what
 *    the deadlines drop.
 * 2. EXECUTION (FORK_RPC set: an anvil fork of Rootstock). For each case the SwaptoX
 *    route's router call — encoded exactly as the filler encodes it — is run from a
 *    token holder (impersonated, approved) with `eth_call` + `eth_estimateGas`: what it
 *    delivers vs the API's `amountOut`, and its gas vs the API's `gas`.
 */
import { readFileSync } from "node:fs";

import { createPublicClient, erc20Abi, formatUnits, getAddress, http, maxUint256, parseUnits, zeroAddress, type Address, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { connect, readSendGasPrice, type Chain } from "../src/chain";
import { loadConfig, ROOTSTOCK } from "../src/config";
import { Guard } from "../src/guard";
import { Budget } from "../src/policy";
import { RouteFiller } from "../src/routeFiller";
import { encodeSwaptoxSwap, fetchSwaptoxRoute, SWAPTOX_ROUTER_ABI } from "../src/swaptox";

const HERE = new URL(".", import.meta.url).pathname;
/** The live beta solver's operator (read-only: `isOperator` is all init checks). */
const OPERATOR = getAddress("0xcafe35944e3195d59b4a354Ea23D60a0445c083a");

const T: Record<string, { a: Address; d: number; usd: number; holder: Address }> = {
  WRBTC: { a: ROOTSTOCK.wrbtc as Address, d: 18, usd: 0, holder: getAddress("0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd") },
  USDT0: { a: ROOTSTOCK.usdt0 as Address, d: 6, usd: 1, holder: getAddress("0xaef6fabf3b0c9e5f9d6d5170afc703a633479bbd") },
  USDRIF: { a: ROOTSTOCK.usdrif as Address, d: 18, usd: 1, holder: getAddress("0xd845702af381f0405661747a6a20bde0401a19d6") },
  RIF: { a: ROOTSTOCK.rif as Address, d: 18, usd: 0, holder: getAddress("0x57079b2d3071eb06cce6dbafb9b0306bcc49b020") },
};
const ALL_PAIRS: Array<[string, string]> = [
  ["WRBTC", "USDT0"],
  ["USDT0", "WRBTC"],
  ["USDRIF", "USDT0"],
  ["USDT0", "USDRIF"],
  ["USDT0", "RIF"],
  ["RIF", "USDT0"],
  ["WRBTC", "USDRIF"],
  ["RIF", "WRBTC"],
];
/** `PAIRS=WRBTC>USDT0,USDT0>RIF` narrows the matrix. */
const PAIRS = process.env.PAIRS ? process.env.PAIRS.split(",").map((p) => p.split(">") as [string, string]) : ALL_PAIRS;
const SIZES_USD = (process.env.SIZES_USD ?? "10,100,1000,10000").split(",").map(Number);

/** The Worker's [vars] — the production knobs — as an env map. */
function workerVars(): Record<string, string> {
  const toml = readFileSync(`${HERE}/../../filler-worker/wrangler.toml`, "utf8");
  const vars = toml.slice(toml.indexOf("[vars]"));
  const env: Record<string, string> = {};
  for (const line of vars.split("\n")) {
    const m = /^([A-Z0-9_]+)\s*=\s*"([^"]*)"/.exec(line.trim());
    if (m) env[m[1]!] = m[2]!;
  }
  return env;
}

const BASE = {
  ...workerVars(),
  PRIVATE_KEY: "0x" + "11".repeat(32),
  ORDERBOOK_URL: "http://unused.invalid",
  ...(process.env.RPC_URL ? { RPC_URL: process.env.RPC_URL } : {}),
  SWAPTOX_API_KEY: process.env.SWAPTOX_API_KEY ?? "",
};
const VARIANTS: Record<string, Record<string, string>> = {
  pools: { SUSHI_ENABLED: "0", NORDSTERN_ENABLED: "0", SWAPTOX_ENABLED: "0" },
  sushi: { ROUTE_OKU_PULL: "0", SUSHI_ENABLED: "1", NORDSTERN_ENABLED: "0", SWAPTOX_ENABLED: "0" },
  nordstern: { ROUTE_OKU_PULL: "0", SUSHI_ENABLED: "0", NORDSTERN_ENABLED: "1", SWAPTOX_ENABLED: "0" },
  swaptox: { ROUTE_OKU_PULL: "0", SUSHI_ENABLED: "0", NORDSTERN_ENABLED: "0", SWAPTOX_ENABLED: "1" },
  all: { SWAPTOX_ENABLED: "1" },
};
/** Variants that run with SwaptoX's timeouts lifted (the config caps them at 3 s): what the cap costs. */
const UNCAPPED = new Set(["swaptox∞", "all∞"]);
VARIANTS["swaptox∞"] = VARIANTS.swaptox!;
VARIANTS["all∞"] = VARIANTS.all!;

function filler(over: Record<string, string>, uncapped = false): RouteFiller {
  const cfg = loadConfig({ ...BASE, ...over });
  if (uncapped) Object.assign(cfg.route!.swaptox, { timeoutMs: 30_000, quoteTimeoutMs: 30_000 });
  const c = connect(cfg);
  const chain: Chain = { ...c, me: OPERATOR };
  return new RouteFiller(cfg, chain, new Budget({}), () => {}, () => {}, new Guard(cfg.gas));
}

const fmt = (v: bigint | undefined, d: number) => (v === undefined ? "—" : Number(formatUnits(v, d)).toPrecision(7));

async function usdPrices(): Promise<void> {
  const r = (await (await fetch("https://api-v2.swaptox.com/rootstock/tokens")).json()) as { data: Array<{ address: string; usd_buy?: string }> };
  for (const t of Object.values(T)) {
    if (t.usd) continue;
    const row = r.data.find((x) => x.address.toLowerCase() === t.a.toLowerCase());
    t.usd = Number(row?.usd_buy ?? 0);
    if (!t.usd) throw new Error(`no USD price for ${t.a}`);
  }
}

async function quotes(): Promise<Array<{ a: string; b: string; amountIn: bigint }>> {
  const fillers = Object.fromEntries(Object.entries(VARIANTS).map(([k, v]) => [k, filler(v, UNCAPPED.has(k))])) as Record<string, RouteFiller>;
  const cfg = loadConfig(BASE);
  const pub = connect(cfg).pub;
  const gp = (await readSendGasPrice(pub, cfg.gas.minGasPriceMultBps)).wei;
  console.log(`gas price ${gp} wei · RBTC $${T.WRBTC!.usd.toFixed(0)} · RIF $${T.RIF!.usd.toFixed(4)} · net = route output − fill cost (gas + min profit), pull delivery\n`);
  // Graph discovery once per filler, before the timed calls.
  await Promise.all(Object.values(fillers).map((f) => f.init()));
  const cases: Array<{ a: string; b: string; amountIn: bigint }> = [];
  const rows: string[][] = [];
  let nordReason = "";
  for (const [a, b] of PAIRS) {
    for (const usd of SIZES_USD) {
      const ti = T[a]!;
      const to = T[b]!;
      const amountIn = parseUnits((usd / ti.usd).toFixed(Math.min(ti.d, 8)), ti.d);
      cases.push({ a, b, amountIn });
      const req = { tokenIn: ti.a, tokenOut: to.a, amountIn, direct: false, gasPrice: gp };
      const timed = async (f: RouteFiller) => {
        const t0 = Date.now();
        const v = await f.quoteRoute(req);
        return { v, ms: Date.now() - t0 };
      };
      const res = await Promise.all(Object.keys(VARIANTS).map(async (k) => [k, await timed(fillers[k]!)] as const));
      const by = Object.fromEntries(res);
      const net = (k: string) => {
        const v = by[k]!.v;
        return v.ok ? v.candidate.grossOut - v.candidate.costOut : undefined;
      };
      const best = ["pools", "sushi", "nordstern", "swaptox∞"].filter((k) => net(k) !== undefined).sort((x, y) => (net(y)! > net(x)! ? 1 : net(y)! < net(x)! ? -1 : 0))[0];
      const all = by.all!.v;
      const sx = by["swaptox∞"]!;
      const allU = by["all∞"]!.v;
      // SwaptoX's edge over the best other source, net, in bps.
      const others = ["pools", "sushi", "nordstern"].map(net).filter((v): v is bigint => v !== undefined);
      const rival = others.length ? others.reduce((x, y) => (y > x ? y : x)) : undefined;
      const sxNet = net("swaptox∞");
      const edge = sxNet !== undefined && rival ? `${((Number(sxNet - rival) / Number(rival)) * 1e4).toFixed(1)}` : "—";
      rows.push([
        `${a}→${b}`,
        `$${usd}`,
        fmt(net("pools"), to.d),
        fmt(net("sushi"), to.d),
        fmt(net("nordstern"), to.d),
        fmt(sxNet, to.d),
        `${sx.ms}ms`,
        edge,
        best === "swaptox∞" ? "SWAPTOX" : (best ?? "—"),
        all.ok ? all.candidate.source : "✗",
        allU.ok ? allU.candidate.source : "✗",
      ]);
      if (!by.nordstern!.v.ok && !nordReason) nordReason = by.nordstern!.v.reason;
      process.stdout.write(".");
    }
  }
  process.stdout.write("\n");
  const head = ["pair", "size", "net pools", "net sushi", "net nordstern", "net swaptox", "swaptox api", "edge bps", "best net", "app shows (prod timeouts)", "uncapped"];
  const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i]!.length)));
  const line = (r: string[]) => r.map((c, i) => c.padEnd(w[i]!)).join("  ");
  console.log(line(head));
  for (const r of rows) console.log(line(r));
  if (nordReason) console.log(`(nordstern: ${nordReason})`);
  return cases;
}

async function execution(fork: string, cases: Array<{ a: string; b: string; amountIn: bigint }>): Promise<void> {
  const pub = createPublicClient({ transport: http(fork, { timeout: 120_000 }) }) as PublicClient;
  const cfg = loadConfig({ ...BASE, SWAPTOX_ENABLED: "1" }).route!.swaptox;
  const rpc = (method: string, params: unknown[]) => pub.request({ method: method as never, params: params as never });
  console.log(`\nEXECUTION on ${fork}: the router call as the filler encodes it, from a token holder (recipient = the holder)`);
  const head = ["pair", "amountIn", "steps", "api amountOut", "executed", "Δ bps", "api gas", "estimateGas", "ratio"];
  const rows: string[][] = [];
  for (const { a, b, amountIn } of cases) {
    const ti = T[a]!;
    const to = T[b]!;
    const q = await fetchSwaptoxRoute({ ...cfg, timeoutMs: 30_000 }, { chainId: 30, tokenIn: ti.a, tokenOut: to.a, amountIn });
    if (!q.ok) {
      rows.push([`${a}→${b}`, fmt(amountIn, ti.d), "—", `✗ ${q.reason.slice(0, 40)}`, "", "", "", "", ""]);
      continue;
    }
    const from = ti.holder;
    await rpc("anvil_impersonateAccount", [from]);
    await rpc("anvil_setBalance", [from, "0x56BC75E2D63100000"]);
    const bal = await pub.readContract({ address: ti.a, abi: erc20Abi, functionName: "balanceOf", args: [from] });
    if (bal < amountIn) {
      rows.push([`${a}→${b}`, fmt(amountIn, ti.d), "", `holder has only ${fmt(bal, ti.d)}`, "", "", "", "", ""]);
      continue;
    }
    // The holder is a pool, and the route may swap through it: hand the input to a fresh
    // account first so the swap never reads a pool's balance mid-transfer.
    const user = privateKeyToAccount(("0x" + "ab".repeat(31) + (rows.length + 16).toString(16).padStart(2, "0")) as Hex).address;
    await rpc("anvil_setBalance", [user, "0x56BC75E2D63100000"]);
    await rpc("anvil_impersonateAccount", [user]);
    const send = async (f: Address, to_: Address, data: Hex) => {
      const hash = (await rpc("eth_sendTransaction", [{ from: f, to: to_, data }])) as Hex;
      await pub.waitForTransactionReceipt({ hash });
    };
    const { encodeFunctionData } = await import("viem");
    await send(from, ti.a, encodeFunctionData({ abi: erc20Abi, functionName: "transfer", args: [user, amountIn] }));
    await send(user, ti.a, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [cfg.router, maxUint256] }));
    const data = encodeSwaptoxSwap({ quote: q, recipient: user, amountMinOut: 1n, deadline: BigInt(Math.floor(Date.now() / 1000) + 3600), referral: zeroAddress });
    let out: bigint | undefined;
    let gas: bigint | undefined;
    let err = "";
    try {
      const r = await pub.call({ account: user, to: cfg.router, data });
      const { decodeFunctionResult } = await import("viem");
      out = (decodeFunctionResult({ abi: SWAPTOX_ROUTER_ABI, functionName: "swap", data: r.data! }) as readonly [bigint, bigint])[0];
      gas = await pub.estimateGas({ account: user, to: cfg.router, data });
    } catch (e) {
      err = (e as Error).message.split("\n")[0]!.slice(0, 60);
    }
    const dBps = out !== undefined ? (Number(out - q.amountOut) / Number(q.amountOut)) * 1e4 : undefined;
    const apiGas = (q.gasUnits * 100n) / cfg.gasMultPct;
    rows.push([
      `${a}→${b}`,
      fmt(amountIn, ti.d),
      String(q.pools.length),
      fmt(q.amountOut, to.d),
      out !== undefined ? fmt(out, to.d) : `✗ ${err}`,
      dBps !== undefined ? dBps.toFixed(2) : "",
      apiGas.toString(),
      gas?.toString() ?? "",
      gas ? (Number(gas) / Number(apiGas)).toFixed(2) : "",
    ]);
    process.stdout.write(".");
  }
  process.stdout.write("\n");
  const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i]!.length)));
  const line = (r: string[]) => r.map((c, i) => c.padEnd(w[i]!)).join("  ");
  console.log(line(head));
  for (const r of rows) console.log(line(r));
  console.log("(estimateGas is the whole router tx on anvil's Cancun schedule, 21k intrinsic included; Rootstock's schedule differs — the fork fill in e2e/fork-e2e.sh is the Rootstock-shaped figure)");
}

await usdPrices();
const cases = await quotes();
if (process.env.FORK_RPC) await execution(process.env.FORK_RPC, cases);

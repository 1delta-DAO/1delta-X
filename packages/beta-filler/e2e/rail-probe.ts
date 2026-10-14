/**
 * MoC rail vs DEX aggregators, gas included (LOCAL ONLY, read-only — sends nothing).
 *
 *   npx tsx e2e/rail-probe.ts            # RPC_URL defaults to the 1delta gateway
 *
 * For USD0 ⇄ RIF and USD0 ⇄ RIFP at $10 / $100 / $1k / $10k, prices:
 *   • pool  — QuoterV2 over the Uniswap (Oku) pools the filler routes (best path);
 *   • sushi — Sushi's swap/v7 API (`assumedAmountOut`, its `gasSpent`);
 *   • nord  — Nordstern's aggregator API (`toAmount`, its `gasEstimate`);
 *   • rail  — the MoC conversion at its own price (USDRIF ⇄ RIF via redeemTP / mintTP at
 *             getPACtp, 0.2 %; RIFP ⇄ RIF via mintTC / redeemTC at getPTCac, 0.15 %)
 *             plus the pool legs it needs, filled from inventory and rebalanced after.
 * Every figure is turned into the USD the user ends up with, minus the gas the fill (and,
 * for the rail, its rebalance) costs at the live minimum gas price × 1.03.
 *
 * Gas model (Rootstock gas units; scripts/rsk-gas sim + the live receipts):
 *   pool fill 1 hop 204k / 2 hops 269k (direct, solver) · API route fill 160k + the API's
 *   own route gas · rail: inventory fill 200k + rebalance tx 450k + MoC exec fee
 *   (execCost × basefee), shown per trade AND amortized over $1k batches.
 */
import { encodePacked, formatUnits, parseAbi, parseUnits, createPublicClient, http, type Address, type Hex } from "viem";

const RPC = process.env.RPC_URL ?? "https://rpc-gateway.1delta.io/30";
const c = createPublicClient({ transport: http(RPC, { timeout: 20_000 }) });
const T = {
  USD0: { a: "0x779ded0c9e1022225f8e0630b35a9b54be713736" as Address, d: 6 },
  USDRIF: { a: "0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37" as Address, d: 18 },
  RIF: { a: "0x2acc95758f8b5f583470ba265eb685a8f45fc9d5" as Address, d: 18 },
  RIFP: { a: "0xf4d27c56595ed59b66cc7f03cff5193e4bd74a61" as Address, d: 18 },
  WRBTC: { a: "0x542fda317318ebf1d3deaf76e0b632741a7e677d" as Address, d: 18 },
};
type Sym = keyof typeof T;
const QUOTER = "0xb51727c996c68e60f598a923a5006853cd2feb31" as Address;
const MOC = "0xa27024ed70035e46dba712609fc2afa1c97aa36a" as Address;
const QUEUE = "0x47f5014115d3bb29b20b5168ee75050d6f8c3bf1" as Address;
const SOLVER = "0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1";
const qAbi = parseAbi(["function quoteExactInput(bytes path, uint256 amountIn) returns (uint256, uint160[], uint32[], uint256)"]);
const mAbi = parseAbi(["function getPACtp(address) view returns (uint256)", "function getPTCac() view returns (uint256)", "function tcMintFee() view returns (uint256)", "function tcRedeemFee() view returns (uint256)"]);
const queueAbi = parseAbi(["function getExecFee(uint8) view returns (uint256)"]);

/** Oku pool paths (swap order) the filler can route, per pair. */
const POOL_PATHS: Record<string, { tokens: Sym[]; fees: number[] }[]> = {
  "USD0>RIF": [{ tokens: ["USD0", "RIF"], fees: [3000] }, { tokens: ["USD0", "WRBTC", "RIF"], fees: [3000, 3000] }],
  "RIF>USD0": [{ tokens: ["RIF", "USD0"], fees: [3000] }, { tokens: ["RIF", "WRBTC", "USD0"], fees: [3000, 3000] }],
  "USD0>USDRIF": [{ tokens: ["USD0", "USDRIF"], fees: [500] }],
  "USDRIF>USD0": [{ tokens: ["USDRIF", "USD0"], fees: [500] }],
  "RIF>RIFP": [{ tokens: ["RIF", "RIFP"], fees: [3000] }],
  "RIFP>RIF": [{ tokens: ["RIFP", "RIF"], fees: [3000] }],
  "USD0>RIFP": [{ tokens: ["USD0", "RIF", "RIFP"], fees: [3000, 3000] }],
  "RIFP>USD0": [{ tokens: ["RIFP", "RIF", "USD0"], fees: [3000, 3000] }],
};

async function poolBest(from: Sym, to: Sym, amt: bigint): Promise<{ out: bigint; hops: number }> {
  let best = { out: 0n, hops: 0 };
  for (const p of POOL_PATHS[`${from}>${to}`] ?? []) {
    const types: string[] = [];
    const vals: unknown[] = [];
    p.tokens.forEach((s, i) => {
      types.push("address");
      vals.push(T[s].a);
      if (i < p.fees.length) {
        types.push("uint24");
        vals.push(p.fees[i]);
      }
    });
    try {
      const r = await c.simulateContract({ address: QUOTER, abi: qAbi, functionName: "quoteExactInput", args: [encodePacked(types, vals) as Hex, amt] });
      if (r.result[0] > best.out) best = { out: r.result[0], hops: p.fees.length };
    } catch {
      /* no liquidity on that path */
    }
  }
  return best;
}

async function sushi(from: Sym, to: Sym, amt: bigint): Promise<{ out: bigint; gas: number } | null> {
  try {
    const u = `https://api.sushi.com/swap/v7/30?tokenIn=${T[from].a}&tokenOut=${T[to].a}&amount=${amt}&maxSlippage=0.005&sender=${SOLVER}`;
    const j = (await (await fetch(u, { signal: AbortSignal.timeout(8000) })).json()) as { assumedAmountOut?: string; gasSpent?: number };
    return j.assumedAmountOut ? { out: BigInt(j.assumedAmountOut), gas: Number(j.gasSpent ?? 0) } : null;
  } catch {
    return null;
  }
}

async function nord(from: Sym, to: Sym, amt: bigint): Promise<{ out: bigint; gas: number } | null> {
  try {
    const u = `https://api.nordstern.finance/aggregator/30?src=${T[from].a}&dst=${T[to].a}&amount=${amt}&from=${SOLVER}&slippage=0.5`;
    const j = (await (await fetch(u, { headers: { Referer: "https://1delta-x.pages.dev" }, signal: AbortSignal.timeout(8000) })).json()) as { toAmount?: string; gasEstimate?: number };
    return j.toAmount ? { out: BigInt(j.toAmount), gas: Number(j.gasEstimate ?? 0) } : null;
  } catch {
    return null;
  }
}

const main = async () => {
  const block = (await c.request({ method: "eth_getBlockByNumber" as never, params: ["latest", false] as never })) as { minimumGasPrice?: Hex };
  const minGas = BigInt(block.minimumGasPrice ?? "0x1699a00");
  const gasPrice = (minGas * 103n) / 100n;
  const usd = (await (await fetch("https://api.sushi.com/price/v1/30")).json()) as Record<string, number>;
  let pxRifp = 0;
  const px = (s: Sym) => usd[T[s].a] ?? (s === "USD0" ? 1 : s === "RIFP" ? pxRifp : 0);
  const rbtcUsd = px("WRBTC");
  const gasUsd = (units: number) => (units * Number(gasPrice) * rbtcUsd) / 1e18;

  const pACtp = (await c.readContract({ address: MOC, abi: mAbi, functionName: "getPACtp", args: [T.USDRIF.a] })) as bigint; // USDRIF per RIF, 1e18
  const pTCac = (await c.readContract({ address: MOC, abi: mAbi, functionName: "getPTCac" })) as bigint; // RIF per RIFP, 1e18
  const tcFee = (await c.readContract({ address: MOC, abi: mAbi, functionName: "tcMintFee" })) as bigint;
  const execRedeemTP = (await c.readContract({ address: QUEUE, abi: queueAbi, functionName: "getExecFee", args: [4] })) as bigint;
  const execMintTP = (await c.readContract({ address: QUEUE, abi: queueAbi, functionName: "getExecFee", args: [3] })) as bigint;
  const execTC = (await c.readContract({ address: QUEUE, abi: queueAbi, functionName: "getExecFee", args: [1] })) as bigint;
  // RIFP is not in Sushi's price table: value it at MoC's price × RIF's USD price.
  pxRifp = Number(formatUnits(pTCac, 18)) * (usd[T.RIF.a] ?? 0);
  const TP_FEE = 2_000_000_000_000_000n; // 0.2 %
  const E18 = 10n ** 18n;
  const weiUsd = (w: bigint) => (Number(w) * rbtcUsd) / 1e18;

  // MoC conversions (exact-in), fees taken in the collateral (RIF).
  const redeemTP = (usdrif: bigint) => ((usdrif * E18) / pACtp) * (E18 - TP_FEE) / E18; // USDRIF → RIF
  const mintTP = (rif: bigint) => (((rif * (E18 - TP_FEE)) / E18) * pACtp) / E18; // RIF → USDRIF
  const mintTC = (rif: bigint) => (((rif * (E18 - tcFee)) / E18) * E18) / pTCac; // RIF → RIFP
  const redeemTC = (rifp: bigint) => (((rifp * pTCac) / E18) * (E18 - tcFee)) / E18; // RIFP → RIF

  console.log(`gas price ${gasPrice} wei · RBTC $${rbtcUsd.toFixed(0)} · RIF oracle ${formatUnits(pACtp, 18)} USDRIF · RIFP ${formatUnits(pTCac, 18)} RIF · 1k gas = $${gasUsd(1000).toFixed(4)}`);
  console.log(`USD prices (Sushi): RIF $${px("RIF").toFixed(5)} RIFP $${px("RIFP").toFixed(5)} USDRIF $${px("USDRIF").toFixed(5)}\n`);

  const RAIL_FILL = 200_000;
  const REBAL = 450_000;
  type Row = { src: string; out: bigint; gas: number; extraUsd?: number };
  const only = process.env.PAIRS?.split(",");
  const all: [Sym, Sym][] = [["USD0", "RIF"], ["RIF", "USD0"], ["USD0", "RIFP"], ["RIFP", "USD0"], ["USDRIF", "USD0"], ["USD0", "USDRIF"]];
  const pairs = only ? all.filter(([a, b]) => only.includes(`${a}>${b}`)) : all;
  for (const [from, to] of pairs) {
    console.log(`── ${from} → ${to}`);
    for (const usdIn of [10, 100, 1_000, 10_000]) {
      const amt = parseUnits((usdIn / px(from)).toFixed(T[from].d === 6 ? 6 : 12), T[from].d);
      const rows: Row[] = [];
      const pool = await poolBest(from, to, amt);
      if (pool.out > 0n) rows.push({ src: `pool(${pool.hops}h)`, out: pool.out, gas: pool.hops > 1 ? 269_000 : 204_000 });
      const [s, n] = await Promise.all([sushi(from, to, amt), nord(from, to, amt)]);
      if (s) rows.push({ src: "sushi", out: s.out, gas: 160_000 + s.gas });
      if (n) rows.push({ src: "nord", out: n.out, gas: 160_000 + n.gas });
      // The rail.
      let rail: bigint | null = null;
      let exec = 0n;
      if (from === "USD0" && to === "RIF") {
        const u = (await poolBest("USD0", "USDRIF", amt)).out;
        rail = redeemTP(u);
        exec = execRedeemTP;
      } else if (from === "RIF" && to === "USD0") {
        rail = (await poolBest("USDRIF", "USD0", mintTP(amt))).out;
        exec = execMintTP;
      } else if (from === "USD0" && to === "RIFP") {
        const u = (await poolBest("USD0", "USDRIF", amt)).out;
        rail = mintTC(redeemTP(u)); // USD0 → USDRIF (pool) → RIF (redeemTP) → RIFP (mintTC)
        exec = execRedeemTP + execTC;
      } else if (from === "RIFP" && to === "USD0") {
        rail = (await poolBest("USDRIF", "USD0", mintTP(redeemTC(amt)))).out; // RIFP → RIF → USDRIF → USD0
        exec = execMintTP + execTC;
      } else if (from === "USDRIF" && to === "USD0") {
        // The inventory strategy's exit: redeem USDRIF → RIF at the oracle, sell RIF → USD0 on the pools.
        rail = (await poolBest("RIF", "USD0", redeemTP(amt))).out;
        exec = execRedeemTP;
      } else if (from === "USD0" && to === "USDRIF") {
        // The mirror: buy RIF on the pools, mint USDRIF at the oracle.
        rail = mintTP((await poolBest("USD0", "RIF", amt)).out);
        exec = execMintTP;
      }
      if (rail) {
        rows.push({ src: "rail/trade", out: rail, gas: RAIL_FILL + REBAL, extraUsd: weiUsd(exec) });
        const share = Math.min(1, usdIn / 1000);
        rows.push({ src: "rail/$1k", out: rail, gas: RAIL_FILL + REBAL * share, extraUsd: weiUsd(exec) * share });
      }
      const scored = rows.map((r) => {
        const outUsd = Number(formatUnits(r.out, T[to].d)) * px(to);
        const cost = gasUsd(r.gas) + (r.extraUsd ?? 0);
        return { ...r, outUsd, cost, net: outUsd - cost };
      });
      const best = Math.max(...scored.filter((r) => !r.src.startsWith("rail")).map((r) => r.net));
      const line = scored
        .map((r) => `${r.src} ${r.net.toFixed(2)}${best > 0 && r.src.startsWith("rail") ? ` (${(((r.net - best) / usdIn) * 100).toFixed(2)}%)` : ""}`)
        .join(" | ");
      console.log(`  $${usdIn}: ${line}`);
    }
  }
};

void main();

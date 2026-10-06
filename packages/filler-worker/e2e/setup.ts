/**
 * Staging-harness chain setup (LOCAL ONLY, run by staging.sh against the anvil fork).
 *
 *   tsx e2e/setup.ts pre-deploy    fund the deployer 1e6 wei of each FLOOR_TOKENS token
 *   tsx e2e/setup.ts post-deploy   keep the MoC oracle alive, fund the operator, price
 *                                  RBTC, write $RUN_DIR/env.json
 *
 * Only anvil's well-known dev keys and keccak-derived test keys are used.
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { getAddress, numberToHex, pad, parseEther, parseUnits, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { balanceOf, deal, json, publicClient, quote, rpc, setBalance, USDRIF, USDT0, WETH, WRBTC, type StagingEnv } from "./lib";

const e = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined || v === "") throw new Error(`setup: missing env ${k}`);
  return v;
};

const anvilUrl = e("ANVIL_URL");
const pub = publicClient({ anvilUrl });
const mode = process.argv[2];

/** The OMoC price provider MoC reads for USDRIF (traced on the fork, 2026-10-05). */
const MOC_PRICE_PROVIDER = "0xaFb1B8C320ACc776c1279bcDB24Ab8F84aB727A4" as Address;
/** Its "valid for N blocks after publication" word (20 on mainnet ≈ 10 min at 30 s blocks). */
const MOC_VALIDITY_SLOT = pad("0x79", { size: 32 });
const MOC_CORE = "0xA27024Ed70035E46dba712609fc2Afa1c97aA36A" as Address;
const MOC_ABI = [{ type: "function", name: "getPACtp", stateMutability: "view", inputs: [{ name: "tp", type: "address" }], outputs: [{ type: "uint256" }] }] as const;

async function preDeploy(): Promise<void> {
  const deployer = privateKeyToAccount(e("DEPLOYER_KEY") as Hex).address;
  for (const t of [WRBTC, USDT0, WETH, USDRIF]) await deal(pub, t, deployer, 1_000_000n);
  console.log(`setup: deployer ${deployer} holds 1e6 wei of WRBTC/USDT0/WETH/USDRIF (FLOOR_TOKENS)`);
}

async function postDeploy(): Promise<void> {
  // 1. MoC oracle keep-alive. On a fork nobody publishes prices, and with 2 s blocks
  //    the provider's 20-block validity lapses after ~40 s: getPACtp then reverts
  //    MissingProviderPrice and the inventory strategy cannot price its exit. A
  //    fork artefact — widen the window so the fork-block price stays valid.
  await rpc(pub, "anvil_setStorageAt", [MOC_PRICE_PROVIDER, MOC_VALIDITY_SLOT, pad(numberToHex(1_000_000_000n), { size: 32 })]);
  let pACtp = 0n;
  try {
    pACtp = await pub.readContract({ address: MOC_CORE, abi: MOC_ABI, functionName: "getPACtp", args: [USDRIF] });
  } catch (err) {
    console.log(`setup: ⚠ MoC getPACtp still reverts after the keep-alive (${(err as Error).message.split("\n")[0]}) — inventory fills will fail over to route`);
  }

  // 2. The operator (filler hot wallet, anvil dev key #1): gas + inventory.
  const operatorKey = e("OPERATOR_KEY") as Hex;
  const operator = privateKeyToAccount(operatorKey).address;
  await setBalance(pub, operator, parseEther(e("OPERATOR_RBTC", "10")));
  await deal(pub, USDT0, operator, parseUnits(e("OPERATOR_USDT0", "20000"), 6));
  await deal(pub, USDRIF, operator, parseUnits(e("OPERATOR_USDRIF", "500"), 18));

  // 3. RBTC price off the WRBTC/USDT0 pool (the filler prices gas at max(pool, RBTC_PRICE_USD)).
  const per1e15 = await quote(pub, [WRBTC, USDT0], [3000], 10n ** 15n);
  const rbtcUsd = Math.round(Number(per1e15) / 1e3);

  const env: StagingEnv = {
    label: e("LABEL", "run"),
    runDir: e("RUN_DIR"),
    anvilUrl,
    proxyUrl: e("PROXY_URL"),
    gatewayUrl: e("GATEWAY_URL"),
    explorerUrl: `${e("GATEWAY_URL")}/cdn-cgi/explorer/api`,
    forkUrl: e("FORK_URL"),
    forkBlock: Number(e("FORK_BLOCK")),
    startBlock: Number(e("START_BLOCK")),
    blockTimeS: Number(e("BLOCK_TIME")),
    chainId: 30,
    permit3: getAddress(e("PERMIT3")),
    settlement: getAddress(e("SETTLEMENT")),
    lens: getAddress(e("LENS")),
    solver: getAddress(e("SOLVER")),
    sandbox: getAddress(e("SANDBOX")),
    operator,
    operatorKey,
    deployerKey: e("DEPLOYER_KEY") as Hex,
    treasury: getAddress(e("TREASURY")),
    adminToken: e("ADMIN_TOKEN"),
    bindingKey: e("BINDING_KEY"),
    rbtcUsd,
    gasPriceWei: e("GAS_PRICE_WEI"),
    latencyMs: Number(e("LATENCY_MS", "0")),
    jitterMs: Number(e("JITTER_MS", "0")),
    workerVars: { orderbook: {}, filler: {} },
  };
  writeFileSync(join(env.runDir, "env.json"), json(env));
  const [u, r] = await Promise.all([balanceOf(pub, USDT0, operator), balanceOf(pub, USDRIF, operator)]);
  console.log(`setup: operator ${operator}: 10 RBTC, ${u} USDT0 units, ${r} USDRIF wei; MoC pACtp ${pACtp}; RBTC ≈ $${rbtcUsd} (pool)`);
  // Machine-readable line for staging.sh.
  console.log(`RBTC_USD=${rbtcUsd}`);
}

if (mode === "pre-deploy") await preDeploy();
else if (mode === "post-deploy") await postDeploy();
else throw new Error("usage: setup.ts pre-deploy|post-deploy");

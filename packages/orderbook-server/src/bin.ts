import { createPublicClient, http, parseAbi, type Address } from "viem";

import { loadEnv } from "./env";
import { buildServer } from "./server";

/**
 * The three deployment addresses arrive as three independent env vars. The
 * on-chain periphery refuses a lens whose `SETTLEMENT()` is not the settlement it
 * is paired with (the 7683 adapters check it in their constructors); a server
 * booted on a mis-set triple would verify signatures under one settlement's
 * domain and preview against another, or read Permit3 grants from the wrong hub
 * — the Morpho-App class of "the front-end names the wrong contract", on our own
 * config (F29 lead, B13). Refuse to start on a mismatch; skip when no RPC is set.
 */
async function assertDeploymentTriple(cfg: { rpcUrl: string; settlement: Address; permit3: Address; lens: Address }) {
  if (!cfg.rpcUrl) return;
  const client = createPublicClient({ transport: http(cfg.rpcUrl) });
  const lensAbi = parseAbi(["function SETTLEMENT() view returns (address)", "function PERMIT3() view returns (address)"]);
  const settlementAbi = parseAbi(["function PERMIT3() view returns (address)"]);
  const [lensSettlement, lensPermit3, settlementPermit3] = await Promise.all([
    client.readContract({ address: cfg.lens, abi: lensAbi, functionName: "SETTLEMENT" }),
    client.readContract({ address: cfg.lens, abi: lensAbi, functionName: "PERMIT3" }),
    client.readContract({ address: cfg.settlement, abi: settlementAbi, functionName: "PERMIT3" }),
  ]);
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  if (!same(lensSettlement, cfg.settlement)) {
    throw new Error(`LENS ${cfg.lens} serves settlement ${lensSettlement}, but SETTLEMENT is ${cfg.settlement}`);
  }
  if (!same(lensPermit3, cfg.permit3) || !same(settlementPermit3, cfg.permit3)) {
    throw new Error(`PERMIT3 ${cfg.permit3} does not match the lens (${lensPermit3}) / settlement (${settlementPermit3})`);
  }
}

/** CLI entrypoint: load env, cross-check the deployment, build the server, listen. */
async function main(): Promise<void> {
  const env = loadEnv();
  await assertDeploymentTriple(env.config as never);
  const server = await buildServer({
    config: env.config,
    admission: env.admission,
    rateLimit: env.rateLimit,
    watchChain: env.watchChain,
    indexFills: env.indexFills,
    ...(env.fillsFromBlock !== undefined ? { fillsFromBlock: env.fillsFromBlock } : {}),
    ...(env.ocoModules ? { ocoModules: env.ocoModules } : {}),
    logger: true,
  });
  await server.app.listen({ host: env.host, port: env.port });

  const shutdown = () => {
    server.close().then(() => process.exit(0)).catch(() => process.exit(1));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

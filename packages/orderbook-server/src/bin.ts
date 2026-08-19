import { loadEnv } from "./env";
import { buildServer } from "./server";

/** CLI entrypoint: load env, build the server, listen. */
async function main(): Promise<void> {
  const env = loadEnv();
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

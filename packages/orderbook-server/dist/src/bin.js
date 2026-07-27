import { loadEnv } from "./env";
import { buildServer } from "./server";
/** CLI entrypoint: load env, build the server, listen. */
async function main() {
    const { config, host, port } = loadEnv();
    const server = await buildServer({ config, logger: true });
    await server.app.listen({ host, port });
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

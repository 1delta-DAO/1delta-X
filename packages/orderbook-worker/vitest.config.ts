import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

/**
 * workerd's own "uncaught exception" lines. The pool forwards the runtime's
 * structured logs to THIS process's stderr; an exception thrown by the runtime
 * outside any JS call (e.g. the request-body pump into a Durable Object after the
 * object answered) never reaches the test, which still passes. Captured here and
 * served to tests over the `RUNTIME_ERRORS` service binding (a Node function), so a
 * test can assert the runtime logged none.
 */
const runtimeErrors: string[] = [];
for (const stream of [process.stdout, process.stderr]) {
  const write = stream.write.bind(stream) as (...a: unknown[]) => boolean;
  stream.write = ((chunk: unknown, ...rest: unknown[]) => {
    const text = typeof chunk === "string" ? chunk : chunk instanceof Uint8Array ? Buffer.from(chunk).toString("utf8") : "";
    for (const line of text.split("\n")) if (/uncaught exception/i.test(line)) runtimeErrors.push(line.slice(0, 400));
    return write(chunk, ...rest);
  }) as typeof stream.write;
}

/**
 * Two projects:
 *   • `workers` — runs INSIDE workerd (Miniflare) against the real SQLite Durable
 *     Object, alarms and storage; the chain/lens are stubbed through `setDepsFactory`.
 *   • `node` — the JSON-parity test against `orderbook-server`'s protobuf path,
 *     which cannot run in workerd (protobufjs needs `new Function`).
 */
export default defineConfig({
  test: {
    projects: [
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.toml" },
            miniflare: {
              bindings: {
                SETTLEMENT: "0x1111111111111111111111111111111111111111",
                PERMIT3: "0x2222222222222222222222222222222222222222",
                LENS: "0x3333333333333333333333333333333333333333",
                RPC_URL: "http://rpc.invalid",
                ALLOWED_TOKENS: "",
                MAX_ORDERS: "4",
                MAX_ORDERS_PER_MAKER: "3",
                RATE_LIMIT_IP_CAPACITY: "100",
                RATE_LIMIT_IP_REFILL: "0.01",
                RATE_LIMIT_MAKER_CAPACITY: "30",
                RATE_LIMIT_MAKER_REFILL: "0.01",
                CONFIRMATIONS: "0",
                MAX_LOG_RANGE: "100",
                BINDING_KEY: "test-binding-key",
              },
              serviceBindings: {
                RUNTIME_ERRORS: async () => Response.json(runtimeErrors),
              },
            },
          }),
        ],
        test: { name: "workers", include: ["test/*.test.ts"] },
      },
      {
        test: { name: "node", include: ["test/node/*.test.ts"], environment: "node" },
      },
    ],
  },
});

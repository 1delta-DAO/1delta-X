import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

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

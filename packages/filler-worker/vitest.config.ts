import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

/**
 * Runs INSIDE workerd (Miniflare) against the real SQLite Durable Object, its
 * alarms and storage. The chain, the book and the alert webhook are injected
 * fakes (`setDeps`, test/helpers.ts) — the suite is offline. The ORDERBOOK
 * service binding is a local handler serving an empty book.
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
                // anvil dev key #1 — test only.
                PRIVATE_KEY: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
                ADMIN_TOKEN: "test-admin-token-0123456789abcdef",
                ALERT_WEBHOOK_URL: "https://hooks.test/alert",
                SETTLEMENT: "0x1111111111111111111111111111111111111111",
                PERMIT3: "0x2222222222222222222222222222222222222222",
                LENS: "0x3333333333333333333333333333333333333333",
                AGGREGATOR_SOLVER: "0x00000000000000000000000000000000000050a1",
                INVENTORY_ENABLED: "0",
                SUSHI_ENABLED: "0",
                DRY_RUN: "0",
                RPC_URL: "http://rpc.invalid",
                // Idle alarms far out, so no test DO ticks in the background against
                // the shared fake world; tests drive ticks explicitly.
                TICK_SECONDS: "3600",
                MAX_ORDERS_PER_TICK: "2",
                MAX_SUBREQUESTS_PER_TICK: "200",
                SUBREQUESTS_PER_ORDER: "40",
                ALERT_REVERTS_PER_HOUR: "1",
                ALERT_MIN_RBTC: "0.5",
                ALERT_RPC_ERROR_STREAK: "3",
              },
              serviceBindings: {
                ORDERBOOK: async (request: Request) => {
                  const url = new URL(request.url);
                  if (url.pathname !== "/orders") return new Response("not found", { status: 404 });
                  return Response.json({ orders: [], total: 0, seenPath: url.pathname });
                },
              },
            },
          }),
        ],
        test: { name: "workers", include: ["test/*.test.ts"] },
      },
    ],
  },
});

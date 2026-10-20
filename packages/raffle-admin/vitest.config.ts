import { resolve } from "node:path";

import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "@app": resolve(__dirname, "../app/src") } },
  define: { __TERMS_HASH__: JSON.stringify(`0x${"7e".repeat(32)}`) },
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});

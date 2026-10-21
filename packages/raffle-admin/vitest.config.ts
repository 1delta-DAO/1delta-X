import { resolve } from "node:path";

import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "@app": resolve(__dirname, "../app/src") } },
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});

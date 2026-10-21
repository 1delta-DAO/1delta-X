import { defineConfig } from "vitest/config";

// Kept apart from `vite.config.ts` so the test runner never loads the React
// plugin or the dev proxy: everything under test is plain TypeScript.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});

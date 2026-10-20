import { defineConfig } from "vitest/config";

// Kept apart from `vite.config.ts` so the test runner never loads the React
// plugin or the dev proxy: everything under test is plain TypeScript.
export default defineConfig({
  // A fixed stand-in for the build's keccak256(TC.md) (vite.config.ts).
  define: { __TERMS_HASH__: JSON.stringify(`0x${"7e".repeat(32)}`) },
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});

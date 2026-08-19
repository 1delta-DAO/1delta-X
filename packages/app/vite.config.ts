import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative base so the build works served from a domain root or a sub-path.
// The Oku API and the token lists are called straight from the browser
// (permissive CORS, no key), so there is no dev proxy and nothing to deploy
// alongside this.
//
// `@1delta-x/sdk` resolves through the workspace package — its built `dist` for
// both types and runtime. Aliasing the bundler to the SDK's source while tsc
// read its `dist` types would let the two diverge silently, which is the one
// failure this app cannot afford: the order encoding it signs has to be the one
// the contract hashes.
export default defineConfig({
  plugins: [react()],
  base: "./",
  server: { port: 5173 },
  build: { outDir: "dist", assetsDir: "assets" },
});

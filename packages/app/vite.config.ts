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
  // A dedicated port, and `strictPort` so a clash FAILS instead of quietly
  // moving. Vite's default 5173 is already taken here by the Rootstock pitch
  // deck, and the silent fallback meant `pnpm run app` printed one port while
  // the browser sat on another app entirely — which reads as "nothing works".
  server: {
    port: 5175,
    strictPort: true,
    // Mirrors the Pages Function at `functions/api/oku/[[path]].ts`, so the
    // request path the app uses is identical in development and production.
    proxy: {
      "/api/oku": {
        target: "https://omni.icarus.tools",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api\/oku/, ""),
      },
    },
  },
  build: { outDir: "dist", assetsDir: "assets" },
});

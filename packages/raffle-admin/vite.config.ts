import { resolve } from "node:path";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * The raffle operator console — its OWN build and deployment (a separate Cloudflare
 * Pages project), so nothing of it ships in the trading app's bundle or on its domain.
 *
 * It reuses the app's pure libraries at BUILD time through the `@app` alias (the fill
 * valuation the Dashboard uses, the pinned token table, the USD price feed, the theme
 * and the stylesheet), so a draw values fills exactly as the app shows them. Nothing
 * runs in the app on the console's behalf.
 */

export default defineConfig({
  plugins: [react()],
  base: "./",
  resolve: { alias: { "@app": resolve(__dirname, "../app/src") } },
  server: {
    port: 5176,
    strictPort: true,
    proxy: {
      // Same path as production (`public/_worker.js` → the ORDERBOOK service binding).
      "/api/book": {
        target: process.env.ORDERBOOK_PROXY_TARGET ?? "http://localhost:8787",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api\/book/, ""),
      },
    },
  },
  build: { outDir: "dist", assetsDir: "assets" },
});

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative base so the build works served from a domain root or a sub-path.
// The Oku API is called straight from the browser (permissive CORS, no key), so
// there is no dev proxy and no server-side component to deploy alongside this.
export default defineConfig({
  plugins: [react()],
  base: "./",
  server: { port: 5173 },
  build: { outDir: "dist", assetsDir: "assets" },
});

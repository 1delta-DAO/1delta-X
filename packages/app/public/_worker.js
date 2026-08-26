/**
 * Cloudflare Pages advanced-mode worker.
 *
 * Lives in `public/`, so Vite copies it verbatim to `dist/_worker.js` and it
 * travels with the build output — unlike a `functions/` directory, which Pages
 * only reads from the project ROOT and which is therefore silently dropped
 * whenever the root is not this package. A dropped proxy does not fail loudly:
 * `/api/oku/*` just falls through to the SPA handler, GET returns index.html and
 * POST returns 405, which is exactly the symptom this replaced.
 *
 * Its one job is proxying Oku. Oku allow-lists CORS origins — `localhost:*` and
 * `oku.trade` get an `access-control-allow-origin` header, every other origin
 * gets none — so a browser on a deployed domain can never call it directly.
 * A worker is server-side, where CORS does not apply.
 */
const OKU_ORIGIN = "https://omni.icarus.tools";
const PROXY_PREFIX = "/api/oku/";

/** Only Oku's own JSON-RPC shape, so this cannot be used as an open relay. */
const ALLOWED_PATH = /^[a-z0-9-]+\/cush\/[a-zA-Z0-9_]+$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith(PROXY_PREFIX)) return serveAsset(request, env);

    const path = url.pathname.slice(PROXY_PREFIX.length);
    if (!ALLOWED_PATH.test(path)) return json({ error: "unsupported path" }, 400);
    if (request.method === "OPTIONS") return preflight();
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405);

    try {
      const upstream = await fetch(`${OKU_ORIGIN}/${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: await request.text(),
      });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": upstream.headers.get("content-type") ?? "application/json",
          "access-control-allow-origin": "*",
          "cache-control": "no-store",
        },
      });
    } catch (e) {
      return json({ error: `upstream unreachable: ${e?.message ?? e}` }, 502);
    }
  },
};

/**
 * Static assets, preserving the SPA fallback the project had before this worker
 * existed. In advanced mode the worker owns routing, so the platform's
 * not-found handling is no longer guaranteed to apply — and silently turning
 * every deep link into a 404 would be a regression nobody asked for.
 */
async function serveAsset(request, env) {
  const response = await env.ASSETS.fetch(request);
  if (response.status !== 404) return response;
  const wantsHtml = request.method === "GET" && (request.headers.get("accept") ?? "").includes("text/html");
  if (!wantsHtml) return response;
  const url = new URL(request.url);
  url.pathname = "/index.html";
  return env.ASSETS.fetch(new Request(url, request));
}

function preflight() {
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
      "access-control-max-age": "86400",
    },
  });
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
  });
}

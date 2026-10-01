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

/**
 * Security headers on every page and asset (G-TS_SIGN-14).
 *
 * In advanced mode this worker owns routing, so a `_headers` file is NOT
 * applied — the headers have to be set here. `frame-ancestors 'none'` (plus the
 * legacy X-Frame-Options) stops a hostile site framing the app to steer clicks
 * on "Approve" and "Sign order". The CSP allows exactly the origins the app
 * fetches from: this origin (the Oku proxy), the token-list CDN and the two
 * subgraph hosts. Token logos come from arbitrary list-supplied hosts, hence
 * `img-src https:`; React's `style={…}` attributes need `'unsafe-inline'` for
 * styles only — scripts stay `'self'`. A self-hosted `VITE_OKU_BASE` on another
 * origin must be added to `connect-src`.
 */
export const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: https:",
  "font-src 'self' data:",
  "connect-src 'self' https://cdn.jsdelivr.net https://api.goldsky.com https://gateway-arbitrum.network.thegraph.com",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");

export const SECURITY_HEADERS = {
  "content-security-policy": CONTENT_SECURITY_POLICY,
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=()",
};

/** A copy of `response` with the security headers set. Asset responses are immutable, hence the copy. */
export function withSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) headers.set(k, v);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/** Only Oku's own JSON-RPC shape, so this cannot be used as an open relay. */
const ALLOWED_PATH = /^[a-z0-9-]+\/cush\/[a-zA-Z0-9_]+$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith(PROXY_PREFIX)) return withSecurityHeaders(await serveAsset(request, env));

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
          "x-content-type-options": "nosniff",
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

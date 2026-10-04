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
 * It proxies two things: Oku, and the orderbook under `/api/book/*` (an
 * `ORDERBOOK` service binding, else `ORDERBOOK_ORIGIN`) — see {@link proxyBook}.
 *
 * Oku: Oku allow-lists CORS origins — `localhost:*` and
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

/**
 * Same-origin proxy to the orderbook, for `VITE_ORDERBOOK_URL=/api/book`.
 *
 * Two upstreams, in order of preference:
 *
 *   1. `env.ORDERBOOK` — a SERVICE BINDING to the `@1delta-x/orderbook-worker`
 *      Worker (the Rootstock beta book). The call never leaves Cloudflare.
 *   2. `env.ORDERBOOK_ORIGIN` — an HTTPS origin (e.g. the Node
 *      `@1delta-x/orderbook-server`), the fallback when no binding is configured.
 *
 * Neither set → `503 orderbook not configured`; there is deliberately no default.
 * The orderbook sends no CORS headers and `connect-src 'self'` would refuse
 * another origin anyway, so the browser only ever talks to this origin.
 *
 * Not an open relay: exactly the routes the app (and the beta filler) use, each
 * with its methods, are forwarded — anything else is 400 (unknown path) or 405
 * (wrong method). Bodies are capped and must be JSON or protobuf. Only
 * `content-type` and `accept` are forwarded from the client.
 *
 * CLIENT IP. The per-IP rate limit upstream must bill the VISITOR, not this
 * worker, and the visitor must not be able to choose the address:
 *
 *   • binding: a service-binding request carries exactly the headers this worker
 *     puts on it — Cloudflare's edge does not rewrite them, and a freshly built
 *     request has no `cf-connecting-ip` at all. So the address Cloudflare saw on
 *     THIS request (`cf-connecting-ip`, set by the edge, not client-writable) is
 *     copied into `x-orderbook-client-ip`, together with
 *     `x-orderbook-binding-key: env.ORDERBOOK_BINDING_KEY`. The orderbook worker
 *     honours `x-orderbook-client-ip` ONLY when that key matches its own
 *     `BINDING_KEY` secret; on its public route the key is unknown to clients, so
 *     the header is ignored there and the edge-set `cf-connecting-ip` is used.
 *     `cf-connecting-ip` is forwarded as-is too, for a callee without the key.
 *   • origin: `x-forwarded-for` is REPLACED with `cf-connecting-ip`; the server
 *     must run with `TRUST_PROXY=true` (see the app README for the hop count).
 */
const BOOK_PREFIX = "/api/book/";
/** The server's raw JSON cap (4 × its 64 KiB `MAX_BODY_BYTES` default). */
export const BOOK_MAX_BODY_BYTES = 256 * 1024;
const BOOK_POST_TYPES = ["application/json", "application/x-protobuf"];
const ORDER_STATUS_PATH = /^orders\/0x[0-9a-fA-F]{64}\/status$/;
/** Base URL of a service-binding request; the host is ignored by the callee. */
const BINDING_BASE = "https://orderbook.binding";

/**
 * The allowlist: `path → { method → forward the query string? }`. `GET /orders`
 * is the maker's own resting orders on reload (`?maker=`) and the beta filler's
 * intake; it is read-only and rate-limited upstream like every read.
 */
function bookRoute(path) {
  if (path === "orders") return { POST: false, GET: true };
  if (path === "cancels") return { POST: false };
  if (path === "fills") return { GET: true };
  if (ORDER_STATUS_PATH.test(path)) return { GET: false };
  return null;
}

/** An `env.ORDERBOOK` service binding, if one is configured. */
function bookBinding(env) {
  const b = env?.ORDERBOOK;
  return b && typeof b.fetch === "function" ? b : null;
}

async function proxyBook(request, env, url) {
  const path = url.pathname.slice(BOOK_PREFIX.length);
  const route = bookRoute(path);
  if (!route) return bookJson({ error: "unsupported path" }, 400);
  const method = request.method;
  if (!Object.prototype.hasOwnProperty.call(route, method)) {
    return bookJson({ error: "method not allowed" }, 405, { allow: Object.keys(route).join(", ") });
  }
  const forwardQuery = route[method];

  const binding = bookBinding(env);
  let base = null;
  if (!binding) {
    const origin = typeof env?.ORDERBOOK_ORIGIN === "string" ? env.ORDERBOOK_ORIGIN.trim() : "";
    if (!origin) return bookJson({ error: "orderbook not configured" }, 503);
    try {
      base = new URL(origin);
      if (base.protocol !== "https:" && base.protocol !== "http:") throw new Error("scheme");
    } catch {
      return bookJson({ error: "orderbook not configured" }, 503);
    }
  }

  const headers = { accept: request.headers.get("accept") ?? "application/json" };
  const ip = request.headers.get("cf-connecting-ip");
  if (binding) {
    if (ip) {
      headers["cf-connecting-ip"] = ip;
      headers["x-orderbook-client-ip"] = ip;
    }
    const key = typeof env?.ORDERBOOK_BINDING_KEY === "string" ? env.ORDERBOOK_BINDING_KEY : "";
    if (key) headers["x-orderbook-binding-key"] = key;
  } else if (ip) {
    headers["x-forwarded-for"] = ip;
  }

  let body;
  if (method === "POST") {
    const type = request.headers.get("content-type") ?? "";
    if (!BOOK_POST_TYPES.includes(type.split(";")[0].trim().toLowerCase())) {
      return bookJson({ error: "unsupported content type" }, 415);
    }
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > BOOK_MAX_BODY_BYTES) return bookJson({ error: "body too large" }, 413);
    body = await readCapped(request, BOOK_MAX_BODY_BYTES);
    if (body === null) return bookJson({ error: "body too large" }, 413);
    headers["content-type"] = type;
  }

  const suffix = `/${path}${forwardQuery ? url.search : ""}`;
  try {
    const upstream = binding
      ? await binding.fetch(new Request(`${BINDING_BASE}${suffix}`, { method, headers, body, redirect: "manual" }))
      : await fetch(`${base.origin}${base.pathname.replace(/\/+$/, "")}${suffix}`, { method, headers, body, redirect: "manual" });
    const out = {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
      "cache-control": "no-store",
    };
    for (const h of ["retry-after", "x-next-cursor", "x-total-count"]) {
      const v = upstream.headers.get(h);
      if (v) out[h] = v;
    }
    return withSecurityHeaders(new Response(upstream.body, { status: upstream.status, headers: out }));
  } catch {
    // The upstream URL is configuration, not something to echo to a browser.
    return bookJson({ error: "orderbook unreachable" }, 502);
  }
}

/** The request body, or `null` once it exceeds `cap` bytes — never buffered past the cap. */
async function readCapped(request, cap) {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > cap) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

function bookJson(body, status, extra = {}) {
  return withSecurityHeaders(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
    }),
  );
}

/** Only Oku's own JSON-RPC shape, so this cannot be used as an open relay. */
const ALLOWED_PATH = /^[a-z0-9-]+\/cush\/[a-zA-Z0-9_]+$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith(BOOK_PREFIX) || url.pathname === "/api/book") return proxyBook(request, env, url);
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

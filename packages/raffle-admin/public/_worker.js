/**
 * Cloudflare Pages advanced-mode worker for the RAFFLE OPERATOR CONSOLE — a Pages
 * project of its own, on its own hostname, separate from the trading app.
 *
 * It serves the built console and proxies exactly the orderbook routes the console
 * uses under `/api/book/*` to the orderbook worker:
 *
 *   1. `env.ORDERBOOK` — a service binding to `@1delta-x/orderbook-worker` (preferred);
 *   2. `env.ORDERBOOK_ORIGIN` — the worker's HTTPS URL, when no binding is configured.
 *
 * `authorization` (the operator's RAFFLE_ADMIN_TOKEN bearer) is forwarded — the
 * orderbook worker checks it; this proxy holds no admin secret and decides nothing.
 * The visitor's address goes along as on the app's proxy (`x-orderbook-client-ip` +
 * `ORDERBOOK_BINDING_KEY`), so the orderbook's per-IP limits bill the operator.
 *
 * Put Cloudflare Access (or another SSO gate) in front of this project: the token is
 * the authorisation, Access keeps the console itself out of sight.
 *
 * EXPORTS: only `export default` (workerd refuses a Pages main module exporting more).
 */

const PREFIX = "/api/book/";
const MAX_BODY = 256 * 1024;
const BINDING_BASE = "https://orderbook.binding";

/** path → allowed methods. */
function route(path) {
  if (path === "raffle" || path === "fills") return ["GET"];
  if (/^raffle\/status\/0x[0-9a-fA-F]{40}$/.test(path)) return ["GET"];
  if (/^raffle\/admin\/(config|promotions|entries|entries\/0x[0-9a-fA-F]{40}|status|purge-contacts|reset|draws|draws\/\d{4}-\d{2}-\d{2})$/.test(path)) {
    return ["GET", "PUT", "POST", "DELETE"];
  }
  return null;
}

const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self' data:",
  // Draw blocks (Rootstock public node) and the USD reference prices (Sushi).
  "connect-src 'self' https://public-node.rsk.co https://api.sushi.com",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");

const SECURITY = {
  "content-security-policy": CSP,
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "x-robots-tag": "noindex, nofollow",
  "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=()",
};

function secure(response) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(SECURITY)) headers.set(k, v);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

const json = (body, status, extra = {}) =>
  secure(new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } }));

async function proxy(request, env, url) {
  const path = url.pathname.slice(PREFIX.length);
  const methods = route(path);
  if (!methods) return json({ error: "unsupported path" }, 400);
  if (!methods.includes(request.method)) return json({ error: "method not allowed" }, 405, { allow: methods.join(", ") });

  const binding = env?.ORDERBOOK && typeof env.ORDERBOOK.fetch === "function" ? env.ORDERBOOK : null;
  let base = null;
  if (!binding) {
    try {
      base = new URL(String(env?.ORDERBOOK_ORIGIN ?? "").trim());
      if (base.protocol !== "https:" && base.protocol !== "http:") throw new Error("scheme");
    } catch {
      return json({ error: "orderbook not configured" }, 503);
    }
  }

  const headers = { accept: "application/json" };
  const auth = request.headers.get("authorization");
  if (auth) headers.authorization = auth;
  const ip = request.headers.get("cf-connecting-ip");
  if (binding) {
    if (ip) {
      headers["cf-connecting-ip"] = ip;
      headers["x-orderbook-client-ip"] = ip;
    }
    if (typeof env?.ORDERBOOK_BINDING_KEY === "string" && env.ORDERBOOK_BINDING_KEY) headers["x-orderbook-binding-key"] = env.ORDERBOOK_BINDING_KEY;
  } else if (ip) {
    headers["x-forwarded-for"] = ip;
  }

  let body;
  if (request.method === "POST" || request.method === "PUT") {
    if ((request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase() !== "application/json") return json({ error: "unsupported content type" }, 415);
    const buf = new Uint8Array(await request.arrayBuffer());
    if (buf.byteLength > MAX_BODY) return json({ error: "body too large" }, 413);
    body = buf;
    headers["content-type"] = "application/json";
  }

  const suffix = `/${path}${url.search}`;
  try {
    const upstream = binding
      ? await binding.fetch(new Request(`${BINDING_BASE}${suffix}`, { method: request.method, headers, body, redirect: "manual" }))
      : await fetch(`${base.origin}${base.pathname.replace(/\/+$/, "")}${suffix}`, { method: request.method, headers, body, redirect: "manual" });
    const out = { "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-store" };
    const retry = upstream.headers.get("retry-after");
    if (retry) out["retry-after"] = retry;
    return secure(new Response(upstream.body, { status: upstream.status, headers: out }));
  } catch {
    return json({ error: "orderbook unreachable" }, 502);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith(PREFIX)) return proxy(request, env, url);
    return secure(await env.ASSETS.fetch(request));
  },
};

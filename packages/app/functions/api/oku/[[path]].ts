/**
 * Server-side proxy for Oku's JSON-RPC API.
 *
 * Oku allow-lists CORS origins: `http://localhost:*` and `https://oku.trade`
 * get an `access-control-allow-origin` header, and every other origin gets
 * none at all — so a browser on a deployed domain blocks the response before
 * our code ever sees it. That is a policy on their side, not a bug on ours, and
 * no client-side change can work around it.
 *
 * A Cloudflare Pages Function is not subject to CORS: it is server-to-server.
 * This forwards the request, unchanged, and returns the answer same-origin.
 *
 * Deployed at `/api/oku/*` — so `/api/oku/rootstock/cush/liveBlock` reaches
 * `https://omni.icarus.tools/rootstock/cush/liveBlock`.
 */
const OKU_ORIGIN = "https://omni.icarus.tools";

/** Only Oku's own JSON-RPC shape, so this cannot be used as an open relay. */
const ALLOWED_PATH = /^[a-z0-9-]+\/cush\/[a-zA-Z0-9_]+$/;

export const onRequest: PagesFunction = async (context) => {
  const { request, params } = context;
  const path = Array.isArray(params.path) ? params.path.join("/") : String(params.path ?? "");

  if (!ALLOWED_PATH.test(path)) {
    return json({ error: "unsupported path" }, 400);
  }
  if (request.method !== "POST" && request.method !== "GET") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    const upstream = await fetch(`${OKU_ORIGIN}/${path}`, {
      method: request.method,
      headers: { "content-type": "application/json" },
      body: request.method === "POST" ? await request.text() : undefined,
    });
    // Stream the body straight through; the client parses the same JSON-RPC
    // envelope it would have got directly.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "content-type": upstream.headers.get("content-type") ?? "application/json",
        // Same-origin in practice, but explicit so a preview deployment on a
        // different subdomain is not a surprise 
        "access-control-allow-origin": "*",
        "cache-control": "no-store",
      },
    });
  } catch (e) {
    return json({ error: `upstream unreachable: ${e instanceof Error ? e.message : String(e)}` }, 502);
  }
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
  });
}

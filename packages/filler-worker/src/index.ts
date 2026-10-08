import { isAdmin } from "./auth";
import { DO_IP_HEADER, quoteClientIp } from "./clientIp";
import { locationHint, type Env } from "./config";
import { FillerDO } from "./do";

// The entry module exports ONLY Workers entrypoints (the default handler and the
// Durable Object class): workerd refuses to start a script whose main module exports
// anything else (a string, a number). Everything else stays module-private.
export { FillerDO };

/** The admin routes (all need `Authorization: Bearer <ADMIN_TOKEN>`). */
const ADMIN_ROUTES: Record<string, string> = {
  "/status": "GET",
  "/fills": "GET",
  "/pause": "POST",
  "/resume": "POST",
  "/dry-run": "POST",
  "/tick": "POST",
};

const json = (v: unknown, status: number, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers } });

/**
 * THE filler object. `DO_LOCATION_HINT` (optional) is passed on every `get()`, but
 * Cloudflare honours it only when the object is first CREATED — it never moves one.
 */
function stubFor(env: Env): DurableObjectStub<FillerDO> {
  const hint = locationHint(env);
  return env.FILLER.get(env.FILLER.idFromName("filler"), hint ? { locationHint: hint } : undefined) as DurableObjectStub<FillerDO>;
}

/** `POST /quote` body cap: the request is a handful of short fields. */
const QUOTE_MAX_BODY = 2048;

const allowWorkersDev = (env: Env) => typeof env.ADMIN_ALLOW_WORKERS_DEV === "string" && env.ADMIN_ALLOW_WORKERS_DEV.trim().toLowerCase() === "true";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    // Unauthenticated liveness: ok + last tick age, nothing else.
    if (path === "/health") {
      if (method !== "GET") return json({ error: "method not allowed" }, 405, { allow: "GET" });
      return stubFor(env).fetch(new Request("https://filler/health"));
    }
    // PUBLIC: an indicative quote for a market ticket (packages/beta-filler src/quote.ts).
    // No auth (the app's visitors call it through the Pages worker's `/api/quote`), a
    // body cap, and a per-IP + global rate limit in the Durable Object. Answers on
    // *.workers.dev too: it reveals nothing the chain does not.
    if (path === "/quote") {
      if (method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST" });
      const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
      if (type !== "application/json") return json({ error: "content-type must be application/json" }, 415);
      if (Number(request.headers.get("content-length") ?? "0") > QUOTE_MAX_BODY) return json({ error: "body too large" }, 413);
      const body = await request.text();
      if (body.length > QUOTE_MAX_BODY) return json({ error: "body too large" }, 413);
      const ip = await quoteClientIp(request, env.QUOTE_BINDING_KEY);
      return stubFor(env).fetch(new Request("https://filler/quote", { method: "POST", headers: { "content-type": "application/json", [DO_IP_HEADER]: ip }, body }));
    }
    const want = ADMIN_ROUTES[path];
    if (!want) return json({ error: "not found" }, 404);
    // The admin API does not answer on *.workers.dev unless explicitly allowed:
    // serve it on a custom domain (ideally behind Cloudflare Access).
    if (url.hostname.endsWith(".workers.dev") && !allowWorkersDev(env)) return json({ error: "not found" }, 404);
    if (!(await isAdmin(request, env.ADMIN_TOKEN))) return json({ error: "unauthorized" }, 401, { "www-authenticate": 'Bearer realm="filler"' });
    if (method !== want) return json({ error: "method not allowed" }, 405, { allow: want });
    const body = method === "POST" ? await request.text() : undefined;
    if (body !== undefined && body.length > 4096) return json({ error: "body too large" }, 413);
    return stubFor(env).fetch(
      new Request(`https://filler${path}${url.search}`, {
        method,
        headers: { "content-type": "application/json" },
        ...(body !== undefined ? { body } : {}),
      }),
    );
  },

  /** The cron trigger only re-arms the alarm loop; the alarm does the work. */
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await stubFor(env).kick();
  },
} satisfies ExportedHandler<Env>;

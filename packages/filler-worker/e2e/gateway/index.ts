/**
 * Staging-harness "edge" (LOCAL ONLY, never deployed): the primary worker of the
 * multi-config `wrangler dev` session, because only the primary is served over
 * HTTP. It plays two roles the harness needs:
 *
 *   /api/book/*  → the app's REAL Pages worker (packages/app/public/_worker.js),
 *                  which proxies to the orderbook over the ORDERBOOK service binding
 *                  with the Pages-style `x-orderbook-client-ip` +
 *                  `x-orderbook-binding-key` headers. `x-sim-ip` stands in for the
 *                  edge-set `cf-connecting-ip`, so each simulated visitor gets its
 *                  own rate-limit bucket, exactly as distinct visitors would.
 *   /ob/*        → the orderbook worker directly (health, `/orders/:hash`), as a
 *                  hit on its public route would arrive (cf-connecting-ip only).
 *   /filler/*    → the filler worker (admin API; auth is the filler's own).
 *   /__harness/scheduled?worker=orderbook|filler
 *                → that worker's `scheduled()` handler (the cron), when the runtime
 *                  supports invoking it over a service binding.
 */
// @ts-expect-error -- plain JS module without types
import pages from "../../../app/public/_worker.js";

interface Env {
  ORDERBOOK: Fetcher;
  FILLER: Fetcher;
  ORDERBOOK_BINDING_KEY?: string;
}

const SIM_IP = "x-sim-ip";

function strip(url: URL, prefix: string, host: string): URL {
  return new URL(`${url.pathname.slice(prefix.length) || "/"}${url.search}`, `https://${host}`);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const ip = request.headers.get(SIM_IP) ?? "127.0.0.1";
    const method = request.method.toUpperCase();
    const body = method === "GET" || method === "HEAD" ? undefined : await request.arrayBuffer();

    if (url.pathname === "/api/book" || url.pathname.startsWith("/api/book/")) {
      const headers = new Headers(request.headers);
      headers.delete(SIM_IP);
      headers.set("cf-connecting-ip", ip);
      const req = new Request(url, { method, headers, ...(body !== undefined ? { body } : {}) });
      return (pages as { fetch: (r: Request, e: unknown) => Promise<Response> }).fetch(req, {
        ORDERBOOK: env.ORDERBOOK,
        ORDERBOOK_BINDING_KEY: env.ORDERBOOK_BINDING_KEY ?? "",
      });
    }
    if (url.pathname.startsWith("/ob/")) {
      const headers = new Headers();
      for (const h of ["content-type", "accept"]) {
        const v = request.headers.get(h);
        if (v !== null) headers.set(h, v);
      }
      headers.set("cf-connecting-ip", ip);
      return env.ORDERBOOK.fetch(new Request(strip(url, "/ob", "orderbook.local"), { method, headers, ...(body !== undefined ? { body } : {}) }));
    }
    if (url.pathname.startsWith("/filler/")) {
      const headers = new Headers();
      for (const h of ["content-type", "accept", "authorization"]) {
        const v = request.headers.get(h);
        if (v !== null) headers.set(h, v);
      }
      return env.FILLER.fetch(new Request(strip(url, "/filler", "filler.local"), { method, headers, ...(body !== undefined ? { body } : {}) }));
    }
    if (url.pathname === "/__harness/scheduled") {
      const which = url.searchParams.get("worker");
      const target = which === "orderbook" ? env.ORDERBOOK : which === "filler" ? env.FILLER : undefined;
      if (!target) return Response.json({ error: "worker must be orderbook or filler" }, { status: 400 });
      const f = target as Fetcher & { scheduled?: (o: { cron?: string; scheduledTime?: Date }) => Promise<{ outcome: string; noRetry: boolean }> };
      if (typeof f.scheduled !== "function") return Response.json({ error: "Fetcher.scheduled unavailable in this runtime" }, { status: 501 });
      try {
        const r = await f.scheduled({ cron: "* * * * *", scheduledTime: new Date() });
        return Response.json({ worker: which, ...r });
      } catch (e) {
        return Response.json({ worker: which, error: e instanceof Error ? e.message : String(e) }, { status: 500 });
      }
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
};

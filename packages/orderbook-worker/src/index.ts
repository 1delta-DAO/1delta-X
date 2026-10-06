import { readCappedBytes } from "./body";
import { clientIp } from "./clientIp";
import { locationHint, maxBodyBytesOf, type Env } from "./config";
import { CLIENT_IP_HEADER, OrderBookDO } from "./do";

// The entry module exports ONLY Workers entrypoints (the default handler and the
// Durable Object class): workerd refuses to start a script whose main module
// exports anything else, e.g. a string constant. Helpers live in their own modules.
export { OrderBookDO };

/**
 * The chain's one Durable Object. `DO_LOCATION_HINT` (optional) is passed on every
 * `get()`, but Cloudflare honours it only when the object is first CREATED — an
 * existing object never moves.
 */
function stubFor(env: Env): DurableObjectStub<OrderBookDO> {
  const hint = locationHint(env);
  return env.BOOK.get(env.BOOK.idFromName(`chain:${env.CHAIN_ID}`), hint ? { locationHint: hint } : undefined) as DurableObjectStub<OrderBookDO>;
}

function tooLarge(cap: number): Response {
  return new Response(JSON.stringify({ error: `body exceeds ${cap} bytes` }), {
    status: 413,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const ip = clientIp(request, env);
    // A fresh request to the DO: only the headers the book reads, the binding
    // headers dropped, and the resolved address in a header nothing else can set
    // (the DO is reachable only through this worker).
    const headers = new Headers();
    for (const h of ["content-type", "accept"]) {
      const v = request.headers.get(h);
      if (v !== null) headers.set(h, v);
    }
    headers.set(CLIENT_IP_HEADER, ip);
    let body: Uint8Array | undefined;
    if (request.method !== "GET" && request.method !== "HEAD") {
      // BUFFER the body (capped) before the DO sees the request. It used to be
      // streamed through; the DO answers most refusals (429 rate limit, 413, 415,
      // 405) WITHOUT reading the body, and the runtime's pump from this request into
      // the DO's then threw "Can't read from request stream after response has been
      // sent" — one uncaught exception per refused POST (6,941 under the staging
      // harness's abusive client). A body over MAX_BODY_BYTES is refused here.
      let cap: number;
      try {
        cap = maxBodyBytesOf(env);
      } catch {
        cap = 256 * 1024; // a malformed var: the DO reports the misconfiguration itself
      }
      if (Number(request.headers.get("content-length") ?? "0") > cap) return tooLarge(cap);
      const bytes = await readCappedBytes(request.body, cap);
      if (bytes === null) return tooLarge(cap);
      body = bytes;
    }
    return stubFor(env).fetch(new Request(request.url, { method: request.method, headers, ...(body !== undefined ? { body } : {}) }));
  },

  /** The cron trigger only re-arms the alarm loop; the alarm does the work. */
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await stubFor(env).kick();
  },
} satisfies ExportedHandler<Env>;

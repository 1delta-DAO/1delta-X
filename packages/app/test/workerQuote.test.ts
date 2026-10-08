import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * `public/_worker.js` → `/api/quote`: the same-origin proxy to the filler's public
 * indicative quote — a `FILLER` service binding when configured, else `FILLER_ORIGIN`.
 * One route, POST + JSON only, ≤ 2 KiB; the visitor's IP from Cloudflare (never the
 * client) with the binding key, so the filler's per-IP limit bills the visitor.
 */

// @ts-expect-error — plain JS worker module
const workerModule = await import("../public/_worker.js");
const worker = workerModule.default as { fetch: (r: Request, env: unknown) => Promise<Response> };

const APP = "https://app.example";
const BODY = JSON.stringify({ chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", amountIn: "1", delivery: "direct" });

interface Seen {
  url: string;
  method: string;
  headers: Headers;
  body: string | null;
}
let seen: Seen[] = [];
const record = async (url: string, init: RequestInit = {}) => {
  seen.push({ url, method: init.method ?? "GET", headers: new Headers(init.headers), body: init.body ? new TextDecoder().decode(init.body as Uint8Array) : null });
  return new Response(JSON.stringify({ amountOut: "1" }), { status: 200, headers: { "content-type": "application/json", "retry-after": "2", "set-cookie": "a=b" } });
};
const binding = {
  fetch: async (req: Request) => {
    const body = await req.arrayBuffer();
    return record(req.url, { method: req.method, headers: req.headers, body: new Uint8Array(body) });
  },
};
const env = (over: Record<string, unknown> = {}) => ({ FILLER: binding, FILLER_BINDING_KEY: "k-123", ASSETS: { fetch: async () => new Response("asset") }, ...over });

beforeEach(() => {
  seen = [];
  vi.stubGlobal("fetch", record);
});
afterEach(() => vi.unstubAllGlobals());

const call = (path: string, init: RequestInit = {}, e: unknown = env()) => worker.fetch(new Request(`${APP}${path}`, init), e);
const post = (headers: Record<string, string> = {}, body = BODY, e: unknown = env()) =>
  call("/api/quote", { method: "POST", headers: { "content-type": "application/json", ...headers }, body }, e);

describe("worker /api/quote proxy", () => {
  it("POST over the FILLER binding: body as-is, the visitor's IP + binding key; nothing else of the client's", async () => {
    const res = await post({ "cf-connecting-ip": "203.0.113.9", "x-forwarded-for": "6.6.6.6", "x-filler-client-ip": "6.6.6.6", cookie: "s=1", authorization: "Bearer x" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ amountOut: "1" });
    expect(seen).toHaveLength(1);
    expect(seen[0]!.url).toBe("https://filler.binding/quote");
    expect(seen[0]!.method).toBe("POST");
    expect(seen[0]!.body).toBe(BODY);
    expect(seen[0]!.headers.get("x-filler-client-ip")).toBe("203.0.113.9"); // from cf-connecting-ip, not the client's claim
    expect(seen[0]!.headers.get("x-filler-binding-key")).toBe("k-123");
    expect(seen[0]!.headers.get("x-forwarded-for")).toBeNull();
    expect(seen[0]!.headers.get("cookie")).toBeNull();
    expect(seen[0]!.headers.get("authorization")).toBeNull();
    expect(res.headers.get("retry-after")).toBe("2");
    expect(res.headers.get("set-cookie")).toBeNull();
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-frame-options")).toBe("DENY");
  });

  it("FILLER_ORIGIN when no binding (with a path prefix kept); neither → 503", async () => {
    const res = await post({}, BODY, env({ FILLER: undefined, FILLER_ORIGIN: "https://filler.example/x/" }));
    expect(res.status).toBe(200);
    expect(seen[0]!.url).toBe("https://filler.example/x/quote");
    const none = await post({}, BODY, env({ FILLER: undefined }));
    expect(none.status).toBe(503);
    expect(await none.json()).toEqual({ error: "quote service not configured" });
    expect((await post({}, BODY, env({ FILLER: undefined, FILLER_ORIGIN: "ftp://x" }))).status).toBe(503);
  });

  it("not an open relay: one path, POST, JSON, ≤ 2 KiB", async () => {
    expect((await call("/api/quote/../book/orders", { method: "POST", headers: { "content-type": "application/json" }, body: BODY })).status).not.toBe(200);
    expect((await call("/api/quote/x", { method: "POST", headers: { "content-type": "application/json" }, body: BODY })).status).toBe(400);
    const g = await call("/api/quote");
    expect(g.status).toBe(405);
    expect(g.headers.get("allow")).toBe("POST");
    expect((await post({ "content-type": "text/plain" })).status).toBe(415);
    expect((await post({}, JSON.stringify({ pad: "x".repeat(3000) }))).status).toBe(413);
    expect(seen).toHaveLength(0);
  });

  it("an unreachable filler is a 502 that echoes no upstream detail; the upstream status passes through", async () => {
    const down = await post({}, BODY, env({ FILLER: { fetch: async () => { throw new Error("connect ECONNREFUSED 10.0.0.1"); } } }));
    expect(down.status).toBe(502);
    expect(await down.text()).not.toContain("10.0.0.1");
    const limited = await post({}, BODY, env({ FILLER: { fetch: async () => Response.json({ error: "rate limited" }, { status: 429, headers: { "retry-after": "7" } }) } }));
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("7");
  });
});

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * `public/_worker.js` → `/api/book/*`: the same-origin proxy to the orderbook —
 * an `ORDERBOOK` service binding when configured, else `ORDERBOOK_ORIGIN`. Only
 * the allowlisted routes and methods; client IP from Cloudflare, never from the
 * client; security headers on every answer.
 */

// @ts-expect-error — plain JS worker module
const workerModule = await import("../public/_worker.js");
const worker = workerModule.default as { fetch: (r: Request, env: unknown) => Promise<Response> };
/**
 * The proxy's body cap. Not imported: the worker exports nothing but its default
 * handler (workerd refuses a main module exporting a number). The boundary test
 * below pins the value through behaviour instead.
 */
const MAX = 256 * 1024;

const APP = "https://app.example";
const ORIGIN = "https://book.internal";
const HASH = `0x${"ab".repeat(32)}`;
const env = (over: Record<string, unknown> = {}) => ({
  ORDERBOOK_ORIGIN: ORIGIN,
  ASSETS: { fetch: async () => new Response("asset") },
  ...over,
});

interface Seen {
  url: string;
  method: string;
  headers: Headers;
  body: string | null;
}
let seen: Seen[] = [];

beforeEach(() => {
  seen = [];
  vi.stubGlobal("fetch", async (url: string, init: RequestInit = {}) => {
    seen.push({
      url,
      method: init.method ?? "GET",
      headers: new Headers(init.headers),
      body: init.body ? new TextDecoder().decode(init.body as Uint8Array) : null,
    });
    return new Response(JSON.stringify({ upstream: true }), {
      status: 202,
      headers: { "content-type": "application/json", "retry-after": "3", "set-cookie": "a=b" },
    });
  });
});
afterEach(() => vi.unstubAllGlobals());

const call = (path: string, init: RequestInit = {}, e = env()) => worker.fetch(new Request(`${APP}${path}`, init), e);

function expectSecurityHeaders(res: Response) {
  expect(res.headers.get("content-security-policy")).toContain("script-src 'self'");
  expect(res.headers.get("content-security-policy")).not.toContain("unsafe-eval");
  expect(res.headers.get("x-frame-options")).toBe("DENY");
  expect(res.headers.get("x-content-type-options")).toBe("nosniff");
}

describe("worker /api/book proxy — allowlisted routes", () => {
  it("POST /orders: forwards the JSON body and content-type; client IP from cf-connecting-ip only", async () => {
    const body = JSON.stringify({ order: {}, sig: "0x" });
    const res = await call("/api/book/orders", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": "203.0.113.7",
        "x-forwarded-for": "6.6.6.6", // client-written: must not reach the server
        cookie: "session=secret",
        authorization: "Bearer x",
      },
      body,
    });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ upstream: true });
    expect(seen).toHaveLength(1);
    expect(seen[0]!.url).toBe(`${ORIGIN}/orders`);
    expect(seen[0]!.method).toBe("POST");
    expect(seen[0]!.body).toBe(body);
    expect(seen[0]!.headers.get("content-type")).toBe("application/json");
    expect(seen[0]!.headers.get("x-forwarded-for")).toBe("203.0.113.7");
    expect(seen[0]!.headers.get("cookie")).toBeNull();
    expect(seen[0]!.headers.get("authorization")).toBeNull();
    expect(res.headers.get("retry-after")).toBe("3");
    expect(res.headers.get("set-cookie")).toBeNull();
    expectSecurityHeaders(res);
  });

  it("POST /cancels, GET status and GET fills (with its query string) are forwarded", async () => {
    expect((await call("/api/book/cancels", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status).toBe(202);
    expect((await call(`/api/book/orders/${HASH}/status?x=1`)).status).toBe(202);
    expect((await call("/api/book/fills?maker=0xabc&limit=100")).status).toBe(202);
    expect(seen.map((s) => `${s.method} ${s.url}`)).toEqual([
      `POST ${ORIGIN}/cancels`,
      `GET ${ORIGIN}/orders/${HASH}/status`,
      `GET ${ORIGIN}/fills?maker=0xabc&limit=100`,
    ]);
  });

  it("GET /orders (the maker's resting orders on reload) is forwarded with its query", async () => {
    const res = await call("/api/book/orders?maker=0xabc&limit=500");
    expect(res.status).toBe(202);
    expect(seen.map((s) => `${s.method} ${s.url}`)).toEqual([`GET ${ORIGIN}/orders?maker=0xabc&limit=500`]);
    expect(res.headers.get("allow")).toBeNull();
  });

  it("no x-forwarded-for when Cloudflare supplied no client address", async () => {
    await call("/api/book/fills");
    expect(seen[0]!.headers.get("x-forwarded-for")).toBeNull();
  });

  it("an ORDERBOOK_ORIGIN with a path prefix keeps it", async () => {
    await call("/api/book/fills", {}, env({ ORDERBOOK_ORIGIN: "https://gw.example/book/" }));
    expect(seen[0]!.url).toBe("https://gw.example/book/fills");
  });
});

describe("worker /api/book proxy — not an open relay", () => {
  it.each([
    ["/api/book", "GET"],
    ["/api/book/", "GET"],
    ["/api/book/health", "GET"],
    ["/api/book/quote?hash=1", "GET"],
    ["/api/book/replaces", "POST"],
    ["/api/book/stream", "GET"],
    [`/api/book/orders/${HASH}`, "GET"],
    ["/api/book/orders/0x1234/status", "GET"],
    [`/api/book/orders/${HASH}/status/extra`, "GET"],
    ["/api/book/https://evil.example/x", "GET"],
    ["/api/book/fills/../health", "GET"],
  ])("%s %s → 400", async (path, method) => {
    const res = await call(path, { method, ...(method === "POST" ? { body: "{}", headers: { "content-type": "application/json" } } : {}) });
    expect(res.status).toBe(400);
    expectSecurityHeaders(res);
    expect(seen).toHaveLength(0);
  });

  it.each([
    ["/api/book/orders", "PUT"],
    ["/api/book/cancels", "GET"],
    ["/api/book/fills", "POST"],
    [`/api/book/orders/${HASH}/status`, "POST"],
    ["/api/book/orders", "OPTIONS"],
    ["/api/book/orders", "DELETE"],
  ])("%s %s → 405", async (path, method) => {
    const res = await call(path, { method, ...(method === "POST" || method === "PUT" ? { body: "{}" } : {}) });
    expect(res.status).toBe(405);
    expectSecurityHeaders(res);
    expect(seen).toHaveLength(0);
  });

  it("the body cap is exactly 256 KiB: a body of MAX bytes is forwarded, MAX + 1 is a 413", async () => {
    const at = await call("/api/book/orders", { method: "POST", headers: { "content-type": "application/json" }, body: "x".repeat(MAX) });
    expect(at.status).toBe(202);
    expect(seen).toHaveLength(1);
    expect(seen[0]!.body).toHaveLength(MAX);
    const over = await call("/api/book/orders", { method: "POST", headers: { "content-type": "application/json" }, body: "x".repeat(MAX + 1) });
    expect(over.status).toBe(413);
    expect(seen).toHaveLength(1);
  });

  it("refuses other content types and oversized bodies", async () => {
    const form = await call("/api/book/orders", { method: "POST", headers: { "content-type": "text/plain" }, body: "x" });
    expect(form.status).toBe(415);
    const big = await call("/api/book/orders", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "x".repeat(MAX + 1),
    });
    expect(big.status).toBe(413);
    // A body that lies about its length is still cut off at the cap.
    const stream = new ReadableStream({
      start(c) {
        for (let i = 0; i < 5; i++) c.enqueue(new Uint8Array(MAX / 2));
        c.close();
      },
    });
    const lying = await call("/api/book/orders", {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": "10" },
      body: stream,
      // @ts-expect-error — Node's fetch needs this for a stream body
      duplex: "half",
    });
    expect(lying.status).toBe(413);
    expectSecurityHeaders(lying);
    expect(seen).toHaveLength(0);
  });

  it("503 `orderbook not configured` without ORDERBOOK_ORIGIN — no fallback", async () => {
    for (const e of [env({ ORDERBOOK_ORIGIN: undefined }), env({ ORDERBOOK_ORIGIN: "" }), env({ ORDERBOOK_ORIGIN: "not a url" }), env({ ORDERBOOK_ORIGIN: "ftp://x" })]) {
      const res = await call("/api/book/fills", {}, e);
      expect(res.status).toBe(503);
      expect(await res.json()).toEqual({ error: "orderbook not configured" });
      expectSecurityHeaders(res);
    }
    expect(seen).toHaveLength(0);
  });

  it("an unreachable upstream is a 502 that does not echo the origin", async () => {
    vi.stubGlobal("fetch", async () => {
      throw new Error(`connect ECONNREFUSED ${ORIGIN}`);
    });
    const res = await call("/api/book/fills");
    expect(res.status).toBe(502);
    expect(await res.text()).not.toContain("book.internal");
    expectSecurityHeaders(res);
  });

  it("other paths still serve assets with the security headers", async () => {
    const res = await call("/api/bookkeeping");
    expect(await res.text()).toBe("asset");
    expectSecurityHeaders(res);
  });
});

describe("worker /api/book proxy — ORDERBOOK service binding", () => {
  const KEY = "binding-key-from-secret";
  let bound: Request[] = [];
  const binding = {
    fetch: async (req: Request) => {
      bound.push(req);
      return new Response(JSON.stringify({ bound: true }), {
        status: 200,
        headers: { "content-type": "application/json", "x-next-cursor": "5~0xab", "x-total-count": "9", "set-cookie": "a=b" },
      });
    },
  };
  beforeEach(() => {
    bound = [];
  });

  it("prefers the binding over ORDERBOOK_ORIGIN and passes the client IP with the binding key", async () => {
    const res = await call(
      "/api/book/orders?maker=0xabc",
      {
        headers: {
          "cf-connecting-ip": "203.0.113.7",
          // Client-written attempts to choose the billed address or the key: never forwarded.
          "x-orderbook-client-ip": "6.6.6.6",
          "x-orderbook-binding-key": "guess",
          "x-forwarded-for": "6.6.6.6",
          cookie: "session=secret",
        },
      },
      env({ ORDERBOOK: binding, ORDERBOOK_BINDING_KEY: KEY }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ bound: true });
    expect(seen).toHaveLength(0); // the origin fallback was not used
    expect(bound).toHaveLength(1);
    const req = bound[0]!;
    expect(new URL(req.url).pathname + new URL(req.url).search).toBe("/orders?maker=0xabc");
    expect(req.method).toBe("GET");
    expect(req.headers.get("x-orderbook-client-ip")).toBe("203.0.113.7");
    expect(req.headers.get("cf-connecting-ip")).toBe("203.0.113.7");
    expect(req.headers.get("x-orderbook-binding-key")).toBe(KEY);
    expect(req.headers.get("x-forwarded-for")).toBeNull();
    expect(req.headers.get("cookie")).toBeNull();
    // Paging metadata passes back; cookies do not.
    expect(res.headers.get("x-next-cursor")).toBe("5~0xab");
    expect(res.headers.get("x-total-count")).toBe("9");
    expect(res.headers.get("set-cookie")).toBeNull();
    expectSecurityHeaders(res);
  });

  it("POST through the binding keeps the body, content type and caps; no key configured → no key header", async () => {
    const body = JSON.stringify({ order: {}, sig: "0x" });
    const e = env({ ORDERBOOK: binding, ORDERBOOK_ORIGIN: undefined });
    const res = await call("/api/book/orders", { method: "POST", headers: { "content-type": "application/json" }, body }, e);
    expect(res.status).toBe(200);
    expect(await bound[0]!.text()).toBe(body);
    expect(bound[0]!.headers.get("content-type")).toBe("application/json");
    expect(bound[0]!.headers.get("x-orderbook-binding-key")).toBeNull();
    expect(bound[0]!.headers.get("x-orderbook-client-ip")).toBeNull(); // no cf-connecting-ip on this request
    const big = await call("/api/book/orders", { method: "POST", headers: { "content-type": "application/json" }, body: "x".repeat(MAX + 1) }, e);
    expect(big.status).toBe(413);
    expect((await call("/api/book/health", {}, e)).status).toBe(400);
    expect((await call("/api/book/cancels", {}, e)).status).toBe(405);
    expect(bound).toHaveLength(1);
  });

  it("a throwing binding is a 502", async () => {
    const res = await call("/api/book/fills", {}, env({ ORDERBOOK: { fetch: async () => { throw new Error("down"); } } }));
    expect(res.status).toBe(502);
  });
});

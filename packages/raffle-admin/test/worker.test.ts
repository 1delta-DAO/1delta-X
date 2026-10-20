import { describe, expect, it } from "vitest";

// @ts-expect-error — plain JS worker module
const { default: worker } = await import("../public/_worker.js");

/** The console's own proxy: only its routes, `authorization` forwarded to the orderbook binding. */
function env() {
  const seen: Array<{ url: string; method: string; auth: string | null; body: string | null }> = [];
  return {
    seen,
    ORDERBOOK: {
      fetch: async (r: Request) => {
        seen.push({ url: r.url, method: r.method, auth: r.headers.get("authorization"), body: r.body ? await r.text() : null });
        return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
      },
    },
    ASSETS: { fetch: async () => new Response("<html>") },
  };
}
const call = (e: ReturnType<typeof env>, path: string, init: RequestInit = {}) => worker.fetch(new Request(`https://admin.example${path}`, init), e) as Promise<Response>;

describe("raffle-admin _worker.js", () => {
  it("forwards admin calls with the bearer and bodies", async () => {
    const e = env();
    const auth = { authorization: "Bearer t" };
    expect((await call(e, "/api/book/raffle/admin/config", { headers: auth })).status).toBe(200);
    expect((await call(e, "/api/book/raffle/admin/config", { method: "PUT", headers: { ...auth, "content-type": "application/json" }, body: '{"id":"x"}' })).status).toBe(200);
    expect((await call(e, "/api/book/raffle/admin/entries/0x00000000000000000000000000000000000000a1?promotion=x", { method: "DELETE", headers: auth })).status).toBe(200);
    expect((await call(e, "/api/book/fills?limit=500", { headers: auth })).status).toBe(200);
    expect(e.seen).toEqual([
      { url: "https://orderbook.binding/raffle/admin/config", method: "GET", auth: "Bearer t", body: null },
      { url: "https://orderbook.binding/raffle/admin/config", method: "PUT", auth: "Bearer t", body: '{"id":"x"}' },
      { url: "https://orderbook.binding/raffle/admin/entries/0x00000000000000000000000000000000000000a1?promotion=x", method: "DELETE", auth: "Bearer t", body: null },
      { url: "https://orderbook.binding/fills?limit=500", method: "GET", auth: "Bearer t", body: null },
    ]);
  });

  it("refuses everything else and sets its own security headers", async () => {
    const e = env();
    expect((await call(e, "/api/book/orders", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status).toBe(400);
    expect((await call(e, "/api/book/raffle/admin/nope")).status).toBe(400);
    expect((await call(e, "/api/book/raffle", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status).toBe(405);
    expect(e.seen).toHaveLength(0);
    const page = await call(e, "/");
    expect(page.headers.get("x-robots-tag")).toBe("noindex, nofollow");
    expect(page.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
  });
});

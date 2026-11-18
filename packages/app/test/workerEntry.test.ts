import { describe, expect, it } from "vitest";

/**
 * `public/_worker.js` is the Pages advanced-mode MAIN module. workerd treats every
 * named export of a main module as an entrypoint and refuses to START the script on
 * anything that is not a function or a handler object:
 *
 *   Incorrect type for map entry 'BOOK_MAX_BODY_BYTES': the provided value is not
 *   of type 'function or ExportedHandler'
 *
 * — the whole app (assets included) then fails to deploy. Node-side tests import the
 * module happily, so this pins workerd's rule here; `make workers-smoke` starts the
 * real runtime (`wrangler pages dev`).
 */
describe("Pages worker entry module", () => {
  it("exports only Workers entrypoints (functions / handler objects), in practice only `default`", async () => {
    // @ts-expect-error — plain JS worker module
    const mod = (await import("../public/_worker.js")) as Record<string, unknown>;
    const bad = Object.entries(mod)
      .filter(([, v]) => !(typeof v === "function" || (typeof v === "object" && v !== null)))
      .map(([k, v]) => `${k}: ${typeof v}`);
    expect(bad).toEqual([]);
    expect(Object.keys(mod)).toEqual(["default"]);
    expect(typeof (mod.default as { fetch?: unknown }).fetch).toBe("function");
  });

  it("redirects the old language path (/es) to the query form (?lang=es), keeping the query", async () => {
    // @ts-expect-error — plain JS worker module
    const worker = (await import("../public/_worker.js")).default as { fetch: (r: Request, env: unknown) => Promise<Response> };
    const asked: string[] = [];
    const env = {
      ASSETS: {
        fetch: async (r: Request) => {
          asked.push(new URL(r.url).pathname);
          return new Response("<html>", { status: 200 });
        },
      },
    };
    const page = { headers: { accept: "text/html" } };

    for (const [from, to] of [
      ["/es", "/?lang=es"],
      ["/es/", "/?lang=es"],
      ["/es?x=1", "/?x=1&lang=es"],
    ] as const) {
      const res = await worker.fetch(new Request(`https://app.example${from}`, page), env);
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe(to);
    }
    expect(asked).toEqual([]);

    // The query form is the app itself, served with the security headers.
    const es = await worker.fetch(new Request("https://app.example/?lang=es", page), env);
    expect(es.status).toBe(200);
    expect(asked).toEqual(["/"]);
    expect(es.headers.get("x-frame-options")).toBe("DENY");
  });
});

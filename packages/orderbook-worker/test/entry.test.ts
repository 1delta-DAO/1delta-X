import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { BINDING_IP_HEADER, BINDING_KEY_HEADER, clientIp } from "../src/clientIp";
import * as entry from "../src/index";
import worker from "../src/index";
import { alice, resetWorld, signed, testEnv } from "./helpers";

const req = (headers: Record<string, string>) => new Request("https://book.test/health", { headers });
const KEY = { BINDING_KEY: "s3cret-binding-key" };

describe("entry module", () => {
  // Regression (staging harness, 2026-10-05): `index.ts` exported the string
  // constants BINDING_IP_HEADER / BINDING_KEY_HEADER, and workerd refused to start
  // the script — `wrangler dev` (and a real deploy) died with "Incorrect type for
  // map entry 'BINDING_IP_HEADER': the provided value is not of type 'function or
  // ExportedHandler'". vitest-pool-workers does not apply that startup check, so
  // this pins workerd's rule: every export of the main module is an entrypoint — a
  // class / function or a handler object — never a primitive.
  it("exports only Workers entrypoints (workerd refuses to start on anything else)", () => {
    const bad = Object.entries(entry)
      .filter(([, v]) => !(typeof v === "function" || (typeof v === "object" && v !== null)))
      .map(([k, v]) => `${k}: ${typeof v}`);
    expect(bad).toEqual([]);
    expect(Object.keys(entry).sort()).toEqual(["OrderBookDO", "default"]);
  });
});

describe("client IP resolution", () => {
  it("trusts cf-connecting-ip and never x-forwarded-for", () => {
    expect(clientIp(req({ "cf-connecting-ip": "203.0.113.5", "x-forwarded-for": "1.2.3.4" }), {})).toBe("203.0.113.5");
    expect(clientIp(req({ "x-forwarded-for": "1.2.3.4" }), {})).toBe("unknown");
  });

  it("trusts the binding header only with the right binding key", () => {
    const via = { [BINDING_IP_HEADER]: "198.51.100.1", "cf-connecting-ip": "203.0.113.5" };
    expect(clientIp(req({ ...via, [BINDING_KEY_HEADER]: KEY.BINDING_KEY }), KEY)).toBe("198.51.100.1");
    expect(clientIp(req({ ...via, [BINDING_KEY_HEADER]: "guess" }), KEY)).toBe("203.0.113.5");
    expect(clientIp(req(via), KEY)).toBe("203.0.113.5");
    // No key configured: the header is ignored outright, even with a matching-looking key.
    expect(clientIp(req({ ...via, [BINDING_KEY_HEADER]: "" }), {})).toBe("203.0.113.5");
    // Garbage in the trusted header is not an address.
    expect(clientIp(req({ [BINDING_IP_HEADER]: "a b; drop", [BINDING_KEY_HEADER]: KEY.BINDING_KEY }), KEY)).toBe("unknown");
  });

  it("routes through the entry worker to the chain's Durable Object", async () => {
    const res = await worker.fetch(req({ "cf-connecting-ip": "203.0.113.5", "x-ob-client-ip": "6.6.6.6" }), testEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ chainId: 30, configured: true });

    // A client-supplied internal header is overwritten by the entry worker.
    const list = await worker.fetch(new Request("https://book.test/orders", { headers: { "cf-connecting-ip": "203.0.113.77", "x-ob-client-ip": "6.6.6.6" } }), testEnv);
    expect(list.status).toBe(200);
    const stub = testEnv.BOOK.get(testEnv.BOOK.idFromName(`chain:${testEnv.CHAIN_ID}`));
    const keys = await runInDurableObject(stub, (_i, state) => state.storage.sql.exec(`SELECT key FROM buckets`).toArray().map((r) => r.key));
    expect(keys).toContain("ip:203.0.113.77");
    expect(keys).not.toContain("ip:6.6.6.6");
  });
});

describe("POST through the entry worker", () => {
  it("streams the JSON body to the Durable Object", async () => {
    resetWorld();
    const o = await signed(alice);
    const res = await worker.fetch(
      new Request("https://book.test/orders", { method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.88" }, body: o.body }),
      testEnv,
    );
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ orderHash: o.hash });
  });
});

describe("request bodies are buffered before the Durable Object sees them (M4)", () => {
  /** workerd's own "uncaught exception" log lines, captured by vitest.config.ts. */
  const runtimeErrors = async (): Promise<string[]> =>
    (await (await (env as unknown as { RUNTIME_ERRORS: Fetcher }).RUNTIME_ERRORS.fetch("http://runtime/errors")).json()) as string[];
  const streamErrors = (lines: string[]) => lines.filter((l) => /Can't read from request stream/.test(l));
  const post = (ip: string, body: BodyInit, init: { type?: string; method?: string; length?: string } = {}) =>
    SELF.fetch("https://book.test/orders", {
      method: init.method ?? "POST",
      headers: { "content-type": init.type ?? "application/json", "cf-connecting-ip": ip, ...(init.length ? { "content-length": init.length } : {}) },
      body,
      ...(body instanceof ReadableStream ? { duplex: "half" } : {}),
    } as RequestInit);

  // Regression (staging harness, 2026-10-05): the entry worker STREAMED each body into
  // the DO, and every refusal the DO answers without reading the body (429, 415, 405)
  // left the runtime's body pump to throw "Can't read from request stream after
  // response has been sent" — 6,941 uncaught exceptions under the abusive client. The
  // test passed regardless (the exception never reaches JS), hence the runtime-log probe.
  it("refusals that never read the body (415, 429, 405) raise no stream exception", async () => {
    const before = streamErrors(await runtimeErrors()).length;
    const junk = "x".repeat(150_000);
    for (let i = 0; i < 3; i++) {
      const r = await post("203.0.113.201", junk, { type: "text/plain" });
      expect(r.status).toBe(415);
      await r.arrayBuffer();
    }
    // IP capacity 100, a write costs 10: the 11th write is refused before the body is read.
    const statuses: number[] = [];
    for (let i = 0; i < 13; i++) {
      const r = await post("203.0.113.202", junk);
      statuses.push(r.status);
      await r.arrayBuffer();
    }
    expect(statuses.slice(0, 10).every((s) => s === 400)).toBe(true);
    expect(statuses.slice(10)).toEqual([429, 429, 429]);
    const put = await post("203.0.113.203", junk, { method: "PUT" });
    expect(put.status).toBe(405);
    await put.arrayBuffer();
    // The exception, when it happens, is logged asynchronously after the response.
    await new Promise((r) => setTimeout(r, 750));
    expect(streamErrors(await runtimeErrors()).slice(before)).toEqual([]);
  });

  it("a body over MAX_BODY_BYTES is a 413 from the entry worker, declared or streamed", async () => {
    const cap = Number(testEnv.MAX_BODY_BYTES);
    const declared = await post("203.0.113.204", "x".repeat(cap + 1));
    expect(declared.status).toBe(413);
    expect(await declared.json()).toEqual({ error: `body exceeds ${cap} bytes` });
    // A client that under-declares is cut off at the cap while reading.
    const chunk = new Uint8Array(64 * 1024).fill(120);
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        for (let i = 0; i < 6; i++) c.enqueue(chunk);
        c.close();
      },
    });
    const lying = await post("203.0.113.205", stream);
    expect(lying.status).toBe(413);
    // Exactly at the cap is fine (the DO then judges the JSON).
    const atCap = await post("203.0.113.206", "x".repeat(cap));
    expect(atCap.status).toBe(400);
  });
});

describe("cron trigger", () => {
  it("re-arms the Durable Object's alarm loop", async () => {
    const { createScheduledController } = await import("cloudflare:test");
    const stub = testEnv.BOOK.get(testEnv.BOOK.idFromName(`chain:${testEnv.CHAIN_ID}`));
    await runInDurableObject(stub, (_i, state) => state.storage.deleteAlarm());
    expect(await runInDurableObject(stub, (_i, state) => state.storage.getAlarm())).toBeNull();
    await worker.scheduled(createScheduledController({ cron: "* * * * *", scheduledTime: Date.now() }), testEnv);
    expect(await runInDurableObject(stub, (_i, state) => state.storage.getAlarm())).toBeGreaterThan(Date.now() - 1000);
  });
});

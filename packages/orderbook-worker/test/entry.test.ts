import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import worker, { BINDING_IP_HEADER, BINDING_KEY_HEADER, clientIp } from "../src/index";
import { alice, resetWorld, signed, testEnv } from "./helpers";

const req = (headers: Record<string, string>) => new Request("https://book.test/health", { headers });
const KEY = { BINDING_KEY: "s3cret-binding-key" };

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

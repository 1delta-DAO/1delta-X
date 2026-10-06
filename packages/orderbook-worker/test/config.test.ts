import { describe, expect, it } from "vitest";

import { loadConfig, locationHint, maxBodyBytesOf, type Env } from "../src/config";
import worker from "../src/index";
import { isMethodNotFound, redactRpcUrl } from "../src/redact";
import { testEnv } from "./helpers";

const SECRET = "https://rootstock-mainnet.example-provider.io/v2/sk_live_ABC123";

describe("RPC_URL_SECRET (B3a)", () => {
  it("wins over the RPC_URL var; /health names the binding, never the URL", () => {
    const both = loadConfig({ ...testEnv, RPC_URL: "https://public-node.rsk.co", RPC_URL_SECRET: SECRET } as Env);
    expect(both.chain.rpcUrl).toBe(SECRET);
    expect(both.rpcSource).toBe("RPC_URL_SECRET");
    const plain = loadConfig({ ...testEnv, RPC_URL: "https://public-node.rsk.co", RPC_URL_SECRET: " " } as Env);
    expect(plain.chain.rpcUrl).toBe("https://public-node.rsk.co");
    expect(plain.rpcSource).toBe("RPC_URL");
    // Neither: not configured (writes 503, no chain work).
    expect(loadConfig({ ...testEnv, RPC_URL: "", RPC_URL_SECRET: undefined } as Env).configured).toBe(false);
  });

  it("an error quoting the keyed URL is redacted before it reaches /health", () => {
    const msg = `HTTP request failed. URL: ${SECRET} Status: 429; host rootstock-mainnet.example-provider.io`;
    const out = redactRpcUrl(msg, SECRET);
    expect(out).not.toContain("sk_live_ABC123");
    expect(out).not.toContain("example-provider.io");
  });

  it("recognises 'method not found' by code or by the node's message, and nothing else", () => {
    expect(isMethodNotFound({ code: -32601 })).toBe(true);
    expect(isMethodNotFound(new Error("x", { cause: { code: -32601 } }))).toBe(true);
    expect(isMethodNotFound(new Error('The method "eth_getLogs" does not exist / is not available.'))).toBe(true);
    expect(isMethodNotFound(new Error("the method eth_getLogs does not exist/is not available"))).toBe(true);
    expect(isMethodNotFound(new Error("query exceeds max block range 1000"))).toBe(false);
    expect(isMethodNotFound(new Error("HTTP request failed. Status: 503"))).toBe(false);
    expect(isMethodNotFound({ code: -32005 })).toBe(false);
  });
});

describe("DO_LOCATION_HINT and MAX_BODY_BYTES", () => {
  it("accepts Cloudflare's hints only; an unknown one is ignored, never breaks get()", async () => {
    expect(locationHint({ DO_LOCATION_HINT: "wnam" })).toBe("wnam");
    expect(locationHint({ DO_LOCATION_HINT: "Apac-NE" })).toBe("apac-ne");
    expect(locationHint({ DO_LOCATION_HINT: "mars" })).toBeUndefined();
    for (const hint of ["wnam", "mars", ""]) {
      const res = await worker.fetch(new Request("https://book.test/health", { headers: { "cf-connecting-ip": "203.0.113.70" } }), { ...testEnv, DO_LOCATION_HINT: hint });
      expect(res.status).toBe(200);
    }
  });

  it("the entry worker's body cap reads MAX_BODY_BYTES like the DO does", () => {
    expect(maxBodyBytesOf({ MAX_BODY_BYTES: "1024" })).toBe(1024);
    expect(maxBodyBytesOf({})).toBe(256 * 1024);
    expect(() => maxBodyBytesOf({ MAX_BODY_BYTES: "-1" })).toThrow();
  });
});

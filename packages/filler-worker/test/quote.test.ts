import { hashOrderStruct, orderToJson, packTiming } from "@1delta-x/sdk";
import { decodeFunctionData, type Hex } from "viem";
import { AGGREGATOR_FILL_SOLVER_ABI } from "@1delta-x/sdk";
import { beforeEach, describe, expect, it } from "vitest";

import type { FillerDO, TickSummary } from "../src/do";
import worker from "../src/index";
import { ADMIN, GAS_PRICE, order, RECEIVED, resetWorld, testEnv, USDT0, WRBTC, world } from "./helpers";

/**
 * The PUBLIC `POST /quote` (packages/beta-filler src/quote.ts): no auth, body caps,
 * per-IP + global rate limits in the DO's SQLite, the filler's own pricing —
 * amountOut = route output − gas × (1 + QUOTE_GAS_MARGIN_BPS) — and nothing secret
 * in any answer.
 */
beforeEach(() => resetWorld());

let ipSeq = 0;
/** A fresh visitor IP per call site, so the shared DO's per-IP buckets do not leak across tests. */
const nextIp = () => `198.51.100.${++ipSeq}`;

const post = (body: unknown, o: { ip?: string; headers?: Record<string, string>; method?: string; env?: Record<string, unknown>; raw?: string } = {}) =>
  worker.fetch(
    new Request("https://filler.example.com/quote", {
      method: o.method ?? "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": o.ip ?? nextIp(), ...(o.headers ?? {}) },
      ...((o.method ?? "POST") === "POST" ? { body: o.raw ?? JSON.stringify(body) } : {}),
    }),
    (o.env ?? testEnv) as never,
  );

const SELL = { chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "sell", amountIn: RECEIVED.toString(), delivery: "pull" };
/** WRBTC wei → USDT0 units at $100k, rounded up (the route's gas conversion). */
const rbtcToUsdt0 = (wei: bigint) => (wei * 10n ** 8n + 10n ** 15n - 1n) / 10n ** 15n;
const admin = (path: string) => worker.fetch(new Request(`https://filler.example.com${path}`, { method: "POST", headers: { authorization: `Bearer ${ADMIN}` } }), testEnv);
const named = () => testEnv.FILLER.get(testEnv.FILLER.idFromName("filler")) as DurableObjectStub<FillerDO>;

describe("POST /quote — the math", () => {
  it("SELL 0.01 WRBTC: grossOut = the route output, amountOut = gross − gas × 1.1 (QUOTE_GAS_MARGIN_BPS 1000)", async () => {
    const res = await post(SELL);
    expect(res.status).toBe(200);
    const q = (await res.json()) as Record<string, string | number | boolean | Record<string, unknown>>;
    expect(q.grossOut).toBe("1000000000"); // 0.01 × $100k
    expect(q.gasUnits).toBe("334400"); // QUOTE_GAS_ESTIMATE_PULL 380k × 0.88 (no receipt learned yet)
    const gasCost = rbtcToUsdt0(334_400n * GAS_PRICE);
    expect(q.gasCostOut).toBe(gasCost.toString());
    const charge = (gasCost * 11_000n + 9_999n) / 10_000n;
    expect(q.gasChargeOut).toBe(charge.toString());
    expect(q.amountOut).toBe((1_000_000_000n - charge).toString());
    expect(q.gasMarginBps).toBe("1000");
    expect(q.toleranceBps).toBe("0");
    expect(q.gasPriceWei).toBe(GAS_PRICE.toString());
    expect(q).toMatchObject({ chainId: 30, side: "sell", delivery: "pull", tokenIn: WRBTC, tokenOut: USDT0, strategy: "route", route: { source: "oku", hops: 1 }, live: true });
    expect(Number(q.validUntil) - Math.floor(Number(q.issuedAt) / 1000)).toBe(30);
    expect(String(q.quoteId)).toMatch(/^q_[0-9a-f]{24}$/);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("BUY (pay $20 USDT0 for WRBTC): exact input of the pay amount, gas in the RECEIVE token (wei); direct = 360k × 0.88", async () => {
    const res = await post({ chainId: 30, marketId: "rsk-30-wrbtc-usd0", side: "buy", amountIn: "20000000", delivery: "direct" });
    expect(res.status).toBe(200);
    const q = (await res.json()) as Record<string, string>;
    expect([q.tokenIn, q.tokenOut]).toEqual([USDT0, WRBTC]);
    expect(q.grossOut).toBe((2n * 10n ** 14n).toString());
    expect(q.gasUnits).toBe("316800");
    const charge = (316_800n * GAS_PRICE * 11_000n + 9_999n) / 10_000n;
    expect(q.amountOut).toBe((2n * 10n ** 14n - charge).toString());
  });

  it("nothing secret in an answer (key, admin token, RPC URL)", async () => {
    const text = await (await post(SELL)).text();
    expect(text.toLowerCase()).not.toContain((testEnv.PRIVATE_KEY as string).slice(2).toLowerCase());
    expect(text).not.toContain(ADMIN);
    expect(text).not.toContain("rpc.invalid");
  });

  it("an order signed from the quote is matched by the filler and sent on the next tick (tag `quoted`)", async () => {
    const q = (await (await post({ ...SELL, maker: "0x00000000000000000000000000000000000000bb" })).json()) as Record<string, string> & { amountOut: string };
    const o = order();
    const now = Math.floor(Date.now() / 1000);
    o.legsOut = [{ ...o.legsOut[0]!, start: BigInt(q.amountOut), end: (BigInt(q.amountOut) * 9_970n) / 10_000n }];
    o.timing = packTiming(now, 60, 0);
    o.expiry = BigInt(now + 300);
    const h = hashOrderStruct(o).toLowerCase() as Hex;
    world.book.push({ orderHash: h, order: orderToJson(o), sig: "0x00", state: { ok: true, status: "Fillable", fillableAmount: RECEIVED.toString(), validatorsPass: true } });
    const t = (await named().runTick("test")) as TickSummary;
    expect(t.sent?.orderHash).toBe(h);
    expect(world.sent).toHaveLength(1);
    expect(decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: world.sent[0]!.data! }).functionName).toBe("executeFill");
    const st = (await (await worker.fetch(new Request("https://filler.example.com/status", { headers: { authorization: `Bearer ${ADMIN}` } }), testEnv)).json()) as { pending: { info: { tag: string } } };
    expect(st.pending.info.tag).toContain(`pull quoted ${q.quoteId} ${h}`);
    // Clear the outstanding tx so the shared DO is idle for the next test.
    world.receipt = "success";
    await named().runTick("test");
  });
});

describe("POST /quote — validation", () => {
  it.each([
    [{ ...SELL, chainId: 31 }, /chainId/],
    [{ ...SELL, side: "long" }, /side/],
    [{ ...SELL, delivery: "x" }, /delivery/],
    [{ ...SELL, amountIn: "0" }, /out of range/],
    [{ ...SELL, amountIn: 1 }, /amountIn/],
    [{ ...SELL, marketId: "nope" }, /unknown marketId/],
    [{ ...SELL, extra: true }, /unknown field/],
    [[], /JSON object/],
  ])("400 for %j", async (body, why) => {
    const res = await post(body);
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toMatch(why);
  });

  it("400 for a body that is not JSON; 413 above 2 KiB; 415 without application/json; 405 for GET", async () => {
    expect((await post(null, { raw: "{nope" })).status).toBe(400);
    expect((await post(null, { raw: JSON.stringify({ ...SELL, pad: "x".repeat(3000) }) })).status).toBe(413);
    expect((await post(SELL, { headers: { "content-type": "text/plain" } })).status).toBe(415);
    const g = await post(null, { method: "GET" });
    expect(g.status).toBe(405);
    expect(g.headers.get("allow")).toBe("POST");
  });

  it("422 when there is no quote (gas above the output of a dust ticket)", async () => {
    const res = await post({ ...SELL, amountIn: "100000000000" }); // 1e-7 WRBTC = $0.01
    expect(res.status).toBe(422);
    expect(((await res.json()) as { error: string; reason: string }).reason).toMatch(/exceeds the output/);
  });

  it("503 while the filler is paused", async () => {
    expect((await admin("/pause")).status).toBe(200);
    try {
      const res = await post(SELL);
      expect(res.status).toBe(503);
      expect(await res.json()).toEqual({ error: "filler paused" });
    } finally {
      await admin("/resume");
    }
  });
});

describe("POST /quote — rate limits (DO SQLite token buckets)", () => {
  it("per visitor IP: QUOTE_RATE_IP_CAPACITY (30) then 429 with retry-after; another IP is unaffected", async () => {
    const ip = nextIp();
    const codes: number[] = [];
    for (let i = 0; i < 31; i++) codes.push((await post({ ...SELL, side: "sell", amountIn: "abc" }, { ip })).status);
    expect(codes.slice(0, 30).every((c) => c === 400)).toBe(true); // limited BEFORE parsing: bad requests are billed too
    expect(codes[30]).toBe(429);
    const r = await post(SELL, { ip });
    expect(r.status).toBe(429);
    expect(Number(r.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);
    expect((await post(SELL, { ip: nextIp() })).status).toBe(200);
  });

  it("x-filler-client-ip is honoured ONLY with the matching QUOTE_BINDING_KEY (the Pages worker's binding call)", async () => {
    const env = { ...testEnv, QUOTE_BINDING_KEY: "k-123" };
    const edge = nextIp();
    const visitor = nextIp();
    // Without the key the claimed IP is ignored: billed to the edge address.
    for (let i = 0; i < 30; i++) await post({ ...SELL, amountIn: "abc" }, { ip: edge, headers: { "x-filler-client-ip": nextIp() }, env });
    expect((await post(SELL, { ip: edge, env })).status).toBe(429);
    // With the key, the visitor's own bucket.
    expect((await post(SELL, { ip: edge, env, headers: { "x-filler-client-ip": visitor, "x-filler-binding-key": "k-123" } })).status).toBe(200);
    // A wrong key: the edge address again (exhausted).
    expect((await post(SELL, { ip: edge, env, headers: { "x-filler-client-ip": visitor, "x-filler-binding-key": "nope" } })).status).toBe(429);
  });
});

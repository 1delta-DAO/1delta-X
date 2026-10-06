import { hashOrderStruct, orderToJson, OrderSide, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Hex } from "viem";
import { describe, expect, it } from "vitest";

import { ROOTSTOCK } from "../src/config";
import { fetchOrders } from "../src/intake";

const SIG = `0x${"ab".repeat(65)}` as Hex;

function order(nonce: bigint): Order {
  return {
    maker: "0x00000000000000000000000000000000000000bb",
    side: OrderSide.SELL,
    nonce,
    expiry: 2_000_000_000n,
    legsIn: [{ token: ROOTSTOCK.usdrif, start: 100n * 10n ** 18n, end: 0n }],
    legsOut: [{ token: ROOTSTOCK.usdt0, start: 99_400_000n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };
}

const state = (over: Record<string, unknown> = {}) => ({ status: "Fillable", ok: true, fillableAmount: "100000000000000000000", isSignatureValid: true, validatorsPass: true, ...over });
const item = (o: Order, over: Record<string, unknown> = {}) => ({ orderHash: hashOrderStruct(o), order: orderToJson(o), sig: SIG, addedAt: 1, filledAmount: "0", state: state(), ...over });

describe("fetchOrders — the worker's GET /orders JSON as filler intake", () => {
  it("parses strictly, pages by cursor, and keeps only orders the node reports fillable", async () => {
    const [a, b, c, d, e] = [1n, 2n, 3n, 4n, 5n].map(order);
    const pages: Record<string, unknown> = {
      "": { orders: [item(a!), item(b!, { orderHash: `0x${"00".repeat(32)}` }), item(c!, { state: state({ ok: false }) })], nextCursor: "9~0xabc" },
      "9~0xabc": { orders: [item(d!, { state: state({ validatorsPass: false }) }), item(e!), { orderHash: "0x", order: { maker: "x" }, sig: SIG }] },
    };
    const urls: string[] = [];
    const doFetch = async (url: string) => {
      urls.push(url);
      const cursor = new URL(url).searchParams.get("cursor") ?? "";
      return new Response(JSON.stringify(pages[cursor]), { status: 200 });
    };
    const { entries, skipped } = await fetchOrders("https://book.example/api/book/", doFetch);
    expect(urls[0]).toBe("https://book.example/api/book/orders?limit=500&fillableOnly=true");
    expect(urls[1]).toContain("cursor=9~0xabc");
    expect(entries.map((x) => x.announce.order.nonce)).toEqual([1n, 5n]);
    expect(entries[0]!.orderHash).toBe(hashOrderStruct(a!));
    expect(entries[0]!.state?.fillableAmount).toBe(100n * 10n ** 18n);
    expect(entries[0]!.announce.sig).toBe(SIG);
    expect(skipped).toBe(4);
  });

  it("throws on a non-2xx answer so the sweep logs it", async () => {
    await expect(fetchOrders("https://book.example", async () => new Response("no", { status: 429 }))).rejects.toThrow(/429/);
  });
});

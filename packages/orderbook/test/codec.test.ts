import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { hashOrderStruct, permitBatch, takerPermit, tokenPermit, type Order } from "@1delta-x/sdk";
import { zeroAddress } from "viem";

import {
  decodeFillNotice,
  decodeOrderAnnounce,
  decodeOrderList,
  decodeOrderReplace,
  decodeSoftCancel,
  decodeStreamMessage,
  encodeFillNotice,
  encodeOrderAnnounce,
  encodeOrderList,
  encodeOrderReplace,
  encodeSoftCancel,
  encodeStreamMessage,
  orderToProto,
  protoToOrder,
} from "../src/proto/codec";
import { SCHEMA, StreamKind } from "../src/proto/schema";
import type { OrderAnnounce } from "../src/messages";
// The SDK's canonical order + its contract-verified golden hash — the same
// fixture the SDK's own EIP-712 golden test pins.
import { CANONICAL_ORDER, GOLDEN_ORDER_HASH } from "../../sdk/test/canonicalOrder";

/** A second, arbitrary 32-byte hash — batch cancels need more than one. */
const OTHER_HASH = "0x1111111111111111111111111111111111111111111111111111111111111111" as const;

describe("Order ⇄ protobuf", () => {
  it("round-trips the canonical order field-for-field", () => {
    const back = protoToOrder(orderToProto(CANONICAL_ORDER));
    expect(back).toEqual(CANONICAL_ORDER);
  });

  it("preserves the golden struct hash through the wire", () => {
    // Sanity: the fixture still hashes to the contract-verified constant…
    expect(hashOrderStruct(CANONICAL_ORDER)).toBe(GOLDEN_ORDER_HASH);
    // …and the encode → decode round-trip does not perturb it.
    const roundTripped = decodeOrderAnnounce(encodeOrderAnnounce({ order: CANONICAL_ORDER, sig: "0x" })).order;
    expect(hashOrderStruct(roundTripped)).toBe(GOLDEN_ORDER_HASH);
  });
});

describe("message encode/decode", () => {
  const sig = `0x${"ab".repeat(65)}` as const;

  it("OrderAnnounce with a permit batch", () => {
    const batch = permitBatch(
      [tokenPermit(CANONICAL_ORDER.maker, CANONICAL_ORDER.legsIn[0]!.token, 2_000_000_000n, 1_893_456_000)],
      [takerPermit(CANONICAL_ORDER.maker, CANONICAL_ORDER.maker, `0x${"11".repeat(32)}`, 1_500_000_000n, 1_893_456_000)],
      7n,
      1_893_456_000n,
    );
    const a: OrderAnnounce = { order: CANONICAL_ORDER, sig, permitBatch: batch, sigless: false };
    const back = decodeOrderAnnounce(encodeOrderAnnounce(a));
    expect(back.sig).toBe(sig);
    expect(back.order).toEqual(CANONICAL_ORDER);
    expect(back.permitBatch).toEqual(batch);
  });

  it("OrderAnnounce without a permit batch omits it", () => {
    const back = decodeOrderAnnounce(encodeOrderAnnounce({ order: CANONICAL_ORDER, sig }));
    expect(back.permitBatch).toBeUndefined();
    expect(back.sigless).toBe(false);
  });

  it("SoftCancel round-trips, including a multi-hash batch", () => {
    const c = {
      cancel: {
        maker: CANONICAL_ORDER.maker,
        orderHashes: [GOLDEN_ORDER_HASH, OTHER_HASH],
        issuedAt: 1_700_000_000n,
        expiry: 1_700_000_300n,
      },
      sig,
    } as const;
    expect(decodeSoftCancel(encodeSoftCancel(c))).toEqual(c);
  });

  it("SoftCancel refuses a mis-sized order hash", () => {
    const bad = {
      cancel: { maker: CANONICAL_ORDER.maker, orderHashes: ["0xdead" as const], issuedAt: 1n, expiry: 2n },
      sig,
    };
    // Hashes are fixed-width on the wire — minimizing one would silently change
    // which order a cancel names.
    expect(() => encodeSoftCancel(bad)).toThrow();
  });

  it("OrderReplace round-trips both signed halves", () => {
    const r = {
      cancel: {
        cancel: {
          maker: CANONICAL_ORDER.maker,
          orderHashes: [GOLDEN_ORDER_HASH],
          issuedAt: 1_700_000_000n,
          expiry: 1_700_000_300n,
        },
        sig,
      },
      announce: { order: { ...CANONICAL_ORDER, nonce: 2n } as Order, sig, sigless: false },
      replaces: GOLDEN_ORDER_HASH,
    } as const;
    const back = decodeOrderReplace(encodeOrderReplace(r));
    expect(back.replaces).toBe(GOLDEN_ORDER_HASH);
    expect(back.announce.order.nonce).toBe(2n);
    expect(back.cancel).toEqual(r.cancel);
  });

  it("FillNotice", () => {
    const n = { orderHash: GOLDEN_ORDER_HASH, filler: CANONICAL_ORDER.exclusiveFiller } as const;
    expect(decodeFillNotice(encodeFillNotice(n))).toEqual(n);
  });

  it("OrderList", () => {
    const items: OrderAnnounce[] = [
      { order: CANONICAL_ORDER, sig },
      { order: { ...CANONICAL_ORDER, nonce: 2n } as Order, sig: "0x" },
    ];
    const back = decodeOrderList(encodeOrderList(items));
    expect(back).toHaveLength(2);
    expect(back[0]!.order.nonce).toBe(1n);
    expect(back[1]!.order.nonce).toBe(2n);
  });

  it("StreamMessage — SNAPSHOT / ADD / CANCEL / REPLACE", () => {
    const add = decodeStreamMessage(encodeStreamMessage({ kind: StreamKind.ADD, order: { order: CANONICAL_ORDER, sig } }));
    expect(add.kind).toBe(StreamKind.ADD);

    const snap = decodeStreamMessage(encodeStreamMessage({ kind: StreamKind.SNAPSHOT, orders: [{ order: CANONICAL_ORDER, sig }] }));
    expect(snap.kind).toBe(StreamKind.SNAPSHOT);
    if (snap.kind === StreamKind.SNAPSHOT) expect(snap.orders).toHaveLength(1);

    const softCancel = {
      cancel: { maker: CANONICAL_ORDER.maker, orderHashes: [GOLDEN_ORDER_HASH], issuedAt: 1n, expiry: 2n },
      sig,
    } as const;
    const cancel = decodeStreamMessage(encodeStreamMessage({ kind: StreamKind.CANCEL, cancel: softCancel }));
    expect(cancel.kind).toBe(StreamKind.CANCEL);
    if (cancel.kind === StreamKind.CANCEL) expect(cancel.cancel).toEqual(softCancel);

    const replace = decodeStreamMessage(
      encodeStreamMessage({
        kind: StreamKind.REPLACE,
        replace: {
          cancel: softCancel,
          announce: { order: CANONICAL_ORDER, sig, sigless: false },
          replaces: GOLDEN_ORDER_HASH,
        },
      }),
    );
    expect(replace.kind).toBe(StreamKind.REPLACE);
    if (replace.kind === StreamKind.REPLACE) expect(replace.replace.replaces).toBe(GOLDEN_ORDER_HASH);
  });

  it("handles a zero-legged fill-module order (empty anchor legs)", () => {
    const nftSwap: Order = { ...CANONICAL_ORDER, legsIn: [], legsOut: [], fillTotal: 1n };
    const back = decodeOrderAnnounce(encodeOrderAnnounce({ order: nftSwap, sig: "0x", sigless: true }));
    expect(back.order).toEqual(nftSwap);
    expect(back.sigless).toBe(true);
    expect(hashOrderStruct(back.order)).toBe(hashOrderStruct(nftSwap));
  });
});

describe("schema", () => {
  it("orderbook.proto mirrors the embedded SCHEMA (no drift)", () => {
    const file = readFileSync(new URL("../src/proto/orderbook.proto", import.meta.url), "utf8");
    expect(file.trim()).toBe(SCHEMA.trim());
  });
});

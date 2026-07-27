import { describe, expect, it, vi } from "vitest";

import { hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Hex } from "viem";

import { Book } from "../src/book";
import { OrderbookClient, signSoftCancel } from "../src/client";
import type { OrderAnnounce } from "../src/messages";
import { InMemoryTransport } from "../src/transport";
import type { Verifier } from "../src/verify";

// A stub Verifier that admits everything — lets us test the Book/transport
// wiring without a chain (Layer 2 is covered by the server integration test).
const stubVerifier = {
  verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }),
  refreshStates: async () => new Map(),
} as unknown as Verifier;

const config = { chainId: 31, settlement: "0x0000000000000000000000000000000000000001" as const, permit3: zeroAddress, lens: zeroAddress, rpcUrl: "" };

function orderFor(maker: Hex): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce: 1n,
    deadline: 4_000_000_000n,
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 800n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
  };
}

describe("Book over InMemoryTransport", () => {
  it("admits a published order and evicts on a maker-signed soft cancel", async () => {
    const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
    const transport = new InMemoryTransport();
    const book = new Book({ transport, config, verifier: stubVerifier, revalidateMs: 0 });
    await book.start();

    const client = new OrderbookClient(transport, config);
    const order = orderFor(account.address);
    const orderHash = hashOrderStruct(order);

    await client.publishOrder(order, "0x");
    await vi.waitFor(() => expect(book.size).toBe(1));
    expect(book.get(orderHash)?.announce.order.maker).toBe(account.address);

    // A cancel signed by a DIFFERENT key must be ignored (spoofing guard).
    const stranger = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
    await client.cancelOrder(await signSoftCancel(stranger, orderHash));
    await new Promise((r) => setTimeout(r, 20));
    expect(book.size).toBe(1);

    // The maker's own signed cancel evicts it.
    const removed: Hex[] = [];
    book.onRemove((e) => removed.push(e.orderHash));
    await client.cancelOrder(await signSoftCancel(account, orderHash));
    await vi.waitFor(() => expect(book.size).toBe(0));
    expect(removed).toContain(orderHash);

    await book.stop();
  });

  it("backfills from transport history on start", async () => {
    const transport = new InMemoryTransport();
    const client = new OrderbookClient(transport, config);
    // Publish BEFORE any book exists — lands only in the Store ring buffer.
    await client.publishOrder(orderFor("0x00000000000000000000000000000000000000a1"), "0x");

    const book = new Book({ transport, config, verifier: stubVerifier, revalidateMs: 0 });
    await book.start();
    await vi.waitFor(() => expect(book.size).toBe(1));
    await book.stop();
  });
});

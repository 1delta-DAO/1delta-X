import { describe, expect, it, vi } from "vitest";

import { amendOrder, hashOrderStruct, OrderSide, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Hex, type PublicClient } from "viem";

import { Book } from "../src/book";
import { CancelVerifier } from "../src/cancels";
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

/**
 * A client that fails every on-chain call. Deliberate: it pins that the EOA
 * cancel path is LOCAL — an EOA maker's cancel must verify with zero RPC, so a
 * dead node cannot stop a maker retracting its quotes. Any test that reaches the
 * chain here fails loudly instead of silently going slow.
 */
const noChain = {
  readContract: async () => {
    throw new Error("no chain in this test");
  },
  verifyTypedData: async () => {
    throw new Error("no chain in this test");
  },
} as unknown as PublicClient;

const cancelVerifier = new CancelVerifier(noChain, config);

function bookFor(transport: InMemoryTransport): Book {
  return new Book({ transport, config, verifier: stubVerifier, cancelVerifier, revalidateMs: 0 });
}

function orderFor(maker: Hex, nonce = 1n): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce,
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

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const stranger = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

describe("Book over InMemoryTransport", () => {
  it("admits a published order and evicts on a maker-signed soft cancel", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();

    const client = new OrderbookClient(transport, config);
    const order = orderFor(account.address);
    const orderHash = hashOrderStruct(order);

    await client.publishOrder(order, "0x");
    await vi.waitFor(() => expect(book.size).toBe(1));
    expect(book.get(orderHash)?.announce.order.maker).toBe(account.address);

    // A cancel signed by a DIFFERENT key must be ignored (spoofing guard).
    await client.cancelOrder(await signSoftCancel(stranger, stranger.address, [orderHash], config));
    await new Promise((r) => setTimeout(r, 20));
    expect(book.size).toBe(1);

    // …and so must a cancel that CLAIMS to be the maker but is signed by someone
    // else. This is the check the signature does, as opposed to the ownership
    // check above.
    await client.cancelOrder(await signSoftCancel(stranger, account.address, [orderHash], config));
    await new Promise((r) => setTimeout(r, 20));
    expect(book.size).toBe(1);

    // The maker's own signed cancel evicts it.
    const removed: Hex[] = [];
    book.onRemove((e) => removed.push(e.orderHash));
    await client.cancelOrder(await signSoftCancel(account, account.address, [orderHash], config));
    await vi.waitFor(() => expect(book.size).toBe(0));
    expect(removed).toContain(orderHash);

    await book.stop();
  });

  it("retracts a whole quote set with ONE signature", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();
    const client = new OrderbookClient(transport, config);

    const orders = [1n, 2n, 3n].map((n) => orderFor(account.address, n));
    for (const o of orders) await client.publishOrder(o, "0x");
    await vi.waitFor(() => expect(book.size).toBe(3));

    const hashes = orders.map(hashOrderStruct);
    await client.cancelOrder(await signSoftCancel(account, account.address, hashes, config));
    await vi.waitFor(() => expect(book.size).toBe(0));

    await book.stop();
  });

  it("evicts only the hashes the signer actually owns", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();
    const client = new OrderbookClient(transport, config);

    const mine = orderFor(account.address, 1n);
    const theirs = orderFor(stranger.address, 2n);
    await client.publishOrder(mine, "0x");
    await client.publishOrder(theirs, "0x");
    await vi.waitFor(() => expect(book.size).toBe(2));

    // A VALID signature naming both hashes — but only one of those orders is
    // this maker's. The other must survive.
    await client.cancelOrder(
      await signSoftCancel(account, account.address, [hashOrderStruct(mine), hashOrderStruct(theirs)], config),
    );
    await vi.waitFor(() => expect(book.size).toBe(1));
    expect(book.get(hashOrderStruct(theirs))).toBeDefined();

    await book.stop();
  });

  it("ignores an expired cancel", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();
    const client = new OrderbookClient(transport, config);

    const order = orderFor(account.address);
    await client.publishOrder(order, "0x");
    await vi.waitFor(() => expect(book.size).toBe(1));

    const stale = await signSoftCancel(account, account.address, [hashOrderStruct(order)], config, {
      now: 1_000_000n, // long past
    });
    await client.cancelOrder(stale);
    await new Promise((r) => setTimeout(r, 20));
    expect(book.size).toBe(1);

    await book.stop();
  });

  it("applies a cancel-and-replace as one step", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();
    const client = new OrderbookClient(transport, config);

    const prev = orderFor(account.address, 1n);
    await client.publishOrder(prev, "0x");
    await vi.waitFor(() => expect(book.size).toBe(1));

    // Re-price: same order, better output, fresh nonce.
    const amended = await amendOrder(
      account,
      prev,
      2n,
      { legsOut: [{ ...prev.legsOut[0]!, start: 950n, end: 850n }] },
      config,
    );
    expect(amended.replaces).toBe(hashOrderStruct(prev));

    const res = await book.ingestReplace({
      cancel: { cancel: amended.cancel, sig: amended.cancelSig },
      announce: { order: amended.order, sig: amended.sig },
      replaces: amended.replaces,
    });

    expect(res.ok).toBe(true);
    expect(book.size).toBe(1); // exactly one live order, never zero and never two
    expect(book.get(amended.orderHash)).toBeDefined();
    expect(book.get(amended.replaces)).toBeUndefined();

    await book.stop();
  });

  it("leaves the predecessor live when the replacement fails to verify", async () => {
    const transport = new InMemoryTransport();
    const rejecting = new Book({
      transport,
      config,
      verifier: { verifyAnnounce: async () => ({ ok: false, reason: "nope", orderHash: "0x" }), refreshStates: async () => new Map() } as unknown as Verifier,
      cancelVerifier,
      revalidateMs: 0,
    });
    await rejecting.start();

    const prev = orderFor(account.address, 1n);
    rejecting.admit(hashOrderStruct(prev), { order: prev, sig: "0x" }); // seed directly

    const amended = await amendOrder(account, prev, 2n, { minFillAnchor: 5n }, config);
    const res = await rejecting.ingestReplace({
      cancel: { cancel: amended.cancel, sig: amended.cancelSig },
      announce: { order: amended.order, sig: amended.sig },
      replaces: amended.replaces,
    });

    expect(res.ok).toBe(false);
    expect(rejecting.get(amended.replaces)).toBeDefined(); // predecessor untouched
    await rejecting.stop();
  });

  it("rejects a replace whose cancel does not name the replaced order", async () => {
    const transport = new InMemoryTransport();
    const book = bookFor(transport);
    await book.start();

    const prev = orderFor(account.address, 1n);
    const other = orderFor(account.address, 9n);
    const amended = await amendOrder(account, prev, 2n, { minFillAnchor: 5n }, config);

    const res = await book.ingestReplace({
      cancel: { cancel: amended.cancel, sig: amended.cancelSig },
      announce: { order: amended.order, sig: amended.sig },
      replaces: hashOrderStruct(other), // ← not what the cancel signed
    });
    expect(res.ok).toBe(false);
    expect(res.reason).toContain("does not name");

    await book.stop();
  });

  it("backfills from transport history on start", async () => {
    const transport = new InMemoryTransport();
    const client = new OrderbookClient(transport, config);
    // Publish BEFORE any book exists — lands only in the Store ring buffer.
    await client.publishOrder(orderFor("0x00000000000000000000000000000000000000a1"), "0x");

    const book = bookFor(transport);
    await book.start();
    await vi.waitFor(() => expect(book.size).toBe(1));
    await book.stop();
  });
});

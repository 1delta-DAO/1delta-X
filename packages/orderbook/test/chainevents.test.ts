import { describe, expect, it, vi } from "vitest";

import { hashOrderStruct, ocoGroup, OrderSide, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Hex, type PublicClient } from "viem";

import { Book } from "../src/book";
import { CancelVerifier } from "../src/cancels";
import { InMemoryTransport } from "../src/transport";
import type { Layer2Result, Verifier } from "../src/verify";
import { isOcoGroupLeg } from "../src/watcher";
import type { OrderAnnounce } from "../src/messages";

const config = { chainId: 31, settlement: "0x0000000000000000000000000000000000000001" as const, permit3: zeroAddress, lens: zeroAddress, rpcUrl: "" };
const MAKER = "0x00000000000000000000000000000000000000a1" as const;
const OTHER = "0x00000000000000000000000000000000000000b2" as const;
const OCO = "0x00000000000000000000000000000000000c0c00" as const;

const noChain = {
  readContract: async () => {
    throw new Error("no chain");
  },
} as unknown as PublicClient;

function orderFor(maker: Hex, nonce: bigint): Order {
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

/** A verifier that never touches a chain — every chain-event path must be RPC-free. */
function stubVerifier(refresh?: () => Promise<Map<Hex, Layer2Result>>): Verifier {
  return {
    verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }),
    refreshStates:
      refresh ??
      (async () => {
        throw new Error("refreshStates must not be called for a cancellation event");
      }),
  } as unknown as Verifier;
}

function bookWith(orders: readonly Order[], verifier = stubVerifier()): Book {
  const book = new Book({
    transport: new InMemoryTransport(),
    config,
    verifier,
    cancelVerifier: new CancelVerifier(noChain, config),
    revalidateMs: 0,
  });
  for (const o of orders) book.admit(hashOrderStruct(o), { order: o, sig: "0x" });
  return book;
}

describe("chain events evict with zero RPC", () => {
  it("OrderCancelledByHash drops exactly that order", () => {
    const a = orderFor(MAKER, 1n);
    const b = orderFor(MAKER, 2n);
    const book = bookWith([a, b]);

    const res = book.applyChainEvent({ kind: "cancelledByHash", maker: MAKER, orderHash: hashOrderStruct(a) });
    expect(res.evicted).toEqual([hashOrderStruct(a)]);
    expect(book.size).toBe(1);
    expect(book.get(hashOrderStruct(b))).toBeDefined();
  });

  it("OrdersCancelled drops every order on those nonces — and only that maker's", () => {
    const mine1 = orderFor(MAKER, 1n);
    const mine2 = orderFor(MAKER, 2n);
    const mine3 = orderFor(MAKER, 3n);
    const theirs = orderFor(OTHER, 1n); // same nonce, different maker
    const book = bookWith([mine1, mine2, mine3, theirs]);

    const res = book.applyChainEvent({ kind: "cancelledNonces", maker: MAKER, nonces: [1n, 3n] });
    expect(res.evicted).toHaveLength(2);
    expect(book.size).toBe(2);
    expect(book.get(hashOrderStruct(mine2))).toBeDefined();
    expect(book.get(hashOrderStruct(theirs))).toBeDefined(); // maker check is load-bearing
  });

  it("NoncesRolledBack drops everything under the watermark", () => {
    const book = bookWith([orderFor(MAKER, 1n), orderFor(MAKER, 5n), orderFor(MAKER, 10n), orderFor(OTHER, 1n)]);
    const res = book.applyChainEvent({ kind: "rolledBack", maker: MAKER, minValidNonce: 6n });
    expect(res.evicted).toHaveLength(2); // nonces 1 and 5
    expect(book.size).toBe(2);
  });

  it("NonceWordInvalidated drops the 256 nonces of that word", () => {
    const inWord0 = orderFor(MAKER, 5n); //   5 >> 8 === 0
    const alsoWord0 = orderFor(MAKER, 255n);
    const word1 = orderFor(MAKER, 256n); // 256 >> 8 === 1
    const book = bookWith([inWord0, alsoWord0, word1]);

    book.applyChainEvent({ kind: "wordInvalidated", maker: MAKER, wordIndex: 0n });
    expect(book.size).toBe(1);
    expect(book.get(hashOrderStruct(word1))).toBeDefined();
  });

  it("GroupClaimed retires every sibling and spares the winner", () => {
    const [tp, sl, third] = ocoGroup(
      [orderFor(MAKER, 1n), orderFor(MAKER, 2n), orderFor(MAKER, 3n)],
      OCO,
      0xb4a6e7n,
    );
    const unrelated = orderFor(MAKER, 9n);
    const book = bookWith([tp!, sl!, third!, unrelated]);
    expect(book.size).toBe(4);

    // Leg with nonce 2 won.
    const res = book.applyChainEvent({ kind: "groupClaimed", maker: MAKER, module: OCO, groupId: 0xb4a6e7n, nonce: 2n });

    expect(res.evicted).toHaveLength(2); // nonces 1 and 3
    expect(book.get(hashOrderStruct(sl!))).toBeDefined(); // the winner stays fillable
    expect(book.get(hashOrderStruct(unrelated))).toBeDefined();
    expect(book.size).toBe(2);
  });

  it("GroupClaimed ignores a different group on the same module", () => {
    const [a, b] = ocoGroup([orderFor(MAKER, 1n), orderFor(MAKER, 2n)], OCO, 111n);
    const book = bookWith([a!, b!]);
    book.applyChainEvent({ kind: "groupClaimed", maker: MAKER, module: OCO, groupId: 222n, nonce: 1n });
    expect(book.size).toBe(2);
  });

  it("OrderFilled only marks dirty — a partial fill must not evict", async () => {
    const o = orderFor(MAKER, 1n);
    const refreshed = vi.fn(async () => new Map<Hex, Layer2Result>());
    const book = bookWith([o], stubVerifier(refreshed));

    const res = book.applyChainEvent({ kind: "filled", orderHash: hashOrderStruct(o), maker: MAKER });
    expect(res.evicted).toEqual([]);
    expect(res.dirty).toEqual([hashOrderStruct(o)]);
    expect(book.size).toBe(1);

    // …and the targeted re-check touches ONLY that order, not the book.
    await book.revalidateDirty();
    expect(refreshed).toHaveBeenCalledOnce();
    expect(refreshed.mock.calls[0]![0]).toHaveLength(1);
    await book.stop();
  });

  it("an unknown hash is a no-op, never a pre-emptive block", () => {
    const book = bookWith([orderFor(MAKER, 1n)]);
    const res = book.applyChainEvent({ kind: "filled", orderHash: `0x${"ab".repeat(32)}`, maker: MAKER });
    expect(res.dirty).toEqual([]);
    expect(book.size).toBe(1);
  });
});

describe("eviction policy", () => {
  const state = (over: Partial<Layer2Result>): Layer2Result => ({
    ok: true,
    status: 1,
    fillableAmount: 100n,
    isSignatureValid: true,
    validatorsPass: true,
    ...over,
  });

  it("by default keeps an order whose validators fail — it may be filler-conditional", async () => {
    const o = orderFor(MAKER, 1n);
    const h = hashOrderStruct(o);
    const book = bookWith([o], stubVerifier(async () => new Map([[h, state({ validatorsPass: false })]])));
    await book.revalidate();
    expect(book.size).toBe(1);
  });

  it("evictWhen lets a book that knows its inventory drop them eagerly", async () => {
    const o = orderFor(MAKER, 1n);
    const h = hashOrderStruct(o);
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: stubVerifier(async () => new Map([[h, state({ validatorsPass: false })]])),
      cancelVerifier: new CancelVerifier(noChain, config),
      revalidateMs: 0,
      evictWhen: (_e, s) => !s.ok || !s.validatorsPass,
    });
    book.admit(h, { order: o, sig: "0x" });
    await book.revalidate();
    expect(book.size).toBe(0);
  });
});

describe("failure visibility", () => {
  it("surfaces a failed re-check instead of swallowing it", async () => {
    const o = orderFor(MAKER, 1n);
    const book = bookWith([o], stubVerifier(async () => {
      throw new Error("eth_call: out of gas");
    }));
    const errors: unknown[] = [];
    book.onError((e) => errors.push(e));

    await expect(book.revalidate()).rejects.toThrow(/out of gas/);

    // …and through the timer path, where it used to vanish entirely.
    book.applyChainEvent({ kind: "filled", orderHash: hashOrderStruct(o), maker: MAKER });
    await vi.waitFor(() => expect(errors).toHaveLength(1));
    await book.stop();
  });
});

describe("isOcoGroupLeg", () => {
  it("matches only the right module and group", () => {
    const [leg] = ocoGroup([orderFor(MAKER, 1n), orderFor(MAKER, 2n)], OCO, 7n);
    expect(isOcoGroupLeg(leg!.validators, OCO, 7n)).toBe(true);
    expect(isOcoGroupLeg(leg!.validators, OCO, 8n)).toBe(false);
    expect(isOcoGroupLeg(leg!.validators, OTHER, 7n)).toBe(false);
    expect(isOcoGroupLeg([], OCO, 7n)).toBe(false);
  });

  it("tolerates a non-group validator that happens to share the module address", () => {
    expect(isOcoGroupLeg([{ target: OCO, data: "0x1234" }], OCO, 7n)).toBe(false);
  });
});

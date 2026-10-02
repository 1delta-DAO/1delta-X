import { describe, expect, it } from "vitest";

import { FILL_ONCE_BIT_INDEX, hashOrderStruct, OrderSide, signOrder, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";

import { Book } from "../src/book";
import { CancelVerifier } from "../src/cancels";
import { signSoftCancel } from "../src/client";
import type { OrderAnnounce } from "../src/messages";
import { InMemoryTransport } from "../src/transport";
import type { Verifier } from "../src/verify";

/** 2026-09-30 audit PRICE-5: a replacement must not reuse its predecessor's nonce
 *  unless the predecessor is fill-once (a shared-nonce bracket leg). */
const stubVerifier = {
  verifyAnnounce: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order) }),
  refreshStates: async () => new Map(),
} as unknown as Verifier;
const config = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001" as const,
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};
const noChain = {
  readContract: async () => {
    throw new Error("no chain");
  },
  verifyTypedData: async () => {
    throw new Error("no chain");
  },
} as unknown as PublicClient;
const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

function orderFor(nonce: bigint, timing = 0n, outStart = 900n): Order {
  return {
    maker: account.address,
    side: OrderSide.SELL,
    nonce,
    expiry: BigInt(Math.floor(Date.now() / 1000) + 86_400),
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: outStart, end: 0n, recipient: zeroAddress }],
    timing,
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
    priorityScale: 0n,
    pricingModule: zeroAddress as Address,
  };
}

async function replaceOf(book: Book, prev: Order, next: Order) {
  const sig = (await signOrder(account, next, config)) as Hex;
  const cancel = await signSoftCancel(account, account.address, [hashOrderStruct(prev)], config);
  return book.ingestReplace({ cancel, announce: { order: next, sig }, replaces: hashOrderStruct(prev) });
}

describe("PRICE-5 — Book.ingestReplace nonce rule", () => {
  it("test_audit_PRICE_5_sameNonceReplacementOfPlainOrderRefused", async () => {
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: stubVerifier,
      cancelVerifier: new CancelVerifier(noChain, config),
      revalidateMs: 0,
    });
    const prev = orderFor(7n);
    book.admit(hashOrderStruct(prev), { order: prev, sig: "0x" });
    const res = await replaceOf(book, prev, orderFor(7n, 0n, 950n));
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/fresh nonce/);
    expect(book.get(hashOrderStruct(prev))).toBeDefined(); // predecessor untouched
  });

  it("test_audit_PRICE_5_fillOnceBracketLegMayKeepItsNonce", async () => {
    const book = new Book({
      transport: new InMemoryTransport(),
      config,
      verifier: stubVerifier,
      cancelVerifier: new CancelVerifier(noChain, config),
      revalidateMs: 0,
    });
    const fillOnce = 1n << FILL_ONCE_BIT_INDEX;
    const prev = orderFor(7n, fillOnce);
    book.admit(hashOrderStruct(prev), { order: prev, sig: "0x" });
    const res = await replaceOf(book, prev, orderFor(7n, fillOnce, 950n));
    expect(res.ok).toBe(true);
  });
});

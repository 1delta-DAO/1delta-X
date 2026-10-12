import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { FILL_ONCE_BIT, hashOrderStruct, isFillOnce } from "@1delta-x/sdk";
import { getAddress } from "viem";

import { buildOrder } from "../src/lib/order";
import {
  DEFAULT_NONCE_WORD,
  fillOnceFor,
  NonceAllocator,
  ORDER_NONCE_LIMIT,
  openOrderNonces,
  pickOrderNonces,
  type NonceStore,
} from "../src/lib/nonces";

const MAKER = getAddress("0x00000000000000000000000000000000000000aa");
const OTHER = getAddress("0x00000000000000000000000000000000000000bb");
const SETTLEMENT = getAddress("0x0000000000000000000000000000000000005e77");
const BASE = DEFAULT_NONCE_WORD * 256n; // 256
const FULL = (1n << 256n) - 1n;

/** A bitmap from set bit positions. */
const bits = (...b: number[]) => b.reduce((m, i) => m | (1n << BigInt(i)), 0n);
/** A `readWord` over a sparse word map (missing words are zero). */
const words = (m: Record<string, bigint> = {}) => (w: bigint) => m[w.toString()] ?? 0n;

class MemStore implements NonceStore {
  readonly m = new Map<string, string>();
  getItem(k: string) {
    return this.m.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.m.set(k, v);
  }
}

function chainOf(m: Record<string, bigint> = {}, minValid = 0n) {
  const reads: bigint[] = [];
  return {
    reads,
    chain: {
      minValidNonce: async () => minValid,
      word: async (w: bigint) => {
        reads.push(w);
        return m[w.toString()] ?? 0n;
      },
    },
  };
}

describe("pickOrderNonces — the lowest free bit", () => {
  it("starts at the default word's bit 0", async () => {
    expect(await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words() })).toEqual([BASE]);
  });

  it("skips bits set on-chain (filled fill-once / cancelled nonces)", async () => {
    const readWord = words({ "1": bits(0, 1, 2, 4) });
    expect(await pickOrderNonces({ count: 2, minValidNonce: 0n, readWord })).toEqual([BASE + 3n, BASE + 5n]);
  });

  it("skips nonces of the maker's open orders and session reservations", async () => {
    const got = await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words({ "1": bits(0) }), taken: [BASE + 1n, BASE + 2n] });
    expect(got).toEqual([BASE + 3n]);
  });

  it("rolls to the next word when the current one is full", async () => {
    expect(await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words({ "1": FULL }) })).toEqual([512n]);
    // Free on-chain but every free bit is taken by an open order: also full.
    const taken = Array.from({ length: 6 }, (_, i) => BASE + 250n + BigInt(i));
    const almost = FULL ^ bits(250, 251, 252, 253, 254, 255);
    expect(await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words({ "1": almost }), taken })).toEqual([512n]);
  });

  it("respects minValidNonce, including a watermark mid-word", async () => {
    // 1000 = word 3, bit 232; bit 232 already used on-chain.
    const got = await pickOrderNonces({ count: 1, minValidNonce: 1000n, readWord: words({ "3": bits(232) }) });
    expect(got).toEqual([1001n]);
    // A watermark below the default word does not pull the start down.
    expect(await pickOrderNonces({ count: 1, minValidNonce: 5n, readWord: words() })).toEqual([BASE]);
  });

  it("respects the floor (persisted high-water + 1)", async () => {
    expect(await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words(), floor: BASE + 10n })).toEqual([BASE + 10n]);
  });

  it("never reaches the reserved half: every nonce < 2^255, and it throws instead of crossing", async () => {
    const top = ORDER_NONCE_LIMIT - 2n;
    expect(await pickOrderNonces({ count: 2, minValidNonce: top, readWord: words() })).toEqual([top, top + 1n]);
    await expect(pickOrderNonces({ count: 3, minValidNonce: top, readWord: words() })).rejects.toThrow(/no free order nonce/);
    await expect(pickOrderNonces({ count: 1, minValidNonce: ORDER_NONCE_LIMIT, readWord: words() })).rejects.toThrow(/2\^255/);
  });

  it("gives up after maxWords full words", async () => {
    await expect(pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: () => FULL, maxWords: 3 })).rejects.toThrow(/within 3/);
  });

  it("TWAP: one distinct bit per slice, skipping used bits and spilling into the next word", async () => {
    const readWord = words({ "1": FULL ^ bits(100, 200, 254) });
    const got = await pickOrderNonces({ count: 5, minValidNonce: 0n, readWord, taken: [BASE + 200n] });
    expect(got).toEqual([BASE + 100n, BASE + 254n, 512n, 513n, 514n]);
    expect(new Set(got).size).toBe(got.length);
  });

  it("rejects a non-positive count", async () => {
    await expect(pickOrderNonces({ count: 0, minValidNonce: 0n, readWord: words() })).rejects.toThrow();
  });
});

describe("NonceAllocator — reservations, persistence and fallback", () => {
  const args = { chainId: 30, settlement: SETTLEMENT, maker: MAKER };

  it("two tickets in a row get consecutive bits (in-memory + persisted reservation)", async () => {
    const store = new MemStore();
    const a = new NonceAllocator(() => store);
    const { chain } = chainOf();
    expect((await a.allocate({ ...args, count: 1, chain })).nonces).toEqual([BASE]);
    expect((await a.allocate({ ...args, count: 1, chain })).nonces).toEqual([BASE + 1n]);
    expect(store.getItem(NonceAllocator.key(30, SETTLEMENT, MAKER))).toBe((BASE + 1n).toString());
  });

  it("two CONCURRENT tickets never collide (allocation is serialised per maker)", async () => {
    const a = new NonceAllocator(() => new MemStore());
    const { chain } = chainOf();
    const [x, y, z] = await Promise.all([1, 2, 3].map(() => a.allocate({ ...args, count: 1, chain })));
    expect(new Set([x!.nonces[0], y!.nonces[0], z!.nonces[0]]).size).toBe(3);
  });

  it("another tab (same storage) continues after this one's high-water mark", async () => {
    const store = new MemStore();
    const { chain } = chainOf();
    await new NonceAllocator(() => store).allocate({ ...args, count: 3, chain });
    expect((await new NonceAllocator(() => store).allocate({ ...args, count: 1, chain })).nonces).toEqual([BASE + 3n]);
  });

  it("keys per maker, chain and settlement", async () => {
    const store = new MemStore();
    const a = new NonceAllocator(() => store);
    const { chain } = chainOf();
    await a.allocate({ ...args, count: 2, chain });
    expect((await a.allocate({ ...args, maker: OTHER, count: 1, chain })).nonces).toEqual([BASE]);
    expect((await a.allocate({ ...args, chainId: 31, count: 1, chain })).nonces).toEqual([BASE]);
  });

  it("skips open orders and on-chain bits, and respects the watermark it reads", async () => {
    const a = new NonceAllocator(() => new MemStore());
    const { chain } = chainOf({ "3": bits(232, 233) }, 1000n);
    const got = await a.allocate({ ...args, count: 2, chain, open: [1002n] });
    expect(got).toMatchObject({ mode: "packed", minValidNonce: 1000n, nonces: [1003n, 1004n] });
  });

  it("works with storage that throws (private window): in-memory reservation still holds", async () => {
    const broken: NonceStore = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    };
    const a = new NonceAllocator(() => broken);
    const { chain } = chainOf();
    expect((await a.allocate({ ...args, count: 1, chain })).nonces).toEqual([BASE]);
    expect((await a.allocate({ ...args, count: 1, chain })).nonces).toEqual([BASE + 1n]);
  });

  it("falls back to a random nonce above the watermark when the bitmap read fails", async () => {
    const store = new MemStore();
    const a = new NonceAllocator(() => store);
    const minValid = 77_000n;
    const got = await a.allocate({
      ...args,
      count: 2,
      chain: { minValidNonce: async () => minValid, word: async () => Promise.reject(new Error("rpc down")) },
    });
    expect(got.mode).toBe("random");
    for (const n of got.nonces) expect(n >= minValid && n < ORDER_NONCE_LIMIT).toBe(true);
    // A random draw says nothing about the packed word: nothing is persisted.
    expect(store.m.size).toBe(0);
  });

  it("falls back to a random nonce with no chain reader (no wallet / undeployed)", async () => {
    const got = await new NonceAllocator(() => new MemStore()).allocate({ ...args, count: 1, chain: null });
    expect(got.mode).toBe("random");
    expect(got.nonces[0]! < ORDER_NONCE_LIMIT).toBe(true);
  });

  it("a failed WATERMARK read fails the ticket (never draws from 0), and does not wedge the lock", async () => {
    const a = new NonceAllocator(() => new MemStore());
    await expect(
      a.allocate({ ...args, count: 1, chain: { minValidNonce: async () => Promise.reject(new Error("rpc")), word: async () => 0n } }),
    ).rejects.toThrow("rpc");
    expect((await a.allocate({ ...args, count: 1, chain: chainOf().chain })).nonces).toEqual([BASE]);
  });

  it("only reads the words it needs", async () => {
    const { chain, reads } = chainOf({ "1": FULL });
    await new NonceAllocator(() => new MemStore()).allocate({ ...args, count: 1, chain });
    expect(reads).toEqual([1n, 2n]);
  });
});

describe("openOrderNonces", () => {
  it("collects every signed order (TWAP slices too) of THIS maker only", () => {
    const so = (maker: string, nonce: bigint) => ({ order: { maker, nonce } });
    const rows = [
      { signed: so(MAKER, 300n) },
      { signed: so(MAKER, 301n), signedOrders: [so(MAKER, 301n), so(MAKER, 302n)] },
      { signed: so(OTHER, 303n) },
      {},
    ];
    expect(new Set(openOrderNonces(rows, MAKER.toLowerCase()))).toEqual(new Set([300n, 301n, 302n]));
  });
});

describe("buildOrder with a packed nonce", () => {
  const sellArgs = {
    maker: MAKER,
    side: "sell" as const,
    pay: { address: getAddress("0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37"), decimals: 18 },
    recv: { address: getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"), decimals: 6 },
    amountIn: 100,
    targetOut: 99.5,
    minOut: 99.5,
    ttlSeconds: 3600,
    decaySeconds: 0,
    now: 1_700_000_000,
  };

  it("signs the allocated nonce and passes the SDK guard", async () => {
    const [nonce] = await pickOrderNonces({ count: 1, minValidNonce: 0n, readWord: words() });
    const draft = buildOrder({ ...sellArgs, nonce });
    expect(draft.order.nonce).toBe(BASE);
    expect(draft.hash).toBe(hashOrderStruct(draft.order));
    expect(isFillOnce(draft.order)).toBe(false);
  });

  it("fillOnce sets timing bit 100 and nothing else", () => {
    const plain = buildOrder({ ...sellArgs, nonce: BASE });
    const once = buildOrder({ ...sellArgs, nonce: BASE, fillOnce: true });
    expect(once.order.timing).toBe(plain.order.timing | FILL_ONCE_BIT);
    expect(isFillOnce(once.order)).toBe(true);
    expect(once.hash).not.toBe(plain.hash);
  });

  it("fill-once is ON for market tickets only; limit and TWAP keep partial fills", () => {
    expect(fillOnceFor("market")).toBe(true);
    expect(fillOnceFor("limit")).toBe(false);
    expect(fillOnceFor("twap")).toBe(false);
  });

  it("the app allocates through lib/nonces and signs fill-once by ticket kind (market only)", () => {
    const app = readFileSync(resolve(__dirname, "..", "src/App.tsx"), "utf8");
    expect(app).toContain("appNonces.allocate(");
    expect(app).toContain("nonce: nonces[0]");
    expect(app).toContain("fillOnce: fillOnceFor(spec.kind)");
    // The market / limit ticket passes its plan kind; every TWAP slice says "twap".
    expect(app).toContain("signDraft({ ...spec, marketId, side, kind: plan.kind })");
    expect(app.split('kind: "twap"').length - 1).toBe(2); // slice 1 and every later slice
    expect(app).not.toContain("FILL_ONCE_ORDERS");
  });
});

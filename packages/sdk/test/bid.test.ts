import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { keccak256, toHex, type Address, type Hex } from "viem";

import { BID_TYPEHASH, bidDigest, recoverBidder, signBid, verifyBid, type BidPayload } from "../src/bid";
import type { QuoteBinding } from "../src/quote";

const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const mallory = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

const ORDER = `0x${"11".repeat(32)}` as Hex;
const binding: QuoteBinding = { module: "0x00000000000000000000000000000000000000cc", chainId: 31 };
const payload: BidPayload = { orderHash: ORDER, filler: alice.address, bumpBps: 1_200, closesAt: 1_060 };

describe("bidDigest", () => {
  it("uses its own type string — a bid can never be replayed as a quote", () => {
    expect(BID_TYPEHASH).toBe(
      keccak256(toHex("QuoteBid(bytes32 orderHash,address filler,uint256 bumpBps,uint256 closesAt)")),
    );
  });

  it("binds the round, so a bid cannot be lifted into a later one", () => {
    expect(bidDigest({ ...payload, closesAt: 2_000 }, binding)).not.toBe(bidDigest(payload, binding));
  });

  it("binds the order, the chain and the module", () => {
    expect(bidDigest({ ...payload, orderHash: `0x${"22".repeat(32)}` }, binding)).not.toBe(bidDigest(payload, binding));
    expect(bidDigest(payload, { ...binding, chainId: 1 })).not.toBe(bidDigest(payload, binding));
    expect(bidDigest(payload, { ...binding, module: "0x00000000000000000000000000000000000000dd" })).not.toBe(
      bidDigest(payload, binding),
    );
  });
});

describe("signBid", () => {
  it("round-trips through recovery", async () => {
    const bid = await signBid(alice, payload, binding);
    expect(await recoverBidder(bid, binding)).toBe(alice.address);
    expect(await verifyBid(bid, binding)).toEqual({ ok: true });
  });

  it("refuses to sign a bid naming someone else — a bid is a commitment to fill", async () => {
    await expect(signBid(mallory, payload, binding)).rejects.toThrow(/signed by the filler/);
  });

  it("signs the RAW digest, matching signQuote", async () => {
    const bid = await signBid(alice, payload, binding);
    const prefixed = await alice.signMessage({ message: { raw: bidDigest(payload, binding) } });
    expect(bid.signature).not.toBe(prefixed);
  });
});

describe("verifyBid — the forgery cases", () => {
  it("REJECTS a rival bidding as someone else", async () => {
    // Mallory wants to displace Alice: she submits an aggressive bump in Alice's
    // name, wins, and never fills. Her own signature does not recover to Alice.
    const forged = await mallory.sign({ hash: bidDigest({ ...payload, bumpBps: 1 }, binding) });
    const res = await verifyBid({ ...payload, bumpBps: 1, signature: forged }, binding);
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/forged/);
  });

  it("REJECTS a bid whose bump was edited after signing", async () => {
    // The operator's shill move: take a real bid and rewrite its number.
    const bid = await signBid(alice, payload, binding);
    const tampered = { ...bid, bumpBps: 9_000 };
    expect((await verifyBid(tampered, binding)).ok).toBe(false);
  });

  it("REJECTS a bid rebound to another round", async () => {
    const bid = await signBid(alice, payload, binding);
    expect((await verifyBid({ ...bid, closesAt: 9_999 }, binding)).ok).toBe(false);
  });

  it("REJECTS a wholly fabricated bid with a garbage signature", async () => {
    const res = await verifyBid({ ...payload, filler: mallory.address, signature: "0xdead" as Hex }, binding);
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/unverifiable-signer/);
  });

  it("rejects an out-of-range bump before touching the signature", async () => {
    const res = await verifyBid({ ...payload, bumpBps: 20_000, signature: "0x00" as Hex }, binding);
    expect(res.reason).toBe("bumpBps out of range");
  });
});

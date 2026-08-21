import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { keccak256, toHex, type Address, type Hex } from "viem";

import {
  ANY_FILLER,
  QUOTE_TYPEHASH,
  decodeQuoteTakerData,
  encodeQuoteTakerData,
  quoteDigest,
  signQuote,
  verifyQuote,
  type PriceQuote,
  type QuoteBinding,
} from "../src/quote";

const cosigner = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const impostor = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

const FILLER = "0x00000000000000000000000000000000000005a1" as Address;
const MODULE = "0x00000000000000000000000000000000000000cc" as Address;
const ORDER_HASH = `0x${"11".repeat(32)}` as Hex;

const binding: QuoteBinding = { module: MODULE, chainId: 31 };
const quote: PriceQuote = { orderHash: ORDER_HASH, filler: FILLER, bumpBps: 2_500, deadline: 4_000_000_000n };

describe("quoteDigest", () => {
  it("uses the modules' type string", () => {
    expect(QUOTE_TYPEHASH).toBe(
      keccak256(toHex("PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline)")),
    );
  });

  it("binds the module address — a quote cannot be replayed onto another instance", () => {
    const other = quoteDigest(quote, { ...binding, module: "0x00000000000000000000000000000000000000dd" });
    expect(other).not.toBe(quoteDigest(quote, binding));
  });

  it("binds the chain id", () => {
    expect(quoteDigest(quote, { ...binding, chainId: 1 })).not.toBe(quoteDigest(quote, binding));
  });

  it("binds the filler, so a named quote is non-transferable", () => {
    expect(quoteDigest({ ...quote, filler: ANY_FILLER }, binding)).not.toBe(quoteDigest(quote, binding));
  });

  it("rejects a bump outside the band rather than silently clamping", () => {
    expect(() => quoteDigest({ ...quote, bumpBps: 10_001 }, binding)).toThrow();
    expect(() => quoteDigest({ ...quote, bumpBps: 1.5 }, binding)).toThrow();
  });
});

describe("takerData", () => {
  it("packs to the module's 84-byte header plus signature", () => {
    const sig = `0x${"ab".repeat(65)}` as Hex;
    const data = encodeQuoteTakerData(quote, sig);
    // filler(20) + bumpBps(32) + deadline(32) + sig(65)
    expect((data.length - 2) / 2).toBe(20 + 32 + 32 + 65);
  });

  it("round-trips", () => {
    const sig = `0x${"ab".repeat(65)}` as Hex;
    const back = decodeQuoteTakerData(encodeQuoteTakerData(quote, sig));
    expect(back.quote.filler.toLowerCase()).toBe(FILLER.toLowerCase());
    expect(back.quote.bumpBps).toBe(2_500);
    expect(back.quote.deadline).toBe(4_000_000_000n);
    expect(back.signature).toBe(sig);
  });

  it("rejects a blob the module would call MalformedQuote", () => {
    expect(() => decodeQuoteTakerData("0xdeadbeef")).toThrow(/MalformedQuote/);
  });
});

describe("signQuote / verifyQuote", () => {
  it("signs the RAW digest — the module ECDSA-recovers an unprefixed hash", async () => {
    const signed = await signQuote(cosigner, quote, binding);
    // The prefixed variant must NOT be what we produced, or every fill reverts.
    const prefixed = await cosigner.signMessage({ message: { raw: signed.digest } });
    expect(signed.signature).not.toBe(prefixed);
    expect(await verifyQuote(signed, { cosigner: cosigner.address, now: 0n })).toEqual({ ok: true });
  });

  it("carries takerData ready for the fill", async () => {
    const signed = await signQuote(cosigner, quote, binding);
    expect(decodeQuoteTakerData(signed.takerData).signature).toBe(signed.signature);
  });

  it("rejects a quote signed by anyone else", async () => {
    const signed = await signQuote(impostor, quote, binding);
    const res = await verifyQuote(signed, { cosigner: cosigner.address, now: 0n });
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/not the configured cosigner/);
  });

  it("rejects an expired quote", async () => {
    const signed = await signQuote(cosigner, quote, binding);
    const res = await verifyQuote(signed, { cosigner: cosigner.address, now: 4_000_000_001n });
    expect(res.reason).toBe("QuoteExpired");
  });

  it("rejects a quote presented by a filler it does not name", async () => {
    const signed = await signQuote(cosigner, quote, binding);
    const res = await verifyQuote(signed, {
      cosigner: cosigner.address,
      filler: "0x00000000000000000000000000000000000000ff",
      now: 0n,
    });
    expect(res.reason).toBe("QuoteNotForFiller");
  });

  it("lets an open quote be presented by anyone", async () => {
    const open = { ...quote, filler: ANY_FILLER };
    const signed = await signQuote(cosigner, open, binding);
    const res = await verifyQuote(signed, {
      cosigner: cosigner.address,
      filler: "0x00000000000000000000000000000000000000ff",
      now: 0n,
    });
    expect(res.ok).toBe(true);
  });

  it("does not verify a quote rebound to another module", async () => {
    const signed = await signQuote(cosigner, quote, binding);
    const rebound = { ...signed, binding: { ...binding, module: "0x00000000000000000000000000000000000000dd" as Address } };
    const res = await verifyQuote(rebound, { cosigner: cosigner.address, now: 0n });
    expect(res.ok).toBe(false);
  });
});

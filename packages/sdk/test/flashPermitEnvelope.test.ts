import { describe, expect, it } from "vitest";
import { decodeAbiParameters, type Address, type Hex } from "viem";

import * as sdk from "../src/index";
import { permitBatchComponents } from "../src/abi";
import { permit3Nonce, Permit3MessageKind } from "../src/permit3nonce";
import type { PermitBatch } from "../src/types";

/**
 * Audit 2026-09-30 AGG-6 (permit half): the flash solvers take a single-signature
 * order through a permit-enveloped `sig`. The SDK must build that envelope with the
 * contract's exact constant and layout. Fails on the pre-fix SDK (no builder).
 */
const SETTLEMENT = "0x00000000000000000000000000000000000000a1" as Address;
const TOKEN = "0x00000000000000000000000000000000000000b2" as Address;

const batch: PermitBatch = {
  tokens: [{ spender: SETTLEMENT, token: TOKEN, amount: 100n, expiration: 1_900_000_000 }],
  takers: [],
  nonce: permit3Nonce(Permit3MessageKind.Batch, 7n),
  deadline: 1_900_000_000n,
};

describe("AGG-6 — flash-solver permit envelope", () => {
  it("test_audit_AGG_6_envelopeConstantMatchesContract", () => {
    // `cast keccak "1delta.BaseFlashSolver.PermitEnvelope"` — BaseFlashSolver.PERMIT_ENVELOPE.
    expect((sdk as any).FLASH_PERMIT_ENVELOPE).toBe(
      "0x26c9f21c3625d8be993a31448f5186366f3c45087c1f1ae54f7a9f6fbd8c4741",
    );
  });

  it("test_audit_AGG_6_envelopeLayoutRoundTrips", () => {
    const encode = (sdk as any).encodeFlashPermitEnvelope as
      | ((b: PermitBatch, s: Hex, m?: bigint) => Hex)
      | undefined;
    expect(typeof encode).toBe("function");
    const env = encode!(batch, "0x1234", 5n);
    const [head, b, sig, minBump] = decodeAbiParameters(
      [{ type: "bytes32" }, { type: "tuple", components: permitBatchComponents }, { type: "bytes" }, { type: "uint256" }],
      env,
    );
    expect(head).toBe("0x26c9f21c3625d8be993a31448f5186366f3c45087c1f1ae54f7a9f6fbd8c4741");
    expect(b.nonce).toBe(batch.nonce);
    expect(b.tokens[0]!.token.toLowerCase()).toBe(TOKEN);
    expect(sig).toBe("0x1234");
    expect(minBump).toBe(5n);
  });

  it("test_audit_AGG_6_envelopeRefusesMisnamespacedNonce", () => {
    const encode = (sdk as any).encodeFlashPermitEnvelope as (b: PermitBatch, s: Hex) => Hex;
    expect(() => encode({ ...batch, nonce: permit3Nonce(Permit3MessageKind.Take, 1n) }, "0x")).toThrow(/namespaced/);
  });
});

import { erc2612DomainSeparator } from "@1delta-x/sdk";
import { getAddress, type Address } from "viem";
import { describe, expect, it } from "vitest";

import type { Reader } from "../src/lib/chain";
import { detectPermitDomain } from "../src/lib/permit";

const tok = (n: number) => getAddress(`0x${n.toString(16).padStart(40, "0")}`) as Address;

/** A reader answering per function name; anything unlisted reverts. */
function reader(answers: Record<string, unknown>): Reader {
  return {
    readContract: async ({ functionName }) => {
      if (!(functionName in answers)) throw new Error("execution reverted");
      return answers[functionName];
    },
  };
}

describe("detectPermitDomain: any ERC-2612 token, proven against its own DOMAIN_SEPARATOR", () => {
  it("pinned tokens need no reads (USD₮0)", async () => {
    const d = await detectPermitDomain(reader({}), 30, getAddress("0x779ded0c9e1022225f8e0630b35a9b54be713736"));
    expect(d?.name).toBe("USD₮0");
  });

  it("reconstructs name() + version() when it hashes to the live separator", async () => {
    const t = tok(0xa1);
    const sep = erc2612DomainSeparator({ name: "Some Token", version: "2", chainId: 30, verifyingContract: t });
    const d = await detectPermitDomain(reader({ DOMAIN_SEPARATOR: sep, nonces: 0n, name: "Some Token" }), 30, t);
    expect(d).toEqual({ name: "Some Token", version: "2", chainId: 30, verifyingContract: t });
  });

  it("uses ERC-5267 eip712Domain() when the name differs from name()", async () => {
    const t = tok(0xa2);
    const sep = erc2612DomainSeparator({ name: "StRIFToken", version: "1", chainId: 30, verifyingContract: t });
    const d = await detectPermitDomain(
      reader({ DOMAIN_SEPARATOR: sep, nonces: 0n, name: "Staked RIF", eip712Domain: ["0x0f", "StRIFToken", "1", 30n, t, "0x" + "0".repeat(64), []] }),
      30,
      t,
    );
    expect(d?.name).toBe("StRIFToken");
  });

  it("refuses: no separator (WRBTC's answer-anything fallback), no nonces, or a domain that does not hash to it", async () => {
    expect(await detectPermitDomain(reader({ DOMAIN_SEPARATOR: "0x", nonces: "0x", name: "Wrapped BTC" }), 30, tok(0xa3))).toBeUndefined();
    const t = tok(0xa4);
    const sep = erc2612DomainSeparator({ name: "X", version: "1", chainId: 30, verifyingContract: t });
    expect(await detectPermitDomain(reader({ DOMAIN_SEPARATOR: sep, name: "X" }), 30, t)).toBeUndefined();
    expect(await detectPermitDomain(reader({ DOMAIN_SEPARATOR: sep, nonces: 0n, name: "Y" }), 30, tok(0xa5))).toBeUndefined();
  });
});

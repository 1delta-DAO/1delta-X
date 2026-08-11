import { describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";
import { encodeConditions, conditionValidator, FLAG_NEGATE, FLAG_TRY } from "../src";

const A = (n: string): Address => getAddress(n);
const V1 = A("0x0000000000000000000000000000000000000e01");
const V2 = A("0x0000000000000000000000000000000000000e02");

describe("encodeConditions", () => {
  it("lays out groupCount | leafCount | flags | target | len | data", () => {
    // One group, one leaf, no data — the smallest well-formed expression.
    expect(encodeConditions([[{ target: V1, data: "0x" }]])).toBe(
      "0x" + "01" + "01" + "00" + V1.slice(2).toLowerCase() + "0000",
    );
  });

  it("encodes an OR of two groups with flags and data", () => {
    const blob = encodeConditions([
      [{ target: V1, data: "0xdead", flags: FLAG_TRY }],
      [{ target: V2, data: "0x", flags: FLAG_NEGATE }],
    ]);
    expect(blob).toBe(
      "0x" +
        "02" + // two groups
        "01" + "02" + V1.slice(2).toLowerCase() + "0002" + "dead" + // TRY leaf with data
        "01" + "01" + V2.slice(2).toLowerCase() + "0000", // NEGATE leaf
    );
  });

  it("rejects the shapes the contract rejects", () => {
    // Vacuous truth/falsity must not be encodable — that is the dangerous case.
    expect(() => encodeConditions([])).toThrow(/at least one group/);
    expect(() => encodeConditions([[]])).toThrow(/vacuously true/);
    expect(() => encodeConditions([[{ target: V1, data: "0x", flags: 4 }]])).toThrow(/unknown condition flag/);
    expect(() => encodeConditions([[{ target: "0x1234" as Address, data: "0x" }]])).toThrow(/20-byte address/);
  });

  it("conditionValidator produces a drop-in validators entry", () => {
    const tree = A("0x0000000000000000000000000000000000000abc");
    const v = conditionValidator(tree, [[{ target: V1, data: "0x" }]]);
    expect(v.target).toBe(tree);
    expect(v.data).toBe(encodeConditions([[{ target: V1, data: "0x" }]]));
  });
});

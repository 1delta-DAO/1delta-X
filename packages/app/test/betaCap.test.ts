import { describe, expect, it } from "vitest";

import { betaCapFor, capCheck } from "../src/lib/betaCap";

describe("pre-audit cap: $1,000 per ORDER on Rootstock (UI)", () => {
  it("is set on Rootstock only", () => {
    expect(betaCapFor(30)).toBe(1000);
    expect(betaCapFor(1)).toBeUndefined();
  });

  it("refuses a single ticket over the cap; at the cap (and within 0.5 % slack) passes; nothing is cumulative", () => {
    expect(capCheck(1000, 1000).over).toBe(false);
    expect(capCheck(1000, 1004).over).toBe(false);
    expect(capCheck(1000, 1006).over).toBe(true);
    expect(capCheck(1000, 2991).over).toBe(true);
    expect(capCheck(1000, undefined).over).toBe(false);
  });
});

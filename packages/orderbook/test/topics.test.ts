import { describe, expect, it } from "vitest";

import { cancelTopic, orderTopic, topicsFor } from "../src/topics";

const SETTLEMENT = "0xAbC0000000000000000000000000000000000001" as const;

describe("content topics", () => {
  it("binds the topic to chainId + settlement (lowercased)", () => {
    expect(orderTopic(31, SETTLEMENT)).toBe("/1delta/1/orders-31-0xabc0000000000000000000000000000000000001/proto");
    expect(cancelTopic(30, SETTLEMENT)).toBe("/1delta/1/cancels-30-0xabc0000000000000000000000000000000000001/proto");
  });

  it("topicsFor returns the pair", () => {
    expect(topicsFor({ chainId: 31, settlement: SETTLEMENT })).toEqual({
      orders: orderTopic(31, SETTLEMENT),
      cancels: cancelTopic(31, SETTLEMENT),
    });
  });
});

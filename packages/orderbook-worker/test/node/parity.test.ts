import { decodeOrderAnnounce, encodeOrderAnnounce } from "@1delta-x/orderbook";
import { hashOrderStruct, OrderSide, orderToJson, type Order } from "@1delta-x/sdk";
import { describe, expect, it } from "vitest";
import { zeroAddress, type Address, type Hex } from "viem";

// The orderbook-server's JSON path, as its route runs it.
import { announceFromJson as serverAnnounceFromJson, parseJsonBytes } from "../../../orderbook-server/src/json";
// The worker's path.
import { announceFromJson } from "@1delta-x/sdk";
import { canonicalAnnounce } from "../../src/core";

/**
 * JSON parity: the same JSON body must name the same order — the same order hash
 * — on the Node server (strict parse → protobuf encode → decode) and on the
 * worker (strict parse, no protobuf), and the worker's stored/served form must
 * re-parse to that hash on both.
 */
const A = "0x1111111111111111111111111111111111111111" as Address;
const B = "0x2222222222222222222222222222222222222222" as Address;
const SIG = `0x${"ab".repeat(65)}` as Hex;

function variants(): Order[] {
  const base: Order = {
    maker: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    side: OrderSide.SELL,
    nonce: 123456789n,
    expiry: 1_900_000_000n,
    legsIn: [{ token: A, start: 10n ** 18n, end: 0n }],
    legsOut: [{ token: B, start: 2_000_000n, end: 1_900_000n, recipient: zeroAddress }],
    timing: (5n << 32n) | 1n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [{ timeDelta: 10, bumpBps: 5000 }],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [{ target: B, data: "0x1234" }],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };
  return [
    base,
    { ...base, side: OrderSide.BUY, nonce: (1n << 200n) + 7n, baselinePriorityFeeWei: 12345n },
    {
      ...base,
      legsIn: [{ token: A, start: 5n, end: 9n }, { token: B, start: 1n, end: 0n }],
      items: [{ op: 3, module: A, amount: (1n << 255n) - 1n, recipient: B, data: "0xdeadbeef" }],
      invariants: [{ target: A, data: "0x" }],
      fillModule: B,
      fillTotal: 777n,
      pricingModule: A,
      exclusiveFiller: B,
      exclusivityOverrideBps: 50n,
      gasBumpBps: 3n,
      gasPriceRef: 10n ** 9n,
      priorityScale: 2n,
      minFillAnchor: 1n,
      curve: [],
    },
  ];
}

describe("JSON parity with orderbook-server", () => {
  it.each(variants().map((o, i) => [i, o] as const))("variant %i hashes identically on both paths", (_i, order) => {
    const body = JSON.stringify({ order: orderToJson(order), sig: SIG });
    const expected = hashOrderStruct(order);

    // Server: strict parse, then the protobuf round trip the route applies.
    const viaServer = decodeOrderAnnounce(encodeOrderAnnounce(serverAnnounceFromJson(parseJsonBytes(new TextEncoder().encode(body)))));
    // Worker: strict parse only.
    const viaWorker = announceFromJson(JSON.parse(body));
    expect(hashOrderStruct(viaServer.order)).toBe(expected);
    expect(hashOrderStruct(viaWorker.order)).toBe(expected);

    // What the worker stores and serves re-parses to the same order on both paths…
    const served = canonicalAnnounce(viaWorker);
    expect(hashOrderStruct(serverAnnounceFromJson(JSON.parse(served)).order)).toBe(expected);
    // …and is a fixed point of the canonical encoding.
    expect(canonicalAnnounce(announceFromJson(JSON.parse(served)))).toBe(served);
  });
});

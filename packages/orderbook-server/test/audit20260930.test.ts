import { afterEach, describe, expect, it } from "vitest";
import {
  encodeOrderAnnounce,
  encodeSoftCancel,
  InMemoryTransport,
  OrderStatus,
  signSoftCancel,
  type OrderAnnounce,
  type OrderbookConfig,
  type Verifier,
} from "@1delta-x/orderbook";
import { encodeProportional, hashOrderStruct, OrderSide, SETTLEMENT_ABI, withPriorityAuction, type Order } from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { decodeFunctionData, maxUint256, zeroAddress, type Address, type Hex } from "viem";

import { buildServer, type OrderbookServer } from "../src/server";

/**
 * Regressions for the 2026-09-30 whole-tree audit, group B-offchain (server).
 * Named `test_audit_<ID>_<what>`; each asserts the safe end state and fails on the
 * pre-fix server.
 */

const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const filler = "0x00000000000000000000000000000000000f1113" as Address;
const config: OrderbookConfig = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
  lens: zeroAddress,
  rpcUrl: "",
};
const unix = () => Math.floor(Date.now() / 1000);

function orderFor(maker: Address, nonce = 1n, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce,
    expiry: BigInt(unix() + 3600),
    legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: 1000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 800n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
    ...over,
  };
}

const okState = { ok: true, status: OrderStatus.Fillable, fillableAmount: 1000n, isSignatureValid: true, validatorsPass: true };

/** Layer 1 proves the maker; Layer 2 says only nonce 1..9 are live — the rest are dead orders. */
const verifier = {
  verifyLayer1: async (a: OrderAnnounce) => ({ ok: true, orderHash: hashOrderStruct(a.order), deferSig: false }),
  verifyAnnounce: async (a: OrderAnnounce) => {
    const orderHash = hashOrderStruct(a.order);
    return a.order.nonce < 10n
      ? { ok: true, orderHash, state: okState }
      : { ok: false, reason: "order fully filled", orderHash, state: { ...okState, ok: false, status: OrderStatus.Filled } };
  },
  refreshStates: async () => new Map(),
} as unknown as Verifier;

const post = (url: string, bytes: Uint8Array) => ({
  method: "POST" as const,
  url,
  headers: { "content-type": "application/x-protobuf" },
  payload: Buffer.from(bytes),
});

let server: OrderbookServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

interface LensCall {
  functionName: string;
  args: readonly unknown[];
  gasPrice?: bigint;
}

/** A lens stub: previewFill answers `delta`, previewBump answers `bump`; every call is logged. */
function lens(delta: bigint, bump: bigint, calls: LensCall[]) {
  return {
    readContract: async (args: LensCall) => {
      calls.push(args);
      if (args.functionName === "previewBump") return bump;
      return [delta, [delta], [850n]];
    },
  };
}

async function quoteServer(delta: bigint, bump: bigint, calls: LensCall[]) {
  return buildServer({ config, verifier, transport: new InMemoryTransport(), client: lens(delta, bump, calls) as never, logger: false, disableRateLimit: true });
}

function decodeFill(data: Hex) {
  const { functionName, args } = decodeFunctionData({ abi: SETTLEMENT_ABI, data });
  expect(functionName).toBe("fillUpTo");
  const [, , fillAmount, , minBumpBps] = args as readonly [unknown, Hex, bigint, Address, bigint, Hex];
  return { fillAmount, minBumpBps };
}

describe("PERIPH-1.v1 — /quote calldata binds the quoted price and size", () => {
  it("test_audit_PERIPH_1_v1_calldata_carries_the_quoted_bump_as_its_floor", async () => {
    const calls: LensCall[] = [];
    server = await quoteServer(1000n, 4_200n, calls);
    const order = orderFor(alice.address);
    const { orderHash } = (await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })))).json();
    const res = await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=1000&filler=${filler}` });
    expect(res.statusCode).toBe(200);
    const { minBumpBps } = decodeFill(res.json().data);
    expect(minBumpBps).toBe(4_200n);
    expect(res.json().minBumpBps).toBe("4200");
  });

  it("test_audit_PERIPH_1_v1_priority_order_needs_a_gas_price_and_quotes_at_it", async () => {
    const calls: LensCall[] = [];
    server = await quoteServer(1000n, 3_000n, calls);
    const order = orderFor(alice.address, 2n, { timing: withPriorityAuction(0n), priorityScale: 1n });
    const { orderHash } = (await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })))).json();

    // No gas price: a gas-price-0 preview is the no-bid quote. Refused.
    const bare = await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=1000&filler=${filler}` });
    expect(bare.statusCode).toBe(400);
    expect(calls).toHaveLength(0);

    const gp = 2_000_000_000n;
    const res = await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=1000&filler=${filler}&gasPrice=${gp}` });
    expect(res.statusCode).toBe(200);
    // Both previews ran at the gas price the filler will send.
    expect(calls.map((c) => c.functionName).sort()).toEqual(["previewBump", "previewFill"]);
    for (const c of calls) expect(c.gasPrice).toBe(gp);
    expect(decodeFill(res.json().data).minBumpBps).toBe(3_000n);
  });

  it("test_audit_PERIPH_3_v1_proportional_sentinel_is_replaced_by_the_resolved_size", async () => {
    const calls: LensCall[] = [];
    server = await quoteServer(777n, 0n, calls);
    const order = orderFor(alice.address, 3n, {
      legsIn: [{ token: "0x1111111111111111111111111111111111111111", start: encodeProportional(10_000n), end: 10n ** 24n }],
    });
    const { orderHash } = (await server.app.inject(post("/orders", encodeOrderAnnounce({ order, sig: "0x" })))).json();
    const res = await server.app.inject({ method: "GET", url: `/quote?hash=${orderHash}&fillAmount=${maxUint256}&filler=${filler}` });
    expect(res.statusCode).toBe(200);
    // The calldata names the exact size the quote priced, never the any-size sentinel.
    expect(decodeFill(res.json().data).fillAmount).toBe(777n);
    expect(res.json().proportional).toBe(true);
  });
});

describe("G-TS_FILLER-6 — replaying a maker's dead orders does not drain the maker", () => {
  it("test_audit_G_TS_FILLER_6_dead_order_replays_are_not_billed_to_the_maker", async () => {
    // Budget for exactly one order and one cancel.
    server = await buildServer({
      config,
      verifier,
      transport: new InMemoryTransport(),
      logger: false,
      rateLimit: { ip: { capacity: 100_000, refillPerSecond: 0 }, maker: { capacity: 15, refillPerSecond: 0 } },
    });
    // A stranger holding five of the maker's genuine, filled orders replays them.
    for (let n = 10n; n < 15n; n++) {
      const res = await server.app.inject(post("/orders", encodeOrderAnnounce({ order: orderFor(alice.address, n), sig: "0x" })));
      expect(res.statusCode).toBe(422);
    }
    // The maker's own post and soft cancel still go through.
    const live = orderFor(alice.address, 1n);
    expect((await server.app.inject(post("/orders", encodeOrderAnnounce({ order: live, sig: "0x" })))).statusCode).toBe(202);
    const cancel = encodeSoftCancel(await signSoftCancel(alice, alice.address, [hashOrderStruct(live)], config));
    expect((await server.app.inject(post("/cancels", cancel))).statusCode).toBe(202);
  });
});

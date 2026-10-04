import { env } from "cloudflare:test";
import { CancelVerifier, OrderStatus, Verifier, type Layer2Result, type OrderAnnounce } from "@1delta-x/orderbook/pure";
import { hashOrderStruct, orderToJson, OrderSide, signOrder, softCancelOrders, softCancelToJson, type Deployment, type Order } from "@1delta-x/sdk";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { ChainLog, ChainReader } from "../src/chain";
import type { Env } from "../src/config";
import type { CoreDeps } from "../src/core";
import { CLIENT_IP_HEADER, setDepsFactory } from "../src/do";

export const testEnv = env as unknown as Env;

export const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
export const bob = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
export const mallory = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

export const deployment: Deployment = {
  chainId: Number(testEnv.CHAIN_ID),
  settlement: testEnv.SETTLEMENT as Address,
  permit3: testEnv.PERMIT3 as Address,
};

export const USDRIF = "0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37" as Address;
export const USDT0 = "0x779ded0c9e1022225f8e0630b35a9b54be713736" as Address;

/**
 * The world the stubbed deps see. Tests mutate it; every Durable Object instance
 * (including a fresh one after eviction) reads the same object.
 */
export const world = {
  /** Seconds added to the real clock. */
  offset: 0,
  /** Lens verdict per order hash; default fillable. `"throw"` simulates an RPC outage. */
  lens: new Map<string, Layer2Result | "throw">(),
  lensDown: false,
  head: 1_000n,
  logs: [] as ChainLog[],
  /** `filled(hash)` per `hash@block` (and `hash@latest`). */
  filled: new Map<string, bigint>(),
  lensCalls: 0,
};

export function resetWorld(): void {
  world.offset = 0;
  world.lens.clear();
  world.lensDown = false;
  world.head = 1_000n;
  world.logs = [];
  world.filled.clear();
  world.lensCalls = 0;
}

export const now = (): number => Math.floor(Date.now() / 1000) + world.offset;

export const fillable = (amount = 1_000n): Layer2Result => ({
  ok: true,
  status: OrderStatus.Fillable,
  fillableAmount: amount,
  isSignatureValid: true,
  validatorsPass: true,
});

/** A chain client for the soft-cancel verifier: EOAs only, no delegates. */
const cancelClient = {
  getCode: async () => "0x",
  readContract: async () => 0n,
} as unknown as PublicClient;

const config = {
  chainId: deployment.chainId,
  settlement: deployment.settlement,
  permit3: deployment.permit3,
  lens: testEnv.LENS as Address,
  rpcUrl: "",
};

/** Real Layer 1 (signature recovery, deadline, denominator) + a scripted Layer 2. */
function scriptedVerifier(): CoreDeps["verifier"] {
  const real = new Verifier({} as PublicClient, config, { now });
  const layer2 = (hash: string): Layer2Result => {
    world.lensCalls++;
    if (world.lensDown) throw new Error("rpc down");
    const v = world.lens.get(hash.toLowerCase());
    if (v === "throw") throw new Error("rpc down");
    return v ?? fillable();
  };
  return {
    verifyLayer1: (a) => real.verifyLayer1(a),
    async verifyAnnounce(a: OrderAnnounce) {
      const l1 = await real.verifyLayer1(a);
      if (!l1.ok) return { ok: false, reason: l1.reason, orderHash: l1.orderHash };
      const state = layer2(l1.orderHash);
      return { ok: state.ok, ...(state.ok ? {} : { reason: "maker has no allowance/balance for this order" }), orderHash: l1.orderHash, state };
    },
    async refreshStates(entries) {
      if (world.lensDown) throw new Error("rpc down");
      const out = new Map<Hex, Layer2Result>();
      for (const e of entries) out.set(e.orderHash, layer2(e.orderHash));
      return out;
    },
    invalidate: () => {},
  };
}

const chain: ChainReader = {
  blockNumber: async () => world.head,
  logs: async (from, to) => world.logs.filter((l) => l.blockNumber >= from && l.blockNumber <= to),
  async filledAt(hash, block) {
    const v = world.filled.get(`${hash.toLowerCase()}@${block ?? "latest"}`);
    if (v === undefined) {
      // Unset history reads as "before any fill".
      return 0n;
    }
    return v;
  },
  blockTime: async (block) => 1_700_000_000 + Number(block) * 30,
};

setDepsFactory(() => ({
  verifier: scriptedVerifier(),
  cancelVerifier: new CancelVerifier(cancelClient, config, { now }),
  chain,
  now,
  nowMs: () => Date.now() + world.offset * 1000,
}));

let nonce = 1n;

export function orderFor(maker: Address, over: Partial<Order> = {}): Order {
  return {
    maker,
    side: OrderSide.SELL,
    nonce: nonce++,
    expiry: BigInt(now() + 3600),
    legsIn: [{ token: USDRIF, start: 1_000n, end: 0n }],
    legsOut: [{ token: USDT0, start: 990n, end: 0n, recipient: zeroAddress }],
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

export async function signed(
  account: typeof alice,
  over: Partial<Order> = {},
): Promise<{ order: Order; sig: Hex; hash: Hex; body: string }> {
  const order = orderFor(account.address, over);
  const sig = await signOrder(account, order, deployment);
  return { order, sig, hash: hashOrderStruct(order).toLowerCase() as Hex, body: JSON.stringify({ order: orderToJson(order), sig }) };
}

export async function cancelBody(account: typeof alice, maker: Address, hashes: Hex[]): Promise<string> {
  const { cancel } = await softCancelOrders(account, maker, hashes, deployment);
  // Signed by `account` but naming `maker` — a stranger's forgery when they differ.
  const sig = await account.signTypedData((await import("@1delta-x/sdk")).softCancelTypedData(cancel, deployment) as never);
  return JSON.stringify({ cancel: softCancelToJson(cancel), sig });
}

let bookSeq = 0;
/** A fresh Durable Object (fresh storage) per call. */
export function freshBook(): DurableObjectStub {
  return testEnv.BOOK.get(testEnv.BOOK.idFromName(`test-${++bookSeq}-${Math.random()}`));
}

export async function call(
  stub: DurableObjectStub,
  method: string,
  path: string,
  body?: string,
  ip = "198.51.100.7",
): Promise<{ status: number; body: Record<string, unknown>; headers: Headers }> {
  const res = await stub.fetch(`https://book.test${path}`, {
    method,
    headers: { [CLIENT_IP_HEADER]: ip, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
    ...(body !== undefined ? { body } : {}),
  });
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    parsed = { raw: text };
  }
  return { status: res.status, body: parsed, headers: res.headers };
}

export function fillLog(hash: Hex, maker: Address, block: bigint, logIndex = 0, tx?: Hex): ChainLog {
  return {
    event: { kind: "filled", orderHash: hash, maker, solver: bob.address },
    blockNumber: block,
    logIndex,
    txHash: tx ?? (`0x${block.toString(16).padStart(32, "0")}${logIndex.toString(16).padStart(32, "0")}` as Hex),
  };
}

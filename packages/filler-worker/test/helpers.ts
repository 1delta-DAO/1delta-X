import { env } from "cloudflare:test";
import { AGGREGATOR_FILL_SOLVER_ABI, hashOrderStruct, orderToJson, OrderSide, type Order } from "@1delta-x/sdk";
import { decodeFunctionData, encodeFunctionResult, keccak256, parseTransaction, TransactionNotFoundError, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { Env } from "../src/config";
import { setDeps, type FillerDO, type TickSummary } from "../src/do";

export const testEnv = env as unknown as Env;

export const SOLVER = "0x00000000000000000000000000000000000050a1" as Address;
export const SANDBOX = "0x0000000000000000000000000000000000005a4d" as Address;
export const WRBTC = "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d" as Address;
export const USDT0 = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736" as Address;
export const GAS_PRICE = 26_065_600n;
export const OWED = 900_000_000n;
export const RECEIVED = 10n ** 16n;
export const ADMIN = testEnv.ADMIN_TOKEN as string;

export interface Sent {
  hash: Hex;
  raw: Hex;
  data?: Hex;
  nonce: number;
  gas?: bigint;
  gasPrice?: bigint;
  type: string;
  to?: Address | null;
}

/**
 * The fake world every Durable Object instance sees (module state survives an
 * eviction within the isolate). Tests mutate it.
 */
export const world = {
  /** Milliseconds added to the clock the filler sees. */
  offset: 0,
  receipt: "none" as "none" | "success" | "reverted",
  /** Whether `getTransaction` finds a sent tx (false = dropped from the mempool). */
  known: true,
  rpcDown: false,
  sent: [] as Sent[],
  mined: 0,
  rbtc: 10n ** 18n,
  /** Subrequests each fake RPC call is billed as (to exercise the per-tick bound). */
  rpcCost: 1,
  rpcCalls: 0,
  previews: 0,
  /** Nonces of orders a mined successful tx filled: the fake lens previews them as empty. */
  filled: new Set<bigint>(),
  /** The book served to the filler, as `GET /orders` items. */
  book: [] as unknown[],
  bookFetches: 0,
  /** The orderbook's `GET /health` body; unset = healthy, its alarm just ran. */
  bookHealth: undefined as Record<string, unknown> | undefined,
  healthFetches: 0,
  /** The pending nonce runs this far ahead of the mined one (an untracked tx in flight). */
  inFlightExtra: 0,
  /** `eth_call` (the fill simulation) throws this message (e.g. a provider error quoting the RPC URL). */
  callError: undefined as string | undefined,
  alerts: [] as Array<{ url: string; body: Record<string, unknown> }>,
};

export function resetWorld(): void {
  Object.assign(world, {
    offset: 0,
    receipt: "none",
    known: true,
    rpcDown: false,
    sent: [],
    mined: 0,
    rbtc: 10n ** 18n,
    rpcCost: 1,
    rpcCalls: 0,
    previews: 0,
    filled: new Set<bigint>(),
    book: [],
    bookFetches: 0,
    bookHealth: undefined,
    healthFetches: 0,
    inFlightExtra: 0,
    callError: undefined,
    alerts: [],
  });
}

/** A healthy orderbook /health as the filler's clock sees it. */
export function healthyBook(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    chainId: 30,
    configured: true,
    rpc: "RPC_URL_SECRET",
    alarmIntervalSeconds: 20,
    lastAlarm: String(Math.floor((Date.now() + world.offset) / 1000) - 5),
    logsUnsupported: false,
    logs: { ok: true, unsupported: false, span: "2000", lastOkAt: null, lastErrorAt: null, lastError: null },
    lastError: null,
    ...over,
  };
}

let nonce = 1n;

/** A plain pull WRBTC → USDT0 order the route strategy fills (distinct hash per call). */
export function order(): Order {
  return {
    maker: "0x00000000000000000000000000000000000000bb",
    side: OrderSide.SELL,
    nonce: nonce++,
    expiry: 2_000_000_000n,
    legsIn: [{ token: WRBTC, start: RECEIVED, end: 0n }],
    legsOut: [{ token: USDT0, start: OWED, end: 0n, recipient: zeroAddress }],
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
  } as Order;
}

/** Put `n` orders on the fake book; returns their hashes (lower case). */
export function seedBook(n: number): Hex[] {
  const hashes: Hex[] = [];
  for (let i = 0; i < n; i++) {
    const o = order();
    const h = hashOrderStruct(o).toLowerCase() as Hex;
    hashes.push(h);
    world.book.push({ orderHash: h, order: orderToJson(o), sig: "0x00", state: { ok: true, status: "Fillable", fillableAmount: RECEIVED.toString(), validatorsPass: true } });
  }
  return hashes;
}

/** A route-strategy chain: lens preview, QuoterV2 at 1 RBTC = 100k USDT0, a passing simulation, raw-tx sends. */
function fakeChain(account: { address: Address; signTransaction: unknown }, count: () => void, chainId: number) {
  const hit = () => {
    world.rpcCalls++;
    for (let i = 0; i < world.rpcCost; i++) count();
    if (world.rpcDown) throw new Error("HTTP request failed. URL: http://rpc.invalid");
  };
  const pub = {
    getBlockNumber: async () => (hit(), 1_000n),
    getCode: async () => (hit(), "0x60"),
    getGasPrice: async () => (hit(), GAS_PRICE),
    getBalance: async () => (hit(), world.rbtc),
    getTransactionCount: async ({ blockTag }: { blockTag?: string } = {}) => (hit(), world.mined + (blockTag === "pending" ? world.inFlightExtra : 0)),
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      hit();
      const t = parseTransaction(serializedTransaction);
      const hash = keccak256(serializedTransaction);
      world.sent.push({ hash, raw: serializedTransaction, data: t.data, nonce: t.nonce!, gas: t.gas, gasPrice: t.gasPrice, type: t.type!, to: t.to });
      return hash;
    },
    getTransactionReceipt: async () => {
      hit();
      if (world.receipt === "none") throw new Error("Transaction receipt could not be found");
      world.mined = world.sent.length;
      if (world.receipt === "success") {
        for (const t of world.sent) {
          try {
            const { args } = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: t.data! });
            world.filled.add((args![0] as { nonce: bigint }).nonce);
          } catch {
            // not an executeFill
          }
        }
      }
      return { status: world.receipt, gasUsed: 280_000n, effectiveGasPrice: GAS_PRICE };
    },
    getTransaction: async ({ hash }: { hash: Hex }) => {
      hit();
      if (!world.known) throw new TransactionNotFoundError({ hash });
      return {};
    },
    readContract: async ({ functionName, args }: { functionName: string; args?: readonly unknown[] }) => {
      hit();
      switch (functionName) {
        case "SETTLEMENT": return testEnv.SETTLEMENT;
        case "GATED": return true;
        case "isOperator": return true;
        case "SANDBOX": return SANDBOX;
        case "OWNER": return SOLVER;
        case "MAKER_SURPLUS_PPM": case "PROTOCOL_SURPLUS_PPM": return 0;
        case "previewFill": {
          world.previews++;
          const nonce = (args?.[0] as { nonce?: bigint } | undefined)?.nonce;
          return nonce !== undefined && world.filled.has(nonce) ? [0n, [0n], [0n]] : [0n, [RECEIVED], [OWED]];
        }
        case "previewBump": return 0n; // the route plan's minBumpBps (task 08)
        case "decimals": return 6;
        case "balanceOf": return 10n ** 9n;
      }
      throw new Error(`unexpected read ${functionName}`);
    },
    simulateContract: async ({ args }: { args: [Hex, bigint] }) => (hit(), { result: [(args[1] * 100_000n * 10n ** 6n) / 10n ** 18n, [], [], 100_000n] }),
    call: async () => {
      hit();
      if (world.callError) throw new Error(world.callError);
      return { data: encodeFunctionResult({ abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "executeFill", result: [OWED] }) };
    },
    estimateGas: async () => (hit(), 250_000n),
  };
  return { pub, account, me: account.address, chainId } as never;
}

/** The fakes every test runs with (the book override can be dropped per test). */
export const testDeps: Parameters<typeof setDeps>[0] = {
  // The REAL account from the PRIVATE_KEY binding signs (viem's privateKeyToAccount in workerd).
  makeChain: (cfg, rpc) => fakeChain(privateKeyToAccount(cfg.privateKey), rpc.count, cfg.chainId),
  fetchBook: async (url) => {
    if (new URL(url).pathname === "/health") {
      world.healthFetches++;
      return Response.json(world.bookHealth ?? healthyBook());
    }
    world.bookFetches++;
    return Response.json({ orders: world.book });
  },
  fetchAlert: async (url, init) => {
    world.alerts.push({ url, body: JSON.parse(String(init.body)) });
    return new Response("ok");
  },
  now: () => Date.now() + world.offset,
};
setDeps(testDeps);

let seq = 0;
/** A fresh filler Durable Object (fresh storage) per call. */
export function freshFiller(): DurableObjectStub<FillerDO> {
  return testEnv.FILLER.get(testEnv.FILLER.idFromName(`test-${++seq}-${Math.random()}`)) as DurableObjectStub<FillerDO>;
}

export async function tick(stub: DurableObjectStub<FillerDO>): Promise<TickSummary> {
  return (await stub.runTick("test")) as TickSummary;
}

/** An internal (already-authenticated) call straight to the DO. */
export async function doCall(stub: DurableObjectStub<FillerDO>, method: string, path: string, body?: unknown): Promise<{ status: number; body: Record<string, unknown>; text: string }> {
  const res = await stub.fetch(`https://filler${path}`, {
    method,
    headers: { "content-type": "application/json" },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    parsed = { raw: text };
  }
  return { status: res.status, body: parsed, text };
}

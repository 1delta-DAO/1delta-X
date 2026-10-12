import { describe, expect, it } from "vitest";
import {
  OrderSide,
  erc2612DomainSeparator,
  erc2612TypedData,
  orderTypedData,
  splitPermitSignature,
  type Erc2612Permit,
  type Order,
} from "@1delta-x/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { zeroAddress, type Address, type Hex, type PublicClient } from "viem";

import { OrderStatus, Verifier } from "../src/verify";
import { decodeOrderAnnounce, encodeOrderAnnounce } from "../src/proto/codec";
import type { OrderAnnounce } from "../src/messages";
import { toDeployment } from "../src/config";

const SETTLEMENT = "0x00000000000000000000000000000000000000E5" as Address;
const TOKEN = "0x1111111111111111111111111111111111111111" as Address;
const config = { chainId: 30, settlement: SETTLEMENT, permit3: zeroAddress, lens: zeroAddress, rpcUrl: "" };
const maker = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const stranger = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
const domain = { name: "USD₮0", version: "1", chainId: 30, verifyingContract: TOKEN };
const NOW = 1_800_000_000;

function order(expiry = BigInt(NOW + 3600)): Order {
  return {
    maker: maker.address,
    side: OrderSide.SELL,
    nonce: 7n,
    expiry,
    legsIn: [{ token: TOKEN, start: 5_000_000n, end: 0n }],
    legsOut: [{ token: "0x2222222222222222222222222222222222222222", start: 900n, end: 0n, recipient: zeroAddress }],
    timing: 0n,
    exclusiveFiller: zeroAddress,
    minFillAnchor: 0n,
    exclusivityOverrideBps: 0n,
    curve: [],
    gasBumpBps: 0n,
    gasPriceRef: 0n,
    priorityScale: 0n,
    baselinePriorityFeeWei: 0n,
    items: [],
    validators: [],
    invariants: [],
    fillModule: zeroAddress,
    fillTotal: 0n,
    pricingModule: zeroAddress,
  };
}

async function permitFor(o: Order, over: Partial<Erc2612Permit> = {}, signer = maker): Promise<Erc2612Permit> {
  const base = { spender: SETTLEMENT, value: 5_000_000n, nonce: 0n, deadline: o.expiry, ...over };
  const sig = await signer.signTypedData(erc2612TypedData(domain, { owner: o.maker, ...base }));
  return { token: TOKEN, ...base, ...splitPermitSignature(sig), ...(over.v !== undefined ? { v: over.v } : {}) };
}

interface Chain {
  nonce: bigint;
  balance: bigint;
  /** The lens's allowance-capped fillable. */
  fillable: bigint;
  /** The token has no EIP-2612 views (WRBTC-like). */
  noPermit?: boolean;
  /** The token's permit() eth_call reverts. */
  permitReverts?: boolean;
  calls: string[];
}

function client(c: Chain): PublicClient {
  return {
    readContract: async (a: { functionName: string; args?: unknown[] }) => {
      c.calls.push(a.functionName);
      switch (a.functionName) {
        case "DOMAIN_SEPARATOR":
          if (c.noPermit) throw Object.assign(new Error("execution reverted"), { name: "ContractFunctionRevertedError" });
          return erc2612DomainSeparator(domain);
        case "nonces":
          return c.nonce;
        case "balanceOf":
          return c.balance;
        case "getOrderRelevantStates": {
          const n = (a.args![0] as unknown[]).length;
          return [new Array(n).fill(OrderStatus.Fillable), new Array(n).fill(c.fillable), new Array(n).fill(true), new Array(n).fill(true)];
        }
        default:
          throw new Error(`unexpected ${a.functionName}`);
      }
    },
    call: async () => {
      c.calls.push("permit");
      if (c.permitReverts) throw new Error("VM Exception while processing transaction: transaction reverted");
      return { data: "0x" };
    },
  } as unknown as PublicClient;
}

async function announce(o: Order, p?: Erc2612Permit): Promise<OrderAnnounce> {
  const sig = (await maker.signTypedData(orderTypedData(o, toDeployment(config)) as never)) as Hex;
  return { order: o, sig, ...(p ? { erc2612Permit: p } : {}) };
}

const chain = (over: Partial<Chain> = {}): Chain => ({ nonce: 0n, balance: 10_000_000n, fillable: 0n, calls: [], ...over });
const verifier = (c: Chain) => new Verifier(client(c), config, { now: () => NOW });

describe("Verifier — ERC-2612 funding permit", () => {
  it("admits an unfunded order on a live, maker-signed permit (lens fillable 0)", async () => {
    const c = chain();
    const o = order();
    const res = await verifier(c).verifyAnnounce(await announce(o, await permitFor(o)));
    expect(res.ok).toBe(true);
    expect(res.state?.erc2612Live).toBe(true);
    expect(res.state?.fillableAmount).toBe(0n);
    expect(c.calls).toContain("permit"); // the token itself was asked
  });

  it("without the permit the same order is refused as unfunded", async () => {
    const o = order();
    const res = await verifier(chain()).verifyAnnounce(await announce(o));
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/no allowance\/balance/);
  });

  it("refuses a permit not signed by the maker, or to another spender, or for a foreign token", async () => {
    const o = order();
    const v = verifier(chain());
    expect((await v.verifyAnnounce(await announce(o, await permitFor(o, {}, stranger)))).reason).toMatch(/not signed by the maker/);
    expect((await v.verifyAnnounce(await announce(o, await permitFor(o, { spender: maker.address })))).reason).toMatch(/spender/);
    const foreign = { ...(await permitFor(o)), token: "0x3333333333333333333333333333333333333333" as Address };
    expect((await v.verifyAnnounce(await announce(o, foreign))).reason).toMatch(/input tokens/);
  });

  it("refuses a deadline before the order's expiry, and a non-canonical v", async () => {
    const o = order();
    const v = verifier(chain());
    expect((await v.verifyAnnounce(await announce(o, await permitFor(o, { deadline: o.expiry - 1n })))).reason).toMatch(/deadline/);
    expect((await v.verifyAnnounce(await announce(o, { ...(await permitFor(o)), v: 1 }))).reason).toMatch(/canonical/);
  });

  it("refuses a token without EIP-2612 views, and a permit the token's own permit() rejects", async () => {
    const o = order();
    const p = await permitFor(o);
    expect((await verifier(chain({ noPermit: true })).verifyAnnounce(await announce(o, p))).reason).toMatch(/does not implement EIP-2612/);
    expect((await verifier(chain({ permitReverts: true })).verifyAnnounce(await announce(o, p))).reason).toMatch(/refused by the token/);
  });

  it("a SPENT permit is not a rejection: the order stands on its on-chain allowance", async () => {
    const o = order();
    const p = await permitFor(o); // nonce 0
    // Relayed: the token's nonce moved on and the allowance exists (lens fillable > 0).
    const relayed = chain({ nonce: 1n, fillable: 5_000_000n });
    const ok = await verifier(relayed).verifyAnnounce(await announce(o, p));
    expect(ok.ok).toBe(true);
    expect(ok.state?.erc2612Live).toBeUndefined();
    expect(relayed.calls).not.toContain("permit");
    // Superseded: nonce moved, nothing approved → unfunded like any other order.
    const dead = await verifier(chain({ nonce: 1n })).verifyAnnounce(await announce(o, p));
    expect(dead.ok).toBe(false);
    // A nonce from the future is malformed.
    expect((await verifier(chain()).verifyAnnounce(await announce(o, await permitFor(o, { nonce: 3n })))).reason).toMatch(/ahead/);
  });

  it("a maker with no balance gets no credit from a permit", async () => {
    const o = order();
    const res = await verifier(chain({ balance: 0n })).verifyAnnounce(await announce(o, await permitFor(o)));
    expect(res.ok).toBe(false);
  });

  it("refreshStates re-judges the permit: live → ok; spent and unfunded → not ok", async () => {
    const o = order();
    const a = await announce(o, await permitFor(o));
    const c = chain();
    const v = verifier(c);
    const first = await v.refreshStates([{ orderHash: (await v.verifyLayer1(a)).orderHash, announce: a }]);
    expect([...first.values()][0]!.ok).toBe(true);
    c.nonce = 1n; // someone spent the nonce on another permit; no allowance came of it
    const second = await v.refreshStates([{ orderHash: (await v.verifyLayer1(a)).orderHash, announce: a }]);
    expect([...second.values()][0]!.ok).toBe(false);
  });

  it("round-trips through the protobuf codec", async () => {
    const o = order();
    const a = await announce(o, await permitFor(o));
    expect(decodeOrderAnnounce(encodeOrderAnnounce(a)).erc2612Permit).toEqual(a.erc2612Permit);
  });
});

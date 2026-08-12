import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress, verifyTypedData, zeroAddress } from "viem";

import {
  amendOrder,
  buildSoftCancel,
  hashOrderStruct,
  patchOrder,
  SOFT_CANCEL_TYPE,
  SOFT_CANCEL_TYPESTRING,
  softCancelDigest,
  softCancelOrders,
  softCancelTypedData,
  type Deployment,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const d: Deployment = {
  chainId: 31,
  settlement: "0x0000000000000000000000000000000000000001",
  permit3: zeroAddress,
};
const order = { ...CANONICAL_ORDER, maker: account.address };

describe("SoftCancel typed data", () => {
  it("the typestring matches the field list (drift guard)", () => {
    const fields = SOFT_CANCEL_TYPE.map((f) => `${f.type} ${f.name}`).join(",");
    expect(SOFT_CANCEL_TYPESTRING).toBe(`SoftCancel(${fields})`);
  });

  it("recovers to the signer", async () => {
    const { cancel, sig } = await softCancelOrders(account, account.address, [order], d);
    const recovered = await recoverTypedDataAddress({ ...softCancelTypedData(cancel, d), signature: sig } as never);
    expect(recovered).toBe(account.address);
    expect(cancel.orderHashes).toEqual([hashOrderStruct(order)]);
  });

  it("is bound to the deployment — the same message on another chain is a different digest", async () => {
    const cancel = buildSoftCancel(account.address, [order], { now: 1_700_000_000n });
    const here = softCancelDigest(cancel, d);
    const elsewhere = softCancelDigest(cancel, { ...d, chainId: 1 });
    const otherSettlement = softCancelDigest(cancel, { ...d, settlement: "0x0000000000000000000000000000000000000002" });
    expect(here).not.toBe(elsewhere);
    expect(here).not.toBe(otherSettlement);
  });

  it("a signature for one chain does not verify on another", async () => {
    const { cancel, sig } = await softCancelOrders(account, account.address, [order], d);
    expect(await verifyTypedData({ ...softCancelTypedData(cancel, d), address: account.address, signature: sig } as never)).toBe(true);
    expect(
      await verifyTypedData({
        ...softCancelTypedData(cancel, { ...d, chainId: 1 }),
        address: account.address,
        signature: sig,
      } as never),
    ).toBe(false);
  });

  it("batches many hashes under one signature", async () => {
    const hashes = [1n, 2n, 3n].map((n) => hashOrderStruct({ ...order, nonce: n }));
    const { cancel } = await softCancelOrders(account, account.address, hashes, d);
    expect(cancel.orderHashes).toEqual(hashes);
  });

  it("stamps a bounded validity window", () => {
    const c = buildSoftCancel(account.address, [order], { now: 1000n, ttlSeconds: 60n });
    expect(c.issuedAt).toBe(1000n);
    expect(c.expiry).toBe(1060n);
  });
});

describe("amendOrder — cancel and replace", () => {
  it("produces a replacement on a fresh nonce plus a cancel naming the predecessor", async () => {
    const res = await amendOrder(account, order, 99n, { minFillAnchor: 5n }, d);

    expect(res.order.nonce).toBe(99n);
    expect(res.order.minFillAnchor).toBe(5n);
    expect(res.replaces).toBe(hashOrderStruct(order));
    expect(res.orderHash).toBe(hashOrderStruct(res.order));
    expect(res.cancel.orderHashes).toEqual([res.replaces]);
    expect(res.cancel.maker).toBe(order.maker);
  });

  it("both halves verify independently", async () => {
    const res = await amendOrder(account, order, 99n, { minFillAnchor: 5n }, d);
    const cancelSigner = await recoverTypedDataAddress({
      ...softCancelTypedData(res.cancel, d),
      signature: res.cancelSig,
    } as never);
    expect(cancelSigner).toBe(account.address);
    expect(res.sig).not.toBe(res.cancelSig);
  });

  it("never re-homes the order — maker is inherited, not patchable", () => {
    const patched = patchOrder(order, 99n, { minFillAnchor: 5n } as never);
    expect(patched.maker).toBe(order.maker);
  });

  it("rejects a no-op amend rather than churning a nonce for nothing", async () => {
    await expect(amendOrder(account, order, order.nonce, {}, d)).rejects.toThrow(/no-op/);
  });

  it("carries every unpatched field through verbatim", () => {
    const patched = patchOrder(order, 99n, { deadline: 123n });
    expect(patched.deadline).toBe(123n);
    expect(patched.legsIn).toEqual(order.legsIn);
    expect(patched.legsOut).toEqual(order.legsOut);
    expect(patched.items).toEqual(order.items);
  });
});

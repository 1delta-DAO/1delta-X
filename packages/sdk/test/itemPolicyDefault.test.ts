import { describe, expect, it } from "vitest";
import { getAddress, zeroAddress, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  ItemOp,
  ItemPolicy,
  amendOrder,
  itemPolicyOf,
  patchOrder,
  signOrder,
  takeFundsInputLeg,
  withDefaultItemPolicy,
  withItemPolicy,
  type Deployment,
  type Item,
  type Order,
} from "../src";
import { CANONICAL_ORDER } from "./canonicalOrder";

/// ACCEPTED-PATTERNS-REVIEW B8: a TAKE whose proceeds fund an INPUT leg, signed
/// below CANONICAL, lets any matchSettle caller PULL the leg first — the Permit3
/// allowance is spent twice for one fill. The SDK defaults such orders to CANONICAL
/// (the only level `Batch._stepPull` enforces against) unless the caller says otherwise.
const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const d: Deployment = {
  chainId: 1,
  settlement: getAddress("0x00000000000000000000000000000000000005e7"),
  permit3: getAddress("0x0000000000000000000000000000000000000033"),
};
const USDC = CANONICAL_ORDER.legsIn[0]!.token;
const WETH = CANONICAL_ORDER.legsOut[0]!.token;
const MODULE = getAddress("0x00000000000000000000000000000000000000d2") as Address;

const take = (recipient: Address = zeroAddress, op: ItemOp = ItemOp.TAKE): Item => ({
  op,
  module: MODULE,
  amount: 1n,
  recipient,
  data: "0xabcd",
});
const withItems = (items: Item[], timing = CANONICAL_ORDER.timing): Order => ({
  ...CANONICAL_ORDER,
  maker: account.address,
  items,
  timing,
});

describe("takeFundsInputLeg", () => {
  it("flags a settler-routed TAKE (0x0 or the settlement address)", () => {
    expect(takeFundsInputLeg(withItems([take()]))).toBe(true);
    expect(takeFundsInputLeg(withItems([take(d.settlement)]), { settlement: d.settlement })).toBe(true);
  });

  it("uses a proceeds resolver when given one: input token yes, output-only token no", () => {
    expect(takeFundsInputLeg(withItems([take()]), { proceedsAsset: () => USDC })).toBe(true);
    expect(takeFundsInputLeg(withItems([take()]), { proceedsAsset: () => WETH })).toBe(false);
    expect(takeFundsInputLeg(withItems([take()]), { proceedsAsset: () => undefined })).toBe(true);
  });

  it("ignores a TAKE routed to the maker (borrow after deposit), TAKE_FOR, MAKE, and no input legs", () => {
    expect(takeFundsInputLeg(withItems([take(account.address)]))).toBe(false);
    expect(takeFundsInputLeg(withItems([take(zeroAddress, ItemOp.TAKE_FOR)]))).toBe(false);
    expect(takeFundsInputLeg(withItems([take(zeroAddress, ItemOp.MAKE)]))).toBe(false);
    expect(takeFundsInputLeg({ ...withItems([take()]), legsIn: [] })).toBe(false);
    // The golden fixture's TAKE pays the maker — the pinned hash is untouched.
    expect(takeFundsInputLeg(CANONICAL_ORDER)).toBe(false);
  });
});

describe("withDefaultItemPolicy", () => {
  it("defaults an input-funding TAKE at ANY to CANONICAL, touching nothing else", () => {
    const o = withItems([take()]);
    const out = withDefaultItemPolicy(o);
    expect(itemPolicyOf(out.timing)).toBe(ItemPolicy.CANONICAL);
    expect(out.timing & ~(0xfn << 96n)).toBe(o.timing & ~(0xfn << 96n));
  });

  it("respects an explicit policy, ANY included", () => {
    const o = withItems([take()]);
    expect(itemPolicyOf(withDefaultItemPolicy(o, { itemPolicy: ItemPolicy.ANY }).timing)).toBe(ItemPolicy.ANY);
    expect(itemPolicyOf(withDefaultItemPolicy(o, { itemPolicy: ItemPolicy.ATOMIC }).timing)).toBe(ItemPolicy.ATOMIC);
  });

  it("keeps a policy already set in timing", () => {
    const o = withItems([take()], withItemPolicy(CANONICAL_ORDER.timing, ItemPolicy.ORDERED));
    expect(withDefaultItemPolicy(o)).toBe(o);
  });

  it("leaves orders without an input-funding TAKE alone", () => {
    const o = withItems([take(account.address)]);
    expect(withDefaultItemPolicy(o)).toBe(o);
    const plain = withItems([]);
    expect(withDefaultItemPolicy(plain)).toBe(plain);
  });
});

describe("signing and amending", () => {
  it("signOrder refuses an input-funding TAKE at ANY, unless ANY is explicit", async () => {
    const o = withItems([take()]);
    await expect(signOrder(account, o, d)).rejects.toThrow(/ItemPolicy\.ANY/);
    await expect(signOrder(account, o, d, { itemPolicy: ItemPolicy.ANY })).resolves.toMatch(/^0x/);
    await expect(signOrder(account, withDefaultItemPolicy(o), d)).resolves.toMatch(/^0x/);
    // Explicit settlement recipient is caught through the deployment address.
    await expect(signOrder(account, withItems([take(d.settlement)]), d)).rejects.toThrow(/ItemPolicy\.ANY/);
  });

  it("patchOrder / amendOrder apply the default, and honour an explicit override", async () => {
    const prev = withItems([take()]);
    expect(itemPolicyOf(patchOrder(prev, 99n).timing)).toBe(ItemPolicy.CANONICAL);
    expect(itemPolicyOf(patchOrder(prev, 99n, {}, { itemPolicy: ItemPolicy.ANY }).timing)).toBe(ItemPolicy.ANY);

    const res = await amendOrder(account, prev, 99n, { minFillAnchor: 5n }, d);
    expect(itemPolicyOf(res.order.timing)).toBe(ItemPolicy.CANONICAL);
    const anyRes = await amendOrder(account, prev, 100n, { minFillAnchor: 5n }, d, { itemPolicy: ItemPolicy.ANY });
    expect(itemPolicyOf(anyRes.order.timing)).toBe(ItemPolicy.ANY);
  });
});

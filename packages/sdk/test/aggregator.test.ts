import { describe, expect, it } from "vitest";
import { concat, decodeFunctionData, encodeFunctionData, hexToBigInt, hexToBytes, numberToHex, size, sliceHex, toFunctionSelector, type Address, type Hex } from "viem";

import {
  AGGREGATOR_FILL_SOLVER_ABI,
  NO_PATCH,
  isNoPatch,
  ROUTE_SANDBOX_ABI,
  SNWAP_AMOUNT_IN_OFFSET,
  decodeSnwap,
  isSnwapExecutorAllowed,
  SUSHI_RED_SNWAPPER_ABI,
  SWAP_ROUTER02_ABI,
  encodeAggregatorExecuteFill,
  encodeExactInput,
  encodeExactInputSingle,
  encodeExactOutput,
  encodeExactOutputSingle,
  encodeV3Path,
  encodeV3PathReversed,
  patchAmountIn,
  POOL_ROUTE,
  ROOTSTOCK_POOL_VENUES,
  decodePoolRoute,
  encodePoolRoute,
  toSolverPermit,
  v3PoolAddress,
  type Permit2612,
  swapRouter02AmountInOffset,
  swapRouter02AmountOutOffset,
  type RoutePlan,
} from "../src/aggregator";
import { CANONICAL_ORDER } from "./canonicalOrder";

const WRBTC = "0x542fDA317318eBF1d3DEAf76E0b632741A7e677d" as Address;
const USDT0 = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736" as Address;
const USDRIF = "0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37" as Address;
const SOLVER = "0x00000000000000000000000000000000000000aa" as Address;
const ROUTER = "0x0B14ff67f0014046b4b99057Aec4509640b3947A" as Address;
// A value no other field of these calls can collide with.
const SENTINEL = 0x1234_5678_9abc_def0_1122_3344_5566_7788n;

const word = (data: Hex, off: bigint) => hexToBigInt(sliceHex(data, Number(off), Number(off) + 32));

describe("NO_PATCH", () => {
  it("is 2^255, the contract's canonical sentinel (one non-zero calldata byte; 2026-10-12)", () => {
    expect(NO_PATCH).toBe(2n ** 255n);
  });
  it("isNoPatch: any bit-255 value, including the pre-2026-10-12 type(uint256).max", () => {
    expect(isNoPatch(NO_PATCH)).toBe(true);
    expect(isNoPatch(2n ** 256n - 1n)).toBe(true);
    expect(isNoPatch(2n ** 255n | 7n)).toBe(true);
    expect(isNoPatch(2n ** 255n - 1n)).toBe(false);
    expect(isNoPatch(0n)).toBe(false);
    expect(isNoPatch(32n)).toBe(false);
  });
  it("a NO_PATCH offset word costs 140 calldata gas (was 512)", () => {
    const gas = (v: bigint) => [...hexToBytes(numberToHex(v, { size: 32 }))].reduce((g, b) => g + (b === 0 ? 4 : 16), 0);
    expect(gas(NO_PATCH)).toBe(140);
    expect(gas(2n ** 256n - 1n)).toBe(512);
  });
});

describe("AggregatorFillSolver ABI", () => {
  it("executeFill selector matches the compiled contract (forge inspect: 0xd828b11a — the `permits` argument, 2026-10-12; was 0x16997a3b)", () => {
    const fn = AGGREGATOR_FILL_SOLVER_ABI.find((x) => x.type === "function" && x.name === "executeFill")!;
    expect(toFunctionSelector(fn as never)).toBe("0xd828b11a");
  });
  it("executeItemFill / poolFor / poolVenue / POOL_VENUES / MAX_POOL_HOPS selectors match (forge inspect, 2026-10-12)", () => {
    const sel = (name: string) =>
      toFunctionSelector(AGGREGATOR_FILL_SOLVER_ABI.find((x) => x.type === "function" && x.name === name)! as never);
    expect(sel("executeItemFill")).toBe("0x12272841");
    expect(sel("poolFor")).toBe("0xee514e78");
    expect(sel("poolVenue")).toBe("0x04ea3416");
    expect(sel("POOL_VENUES")).toBe("0x76eeee66");
    expect(sel("MAX_POOL_HOPS")).toBe("0xf65b5e71");
  });
  it("sweep / isOperator / SANDBOX selectors match; prime and the router set are gone", () => {
    const fn = (name: string) => AGGREGATOR_FILL_SOLVER_ABI.find((x) => x.type === "function" && x.name === name);
    const sel = (name: string) => toFunctionSelector(fn(name) as never);
    expect(sel("sweep")).toBe("0x62c06767");
    expect(sel("isOperator")).toBe("0x6d70f7ae");
    expect(sel("SANDBOX")).toBe("0x9f9a988b");
    expect(fn("prime")).toBeUndefined();
    expect(fn("isAllowedRouter")).toBeUndefined();
    expect(fn("STANDING_ALLOWANCE")).toBeUndefined();
  });
  it("RouteSandbox.exec selector matches (forge inspect: 0xd27570b5)", () => {
    const fn = ROUTE_SANDBOX_ABI.find((x) => x.type === "function" && x.name === "exec")!;
    expect(toFunctionSelector(fn as never)).toBe("0xd27570b5");
  });

  it("encodes executeFill and round-trips the plan", () => {
    const route = encodeExactInputSingle({
      tokenIn: USDRIF,
      tokenOut: USDT0,
      fee: 500,
      recipient: SOLVER,
      amountIn: 10n ** 18n,
      amountOutMinimum: 990_000n,
    });
    const plan: RoutePlan = {
      router: ROUTER,
      minOut: 990_000n,
      maxPay: 980_000n,
      amountInOffset: route.amountInOffset,
      amountOutOffset: route.amountOutOffset,
      minBumpBps: 2_500n,
      profitRecipient: "0x0000000000000000000000000000000000000000",
      originator: "0x0000000000000000000000000000000000000000",
      originatorPpm: 0,
      data: route.data,
    };
    const data = encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x1234", fillAmount: 5n, plan });
    const { functionName, args } = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data });
    expect(functionName).toBe("executeFill");
    const [, sig, fill, p, takerData] = args as unknown as [unknown, Hex, bigint, RoutePlan, Hex];
    expect(sig).toBe("0x1234");
    expect(fill).toBe(5n);
    expect(p.amountInOffset).toBe(132n);
    expect(p.data).toBe(route.data);
    expect(p.maxPay).toBe(980_000n);
    expect(p.amountOutOffset).toBe(NO_PATCH); // exact-input: nothing to patch on the output side
    expect(p.minBumpBps).toBe(2_500n);
    expect(takerData).toBe("0x");
  });

  it("refuses an offset past the end of the route (the contract's PatchOutOfBounds)", () => {
    const plan: RoutePlan = {
      router: ROUTER,
      minOut: 0n,
      maxPay: 0n,
      amountInOffset: 5n,
      amountOutOffset: NO_PATCH,
      minBumpBps: 0n,
      profitRecipient: SOLVER,
      originator: SOLVER,
      originatorPpm: 0,
      data: "0x1234567890",
    };
    expect(() => encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan })).toThrow(/past the end/);
    expect(() =>
      encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan: { ...plan, amountInOffset: NO_PATCH } }),
    ).not.toThrow();
    // The output-side offset is bounds-checked the same way.
    expect(() =>
      encodeAggregatorExecuteFill({
        order: CANONICAL_ORDER,
        sig: "0x",
        fillAmount: 1n,
        plan: { ...plan, amountInOffset: NO_PATCH, amountOutOffset: 5n },
      }),
    ).toThrow(/amountOutOffset 5 past the end/);
  });
});

describe("Uniswap v3 path", () => {
  it("packs token ‖ fee(3) ‖ token", () => {
    const p = encodeV3Path([USDRIF, USDT0, WRBTC], [500, 3000]);
    expect(size(p)).toBe(20 + 3 + 20 + 3 + 20);
    expect(sliceHex(p, 20, 23)).toBe("0x0001f4");
    expect(sliceHex(p, 43, 46)).toBe("0x000bb8");
    expect(sliceHex(p, 0, 20)).toBe(USDRIF.toLowerCase());
  });
  it("reverses for exact-output", () => {
    expect(encodeV3PathReversed([USDRIF, USDT0, WRBTC], [500, 3000])).toBe(encodeV3Path([WRBTC, USDT0, USDRIF], [3000, 500]));
  });
  it("rejects a mismatched fee list", () => {
    expect(() => encodeV3Path([USDRIF, USDT0], [])).toThrow();
  });
});

describe("SwapRouter02 amountOutOffset", () => {
  it("points at amountOut on the exact-output forms", () => {
    const single = encodeExactOutputSingle({
      tokenIn: USDRIF, tokenOut: USDT0, fee: 500, recipient: SOLVER, amountOut: SENTINEL, amountInMaximum: 7n,
    });
    expect(single.amountOutOffset).toBe(132n);
    expect(word(single.data, single.amountOutOffset)).toBe(SENTINEL);
    const multi = encodeExactOutput({
      tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], recipient: SOLVER, amountOut: SENTINEL, amountInMaximum: 7n,
    });
    expect(multi.amountOutOffset).toBe(100n);
    expect(word(multi.data, multi.amountOutOffset)).toBe(SENTINEL);
    // ...one word before the input-side offset, never the same word.
    expect(multi.amountOutOffset + 32n).toBe(multi.amountInOffset);
  });
  it("is NO_PATCH on the exact-input forms", () => {
    expect(
      encodeExactInputSingle({ tokenIn: USDRIF, tokenOut: USDT0, fee: 500, recipient: SOLVER, amountIn: 1n, amountOutMinimum: 7n })
        .amountOutOffset,
    ).toBe(NO_PATCH);
    expect(() => swapRouter02AmountOutOffset("0x12345678")).toThrow(/unknown selector/);
  });
});

describe("SwapRouter02 amountInOffset", () => {
  const cases: [string, () => { data: Hex; amountInOffset: bigint }, bigint][] = [
    [
      "exactInputSingle",
      () =>
        encodeExactInputSingle({ tokenIn: USDRIF, tokenOut: USDT0, fee: 500, recipient: SOLVER, amountIn: SENTINEL, amountOutMinimum: 7n }),
      132n,
    ],
    [
      "exactInput (2 hops)",
      () =>
        encodeExactInput({ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], recipient: SOLVER, amountIn: SENTINEL, amountOutMinimum: 7n }),
      100n,
    ],
    [
      "exactOutputSingle (amountInMaximum)",
      () =>
        encodeExactOutputSingle({ tokenIn: USDRIF, tokenOut: USDT0, fee: 500, recipient: SOLVER, amountOut: 7n, amountInMaximum: SENTINEL }),
      164n,
    ],
    [
      "exactOutput (amountInMaximum)",
      () =>
        encodeExactOutput({ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], recipient: SOLVER, amountOut: 7n, amountInMaximum: SENTINEL }),
      132n,
    ],
  ];

  it.each(cases)("%s: the offset points exactly at the input-amount word", (_n, build, expected) => {
    const { data, amountInOffset } = build();
    expect(amountInOffset).toBe(expected);
    expect(word(data, amountInOffset)).toBe(SENTINEL);
    // The words either side are NOT the amount: an off-by-one would land on them.
    expect(word(data, amountInOffset - 32n)).not.toBe(SENTINEL);
    expect(word(data, amountInOffset + 32n)).not.toBe(SENTINEL);
  });

  it.each(cases)("%s: patching the word rewrites only the amount", (_n, build) => {
    const { data, amountInOffset } = build();
    const patched = patchAmountIn(data, amountInOffset, 42n);
    expect(size(patched)).toBe(size(data));
    const a = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data });
    const b = decodeFunctionData({ abi: SWAP_ROUTER02_ABI, data: patched });
    expect(b.functionName).toBe(a.functionName);
    const pa = (a.args as readonly Record<string, unknown>[])[0]!;
    const pb = (b.args as readonly Record<string, unknown>[])[0]!;
    const key = "amountIn" in pa ? "amountIn" : "amountInMaximum";
    expect(pb[key]).toBe(42n);
    expect({ ...pb, [key]: SENTINEL }).toEqual(pa);
  });

  it("follows a non-canonical tuple offset in the dynamic forms", () => {
    const { data } = encodeExactInput({ tokens: [USDRIF, USDT0], fees: [500], recipient: SOLVER, amountIn: SENTINEL, amountOutMinimum: 0n });
    // Insert a padding word after the head and bump the tuple offset by 32.
    const body = sliceHex(data, 36);
    const shifted = `0x${data.slice(2, 10)}${(0x40).toString(16).padStart(64, "0")}${"00".repeat(32)}${body.slice(2)}` as Hex;
    const off = swapRouter02AmountInOffset(shifted);
    expect(off).toBe(132n);
    expect(word(shifted, off)).toBe(SENTINEL);
  });

  it("rejects an unknown selector", () => {
    expect(() => swapRouter02AmountInOffset("0xdeadbeef")).toThrow(/unknown selector/);
  });

  it("NO_PATCH leaves the calldata alone", () => {
    const { data } = encodeExactInputSingle({ tokenIn: USDRIF, tokenOut: USDT0, fee: 500, recipient: SOLVER, amountIn: 1n, amountOutMinimum: 0n });
    expect(patchAmountIn(data, NO_PATCH, 9n)).toBe(data);
  });
});

describe("Sushi RedSnwapper", () => {
  // Real `api.sushi.com/swap/v7/30` calldata (2026-10-04, block 9,295,925): 100 USDRIF → USDT0,
  // recipient placeholder 0x1111…1111 — the fixture replayed by packages/solvers/test/RouteSandboxFork.t.sol.
  const SNWAP =
    "0x5f3bd1c80000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d631000000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005ea8d5f000000000000000000000000c10ee9031f2a0b84766a86b55a8d90f357910fb400000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001846be92b890000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005f229be0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005101a106b319360001013a15461d8ae0f0fb5fa2629e9da7d66a794a6e3701ffff01d845702af381f0405661747a6a20bde0401a19d601c10ee9031f2a0b84766a86b55a8d90f357910fb400ad7933be450b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as Hex;

  it("decodes snwap and its amountIn sits at the patch offset", () => {
    const d = decodeSnwap(SNWAP);
    expect(d.tokenIn.toLowerCase()).toBe(USDRIF.toLowerCase());
    expect(d.tokenOut.toLowerCase()).toBe(USDT0.toLowerCase());
    expect(d.amountIn).toBe(100n * 10n ** 18n);
    expect(d.amountOutMin).toBe(99_257_695n);
    expect(d.recipient).toBe("0x1111111111111111111111111111111111111111");
    expect(word(SNWAP, SNWAP_AMOUNT_IN_OFFSET)).toBe(d.amountIn);
    const patched = patchAmountIn(SNWAP, SNWAP_AMOUNT_IN_OFFSET, 42n);
    expect(decodeSnwap(patched).amountIn).toBe(42n);
  });
  it("refuses other selectors", () => {
    const route = encodeExactInputSingle({
      tokenIn: USDRIF,
      tokenOut: USDT0,
      fee: 500,
      recipient: SOLVER,
      amountIn: 1n,
      amountOutMinimum: 1n,
    });
    expect(() => decodeSnwap(route.data)).toThrow();
  });

  // Regression (2026-10 beta-filler audit L-1): only byte-canonical calldata decodes.
  const EVIL = "0x000000000000000000000000000000000000dEaD" as Address;
  const base = encodeFunctionData({
    abi: SUSHI_RED_SNWAPPER_ABI,
    functionName: "snwap",
    args: [USDRIF, 10n ** 20n, SOLVER, USDT0, 99_000_000n, EVIL, "0xdeadbeef"],
  });
  it("the live fixture is canonical", () => {
    expect(encodeFunctionData({ abi: SUSHI_RED_SNWAPPER_ABI, functionName: "snwap", args: Object.values(decodeSnwap(SNWAP)) as never })).toBe(SNWAP);
    expect(decodeSnwap(base).executor).toBe(EVIL);
  });
  it("refuses trailing bytes after the ABI body", () => {
    expect(() => decodeSnwap(concat([base, ("0x" + "ff".repeat(100)) as Hex]))).toThrow(/non-canonical/);
    expect(() => decodeSnwap(concat([SNWAP, "0x00"]))).toThrow(/non-canonical/);
  });
  it("refuses a relocated executorData offset", () => {
    const head = base.slice(0, 2 + 8 + 64 * 6);
    const tail = base.slice(2 + 8 + 64 * 7);
    const relocated = (head + (0x100).toString(16).padStart(64, "0") + "00".repeat(32) + tail) as Hex;
    expect(() => decodeSnwap(relocated)).toThrow(/non-canonical/);
  });
  it("refuses dirty address padding", () => {
    const dirty = (base.slice(0, 10) + "ff" + base.slice(12)) as Hex; // high byte of tokenIn's word
    expect(() => decodeSnwap(dirty)).toThrow();
  });
  it("isSnwapExecutorAllowed: empty list = no pin, else exact (case-insensitive) membership", () => {
    expect(isSnwapExecutorAllowed(EVIL, [])).toBe(true);
    expect(isSnwapExecutorAllowed(EVIL, [SOLVER])).toBe(false);
    expect(isSnwapExecutorAllowed(EVIL, [EVIL.toLowerCase() as Address, SOLVER])).toBe(true);
  });
});

describe("direct pool routes", () => {
  it("v3PoolAddress derives the live Rootstock pools for both default venues (checked on chain 30, 2026-10-12)", () => {
    expect(v3PoolAddress(ROOTSTOCK_POOL_VENUES[0]!, WRBTC, USDT0, 3000)).toBe("0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd");
    expect(v3PoolAddress(ROOTSTOCK_POOL_VENUES[1]!, USDT0, WRBTC, 3000)).toBe("0x6d778c369cB386D50f4Ee676c5c264374C52Fd71");
    expect(v3PoolAddress(ROOTSTOCK_POOL_VENUES[0]!, USDRIF, USDT0, 500)).toBe("0xD845702af381f0405661747a6a20bde0401A19d6");
  });

  it("encodePoolRoute lays out amountIn ‖ amountOut ‖ token ‖ fee ‖ venue ‖ token … and round-trips", () => {
    const call = encodePoolRoute({ tokens: [USDRIF, USDT0, WRBTC], fees: [500, 3000], venues: [0, 1], amountIn: 7n, amountOut: 9n });
    expect(size(call.data)).toBe(64 + 20 + 24 * 2);
    expect(word(call.data, 0n)).toBe(7n);
    expect(word(call.data, 32n)).toBe(9n);
    expect(sliceHex(call.data, 64, 84).toLowerCase()).toBe(USDRIF.toLowerCase());
    expect(sliceHex(call.data, 84, 88)).toBe("0x0001f400"); // fee 500, venue 0
    expect(sliceHex(call.data, 108, 112)).toBe("0x000bb801"); // fee 3000, venue 1
    expect(call.amountInOffset).toBe(0n);
    expect(call.amountOutOffset).toBe(32n); // exact-output: the live output word
    const d = decodePoolRoute(call.data);
    expect(d.tokens.map((t) => t.toLowerCase())).toEqual([USDRIF, USDT0, WRBTC].map((t) => t.toLowerCase()));
    expect(d.fees).toEqual([500, 3000]);
    expect(d.venues).toEqual([0, 1]);
    expect(d.amountIn).toBe(7n);
    expect(d.amountOut).toBe(9n);
  });

  it("an exact-input pool route has no output word to patch", () => {
    const call = encodePoolRoute({ tokens: [WRBTC, USDT0], fees: [3000], venues: [0], amountIn: 1n, amountOut: 0n });
    expect(call.amountOutOffset).toBe(NO_PATCH);
  });

  it("refuses what the contract refuses", () => {
    expect(() => encodePoolRoute({ tokens: [WRBTC], fees: [], venues: [], amountIn: 1n, amountOut: 0n })).toThrow();
    const six = [WRBTC, USDT0, WRBTC, USDT0, WRBTC, USDT0];
    expect(() => encodePoolRoute({ tokens: six, fees: [1, 1, 1, 1, 1], venues: [0, 0, 0, 0, 0], amountIn: 1n, amountOut: 0n })).toThrow();
    expect(() => decodePoolRoute(concat([encodePoolRoute({ tokens: [WRBTC, USDT0], fees: [3000], venues: [0], amountIn: 1n, amountOut: 0n }).data, "0x00"]))).toThrow();
    const plan: RoutePlan = {
      router: POOL_ROUTE,
      minOut: 0n,
      maxPay: 0n,
      amountInOffset: 4n, // not a pool-route word
      amountOutOffset: NO_PATCH,
      minBumpBps: 0n,
      profitRecipient: SOLVER,
      originator: SOLVER,
      originatorPpm: 0,
      data: encodePoolRoute({ tokens: [WRBTC, USDT0], fees: [3000], venues: [0], amountIn: 1n, amountOut: 0n }).data,
    };
    expect(() => encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan })).toThrow(/amountInOffset/);
  });
});

describe("executeFill permits", () => {
  const SETTLEMENT = "0x00000000000000000000000000000000000005e7" as Address;
  const permit = {
    token: USDT0,
    spender: SETTLEMENT,
    value: 5n,
    nonce: 0n,
    deadline: 99n,
    v: 27,
    r: ("0x" + "11".repeat(32)) as Hex,
    s: ("0x" + "22".repeat(32)) as Hex,
  };
  const plan: RoutePlan = {
    router: ROUTER,
    minOut: 0n,
    maxPay: 0n,
    amountInOffset: NO_PATCH,
    amountOutOffset: NO_PATCH,
    minBumpBps: 0n,
    profitRecipient: SOLVER,
    originator: SOLVER,
    originatorPpm: 0,
    data: "0x1234",
  };

  it("toSolverPermit binds the owner to the maker and refuses another spender", () => {
    const p = toSolverPermit(CANONICAL_ORDER.maker, permit, SETTLEMENT);
    expect(p.owner).toBe(CANONICAL_ORDER.maker);
    expect(p.value).toBe(5n);
    expect(() => toSolverPermit(CANONICAL_ORDER.maker, { ...permit, spender: SOLVER }, SETTLEMENT)).toThrow(/spender/);
  });

  it("encodes the permits argument and round-trips it", () => {
    const pm = toSolverPermit(CANONICAL_ORDER.maker, permit, SETTLEMENT);
    const data = encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan, permits: [pm] });
    const dec = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data });
    expect(dec.functionName).toBe("executeFill");
    const permits = dec.args![5] as readonly Permit2612[];
    expect(permits.length).toBe(1);
    expect(permits[0]!.owner.toLowerCase()).toBe(CANONICAL_ORDER.maker.toLowerCase());
    expect(permits[0]!.deadline).toBe(99n);
    // No permits = an empty array, not an omitted argument (one entry, no overload).
    const none = decodeFunctionData({ abi: AGGREGATOR_FILL_SOLVER_ABI, data: encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan }) });
    expect((none.args![5] as readonly unknown[]).length).toBe(0);
  });

  it("refuses a permit whose owner is not the maker (the contract reverts PermitOwnerNotMaker)", () => {
    const pm: Permit2612 = { ...toSolverPermit(CANONICAL_ORDER.maker, permit, SETTLEMENT), owner: SOLVER };
    expect(() => encodeAggregatorExecuteFill({ order: CANONICAL_ORDER, sig: "0x", fillAmount: 1n, plan, permits: [pm] })).toThrow(/maker/);
  });
});

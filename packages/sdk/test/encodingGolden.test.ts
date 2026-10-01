import { describe, expect, it } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { getAddress, type Address, type Hex } from "viem";
import {
  FLAG_NEGATE,
  FLAG_TRY,
  ItemPolicy,
  QUOTE_TYPEHASH,
  encodeConditions,
  encodeProportional,
  encodeQuoteTakerData,
  forBalance,
  forLeg,
  forLegPreFund,
  forTotal,
  ocoGroupItem,
  ocoGroupValidator,
  packParams,
  packTiming,
  tickFloorRatio,
  encodeTickFloorData,
  withBlockClock,
  withDeltaVerifyOutputs,
  withFillOnce,
  withItemPolicy,
  withPriorityAuction,
} from "../src";

/**
 * CROSS-LANGUAGE ENCODING VECTORS — the sub-order twin of the golden order hash.
 *
 * `GOLDEN_ORDER_HASH` pins the ORDER encoding: if `packOrder` drifts from
 * `OrderHash`, the hash changes on one side only. It says nothing about the
 * words the settler and the modules INTERPRET after the hash has passed —
 * funding descriptors, proportional markers, timing/params bit-fields, the
 * condition-tree blob, the OCO item blob, the quote takerData head. Each of
 * those is a serialization boundary between this SDK (the encoder) and a
 * contract (the interpreter), and 1inch Aqua's only High of H1 2026 was exactly
 * an encoder/interpreter flag mismatch, fixed in the SDK (reference-bounties.md
 * B4). This file freezes the SDK side of every such boundary in
 * `fixtures/encoding-vectors.json`; `packages/core/test/EncodingGolden.t.sol`
 * reads the SAME file and runs each vector through the real Solidity
 * interpreter. One fixture, two consumers — no duplicated constant to update
 * on two schedules.
 *
 * Regenerate deliberately with `UPDATE_FIXTURES=1 npx vitest run encodingGolden`
 * and commit the diff together with the contract change that motivated it. A
 * regenerated fixture that the Solidity test then rejects is the signal this
 * exists for.
 */

const A = (n: string): Address => getAddress(n);
const WETH = A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2");
const USDC = A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48");
const MODULE = A("0x00000000000000000000000000000000000000d1");
const LEAF_A = A("0x0000000000000000000000000000000000000e01");
const LEAF_B = A("0x0000000000000000000000000000000000000e02");
const LEAF_C = A("0x0000000000000000000000000000000000000e03");
const FILLER = A("0x0000000000000000000000000000000000000b0b");

const hex = (v: bigint): Hex => `0x${v.toString(16).padStart(64, "0")}`;

function build() {
  const timing = packTiming(111, 222, 333);
  return {
    /// Funding descriptors — `Base._forSlice` / `PreFundGuard` / `SettlementLens`.
    descriptors: {
      forLeg_3: hex(forLeg(3)),
      forLegPreFund_1_WETH: hex(forLegPreFund(1, WETH, 0)),
      // Op in bits [244,252) — `PreFundModuleBase._preFundOp` must read 1 (Repay).
      forLegPreFund_1_WETH_op1: hex(forLegPreFund(1, WETH, 1)),
      forBalance_WETH_default: hex(forBalance(WETH)),
      forBalance_WETH_8000: hex(forBalance(WETH, 8_000)),
      forBalance_WETH_1: hex(forBalance(WETH, 1)),
      forTotal_123e18: hex(forTotal(123n * 10n ** 18n)),
      token: WETH,
    },
    /// Proportional markers — `Proportional.isProportional` / `.bps`.
    proportional: {
      bps_2500: hex(encodeProportional(2_500n)),
      bps_10000: hex(encodeProportional(10_000n)),
      bps_1: hex(encodeProportional(1n)),
    },
    /// `Order.timing` — `DutchAuction` accessors (clocks + flag bits + item policy).
    timing: {
      base_111_222_333: hex(timing),
      blockClock: hex(withBlockClock(timing)),
      priorityAuction: hex(withPriorityAuction(timing)),
      deltaVerifyOutputs: hex(withDeltaVerifyOutputs(timing)),
      fillOnce: hex(withFillOnce(timing)),
      itemPolicyCanonical: hex(withItemPolicy(timing, ItemPolicy.CANONICAL)),
      itemPolicyAtomic: hex(withItemPolicy(timing, ItemPolicy.ATOMIC)),
    },
    /// `Order.params` — `DutchAuction.overrideBps/gasBumpBps/gasPriceRef/priorityScale/baselinePriorityFeeWei`.
    params: {
      packed: hex(packParams(25n, 50n, 30_000_000_000n, 7n, 1_000_000_000n)),
      overrideBps: "25",
      gasBumpBps: "50",
      gasPriceRef: "30000000000",
      priorityScale: "7",
      baselinePriorityFeeWei: "1000000000",
    },
    /// Condition tree — `ConditionTreeValidator.validate` on the DNF blob.
    ///   (A) OR (NOT(B) AND TRY(C))
    conditions: {
      blob: encodeConditions([
        [{ target: LEAF_A, data: "0x01" }],
        [
          { target: LEAF_B, data: "0x0202", flags: FLAG_NEGATE },
          { target: LEAF_C, data: "0x", flags: FLAG_TRY },
        ],
      ]),
      leafA: LEAF_A,
      leafB: LEAF_B,
      leafC: LEAF_C,
    },
    /// OCO — `OcoGroupModule.settle` (item blob) and `.validate` (validator blob).
    oco: {
      itemData: ocoGroupItem(MODULE, 77n, 5n, 1_000n, 400n).data,
      itemAmount: "1000",
      minClaim: "400",
      validatorData: ocoGroupValidator(MODULE, 77n).data,
      groupId: "77",
      nonce: "5",
    },
    /// Quote takerData head — `CosignedQuotePriceModule._quote` slices [0:20]/[20:52]/[52:84].
    quote: {
      takerDataHead: encodeQuoteTakerData(
        { orderHash: hex(0n), filler: FILLER, bumpBps: 4_200, deadline: 1_700_000_000n },
        "0x",
      ),
      filler: FILLER,
      bumpBps: "4200",
      deadline: "1700000000",
      typehash: QUOTE_TYPEHASH,
    },
    /// Chainlink tick floor — `ChainlinkTickFloorValidator.validate` on the 4-word blob.
    /// The 18-in / 6-out / 8-dec-feed shape whose 1e18 scale used to truncate to 0.
    tickFloor: {
      data: encodeTickFloorData(FILLER, 3_600n, { dIn: 18, dOut: 6, dFeed: 8, tolBps: 200 }),
      feed: FILLER,
      num: tickFloorRatio({ dIn: 18, dOut: 6, dFeed: 8, tolBps: 200 }).num.toString(),
      den: tickFloorRatio({ dIn: 18, dOut: 6, dFeed: 8, tolBps: 200 }).den.toString(),
    },
    /// Sanity anchor so a wholesale token-address change shows up in the diff.
    tokens: { WETH, USDC },
  };
}

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "encoding-vectors.json");

describe("encoding golden vectors (shared with packages/core/test/EncodingGolden.t.sol)", () => {
  const built = build();
  const serialized = JSON.stringify(built, null, 2) + "\n";

  it("matches the committed fixture byte-for-byte", () => {
    if (process.env.UPDATE_FIXTURES === "1") {
      writeFileSync(FIXTURE, serialized);
    }
    const committed = readFileSync(FIXTURE, "utf8");
    expect(serialized).toBe(committed);
  });

  it("tick floor ratio keeps both halves integral for every decimal shape", () => {
    expect(tickFloorRatio({ dIn: 18, dOut: 6, dFeed: 8, tolBps: 200 })).toEqual({ num: 9_800n, den: 10_000n * 10n ** 20n });
    expect(tickFloorRatio({ dIn: 18, dOut: 18, dFeed: 8, tolBps: 0 })).toEqual({ num: 10_000n, den: 10_000n * 10n ** 8n });
    expect(tickFloorRatio({ dIn: 6, dOut: 18, dFeed: 8, tolBps: 0 })).toEqual({ num: 10_000n * 10n ** 4n, den: 10_000n });
    expect(() => tickFloorRatio({ dIn: 18, dOut: 6, dFeed: 8, tolBps: 10_000 })).toThrow(/any price/);
  });

  it("descriptor bit layout: the three shapes are disjoint on bits 255/254/253", () => {
    const d = built.descriptors;
    expect(BigInt(d.forLeg_3) >> 253n).toBe(4n); // 100
    expect(BigInt(d.forLegPreFund_1_WETH) >> 253n).toBe(5n); // 101
    expect(BigInt(d.forBalance_WETH_default) >> 253n).toBe(6n); // 110
    expect(BigInt(d.forTotal_123e18) >> 253n).toBe(0n); // literal
  });
});

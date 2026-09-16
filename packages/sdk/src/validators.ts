import { encodeAbiParameters, type Address, type Hex } from "viem";
import type { Validator } from "./types";

/**
 * `ChainlinkTickFloorValidator` — the oracle market-limit for TWAP / slow-decay
 * orders. The contract checks
 *
 *     out0 · den  >=  in0 · price(feed) · num
 *
 * and `num / den` folds the feed's decimals, both tokens' decimals and the
 * maker's tolerance into ONE signed rational:
 *
 *     num / den = (10000 − tolBps) / 10000 · 10^(dOut − dIn − dFeed)
 *
 * ⚠ It is a rational, not a 1e18 scale, because the first version's single
 * `scale` integer was `0.0098 → 0` for the most common pair shape (18-decimal
 * input, 6-decimal output, 8-decimal feed: exponent −20) and the gate passed at
 * every price — docs/reference-bounties.md B1, F29 finding 1. This builder puts
 * the power of ten on whichever side keeps both halves integers, and the
 * contract reverts on a zero on either side.
 */
export interface TickFloorParams {
  /** Decimals of `legsIn[0].token`. */
  dIn: number;
  /** Decimals of `legsOut[0].token`. */
  dOut: number;
  /** Decimals the feed reports (`IAggregatorV3.decimals()`). */
  dFeed: number;
  /** Tolerance below the oracle rate the maker accepts, in bps (0 = none). */
  tolBps: number;
}

/** The `(num, den)` pair for {@link TickFloorParams}; both strictly positive. */
export function tickFloorRatio(p: TickFloorParams): { num: bigint; den: bigint } {
  for (const [k, v] of Object.entries(p)) {
    if (!Number.isInteger(v) || v < 0) throw new Error(`tickFloorRatio: ${k} must be a non-negative integer`);
  }
  if (p.tolBps >= 10_000) throw new Error(`tickFloorRatio: tolBps ${p.tolBps} >= 10000 would accept any price`);
  const exp = p.dOut - p.dIn - p.dFeed;
  let num = BigInt(10_000 - p.tolBps);
  let den = 10_000n;
  if (exp >= 0) num *= 10n ** BigInt(exp);
  else den *= 10n ** BigInt(-exp);
  return { num, den };
}

/** `data` for `ChainlinkTickFloorValidator`: `abi.encode(feed, maxStaleness, num, den)`. */
export function encodeTickFloorData(feed: Address, maxStaleness: bigint, p: TickFloorParams): Hex {
  const { num, den } = tickFloorRatio(p);
  return encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
    [feed, maxStaleness, num, den],
  );
}

/** The `Validator` entry to drop into `order.validators`. */
export function tickFloorValidator(
  validator: Address,
  feed: Address,
  maxStaleness: bigint,
  p: TickFloorParams,
): Validator {
  return { target: validator, data: encodeTickFloorData(feed, maxStaleness, p) };
}

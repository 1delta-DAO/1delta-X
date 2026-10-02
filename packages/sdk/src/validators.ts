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

/**
 * The OPTIONAL L2 sequencer check every Chainlink validator accepts as a trailing
 * `(address uptimeFeed, uint256 gracePeriod)` pair after its head words
 * (`ChainlinkRead.checkSequencer`, audit 2026-09-30 PRICE-8): the gate reverts
 * `SequencerDown` while the sequencer is down and `GracePeriodNotOver` within
 * `gracePeriod` seconds of it coming back up. On an L2, ALWAYS sign it — a stale
 * pre-outage price otherwise passes. Omit on an L1 / sequencer-less chain.
 */
export interface SequencerCheck {
  uptimeFeed: Address;
  gracePeriod: bigint;
}

/** Append the sequencer pair after `head` (already ABI-encoded words). */
function withSequencer(head: Hex, seq?: SequencerCheck): Hex {
  if (!seq) return head;
  const tail = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [seq.uptimeFeed, seq.gracePeriod]);
  return (head + tail.slice(2)) as Hex;
}

/** `data` for `ChainlinkTickFloorValidator`: `abi.encode(feed, maxStaleness, num, den[, uptimeFeed, gracePeriod])`. */
export function encodeTickFloorData(feed: Address, maxStaleness: bigint, p: TickFloorParams, seq?: SequencerCheck): Hex {
  const { num, den } = tickFloorRatio(p);
  return withSequencer(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [feed, maxStaleness, num, den],
    ),
    seq,
  );
}

/** The `Validator` entry to drop into `order.validators`. */
export function tickFloorValidator(
  validator: Address,
  feed: Address,
  maxStaleness: bigint,
  p: TickFloorParams,
  seq?: SequencerCheck,
): Validator {
  return { target: validator, data: encodeTickFloorData(feed, maxStaleness, p, seq) };
}

/**
 * `data` for `ChainlinkPriceGteValidator` / `ChainlinkPriceLteValidator`:
 * `abi.encode(feed, threshold, maxStaleness[, uptimeFeed, gracePeriod])` — the
 * three head words, then the optional {@link SequencerCheck}.
 */
export function encodeChainlinkThresholdData(
  feed: Address,
  threshold: bigint,
  maxStaleness: bigint,
  seq?: SequencerCheck,
): Hex {
  return withSequencer(
    encodeAbiParameters([{ type: "address" }, { type: "int256" }, { type: "uint256" }], [feed, threshold, maxStaleness]),
    seq,
  );
}

/** A `Validator` for the Chainlink `price >= threshold` / `price <= threshold` gates. */
export function chainlinkThresholdValidator(
  validator: Address,
  feed: Address,
  threshold: bigint,
  maxStaleness: bigint,
  seq?: SequencerCheck,
): Validator {
  return { target: validator, data: encodeChainlinkThresholdData(feed, threshold, maxStaleness, seq) };
}

/**
 * Filler gates that name CONTRACTS (audit 2026-09-30 VAL-5). A
 * `FillerWhitelistValidator` / `FillerAttestationValidator` checks the fill's
 * `msg.sender`; listing a contract opens the gate to every caller that contract
 * lets through. That is only sound for an operator-GATED solver (e.g. an
 * `AggregatorFillSolver` deployed with an operator set). Pass each listed address
 * and whether it has code (`getCode(addr) !== "0x"`) plus the set of addresses you
 * KNOW to be operator-gated; returns a warning per ungated contract.
 */
export function fillerListingWarnings(
  listed: readonly { address: Address; hasCode: boolean }[],
  knownGated: readonly Address[] = [],
): string[] {
  const gated = new Set(knownGated.map((a) => a.toLowerCase()));
  return listed
    .filter((l) => l.hasCode && !gated.has(l.address.toLowerCase()))
    .map(
      (l) =>
        `${l.address} is a contract that is not known to be operator-gated: listing it admits every caller ` +
        "it forwards (VAL-5)",
    );
}

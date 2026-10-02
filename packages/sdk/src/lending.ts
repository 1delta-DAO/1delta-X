import { type Address, type Hex } from "viem";

import { anchorTotal } from "./pricing";
import { BLOCK_CLOCK_BIT, unpackTiming, type Order } from "./types";

/**
 * Lending-module encoding helpers and preflight warnings that live off-chain.
 */

// ──────────────────── BalanceMode (G-BYTE_MAP-4) ────────────────────

/**
 * A taker module's optional trailing `BalanceMode` word (`DustHandler`):
 * `Exact` (0, also the "absent" reading) or `Full` — withdraw / repay the WHOLE
 * live position.
 */
export enum BalanceMode {
  Exact = 0,
  Full = 1,
}

/** `DustHandler.MODE_TAG`: every non-`Exact` mode word carries it. */
export const BALANCE_MODE_TAG = 0xb0de0000n;

/**
 * The 32-byte word a maker signs to select `mode` — mirror of
 * `DustHandler.encodeMode`: `0` for `Exact`, `0xB0DE0001` for `Full`. NEVER
 * hand-roll `1`: an untagged word reverts `InvalidModeWord`, by design (an
 * untagged `1` used to be the first word of an auth tail read as `Full`).
 */
export function encodeMode(mode: BalanceMode): bigint {
  if (mode !== BalanceMode.Exact && mode !== BalanceMode.Full) throw new Error(`unknown BalanceMode ${mode}`);
  return mode === BalanceMode.Exact ? 0n : BALANCE_MODE_TAG | BigInt(mode);
}

/** Inverse of {@link encodeMode}; throws on any word the modules would reject. */
export function decodeMode(word: bigint): BalanceMode {
  if (word === 0n) return BalanceMode.Exact;
  if (word === (BALANCE_MODE_TAG | 1n)) return BalanceMode.Full;
  throw new Error(`InvalidModeWord: 0x${word.toString(16)}`);
}

// ──────────────────── shared balance ledgers (X-TOKENS-2) ────────────────────

/** Anything that can read `balanceOf` — a viem client wrapper, a fork, a mock. */
export type BalanceReader = (token: Address, holder: Address) => Promise<bigint>;

/**
 * Flag token pairs that look like ONE balance ledger behind two addresses — a
 * double-entry-point token (legacy TUSD, Synthetix `ProxyERC20` + its legacy
 * `Proxy`). `matchSettle` and delta-verify key every structure on the token
 * ADDRESS, so such a pair is credited twice for one arrival (audit 2026-09-30
 * X-TOKENS-2; out of scope for the core, like fee-on-transfer).
 *
 * Heuristic, by design cheap: two distinct tokens are flagged when every probe
 * holder with a NON-ZERO balance in either reads the SAME balance in both, and at
 * least `minAgreeing` such holders agree. Feed it holders that matter for the
 * order set (the makers, the settlement, the executor). A matcher should
 * additionally assert the expected `swept`.
 */
export async function findSharedBalanceLedgers(
  tokens: readonly Address[],
  holders: readonly Address[],
  balanceOf: BalanceReader,
  minAgreeing = 1,
): Promise<[Address, Address][]> {
  const uniq = [...new Map(tokens.map((t) => [t.toLowerCase(), t])).values()];
  const bal = new Map<string, bigint[]>();
  for (const t of uniq) bal.set(t.toLowerCase(), await Promise.all(holders.map((h) => balanceOf(t, h))));
  const out: [Address, Address][] = [];
  for (let i = 0; i < uniq.length; i++) {
    for (let j = i + 1; j < uniq.length; j++) {
      const a = bal.get(uniq[i]!.toLowerCase())!;
      const b = bal.get(uniq[j]!.toLowerCase())!;
      let agree = 0;
      let differ = false;
      for (let k = 0; k < holders.length; k++) {
        if (a[k] === 0n && b[k] === 0n) continue;
        if (a[k] === b[k]) agree++;
        else differ = true;
      }
      if (!differ && agree >= minAgreeing) out.push([uniq[i]!, uniq[j]!]);
    }
  }
  return out;
}

/** The distinct tokens an order set touches (every input and output leg). */
export function orderSetTokens(orders: readonly Order[]): Address[] {
  const seen = new Map<string, Address>();
  for (const o of orders) {
    for (const l of o.legsIn) seen.set(l.token.toLowerCase(), l.token);
    for (const l of o.legsOut) seen.set(l.token.toLowerCase(), l.token);
  }
  return [...seen.values()];
}

// ──────────────────── SETTLE sweep receipts (X-DIFF-CORE-2 follow-up) ────────────────────

/**
 * A filler-side receive check for SETTLE sweeps, whose proceeds the settlement
 * does not guarantee (a SETTLE item is not consideration). Snapshot the filler's
 * balance of every sweep token BEFORE the fill, then call this AFTER: it throws
 * when any token arrived short of the quote. Pair it with an on-chain
 * `minReceived` / post-check in a contract filler; an EOA filler should simulate
 * and compare.
 */
export function assertSweepReceipts(
  before: ReadonlyMap<string, bigint>,
  after: ReadonlyMap<string, bigint>,
  quoted: ReadonlyMap<string, bigint>,
): void {
  for (const [token, want] of quoted) {
    const k = token.toLowerCase();
    const got = (after.get(k) ?? after.get(token) ?? 0n) - (before.get(k) ?? before.get(token) ?? 0n);
    if (got < want) throw new Error(`SETTLE sweep of ${token} delivered ${got} < quoted ${want}`);
  }
}

// ──────────────────── Aave v3 isolation mode (L-AAVE-3) ────────────────────

/** What {@link aaveIsolationWarning} needs to know about the collateral reserve. */
export interface AaveCollateralFacts {
  /** `ReserveConfiguration.getDebtCeiling` of the collateral reserve (0 = not isolated). */
  debtCeiling: bigint;
  /** Pool revision ≥ 3.7 (isolated supplies auto-enable as collateral there). */
  poolAtLeast37: boolean;
  /** The maker already has this reserve enabled as collateral. */
  alreadyCollateral: boolean;
}

/**
 * Supply-then-borrow shapes (Deposit + Borrow, PreFund Supply, Credit Leverage)
 * whose collateral reserve is ISOLATED (`debtCeiling != 0`) on a pre-3.7 Aave v3
 * pool: a supply made by a third party on the maker's behalf is NOT enabled as
 * collateral there, so the borrow in the same fill reverts on health factor. Warn
 * unless the maker already enabled the reserve (audit 2026-09-30 L-AAVE-3).
 */
export function aaveIsolationWarning(f: AaveCollateralFacts): string | null {
  if (f.debtCeiling === 0n || f.poolAtLeast37 || f.alreadyCollateral) return null;
  return (
    "collateral reserve is in isolation mode (debtCeiling != 0) on a pre-3.7 Aave v3 pool and is not yet enabled " +
    "as the maker's collateral: an on-behalf supply will not count, so the borrow reverts — enable it first " +
    "(setUserUseReserveAsCollateral) or sign a different shape"
  );
}

// ──────────────────── Exactly fixed-maturity repay (L-FSE-2) ────────────────────

/**
 * The `totalAmount@160` an `ExactlyPreFundModule` fixed-maturity Repay item must
 * sign for the output leg it references (audit 2026-09-30 L-FSE-2): the leg's
 * SMALLEST full-fill delivery — its auction `end` when it decays (`end != 0`),
 * else its fixed `start`. A full fill then always presents the whole face, and
 * the module clamps an early slice's over-presentation to the live position.
 */
export function exactlyRepayTotalFor(order: Order, legIndex: number): bigint {
  const leg = order.legsOut[legIndex];
  if (!leg) throw new Error(`exactlyRepayTotalFor: no legsOut[${legIndex}]`);
  return leg.end !== 0n ? leg.end : leg.start;
}

/** A tiny helper used by tests and tooling: the 32-byte big-endian word of `x`. */
export function word32(x: bigint): Hex {
  return `0x${x.toString(16).padStart(64, "0")}` as Hex;
}

// ──────────────────── LayerZero fee sponsorship (X-DIFF-REST-3) ────────────────────

/**
 * Refuse to sponsor a `LzOftBridgeOutModule` send unless the order binds the
 * sponsor as its ONLY possible filler, for its whole life, in one shot (audit
 * 2026-09-30 X-DIFF-REST-3). `makeOnBehalf` sees no filler identity, so the
 * module cannot tell the sponsor's own fill from anyone else's: any filler of the
 * sponsored order makes the sponsor pay. Safe only when:
 *   • `exclusiveFiller == sponsor`, a HARD window (`exclusivityOverrideBps == 0`)
 *     that lasts the order's life (`exclusivityEndTime >= expiry`, or the uint32
 *     maximum on a block-clocked order);
 *   • the order is full-fill only (`minFillAnchor == anchor`), so it is one message.
 * Throws with the first violated rule.
 */
export function assertLzSponsorshipSafe(order: Order, sponsor: Address): void {
  if (order.exclusiveFiller.toLowerCase() !== sponsor.toLowerCase()) {
    throw new Error("LZ sponsorship: the order must name the sponsor as exclusiveFiller");
  }
  if (order.exclusivityOverrideBps !== 0n) {
    throw new Error("LZ sponsorship: the exclusivity window must be HARD (exclusivityOverrideBps == 0)");
  }
  const blockClock = ((order.timing >> BLOCK_CLOCK_BIT) & 1n) === 1n;
  const end = BigInt(unpackTiming(order.timing).exclusivityEndTime);
  if (end < (blockClock ? 0xffff_ffffn : order.expiry)) {
    throw new Error("LZ sponsorship: the exclusivity window must cover the order's whole life");
  }
  if (order.minFillAnchor !== anchorTotal(order)) {
    throw new Error("LZ sponsorship: the order must be full-fill only (minFillAnchor == anchor) — fees are per message");
  }
}

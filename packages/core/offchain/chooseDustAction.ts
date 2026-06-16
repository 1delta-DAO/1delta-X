// SPDX-License-Identifier: MIT
//
// Reference implementation of the off-chain order-prep pre-filter that decides a
// repay item's `DustAction` and appends it to the module `data` blob.
//
// Pairs with `packages/core/src/dust/DustHandler.sol`:
//   enum DustAction { SweepToUser = 0, Recycle = 1 }
//
// Division of labour (see the on-chain `DustHandler` doc-comment):
//   • THIS code picks the optimal action from LIVE reserve state, so a recycle is
//     only requested when it is expected to land. It also defaults whole classes
//     of flow to SweepToUser, removing most of the risky surface up front.
//   • The on-chain `disposeResidual` try/catch is the backstop: if state drifts
//     between order prep and execution (cap fills, reserve freezes), a requested
//     recycle reverts and falls back to the sweep floor — funds are never
//     stranded. So picking RESUPPLY here is an OPTIMIZATION, never a correctness
//     requirement.
//
// This module is intentionally stack-agnostic: all chain reads go through the
// injected `ChainReader` so it drops into a viem/ethers/web3 service unchanged.

export enum DustAction {
  SweepToUser = 0,
  Recycle = 1,
}

export enum Protocol {
  AaveV3 = "aave-v3",
  AaveV4 = "aave-v4",
  CompoundV3 = "compound-v3",
  Morpho = "morpho",
}

/** What the user is trying to do — the single biggest input to the decision. */
export enum Flow {
  /** Closing the position / exiting — the user wants funds OUT. Always sweep. */
  FullClose = "full-close",
  /** Migrating to another venue — surplus is incidental, sweep to wallet. */
  Migrate = "migrate",
  /** Levering up / partial rebalance — keeping capital productive is the point. */
  LeverageOrRebalance = "leverage-or-rebalance",
}

/** Reserve snapshot the pre-filter needs. Populate the fields your protocol has. */
export interface ReserveState {
  /** false ⇒ never recycle (deposits disabled / not supported here). */
  isSupplyable: boolean;
  /** Reserve lifecycle flags (Aave). Any true ⇒ sweep. */
  isFrozen?: boolean;
  isPaused?: boolean;
  isActive?: boolean;
  /**
   * Supply-cap headroom in the asset's smallest unit (cap - currentSupply).
   * `undefined` ⇒ no cap (e.g. Morpho, or Comet base). `0n` ⇒ full.
   */
  supplyHeadroom?: bigint;
  /**
   * Comet only: is `asset` the market's BASE token? Recycling a *collateral*
   * asset as dust is rarely intended, so we only recycle the base.
   */
  isCometBase?: boolean;
  /** Aave v3 only: position is in isolation mode and `asset` isn't the isolated collateral. */
  blockedByIsolation?: boolean;
}

export interface ChainReader {
  /** Read the live reserve snapshot for (protocol, market, asset[, reserveId]). */
  getReserveState(args: {
    protocol: Protocol;
    market: string; // pool / spoke / comet / morpho address
    asset: string; // the residual token (loan/base asset of the repay)
    reserveId?: bigint; // Aave v4 spoke reserve id
  }): Promise<ReserveState>;
}

export interface ChooseDustActionArgs {
  protocol: Protocol;
  flow: Flow;
  market: string;
  asset: string;
  reserveId?: bigint;
  /**
   * Conservative estimate of the surplus (buffered ceiling − live debt) in the
   * asset's smallest unit. The real residual depends on the swap fill, so this
   * is an upper-ish bound used only for the headroom margin check.
   */
  estimatedSurplus: bigint;
  /** Fraction [0,1] of cap headroom we refuse to fill. Default 0.10 (=10%). */
  capMarginBps?: number;
}

export interface DustDecision {
  action: DustAction;
  /** Human-readable reason — log this; it explains why recycle was/ wasn't chosen. */
  reason: string;
}

/**
 * Decide the dust action from live reserve state. Returns SweepToUser whenever a
 * recycle is not clearly safe AND beneficial — the safe default.
 */
export async function chooseDustAction(
  reader: ChainReader,
  args: ChooseDustActionArgs,
): Promise<DustDecision> {
  const sweep = (reason: string): DustDecision => ({ action: DustAction.SweepToUser, reason });

  // 1. Flow gate: closing/migrating means the user wants funds out. Don't pay for
  //    a recycle path, and skip all the cap math.
  if (args.flow !== Flow.LeverageOrRebalance) {
    return sweep(`flow=${args.flow}: user wants funds out → sweep`);
  }

  // 2. Live reserve checks.
  const r = await reader.getReserveState({
    protocol: args.protocol,
    market: args.market,
    asset: args.asset,
    reserveId: args.reserveId,
  });

  if (!r.isSupplyable) return sweep("asset not supplyable on this market/spoke");
  if (r.isActive === false) return sweep("reserve inactive");
  if (r.isFrozen) return sweep("reserve frozen");
  if (r.isPaused) return sweep("reserve paused");
  if (r.blockedByIsolation) return sweep("isolation mode blocks this collateral");
  if (args.protocol === Protocol.CompoundV3 && r.isCometBase === false) {
    return sweep("comet: asset is collateral, not base → sweep");
  }

  // 3. Supply-cap headroom with a margin (skip when there is no cap).
  if (r.supplyHeadroom !== undefined) {
    const marginBps = BigInt(args.capMarginBps ?? 1000); // default 10%
    const usableHeadroom = (r.supplyHeadroom * (10000n - marginBps)) / 10000n;
    if (args.estimatedSurplus > usableHeadroom) {
      return sweep(
        `supply-cap headroom too tight: surplus ${args.estimatedSurplus} > usable ${usableHeadroom}`,
      );
    }
  }

  return { action: DustAction.Recycle, reason: "recycle: reserve open, headroom ok" };
}

// ─────────────────────────── data encoding ───────────────────────────
//
// The action is an OPTIONAL trailing field appended to a module's existing `data`
// blob. Omit it entirely for SweepToUser (backward-compatible). `readAction`
// on-chain reads a single 32-byte word past the module's fixed base layout.

/** abi.encode pads a uint8 to a right-aligned 32-byte word. */
function actionWord(action: DustAction): string {
  return action.toString(16).padStart(64, "0");
}

/**
 * Append the dust action to an already-encoded repay `data` blob.
 * `baseDataHex` is `abi.encode(...)` of the module's base tuple (no 0x stripping
 * needed — handled here). For SweepToUser, returns the base unchanged.
 */
export function appendDustAction(baseDataHex: string, action: DustAction): string {
  if (action === DustAction.SweepToUser) return baseDataHex;
  const base = baseDataHex.startsWith("0x") ? baseDataHex.slice(2) : baseDataHex;
  return "0x" + base + actionWord(action);
}

// ─────────────────────────── usage sketch ───────────────────────────
//
//   const decision = await chooseDustAction(reader, {
//     protocol: Protocol.AaveV3,
//     flow: Flow.LeverageOrRebalance,
//     market: pool,
//     asset: USDC,
//     estimatedSurplus: bufferedAmount - liveDebt,
//   });
//
//   // base = abi.encode(pool, asset, rateMode, debtToken)  (your existing encoder)
//   const data = appendDustAction(base, decision.action);
//
// FINAL GATE: simulate the full settlement (eth_call / Tenderly) at current state.
// If the sim reverts on the recycle, downgrade to SweepToUser and re-encode — the
// per-protocol checks above are the fast pre-filter; the sim catches the long
// tail (LTV-0, exotic reserve configs) without re-implementing each protocol's
// revert logic. The on-chain try/catch still backstops drift after the sim.

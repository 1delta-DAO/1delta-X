/**
 * The PURE half of the deployment config — parsing `VITE_DEPLOYMENTS` and
 * choosing a market's filler — with no `import.meta.env`, so node scripts (the
 * filler-worker app-shape e2e) can import it. `deployments.ts` re-exports all of it
 * and adds the build-time-configured lookup.
 */
import type { Deployment } from "@1delta-x/sdk";
import { getAddress, isAddress, zeroAddress, type Address } from "viem";

/**
 * Where UniversalSettlement lives, per chain.
 *
 * An order signature is bound to the EIP-712 domain — `chainId` plus the
 * Settlement address — so this is not cosmetic: sign against the wrong
 * `verifyingContract` and the signature is valid, verifiable, and useless.
 * Nothing is deployed yet, so addresses come from one environment variable and
 * default to unset rather than to a plausible-looking constant.
 *
 *   VITE_DEPLOYMENTS='{"31":{"settlement":"0x…","permit3":"0x…","lens":"0x…","solver":"0x…"}}'
 *
 * `solver` may be the zero address (or omitted): orders then sign PLAIN pull
 * delivery with no named filler, open to any filler.
 *
 * Optionally, `"marketSolvers": {"<marketId>": "0x…" | "pull"}` overrides that
 * per market:
 *  - an address names a different delta-verify `exclusiveFiller` — e.g. the
 *    `UsdrifInventorySolver` for the inventory-served `rsk-30-usdrif-usd0`
 *    market (audit 2026-09-30 APP-RIF4);
 *  - the literal `"pull"` means orders on that market use plain pull delivery
 *    and name NO filler (`exclusiveFiller = 0`, no delta-verify bit), so a plain
 *    EOA filler bot can fill them with `Settlement.fillUpTo` — an EOA cannot run
 *    the fill callback a delta-verify order needs.
 * Markets without an entry use `solver`. See {@link solverForMarket}.
 *
 *   VITE_DEPLOYMENTS='{"30":{"settlement":"0x…","permit3":"0x…","lens":"0x…",
 *     "solver":"0x0000000000000000000000000000000000000000",
 *     "marketSolvers":{"rsk-30-usdrif-usd0":"pull"}}}'
 */
export interface DeploymentConfig extends Deployment {
  /** Read-only companion — `getOrderRelevantStates` is the orderbook's Layer 2. */
  lens: Address;
  /**
   * The operator-gated `AggregatorFillSolver` this app's orders name as their
   * `exclusiveFiller`, or the zero address when none is configured. Direct
   * (delta-verify) delivery is only safe when a trusted filler runs the fill
   * callback, so the settler fills such an order for its named filler ONLY —
   * see `buildOrder`, which falls back to plain delivery without one.
   */
  solver: Address;
  /**
   * Per-market overrides of {@link solver} (market id → filler). Empty when none.
   * The zero address here is the parsed form of `"pull"`: plain pull delivery,
   * no named filler. (A literal zero ADDRESS in the raw config is still rejected
   * — pull mode has to be asked for by name, never reached by a typo.)
   */
  marketSolvers: Record<string, Address>;
}

/** The `marketSolvers` value that selects plain pull delivery with no named filler. */
export const PULL_MODE = "pull";

type RawDeployments = Record<
  string,
  Partial<Record<"settlement" | "permit3" | "lens" | "solver" | "marketSolvers", unknown>>
>;

/**
 * Parse `VITE_DEPLOYMENTS` into per-chain deployments, VALIDATING every
 * address (G-TS_SIGN-14).
 *
 * An entry is the target of real approvals and the `verifyingContract` of
 * real signatures, so a malformed one is dropped whole — degraded to "not
 * deployed", which the UI has an honest state for — rather than half-used.
 * `settlement` and `permit3` are required and non-zero: a deployment whose
 * Permit3 is unknown has nothing a maker could correctly approve. Exposed for
 * tests; the app additionally checks `Settlement.PERMIT3()` on-chain before
 * offering any approval (`lib/chain.ts`).
 */
export function parseDeployments(raw: string | undefined): Record<number, DeploymentConfig> {
  if (!raw) return {};
  let parsed: RawDeployments;
  try {
    parsed = JSON.parse(raw) as RawDeployments;
  } catch {
    // A malformed override must not take the app down.
    console.warn("VITE_DEPLOYMENTS is not valid JSON — ignoring");
    return {};
  }
  const out: Record<number, DeploymentConfig> = {};
  if (!parsed || typeof parsed !== "object") return out;
  for (const [key, entry] of Object.entries(parsed)) {
    const chainId = Number(key);
    if (!Number.isSafeInteger(chainId) || chainId <= 0 || !entry || typeof entry !== "object") continue;
    const addr = (v: unknown, required: boolean): Address | null | undefined => {
      if (v === undefined || v === null || v === "") return required ? null : zeroAddress;
      if (typeof v !== "string" || !isAddress(v, { strict: false })) return null;
      return getAddress(v);
    };
    const settlement = addr(entry.settlement, true);
    const permit3 = addr(entry.permit3, true);
    const lens = addr(entry.lens, false);
    const solver = addr(entry.solver, false);
    if (!settlement || !permit3 || !lens || !solver || settlement === zeroAddress || permit3 === zeroAddress) {
      console.warn(`VITE_DEPLOYMENTS[${key}] has a missing or invalid address — treating chain ${key} as not deployed`);
      continue;
    }
    // Per-market solver overrides: every entry must be a valid non-zero address
    // or the literal "pull", or the whole deployment is dropped (a typo must not
    // silently fall back). "pull" is stored as the zero address, which
    // `buildOrder` signs as plain pull delivery open to any filler.
    const marketSolvers: Record<string, Address> = {};
    let badMarket = false;
    if (entry.marketSolvers !== undefined) {
      if (!entry.marketSolvers || typeof entry.marketSolvers !== "object") badMarket = true;
      else {
        for (const [m, v] of Object.entries(entry.marketSolvers as Record<string, unknown>)) {
          if (v === PULL_MODE) {
            marketSolvers[m] = zeroAddress;
            continue;
          }
          const a = addr(v, true);
          if (!a || a === zeroAddress) badMarket = true;
          else marketSolvers[m] = a;
        }
      }
    }
    if (badMarket) {
      console.warn(`VITE_DEPLOYMENTS[${key}].marketSolvers has an invalid entry — treating chain ${key} as not deployed`);
      continue;
    }
    out[chainId] = { chainId, settlement, permit3, lens, solver, marketSolvers };
  }
  return out;
}

/**
 * The delta-verify `exclusiveFiller` for orders on `marketId`: the market's
 * override when configured (e.g. an inventory solver for an inventory-served
 * market), else the deployment-wide {@link DeploymentConfig.solver}. `undefined`
 * without a deployment.
 *
 * The ZERO address means plain pull delivery with no named filler — a market
 * configured as `"pull"`, or a deployment whose `solver` is zero. `buildOrder`
 * then sets neither the delta-verify bit nor an `exclusiveFiller`. A `"pull"`
 * override wins over a non-zero deployment-wide `solver`.
 */
export function solverForMarket(deployment: DeploymentConfig | null, marketId: string): Address | undefined {
  if (!deployment) return undefined;
  return Object.prototype.hasOwnProperty.call(deployment.marketSolvers, marketId)
    ? deployment.marketSolvers[marketId]
    : deployment.solver;
}

/** True when orders on `marketId` sign plain pull delivery with no named filler. */
export function isPullMarket(deployment: DeploymentConfig | null, marketId: string): boolean {
  return solverForMarket(deployment, marketId) === zeroAddress;
}

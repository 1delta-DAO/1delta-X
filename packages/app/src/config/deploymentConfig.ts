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
 *
 * PULL-MARKET EXCLUSIVITY WINDOW (UniswapX-style, B13) — OPT-IN, OFF BY DEFAULT.
 * With a window configured, a pull market with a non-zero deployment `solver`
 * signs `exclusiveFiller = solver` with a SOFT window: for `seconds` after signing
 * only the solver fills at the signed price; any other filler may fill inside the
 * window by paying the maker `overrideBps` more (`OrderGates.exclusivityOverride`),
 * and after it the order is open to everyone until it expires. Optional keys:
 *
 *   "pullExclusivity":   {"seconds": 60, "overrideBps": 5}             deployment-wide
 *   "marketExclusivity": {"<marketId>": {"seconds": 60}}                 per market
 *
 * Each object takes only those two keys, both optional (a missing one inherits:
 * market ← deployment ← {@link DEFAULT_PULL_EXCLUSIVITY} = 0 s / 5 bps). `seconds`
 * is an integer in [0, 600]; `0` (the default) means no window — the order names
 * no filler and is open from the start. 60 s ≈ 2 Rootstock blocks is the UniswapX
 * "~2 blocks" practice if a deployment opts in. `overrideBps` is an integer in
 * [1, 10 000]: a window is always SOFT. Anything else drops the deployment.
 *
 * WHY OFF BY DEFAULT (2026-10-06, "no additional gas on fills"): measured on the
 * plain SELL fill, naming one filler with a window costs +509 gas per fill (+245
 * exec, +264 calldata) over `exclusiveFiller = 0`; a FILLER_SET covering both our
 * solver contract and the inventory EOA costs +1,229..+1,304 and is not expressible
 * in the SDK (its `curve` is typed curve points). And a single-solver window makes
 * our own inventory EOA (it fills via `fillUpTo` as itself) an OUTSIDER that must
 * pay the premium or wait the window out.
 *
 * DIRECT (delta-verify) markets are unaffected: the core fills a bit-104 order for
 * its named filler ONLY, for its WHOLE life (Core `_snapshotOutRecipients`, ledger
 * F30 — a balance delta cannot tell this fill's delivery from an unrelated inflow,
 * so the callback runner must be the maker's choice), so there is no window to open
 * and no outsider to charge. That is the trade: direct saves the solver ~35k gas per
 * fill; pull + window lets anyone fill after ~2 blocks.
 *
 * FILL GAS (optional, `"fillGas": {"direct": 352000, "pull": 370000}`): the gas one
 * filler fill is priced at, which sizes the market floor of small tickets
 * (lib/marketFloor.ts). Defaults = `DEFAULT_FILL_GAS`: what the filler PRICES a fill at
 * before it has learned a receipt ratio (`eth_estimateGas` × 0.88). Each key optional,
 * an integer in [21 000, 2 000 000]; anything else drops the deployment.
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
  /** Deployment-wide pull-market window (defaults filled in). */
  pullExclusivity: ExclusivityWindow;
  /** Per-market windows, fully resolved against {@link pullExclusivity}. Empty when none. */
  marketExclusivity: Record<string, ExclusivityWindow>;
  /** Net gas per filler fill, by delivery — sizes small tickets' market floor. Defaults when absent. */
  fillGas?: FillGas;
}

/** Net gas of one filler fill, per delivery (lib/marketFloor.ts). */
export interface FillGas {
  direct: number;
  pull: number;
}

/**
 * The beta filler's `eth_estimateGas` for one fill, per delivery: the top of the
 * production e2e range (2026-10-07: direct 363k–385k, pull 386k–404k), rounded up.
 */
export const FILLER_FILL_GAS_ESTIMATE: Readonly<FillGas> = Object.freeze({ direct: 400_000, pull: 420_000 });
/**
 * The filler's receipt/estimate gas ratio before it has learned one, ppm — MUST equal
 * `DEFAULT_GAS_RECEIPT_RATIO` in packages/filler-worker/wrangler.toml (and the
 * beta-filler config default); pinned by test/crossComponent.audit.test.ts (APP-FLOOR-2).
 * The filler prices a fill at estimate × r, r = max(receipt / estimate) over its last
 * 20 receipts of that shape, clamped to [0.6, 1.0] (packages/beta-filler gasRatio.ts).
 */
export const FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM = 880_000;

/** ⌈estimate × ratio⌉, rounded up to a thousand gas (integer arithmetic, no float noise). */
const pricedFillGas = (estimate: number) => Math.ceil((estimate * FILLER_DEFAULT_GAS_RECEIPT_RATIO_PPM) / 1_000_000 / 1_000) * 1_000;

/**
 * The gas the filler PRICES a fill at before it has any receipt: its estimate × the
 * default ratio — direct 400k × 0.88 = 352k, pull 420k × 0.88 = 369.6k → 370k.
 * Conservative by construction: the filler's LEARNED ratio only goes lower (receipts
 * run 0.845–0.877 of the estimate on a fresh solver, less once the solver's floors
 * are seeded), so it prices a fill at or below this and fills before the auction
 * reaches the floor. Re-exported by lib/marketFloor.ts.
 */
export const DEFAULT_FILL_GAS: Readonly<FillGas> = Object.freeze({
  direct: pricedFillGas(FILLER_FILL_GAS_ESTIMATE.direct),
  pull: pricedFillGas(FILLER_FILL_GAS_ESTIMATE.pull),
});

function parseFillGas(v: unknown): FillGas | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (Object.keys(o).some((k) => k !== "direct" && k !== "pull")) return null;
  const int = (x: unknown, dflt: number): number | null =>
    x === undefined ? dflt : typeof x === "number" && Number.isSafeInteger(x) && x >= 21_000 && x <= 2_000_000 ? x : null;
  const direct = int(o.direct, DEFAULT_FILL_GAS.direct);
  const pull = int(o.pull, DEFAULT_FILL_GAS.pull);
  return direct === null || pull === null ? null : { direct, pull };
}

/** A pull market's soft exclusivity window, as configured. */
export interface ExclusivityWindow {
  /** Window length in seconds from signing; `0` = no window (open from the start). */
  seconds: number;
  /** What an outsider pays the maker inside the window, bps (1..10 000). */
  overrideBps: number;
}

/**
 * No window (open pull, zero gas change) — the window is opt-in; see "WHY OFF BY
 * DEFAULT" above. The 5 bps is what an opt-in that gives only `seconds` inherits.
 */
export const DEFAULT_PULL_EXCLUSIVITY: ExclusivityWindow = Object.freeze({ seconds: 0, overrideBps: 5 });
/** Upper bound on a configured window: 20 Rootstock blocks. Longer is a typo, not a policy. */
export const MAX_EXCLUSIVITY_SECONDS = 600;

/** What `buildOrder` needs to sign a pull market's soft window. */
export interface PullExclusivity extends ExclusivityWindow {
  /** The `exclusiveFiller` named for the window — the deployment's solver. */
  filler: Address;
}

/**
 * Parse one exclusivity object over `base`. `null` = invalid (the caller drops the
 * deployment). Strict: an object with only `seconds` / `overrideBps`, each a safe
 * integer in range.
 */
function parseWindow(v: unknown, base: ExclusivityWindow): ExclusivityWindow | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (Object.keys(o).some((k) => k !== "seconds" && k !== "overrideBps")) return null;
  const int = (x: unknown, lo: number, hi: number): number | null =>
    typeof x === "number" && Number.isSafeInteger(x) && x >= lo && x <= hi ? x : null;
  const seconds = o.seconds === undefined ? base.seconds : int(o.seconds, 0, MAX_EXCLUSIVITY_SECONDS);
  const overrideBps = o.overrideBps === undefined ? base.overrideBps : int(o.overrideBps, 1, 10_000);
  if (seconds === null || overrideBps === null) return null;
  return { seconds, overrideBps };
}

/** The `marketSolvers` value that selects plain pull delivery with no named filler. */
export const PULL_MODE = "pull";

type RawDeployments = Record<
  string,
  Partial<Record<"settlement" | "permit3" | "lens" | "solver" | "marketSolvers" | "pullExclusivity" | "marketExclusivity" | "fillGas", unknown>>
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
    // Pull-market exclusivity windows: strict, like the addresses — a typo here
    // must not silently sign a different window than the operator asked for.
    const pullExclusivity = entry.pullExclusivity === undefined ? { ...DEFAULT_PULL_EXCLUSIVITY } : parseWindow(entry.pullExclusivity, DEFAULT_PULL_EXCLUSIVITY);
    const marketExclusivity: Record<string, ExclusivityWindow> = {};
    let badWindow = pullExclusivity === null;
    if (pullExclusivity && entry.marketExclusivity !== undefined) {
      const me = entry.marketExclusivity;
      if (!me || typeof me !== "object" || Array.isArray(me)) badWindow = true;
      else {
        for (const [m, v] of Object.entries(me as Record<string, unknown>)) {
          const w = parseWindow(v, pullExclusivity);
          if (!w) badWindow = true;
          else marketExclusivity[m] = w;
        }
      }
    }
    if (badWindow || !pullExclusivity) {
      console.warn(`VITE_DEPLOYMENTS[${key}] has an invalid pullExclusivity / marketExclusivity — treating chain ${key} as not deployed`);
      continue;
    }
    const fillGas = entry.fillGas === undefined ? { ...DEFAULT_FILL_GAS } : parseFillGas(entry.fillGas);
    if (!fillGas) {
      console.warn(`VITE_DEPLOYMENTS[${key}].fillGas is invalid — treating chain ${key} as not deployed`);
      continue;
    }
    out[chainId] = { chainId, settlement, permit3, lens, solver, marketSolvers, pullExclusivity, marketExclusivity, fillGas };
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

/**
 * The soft exclusivity window a PULL market's orders sign: the deployment's
 * `solver` as `exclusiveFiller` for the market's (or the deployment's) window.
 * `undefined` — sign no window, open from the start — when there is no deployment,
 * the market is DIRECT (its delta-verify exclusivity is whole-life by the core,
 * F30), the deployment has no solver to favour, or the window is 0 seconds.
 */
export function exclusivityForMarket(deployment: DeploymentConfig | null, marketId: string): PullExclusivity | undefined {
  if (!deployment || !isPullMarket(deployment, marketId) || deployment.solver === zeroAddress) return undefined;
  const w = Object.prototype.hasOwnProperty.call(deployment.marketExclusivity, marketId)
    ? deployment.marketExclusivity[marketId]!
    : deployment.pullExclusivity;
  return w.seconds > 0 ? { filler: deployment.solver, seconds: w.seconds, overrideBps: w.overrideBps } : undefined;
}

import {
  AGGREGATOR_FILL_SOLVER_ABI,
  ROUTE_SANDBOX_ABI,
  SUSHI_RED_SNWAPPER_ABI,
  decodeAggregatorExecuteFillResult,
  encodeAggregatorExecuteFill,
  toSolverPermit,
  type PoolVenue,
  type Erc2612Permit,
  type Order,
  type Permit2612,
  type RoutePlan,
} from "@1delta-x/sdk";
import { decodeErrorResult, erc20Abi, type Address, type Hex } from "viem";

import { previewBump, previewFill, type Chain } from "./chain";
import type { Config, RouteConfig, RoutePath } from "./config";
import type { FillOutcome } from "./filler";
import { gasShape, GasRatios } from "./gasRatio";
import type { BookEntry } from "./intake";
import { broadcast, Guard } from "./guard";
import { fillOnceBlocker, type Budget, type Verdict } from "./policy";
import type { PricedCandidate, QuoteBook } from "./quote";
import { isAuctionNotStarted, recheckAtMs, scaleUp } from "./recheck";
import {
  activePools,
  discoverPools,
  discoveryKey,
  estimateBest,
  graphEdges,
  graphFromState,
  graphToState,
  pathKey,
  pathVenues,
  selectPaths,
  type GraphPool,
  type PoolGraph,
  type PoolGraphState,
} from "./poolGraph";
import { isRevert, quotePaths, type PathQuote, type QuoteClient } from "./poolQuote";
import {
  buildPoolPlan,
  classifyRoute,
  extraHopGas,
  NO_ROUTE_REASON,
  grossUp,
  haircutBps,
  nativeToTokenAtQuote,
  nativeToUsdToken,
  liveDecayPerBlock,
  pathLabel,
  patchesLiveOutput,
  PERMIT_IN_FILL_GAS,
  planGasEstimate,
  planKind,
  poolRouteGasUnits,
  POOL_HOP_GAS,
  PPM,
  rankingGasUnits,
  rankRoutes,
  routePaths,
  routeProfitable,
  TYPED_CALLBACK_GAS,
  validatePoolPlan,
  venueName,
  type PlanKind,
  type RouteCandidate,
} from "./route";
import { sanitize } from "./sanitize";
import { buildNordsternPlan, fetchNordsternRoute, type NordsternQuote } from "./nordstern";
import { buildSushiPlan, fetchSushiRoute, type SushiQuote } from "./sushi";

/** A validated API route (pull orders only), with the output it is priced at. */
type ApiRaw =
  | { source: "sushi"; quote: SushiQuote; out: bigint; gasUnits: bigint }
  | { source: "nordstern"; quote: NordsternQuote; out: bigint; gasUnits: bigint };

/**
 * One ranked candidate: a local pool path (a pool plan) or a validated API route
 * (Sushi, Nordstern — a sandbox plan). A DIRECT pool candidate also carries `need`,
 * the backward exact-output quote of the owed amount (its `out` is then the
 * equivalent output `owed × received / need`).
 */
type Candidate = RouteCandidate & ({ source: "pool"; path: RoutePath; need?: bigint } | { source: "sushi"; quote: SushiQuote } | { source: "nordstern"; quote: NordsternQuote });

/** QuoterV2 / a venue factory's `factory()` view (not in the SDK's QuoterV2 ABI). */
const FACTORY_VIEW_ABI = [{ type: "function", name: "factory", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] }] as const;

/** One simulated plan: its calldata, what it delivers, and the gas the node measured. */
interface Simulated {
  plan: RoutePlan;
  data: Hex;
  delivered: readonly bigint[];
  gasUsed: bigint;
}

/** Budget key of the route strategy's fill counter (gas lives in the shared {@link Guard}). */
export const ROUTE_FILLS = "route:fills" as Address;

/** RBTC amount used to price RBTC in another token on the pool (0.001 RBTC). */
const NATIVE_REF = 10n ** 15n;
/** How long a native→token conversion is reused, ms. */
const PRICE_TTL_MS = 60_000;
/** After a failed pool discovery, retry no sooner than this (or ROUTE_DISCOVERY_SECONDS when shorter), ms. */
const DISCOVERY_RETRY_MS = 5 * 60_000;
/**
 * Headroom on the simulation's gas measurement for the gas LIMIT we send. The
 * economics (gate + the plan's on-chain floor) are priced at the measurement × r:
 * `estimateGas` is the GROSS gas a tx needs before refunds, above what a receipt
 * charges (e2e 2026-10-06: estimates 363k–404k vs receipts 317k–341k), and r is the
 * receipt/estimate ratio learned per fill shape from our own receipts (gasRatio.ts,
 * 0.88 before any). The cost is a bounded worst case: a tx that burns past
 * r × estimate loses at most `(receipt − r × estimate) × gasPrice` — cents on Rootstock.
 */
const GAS_LIMIT_PCT = 125n;
/** Re-price/re-simulate rounds before giving up on a gas figure that keeps growing. */
const MAX_REPRICE_ROUNDS = 3;

const ceilPct = (v: bigint, pct: bigint) => (v * pct + 99n) / 100n;

/**
 * The ROUTE strategy: one operator EOA calls `AggregatorFillSolver.executeFill`;
 * the solver takes the maker's input, swaps it — on the configured pools ITSELF (a
 * pool plan) or along an API route in its `RouteSandbox` — and delivers the owed
 * output (pull, or direct to the maker for a delta-verify order naming the solver).
 * No inventory: the hot key holds only RBTC for gas. A gasless maker's ERC-2612
 * permit rides in the same `executeFill` (`permits`, ./permit.ts).
 *
 * Per order: backoff check → classify → gas price ≤ MAX_GAS_PRICE_GWEI →
 * previewFill (filler = the SOLVER contract, which is msg.sender to Settlement) →
 * quote: every configured pool path on its venue's QuoterV2 and, for a PULL order,
 * the Sushi / Nordstern API routes (decoded and validated; capped per sweep) → rank
 * by output net of each route's own gas (+ SANDBOX_ROUTE_OVERHEAD_GAS for an API
 * route) → profitability gate at the plan kind's pre-simulation estimate
 * (ROUTE_GAS_ESTIMATE for a sandbox plan, less the overhead for a pool plan, +
 * PERMIT_IN_FILL_GAS when the fill carries a permit: quote × (1 − slippage) ≥ owed +
 * grossUp(gas + min profit), gas in output units, grossed up for the solver's
 * maker/protocol surplus split) → build (a pool plan is decoded and checked against
 * the order) → eth_call executeFill from the operator and decode → **re-price**: priced gas P = max(estimate,
 * simulated) × r (r = the learned receipt/estimate ratio of the fill's shape,
 * gasRatio.ts); if P exceeds what the plan was priced at, REBUILD the plan's floor
 * (minOut / amountInMaximum) at P and RE-SIMULATE → send with gas limit
 * G = max(P, simulated × 1.25) ≤ MAX_ROUTE_GAS. The gas price is the send price
 * (latest block minimumGasPrice × GAS_PRICE_MIN_MULT_BPS, chain.ts).
 */
export class RouteFiller {
  private readonly rc: RouteConfig;
  private sandbox: Address | undefined;
  /** venue index → its QuoterV2, for every venue the solver has AND whose quoter prices that venue's pools (init). */
  private readonly quoters = new Map<number, Address>();
  /** venue index → the solver's (factory, init code hash), for the venues in {@link quoters} — what discovery derives pools with. */
  private readonly venueInfo = new Map<number, PoolVenue>();
  /** The discovered pool graph (./poolGraph.ts), refreshed every ROUTE_DISCOVERY_SECONDS; persisted in the filler state. */
  private graph: PoolGraph | undefined;
  /** No discovery attempt before this (ms): set after a failure. */
  private graphRetryAt = 0;
  private graphRefresh: Promise<void> | undefined;
  private ready = false;
  /** Our share of each fill's surplus after the solver's maker/protocol split, ppm. */
  private keepPpm = PPM;
  private sushiCalls = 0;
  private nordsternCalls = 0;
  private readonly skipped = new Map<Hex, string>();
  private readonly prices = new Map<string, { at: number; perRef: bigint | undefined }>();
  private readonly decimals = new Map<string, number>();

  constructor(
    private readonly cfg: Config,
    private readonly chain: Chain,
    readonly budget: Budget,
    private readonly log: (m: string) => void,
    private readonly onSpend: () => void = () => {},
    readonly guard: Guard = new Guard(cfg.gas),
    readonly gasRatios: GasRatios = new GasRatios(cfg.gas.defaultReceiptRatioPpm),
    /** Quotes this filler issued (./quote.ts): an order signed from one is gated without the haircut. */
    readonly quotes?: QuoteBook,
  ) {
    if (!cfg.route) throw new Error("RouteFiller: no route config (AGGREGATOR_SOLVER unset)");
    this.rc = cfg.route;
    guard.register("route", budget);
  }

  /** Seed the pool graph from the persisted filler state (rediscovered if its inputs changed or it is stale). */
  restoreGraph(s: PoolGraphState | undefined): void {
    this.graph = graphFromState(s);
  }

  /** The pool graph for the persisted filler state. */
  graphState(): PoolGraphState | undefined {
    return this.graph ? graphToState(this.graph) : undefined;
  }

  /** The current graph (status, tests). */
  get poolGraph(): PoolGraph | undefined {
    return this.graph;
  }

  /**
   * Discover / refresh the pool graph when it is missing, stale (ROUTE_DISCOVERY_SECONDS)
   * or built for other inputs — at most one refresh in flight, and after a failure not
   * before {@link DISCOVERY_RETRY_MS}. Never throws: a failed refresh keeps the old
   * graph (and ROUTE_POOLS / ROUTE_PATHS always work). Costs ~2–4 `eth_call`s through
   * Multicall3; INCREMENTAL — pools already found are only re-read.
   */
  async ensureGraph(force = false): Promise<void> {
    const d = this.rc.discovery;
    if (!d.enabled || this.venueInfo.size === 0) return;
    const now = Date.now();
    if (!force && this.graph && now - this.graph.at < d.refreshMs && this.graph.key === this.graphKey()) return;
    if (!force && now < this.graphRetryAt) return;
    if (this.graphRefresh) return this.graphRefresh;
    this.graphRefresh = (async () => {
      try {
        if (!d.multicall) throw new Error("MULTICALL3 is unset: pool discovery needs Multicall3 (set it, or ROUTE_DISCOVERY=0)");
        const r = await discoverPools(this.chain.pub as unknown as QuoteClient, {
          tokens: this.graphTokens(),
          feeTiers: d.feeTiers,
          venues: this.venueInfo,
          multicall: d.multicall,
          ...(this.graph ? { previous: this.graph } : {}),
          now: Date.now(),
        });
        for (const w of r.warnings) this.log(`⚠ [route] pool discovery: ${sanitize(w)}`);
        this.graph = r.graph;
        this.graphRetryAt = 0;
        const active = activePools(r.graph, d.minLiquidity);
        this.log(`[route] pool graph: ${active.length} active / ${r.graph.pools.length} pool(s) over ${this.graphTokens().length} tokens × ${d.feeTiers.length} fees × venues ${[...this.venueInfo.keys()].map(venueName).join("+")} (${r.rpcCalls} eth_call)`);
        this.onSpend(); // persist the graph with the filler state
      } catch (e) {
        this.graphRetryAt = Date.now() + Math.min(DISCOVERY_RETRY_MS, d.refreshMs);
        this.log(`⚠ [route] pool discovery failed (keeping ${this.graph ? "the previous graph" : "ROUTE_POOLS / ROUTE_PATHS only"}): ${sanitize(errorReason(e))}`);
      } finally {
        this.graphRefresh = undefined;
      }
    })();
    return this.graphRefresh;
  }

  /** Every token the graph spans: ROUTE_TOKENS ∪ ROUTE_HUB_TOKENS. */
  private graphTokens(): Address[] {
    const m = new Map<string, Address>();
    for (const t of [...this.rc.routeTokens, ...this.rc.discovery.hubTokens]) m.set(t.toLowerCase(), t);
    return [...m.values()];
  }

  private graphKey(): string {
    return discoveryKey(this.graphTokens(), this.rc.discovery.feeTiers, this.venueInfo);
  }

  /** The graph's routable edges: active discovered pools + ROUTE_POOLS discovery did not see, on quotable venues. */
  private edges(): GraphPool[] {
    if (!this.rc.discovery.enabled) return [];
    return graphEdges(this.graph, this.rc.discovery.minLiquidity, this.rc.pools).filter((p) => this.quoters.has(p.venue));
  }

  /** Every pool path for the pair (configured + enumerated over the graph), quotable venues only. */
  private pathsFor(tokenIn: Address, tokenOut: Address): RoutePath[] {
    return routePaths(tokenIn, tokenOut, this.rc, this.edges()).filter((p) => this.quotable(p));
  }

  /**
   * The paths worth quoting for `amountIn`: pruned to ROUTE_MAX_CANDIDATES by the
   * graph's zero-RPC estimate, less {@link POOL_HOP_GAS} per extra hop priced at
   * `gasPrice` in the output token (also estimated on the graph). ROUTE_PATHS are
   * always quoted; so is every configured pool discovery has no state for.
   */
  private select(paths: readonly RoutePath[], amountIn: bigint, tokenOut: Address, gasPrice: bigint): RoutePath[] {
    const edges = this.edges();
    if (edges.length === 0) return [...paths];
    const hopWei = gasPrice * POOL_HOP_GAS;
    const hopPenalty = estimateBest(edges, this.cfg.wrbtc, tokenOut, hopWei, { maxHops: this.rc.maxHops, hubs: this.rc.discovery.hubTokens }) ?? 0n;
    const forced = paths.filter((p) => this.rc.paths.some((c) => samePathEitherWay(c, p)));
    return selectPaths(paths, edges, amountIn, { k: this.rc.maxCandidates, hopPenalty, forced });
  }

  /** Quote `paths` for `amount` — exact-input forward (`"in"`) or exact-output backward (`"out"`) — batched (./poolQuote.ts). */
  private quoteMany(paths: readonly RoutePath[], amount: bigint, kind: "in" | "out"): Promise<PathQuote[]> {
    return quotePaths(this.chain.pub as unknown as QuoteClient, this.quoters, this.rc.discovery.multicall, paths, amount, kind);
  }

  /**
   * Start-up checks against the deployed solver: it is wired to OUR Settlement, we
   * are an operator, its RouteSandbox exists and is owned by it; and its surplus
   * split (MAKER_SURPLUS_PPM / PROTOCOL_SURPLUS_PPM), which the profit gate grosses
   * up for.
   */
  async init(): Promise<void> {
    if (this.ready) return;
    const { pub, me } = this.chain;
    const s = this.rc.solver;
    const read = <T>(functionName: string, args: unknown[] = []) =>
      pub.readContract({ address: s, abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: functionName as never, args: args as never }) as Promise<T>;
    const code = await pub.getCode({ address: s });
    if (!code || code === "0x") throw new Error(`AGGREGATOR_SOLVER ${s} has no code`);
    const [settlement, gated, isOp, sandbox, makerPpm, protocolPpm] = await Promise.all([
      read<Address>("SETTLEMENT"),
      read<boolean>("GATED"),
      read<boolean>("isOperator", [me]),
      read<Address>("SANDBOX"),
      read<number | bigint>("MAKER_SURPLUS_PPM"),
      read<number | bigint>("PROTOCOL_SURPLUS_PPM"),
    ]);
    if (settlement.toLowerCase() !== this.cfg.settlement.toLowerCase()) {
      throw new Error(`solver ${s} is wired to Settlement ${settlement}, not ${this.cfg.settlement}`);
    }
    if (gated && !isOp) throw new Error(`${me} is not an operator of the gated solver ${s}`);
    // Every AggregatorFillSolver is gated (constructor refuses an empty operator set);
    // an ungated address here is not that contract.
    if (!gated) throw new Error(`solver ${s} reports GATED=false: not a current AggregatorFillSolver`);
    const owner = (await pub.readContract({ address: sandbox, abi: ROUTE_SANDBOX_ABI, functionName: "OWNER" as never })) as Address;
    if (owner.toLowerCase() !== s.toLowerCase()) throw new Error(`sandbox ${sandbox} is owned by ${owner}, not the solver ${s}`);
    const keep = PPM - BigInt(makerPpm) - BigInt(protocolPpm);
    if (keep <= 0n) throw new Error(`solver ${s} surplus split leaves the filler nothing (maker ${makerPpm} + protocol ${protocolPpm} ppm)`);
    this.keepPpm = keep;
    this.sandbox = sandbox;
    await this.initVenues(read);
    this.ready = true;
    // The pool graph (never fatal: a failed discovery keeps ROUTE_POOLS / ROUTE_PATHS).
    await this.ensureGraph();
    if (this.rc.sushi.enabled && this.rc.sushi.executors.length === 0) {
      this.log(`⚠ SUSHI_EXECUTORS is empty: snwap executors are NOT pinned (any executor the API returns is accepted)`);
    }
    if (this.rc.nordstern.enabled && this.rc.nordstern.executors.length === 0) {
      this.log(`⚠ NORDSTERN_EXECUTORS is empty: every Nordstern route will be refused (the pin is strict)`);
    }
    this.log(
      `route strategy: solver ${s} (${gated ? "gated" : "OPEN"}), sandbox ${sandbox}, surplus split maker ${makerPpm} / protocol ${protocolPpm} ppm (we keep ${keep}), ${this.rc.pools.length} pool(s), ${this.rc.paths.length} path(s), discovery ${this.rc.discovery.enabled ? `on (≤${this.rc.maxHops} hops, ${this.rc.maxCandidates} candidates, ${activePools(this.graph, this.rc.discovery.minLiquidity).length} active pools)` : "off"}, venues ${[...this.quoters.keys()].map(venueName).join("+") || "none"}, sushi ${this.rc.sushi.enabled ? `on (${this.rc.sushi.router}, ≤${this.rc.sushi.maxPerSweep}/sweep)` : "off"}, nordstern ${this.rc.nordstern.enabled ? `on (${this.rc.nordstern.router}, ≤${this.rc.nordstern.maxPerSweep}/sweep, haircut ${this.rc.nordstern.haircutBps} bps)` : "off"}`,
    );
  }

  /**
   * The pool venues we can route on: every venue index below the solver's
   * `POOL_VENUES` that has a configured QuoterV2 whose `factory()` IS the solver's
   * `poolVenue(i)` factory — a quote must price the very pool the plan swaps on. A
   * solver without `POOL_VENUES` predates pool plans (and the 6-argument
   * `executeFill`): refused. A venue that fails the check is dropped with a warning,
   * and its configured pools/paths are never quoted.
   */
  private async initVenues(read: <T>(fn: string, args?: unknown[]) => Promise<T>): Promise<void> {
    const { pub } = this.chain;
    const s = this.rc.solver;
    let count: bigint;
    try {
      count = BigInt(await read<bigint | number>("POOL_VENUES"));
    } catch (e) {
      throw new Error(`solver ${s} has no POOL_VENUES: not a pool-route AggregatorFillSolver (${sanitize(errorReason(e))})`);
    }
    this.quoters.clear();
    this.venueInfo.clear();
    this.rc.venueQuoters.forEach((q, i) => void (q === undefined || BigInt(i) >= count ? undefined : this.quoters.set(i, q)));
    for (const [i, quoter] of [...this.quoters]) {
      const [venue, factory] = await Promise.all([
        read<readonly [Address, Hex]>("poolVenue", [BigInt(i)]),
        pub.readContract({ address: quoter, abi: FACTORY_VIEW_ABI, functionName: "factory" }) as Promise<Address>,
      ]);
      if (venue[0].toLowerCase() !== factory.toLowerCase()) {
        this.quoters.delete(i);
        this.log(`⚠ venue ${i} (${venueName(i)}): quoter ${quoter} prices factory ${factory}, the solver swaps on ${venue[0]} — venue disabled`);
      } else {
        this.venueInfo.set(i, { factory: venue[0], initCodeHash: venue[1] });
      }
    }
    const used = new Set([...this.rc.pools.map((p) => p.venue ?? 0), ...this.rc.paths.flatMap((p) => pathVenues(p))]);
    for (const v of used) {
      if (!this.quoters.has(v)) this.log(`⚠ venue ${v} (${venueName(v)}) is ${BigInt(v) >= count ? `not on the solver (POOL_VENUES = ${count})` : "without a quoter"}: its configured pools/paths are ignored`);
    }
  }

  /** Whether a pool path can be quoted — and so routed — on this solver: every hop's venue has a quoter. */
  private quotable(path: RoutePath): boolean {
    return pathVenues(path).every((v) => this.quoters.has(v));
  }

  /** Reset the per-sweep API call counters (Sushi, Nordstern). */
  beginSweep(): void {
    this.sushiCalls = 0;
    this.nordsternCalls = 0;
  }

  /**
   * The API route candidates for a PULL fill of `amountIn`: Sushi and Nordstern, each
   * when enabled, fetched in PARALLEL and validated against this exact request. With
   * `orderHash` (a fill) each source is capped at its MAX_PER_SWEEP calls per sweep and
   * a refusal is logged; `/quote` (no hash) is bounded by its own rate limit and cache.
   * Any miss — cap, HTTP, timeout, shape — is TRANSIENT: it says nothing about the
   * order, so it never earns a backoff strike or a resting verdict.
   */
  private async apiRoutes(
    a: { tokenIn: Address; tokenOut: Address; amountIn: bigint; slippageBps: bigint },
    orderHash?: Hex,
  ): Promise<{ raw: ApiRaw[]; transient: boolean; reasons: string[] }> {
    const { cfg, rc } = this;
    const raw: ApiRaw[] = [];
    const reasons: string[] = [];
    let transient = false;
    const admit = (name: "sushi" | "nordstern", max: number): boolean => {
      if (!orderHash) return true;
      const used = name === "sushi" ? this.sushiCalls : this.nordsternCalls;
      if (used >= max) {
        transient = true;
        this.log(`· [route] ${orderHash} ${name}: per-sweep cap (${max}) reached`);
        return false;
      }
      if (name === "sushi") this.sushiCalls++;
      else this.nordsternCalls++;
      return true;
    };
    const base = { chainId: cfg.chainId, tokenIn: a.tokenIn, tokenOut: a.tokenOut, amountIn: a.amountIn, recipient: rc.solver, slippageBps: a.slippageBps };
    const [sushi, nordstern] = await Promise.all([
      rc.sushi.enabled && admit("sushi", rc.sushi.maxPerSweep) ? fetchSushiRoute(rc.sushi, { ...base, sender: this.sandbox! }) : undefined,
      rc.nordstern.enabled && admit("nordstern", rc.nordstern.maxPerSweep) ? fetchNordsternRoute(rc.nordstern, base) : undefined,
    ]);
    for (const v of [sushi, nordstern]) {
      if (!v) continue;
      if (v.ok) {
        raw.push(v.source === "sushi" ? { source: "sushi", quote: v, out: v.amountOut, gasUnits: v.gasUnits } : { source: "nordstern", quote: v, out: v.amountOut, gasUnits: v.gasUnits });
      } else {
        transient = true;
        reasons.push(v.reason);
        if (orderHash) this.log(`· [route] ${orderHash} ${sanitize(v.reason)}`);
      }
    }
    return { raw, transient, reasons };
  }

  /**
   * Whether this strategy would even look at the order (cheap, no RPC). Until the
   * solver's venues and the pool graph are loaded (the first {@link consider} /
   * {@link init}), a pair is not refused for lacking a path: discovery may find one.
   */
  accepts(entry: BookEntry): boolean {
    return classifyRoute(entry.announce.order, this.rc, { ...this.extras(entry), anyPath: this.rc.discovery.enabled && !this.ready }).ok;
  }

  private extras(entry: BookEntry) {
    return { hasPermitBatch: !!entry.announce.permitBatch, sigless: !!entry.announce.sigless, graph: this.edges() };
  }

  /** A failure before anything was sent: short strategy-scoped backoff (or a skip while the auction has not started). */
  private failed(orderHash: Hex, e: unknown): FillOutcome {
    // The latest block predates the auction's start (Rootstock's ~30 s blocks lag
    // the wall clock the app stamped it with): not a failure — try the next tick.
    if (isAuctionNotStarted(e)) return this.skip(orderHash, "auction not started at the latest block");
    this.guard.onSimFail(orderHash, "route", Date.now());
    const reason = sanitize(errorReason(e));
    this.log(`✗ [route] ${orderHash} ${reason}`);
    return { orderHash, status: "failed", reason, strategy: "route" };
  }

  async consider(entry: BookEntry): Promise<FillOutcome> {
    const { orderHash } = entry;
    const order = entry.announce.order;
    // The pool graph decides which pairs route: refresh it when stale (never throws;
    // a no-op until init) and, before calling a pair unroutable, make sure the
    // solver's venues and the graph are loaded at all (a cold start).
    if (this.rc.discovery.enabled && this.ready) await this.ensureGraph();
    let cls = classifyRoute(order, this.rc, this.extras(entry));
    if (!cls.ok && cls.reason === NO_ROUTE_REASON && this.rc.discovery.enabled && !this.ready) {
      try {
        await this.init();
      } catch (e) {
        return this.failed(orderHash, e);
      }
      cls = classifyRoute(order, this.rc, this.extras(entry));
    }
    if (!cls.ok) return this.skip(orderHash, cls.reason, true);
    const fillable = entry.state?.fillableAmount ?? 0n;
    if (fillable === 0n) return this.skip(orderHash, "nothing fillable", true);
    // The route fills the book's whole `fillable`; for a FILL-ONCE order that must be
    // the whole order (policy.ts `fillOnceBlocker`), else the fill only reverts.
    const once = fillOnceBlocker(order, fillable);
    if (once) return this.skip(orderHash, once, true);
    try {
      const blocked = this.guard.admit(orderHash, "route", Date.now());
      if (blocked) return { ...this.skip(orderHash, blocked.reason), final: blocked.global };
      await this.init();
      await this.ensureGraph();
      // Re-derive the pair's paths over the (possibly just refreshed) graph.
      const paths = this.pathsFor(order.legsIn[0]!.token, order.legsOut[0]!.token);
      return await this.tryFill(orderHash, order, entry.announce.sig, fillable, cls.direct, paths, entry.fillPermit);
    } catch (e) {
      // Nothing was sent (a sent tx is handled inside tryFill).
      return this.failed(orderHash, e);
    }
  }

  /** `rest`: a verdict about the order's terms against the market (see FillOutcome.rest), not our transient state. */
  private skip(orderHash: Hex, reason: string, rest = false, recheckAt?: number): FillOutcome {
    if (this.skipped.get(orderHash) !== reason) {
      if (this.skipped.size > 5_000) this.skipped.clear(); // a long-running host must not grow without bound
      this.skipped.set(orderHash, reason);
      this.log(`· [route] skip ${orderHash}: ${reason}${recheckAt !== undefined ? ` (re-quote at ${new Date(recheckAt).toISOString()})` : ""}`);
    }
    return { orderHash, status: "skipped", reason, strategy: "route", ...(rest ? { rest: true } : {}), ...(rest && recheckAt !== undefined ? { recheckAt } : {}) };
  }

  /** A pre-send refusal that would recur on every sweep: skip AND back off briefly. */
  private skipBackoff(orderHash: Hex, reason: string): FillOutcome {
    this.guard.onSimFail(orderHash, "route", Date.now());
    return this.skip(orderHash, reason);
  }

  private async tryFill(
    orderHash: Hex,
    order: Order,
    sig: Hex,
    fillAmount: bigint,
    direct: boolean,
    paths: RoutePath[],
    fillPermit?: Erc2612Permit,
  ): Promise<FillOutcome> {
    const { cfg, chain, rc } = this;
    const now = Date.now();
    // A direct SELL still decaying patches the LIVE owed into the route (task 05): the
    // decay since the preview stays with us as input residue. That switches the solver
    // to the typed callback, whose extra gas is part of the estimate the plan's floor
    // is priced at (the re-price step below then works from the measured figure).
    //    Only worth it when one block of decay beats the typed path's gas (decided in
    //    step 3, once gas is priced in the output token): small tickets skip it.
    const nowSec = BigInt(Math.floor(now / 1000));
    const liveCandidate = patchesLiveOutput(order, direct, nowSec);
    // Gas is PRICED at estimate × r, r learned per shape from our receipts (gasRatio.ts).
    const shape = gasShape("route", direct ? "direct" : "pull", order.legsIn[0]!.token, order.legsOut[0]!.token, rc.solver);
    const pricedGas = (estimate: bigint) => this.gasRatios.priced(shape, estimate);
    // A gasless maker's order (./permit.ts) carries its ERC-2612 permit IN the fill: the
    // solver runs it first, in the same tx (and the same simulation). Its gas is part of
    // the pre-simulation estimate; the simulation then measures it for real.
    const permits: Permit2612[] = fillPermit ? [toSolverPermit(order.maker, fillPermit, cfg.settlement)] : [];
    const permitGas = permits.length > 0 ? PERMIT_IN_FILL_GAS : 0n;
    const earlyGas = rc.gasEstimate + (liveCandidate ? TYPED_CALLBACK_GAS : 0n) + permitGas;

    // 0. Fills per hour, the gas-price ceiling, and a cheap early look at the shared
    //    gas budget (the binding check is against the final gas LIMIT, step 7).
    if (this.budget.remaining(ROUTE_FILLS, now) < 1n) return this.skip(orderHash, "hourly fill budget exhausted");
    const gasPrice = await chain.pub.getGasPrice();
    const priceErr = this.guard.checkGasPrice(gasPrice);
    if (priceErr) return this.skip(orderHash, priceErr);
    const early = this.guard.gasRoom(gasPrice * earlyGas, now);
    if (early) return this.skip(orderHash, early);

    // 1. Preview as the SOLVER — Settlement's msg.sender, so exclusivity, the
    //    soft-exclusivity premium and the delta-verify gate resolve as they will on-chain
    //    — and at the gas price we SEND with, so a priority / gas-bump order is quoted at
    //    the tick our own tx will see, not the no-bid one. The bump read alongside is
    //    the plan's `minBumpBps`: the solver hands it to `fillWithCallback` as our
    //    on-chain price floor, so a maker-ward move after this point reverts
    //    `BumpTooLow` instead of eroding the margin (task 08).
    const pv = await previewFill(chain, cfg.lens, order, fillAmount, rc.solver, gasPrice);
    const minBumpBps = await previewBump(chain, cfg.lens, order, rc.solver, gasPrice);
    const received = pv.received[0] ?? 0n;
    const owed = pv.paid[0] ?? 0n;
    if (received === 0n || owed === 0n) return this.skip(orderHash, "zero-sized preview", true);

    // 2. Candidates: the pair's pool paths — configured and enumerated over the pool
    //    graph (multi-hop, mixed venues), pruned to ROUTE_MAX_CANDIDATES by the graph's
    //    zero-RPC estimate — quoted on each hop's venue QuoterV2: PULL forward
    //    (exact-input of `received`), DIRECT backward (the input an exact-output of
    //    `owed` needs: what the plan executes), batched through Multicall3. Plus — PULL
    //    orders only, at most SUSHI_MAX_PER_SWEEP / NORDSTERN_MAX_PER_SWEEP API calls per
    //    sweep — a Sushi and a Nordstern API route, decoded and validated against this
    //    fill (Nordstern priced at its haircut figure, never its raw toAmount).
    const tokenOut = order.legsOut[0]!.token;
    // An order signed from a quote WE issued (matched by its terms, ./quote.ts) is gated
    // WITHOUT the haircut: the quote already charged gas + its gas margin, and it would
    // be refused for a cushion the quote never asked for. The plan's on-chain floor
    // (minOut / amountInMaximum at owed + gas) still turns a move before inclusion into
    // a revert, never a loss. Every other order keeps the haircut.
    const quoted = this.quotes?.match(orderHash, order, now, cfg.quote.matchGraceSeconds);
    const slippageBps = quoted ? 0n : haircutBps(rc, order.legsIn[0]!.token, tokenOut);
    const raw: Array<{ source: "pool"; path: RoutePath; out: bigint; gasUnits: bigint; need?: bigint } | ApiRaw> = [];
    // A quote we could not GET (an RPC failure, an API per-sweep cap, an API error)
    // says nothing about the order: a skip then is not a resting verdict.
    let transient = false;
    const poolPaths = direct || rc.okuPull ? this.select(paths.filter((p) => this.quotable(p)), received, tokenOut, gasPrice) : [];
    const pq = await this.quoteMany(poolPaths, direct ? owed : received, direct ? "out" : "in");
    poolPaths.forEach((path, i) => {
      const q = pq[i]!;
      if (!q.ok) {
        if (q.transient) transient = true;
        return;
      }
      const gasUnits = poolRouteGasUnits(path.fees.length, q.gasUnits);
      // Direct: `q.amount` is the input `owed` needs; express it as the output
      // `received` buys at that rate, so the gate and the ranking read one unit.
      if (direct) raw.push({ source: "pool", path, out: (owed * received) / q.amount, gasUnits, need: q.amount });
      else raw.push({ source: "pool", path, out: q.amount, gasUnits });
    });
    if (!direct) {
      const api = await this.apiRoutes({ tokenIn: order.legsIn[0]!.token, tokenOut, amountIn: received, slippageBps }, orderHash);
      raw.push(...api.raw);
      if (api.transient) transient = true;
    }
    if (raw.length === 0) return this.skip(orderHash, "no quote from any source", !transient);

    // 3. Gas (+ min profit) in output units; rank by output net of each route's gas
    //    (an API route's own gas + the sandbox overhead a pool plan does not pay).
    const profitOut = await this.nativeToToken(rc.minProfitWei, tokenOut);
    const gasOutAt = (gasUnits: bigint) => this.nativeToToken(gasPrice * gasUnits, tokenOut);
    let liveOut = false;
    if (liveCandidate) {
      const typedOut = await gasOutAt(pricedGas(TYPED_CALLBACK_GAS));
      liveOut = typedOut !== undefined && liveDecayPerBlock(order, owed, nowSec) > typedOut;
    }
    // The pre-simulation estimate per plan kind (a pool plan skips the sandbox; each
    // extra pool hop adds POOL_HOP_GAS), with the typed path's and the in-fill permit's
    // extra gas — only a floor: the plan is re-priced at the simulated figure below.
    const estimateFor = (c: Pick<Candidate, "source"> & { path?: RoutePath }) =>
      planGasEstimate(rc.gasEstimate, planKind(c)) + (c.source === "pool" && c.path ? extraHopGas(c.path.fees.length) : 0n) + (liveOut ? TYPED_CALLBACK_GAS : 0n) + permitGas;
    const cands: Candidate[] = [];
    const gasOutOf = new Map<Candidate, bigint>();
    for (const r of raw) {
      const routeGasOut = (await this.nativeToToken(gasPrice * rankingGasUnits(planKind(r), r.gasUnits), tokenOut)) ?? 0n;
      const c = { ...r, routeGasOut } as Candidate;
      const g = await gasOutAt(pricedGas(estimateFor(c)));
      if (g === undefined) return this.skip(orderHash, `cannot price RBTC in ${tokenOut} (configure a WRBTC path or RBTC_PRICE_USD)`);
      gasOutOf.set(c, g);
      cands.push(c);
    }
    if (profitOut === undefined) return this.skip(orderHash, `cannot price RBTC in ${tokenOut} (configure a WRBTC path or RBTC_PRICE_USD)`);
    const gasOutFor = (c: Candidate) => gasOutOf.get(c)!;
    const gate = (c: Candidate, g: bigint) =>
      routeProfitable({ quotedOut: c.out, owed, slippageBps, gasOut: g, minProfitOut: profitOut, keepPpm: this.keepPpm });
    const build = (c: Candidate, costOut: bigint): Verdict<{ plan: RoutePlan }> => {
      if (c.source === "sushi") return buildSushiPlan({ quote: c.quote, owed, costOut, profitRecipient: rc.profitRecipient, minBumpBps });
      if (c.source === "nordstern") return buildNordsternPlan({ quote: c.quote, owed, costOut, profitRecipient: rc.profitRecipient, minBumpBps });
      try {
        const { plan } = buildPoolPlan({ direct, path: c.path, received, owed, quotedOut: c.out, costOut, profitRecipient: rc.profitRecipient, minBumpBps, liveOut });
        // Decode what we built and check it against the ORDER before anything is signed.
        return validatePoolPlan(plan, order, { direct, path: c.path, received, owed });
      } catch (e) {
        return { ok: false, reason: (e as Error).message };
      }
    };
    const simulate = async (plan: RoutePlan): Promise<Simulated> => {
      const data = encodeAggregatorExecuteFill({ order, sig, fillAmount, plan, permits });
      const sim = await chain.pub.call({ account: chain.me, to: rc.solver, data, gasPrice });
      if (!sim.data) throw new Error("simulation returned no data");
      const delivered = decodeAggregatorExecuteFillResult(sim.data);
      // No `delivered[0] > owed` check: on the pull path the plan's `maxPay = owed`
      // already reverts any larger payout inside this same simulation.
      if (delivered.length !== order.legsOut.length || delivered[0]! === 0n) throw new Error(`simulation delivered ${delivered.join(",")}`);
      const gasUsed = await chain.pub.estimateGas({ account: chain.me, to: rc.solver, data, gasPrice });
      return { plan, data, delivered, gasUsed };
    };

    // 4. Every candidate that passes the gate at the ASSUMED gas and builds a plan, best first.
    const viable: Array<{ c: Candidate; plan: RoutePlan; margin: bigint }> = [];
    const refusals: string[] = [];
    let buildFailed = false;
    for (const c of rankRoutes(cands)) {
      const g = gate(c, gasOutFor(c));
      if (!g.ok) {
        refusals.push(`${c.source}: ${g.reason}`);
        continue;
      }
      const built = build(c, g.costOut);
      if (!built.ok) {
        buildFailed = true;
        refusals.push(built.reason);
        continue;
      }
      viable.push({ c, plan: built.plan, margin: g.marginOut });
    }
    // When the gate will pass for a DECAYING order, the quotes held (./recheck.ts):
    // the owed output falls / the received input — and so the quote — rises with the
    // order's own clock. Re-quoted then, not a fixed hold later.
    const passesAt = (list: readonly Candidate[], g: (c: Candidate) => bigint) => (pd: bigint, rv: bigint) =>
      list.some((c) => routeProfitable({ quotedOut: scaleUp(c.out, rv, received), owed: pd, slippageBps, gasOut: g(c), minProfitOut: profitOut, keepPpm: this.keepPpm }).ok);
    const recheck = (passes: (pd: bigint, rv: bigint) => boolean) => recheckAtMs(order, minBumpBps, owed, received, nowSec, passes);
    // Every candidate failed the profit gate (or could not be built): the order's price against the pools.
    if (viable.length === 0) {
      return this.skip(orderHash, refusals.join("; "), !transient, transient || buildFailed ? undefined : recheck(passesAt(cands, gasOutFor)));
    }

    // 5. Simulate from the operator and decode — the best viable candidate first,
    //    falling through to the next if its simulation reverts (e.g. an API route
    //    quoted on state that has since moved, failing its own floor, or one that
    //    delivers less than its priced figure, failing the plan's minOut). A gasless
    //    maker's permit runs inside the same simulation.
    let picked: { c: Candidate; sim: Simulated; tag: string; margin: bigint } | undefined;
    let lastReason = "";
    for (const v of viable) {
      const via =
        v.c.source === "pool"
          ? `${pathLabel(v.c.path)} pool plan ${v.c.path.tokens.length - 1} hop [${v.c.path.fees.join(",")}]${v.c.need !== undefined ? ` need ${v.c.need}` : ""}`
          : v.c.source === "nordstern"
            ? `nordstern api ${v.c.quote.apiAmountOut}`
            : "sushi api";
      const tag = `${direct ? (liveOut ? "direct+live" : "direct") : "pull"}${permits.length > 0 ? "+permit" : ""}${quoted ? ` quoted ${quoted.id}` : ""} ${orderHash} in ${received} ${order.legsIn[0]!.token} → owed ${owed} ${tokenOut} (${via}, quote ${v.c.out}, margin ${v.margin})`;
      try {
        picked = { c: v.c, sim: await simulate(v.plan), tag, margin: v.margin };
        break;
      } catch (e) {
        lastReason = `simulation reverted: ${sanitize(errorReason(e))}`;
        this.log(`${cfg.dryRun ? "[dry-run] " : ""}· [route] ${lastReason} — ${tag}`);
      }
    }
    if (!picked) {
      this.guard.onSimFail(orderHash, "route", Date.now());
      if (cfg.dryRun) return { orderHash, status: "skipped", reason: lastReason, strategy: "route" };
      return this.skip(orderHash, lastReason);
    }
    const { c: best, tag } = picked;

    // 6. Re-price at the MEASURED gas. The plan's floor is priced at
    //    P = max(estimate, simulated) × r; if P is above the gas the floor was built
    //    at, rebuild the floor at P and re-simulate (the new floor changes the
    //    calldata, so the gas is measured again) until the priced gas covers its own
    //    measurement. The tx goes out with gas limit G = max(P, simulated × 1.25):
    //    headroom against a moved state, NOT priced into the quote (see GAS_LIMIT_PCT).
    let sim = picked.sim;
    const gasEstimate = estimateFor(best);
    let priced = pricedGas(gasEstimate);
    for (let round = 0; ; round++) {
      const need = pricedGas(sim.gasUsed > gasEstimate ? sim.gasUsed : gasEstimate);
      const limit = ceilPct(sim.gasUsed, GAS_LIMIT_PCT);
      if ((limit > need ? limit : need) > rc.maxGas) {
        return this.skipBackoff(orderHash, `simulated gas ${sim.gasUsed} → limit ${limit > need ? limit : need} above MAX_ROUTE_GAS ${rc.maxGas}`);
      }
      if (need <= priced) break;
      if (round >= MAX_REPRICE_ROUNDS) return this.skipBackoff(orderHash, `gas did not converge (simulated ${sim.gasUsed}, priced ${priced})`);
      priced = need;
      const g2Out = await gasOutAt(priced);
      if (g2Out === undefined) return this.skipBackoff(orderHash, `cannot price gas (simulated gas ${sim.gasUsed}, priced ${priced})`);
      const g2 = gate(best, g2Out);
      // Unprofitable at the MEASURED gas is a verdict about the order's price, not a
      // failure: rest (no strike, no backoff) and, for a decaying order, re-quote
      // when it clears at this gas.
      if (!g2.ok) return this.skip(orderHash, `${g2.reason} (simulated gas ${sim.gasUsed}, priced ${priced})`, true, recheck(passesAt([best], () => g2Out)));
      const rebuilt = build(best, g2.costOut);
      if (!rebuilt.ok) return this.skipBackoff(orderHash, `${rebuilt.reason} (re-priced at gas ${priced})`);
      try {
        sim = await simulate(rebuilt.plan);
      } catch (e) {
        return this.skipBackoff(orderHash, `re-simulation at gas ${priced} reverted: ${sanitize(errorReason(e))}`);
      }
    }
    const measuredLimit = ceilPct(sim.gasUsed, GAS_LIMIT_PCT);
    const gasLimit = measuredLimit > priced ? measuredLimit : priced;

    // 7. The shared hourly gas budget must cover the full gas LIMIT at this price.
    const room = this.guard.gasRoom(gasLimit * gasPrice, Date.now());
    if (room) return this.skip(orderHash, room);

    if (cfg.dryRun) {
      this.log(`[dry-run] [route] would fill ${tag}, gas limit ${gasLimit} (simulated ${sim.gasUsed}, priced ${priced}, delivers ${sim.delivered[0]})`);
      return { orderHash, status: "dry-run", paid: sim.delivered[0], received, strategy: "route" };
    }

    // 8. Send (legacy, gas limit = the priced gas) and return: a later tick reads
    //    the receipt (gas charged even on a revert). One route fill is reserved.
    //    Profit estimate: the quoted surplus over what is owed, our share of it
    //    (output units, before gas).
    const surplus = best.out > owed ? best.out - owed : 0n;
    const r = await broadcast(chain, this.guard, {
      to: rc.solver,
      data: sim.data,
      gas: gasLimit,
      gasPrice,
      kind: "fill",
      strategy: "route",
      orderHash,
      expiry: order.expiry,
      reserve: { budget: "route", token: ROUTE_FILLS, amount: 1n },
      gasMeter: { shape, estimate: sim.gasUsed.toString() },
      info: {
        tag: `${tag} (limit ${gasLimit})`,
        payToken: tokenOut,
        paid: (sim.delivered[0] ?? 0n).toString(),
        recvToken: order.legsIn[0]!.token,
        received: received.toString(),
        profitEst: ((surplus * this.keepPpm) / PPM).toString(),
        profitToken: tokenOut,
      },
    });
    switch (r.kind) {
      case "refused":
        return this.skip(orderHash, r.reason);
      case "failed":
        throw new Error(r.reason);
      case "sent":
        this.onSpend();
        this.log(`→ [route] sent executeFill ${tag} tx ${r.tx} (gas limit ${gasLimit} @ ${gasPrice} wei, simulated ${sim.gasUsed}, priced ${priced} at r ${Number(this.gasRatios.ratioPpm(shape)) / 1e6})`);
        return { orderHash, status: "pending", tx: r.tx, paid: sim.delivered[0], received, strategy: "route", final: true };
    }
  }

  /**
   * The route candidate for an indicative quote (./quote.ts): the best output for
   * `amountIn` over every routable pool path (and, for a PULL ticket, the Sushi and
   * Nordstern API routes — Nordstern at its haircut figure), ranked like a fill — by
   * output net of each route's own gas, sandbox overhead included — and one fill's
   * cost in the output token, priced as the fill gate prices it: estimate × r × the send
   * gas price, + MIN_PROFIT_RBTC, grossed up for the solver's surplus split. With no
   * order to simulate, the estimate is max(the best candidate's plan-kind estimate
   * (route.ts `planGasEstimate`), the largest estimate learned for the shape, else
   * QUOTE_GAS_ESTIMATE_DIRECT / _PULL; a pool path adds POOL_HOP_GAS per extra hop).
   * `source` names the pool path's venue(s) ("oku", "sushi-v3", "oku+sushi-v3") or
   * the API. The pool candidates are the fill's ({@link pathsFor} + {@link select}),
   * quoted FORWARD for both deliveries: the ticket fixes the input (a direct fill then
   * quotes the backward chain of what it owes).
   */
  async quoteRoute(a: { tokenIn: Address; tokenOut: Address; amountIn: bigint; direct: boolean; gasPrice: bigint; permit?: boolean }): Promise<Verdict<{ candidate: PricedCandidate }>> {
    const { cfg, rc } = this;
    await this.init();
    await this.ensureGraph();
    const inList = (t: Address) => rc.routeTokens.some((x) => x.toLowerCase() === t.toLowerCase());
    if (!inList(a.tokenIn) || !inList(a.tokenOut)) return { ok: false, reason: "route: pair outside ROUTE_TOKENS" };
    const paths = this.pathsFor(a.tokenIn, a.tokenOut);
    const api = !a.direct && (rc.sushi.enabled || rc.nordstern.enabled);
    if (paths.length === 0 && !api) return { ok: false, reason: "route: no configured pool/path for the pair" };
    const raw: Array<{ source: "pool" | "sushi" | "nordstern"; out: bigint; gasUnits: bigint; hops?: number; label: string; fees?: number[] }> = [];
    // The API calls run alongside the pool quotes (one round trip, not three).
    const apiP = api
      ? this.apiRoutes({ tokenIn: a.tokenIn, tokenOut: a.tokenOut, amountIn: a.amountIn, slippageBps: haircutBps(rc, a.tokenIn, a.tokenOut) })
      : Promise.resolve({ raw: [] as ApiRaw[], transient: false, reasons: [] as string[] });
    const poolPaths = a.direct || rc.okuPull ? this.select(paths, a.amountIn, a.tokenOut, a.gasPrice) : [];
    const pq = await this.quoteMany(poolPaths, a.amountIn, "in");
    poolPaths.forEach((path, i) => {
      const q = pq[i]!;
      if (q.ok) raw.push({ source: "pool", out: q.amount, gasUnits: poolRouteGasUnits(path.fees.length, q.gasUnits), hops: path.fees.length, label: pathLabel(path), fees: path.fees });
    });
    for (const r of (await apiP).raw) raw.push({ source: r.source, out: r.out, gasUnits: r.gasUnits, label: r.source });
    if (raw.length === 0) return { ok: false, reason: "route: no quote from any source" };
    const cands: Array<RouteCandidate & { hops?: number; label: string }> = [];
    for (const r of raw) cands.push({ ...r, routeGasOut: (await this.nativeToToken(a.gasPrice * rankingGasUnits(planKind(r), r.gasUnits), a.tokenOut)) ?? 0n });
    const best = rankRoutes(cands)[0]!;
    const shape = gasShape("route", a.direct ? "direct" : "pull", a.tokenIn, a.tokenOut, this.rc.solver);
    // Hops beyond the first cost POOL_HOP_GAS each on top of the single-hop figures (the
    // fallback and the plan-kind floor); a LEARNED estimate is the pair's own receipts,
    // whatever route they took, so it is only floored.
    const hopGas = best.source === "pool" ? extraHopGas(best.hops ?? 1) : 0n;
    const learned = this.gasRatios.typicalEstimate(shape);
    const fallback = (a.direct ? cfg.quote.gasEstimateDirect : cfg.quote.gasEstimatePull) + hopGas;
    const base = learned ?? fallback;
    const floor = planGasEstimate(rc.gasEstimate, planKind(best)) + hopGas;
    // A permit-funded order's fill also runs the maker's ERC-2612 permit — the same
    // PERMIT_IN_FILL_GAS the fill gate adds, so quote and fill price the same gas.
    const estimate = (base > floor ? base : floor) + (a.permit ? PERMIT_IN_FILL_GAS : 0n);
    const gasUnits = this.gasRatios.priced(shape, estimate);
    const permitGasUnits = a.permit ? gasUnits - this.gasRatios.priced(shape, estimate - PERMIT_IN_FILL_GAS) : 0n;
    const gasOut = await this.nativeToToken(a.gasPrice * gasUnits, a.tokenOut);
    const profitOut = await this.nativeToToken(rc.minProfitWei, a.tokenOut);
    if (gasOut === undefined || profitOut === undefined) return { ok: false, reason: `route: cannot price RBTC in ${a.tokenOut}` };
    return {
      ok: true,
      candidate: {
        strategy: "route",
        grossOut: best.out,
        costOut: grossUp(gasOut + profitOut, this.keepPpm),
        gasUnits,
        ...(permitGasUnits > 0n ? { permitGasUnits } : {}),
        source: best.label,
        ...(best.hops !== undefined ? { hops: best.hops } : {}),
      },
    };
  }

  /** QuoterV2 exact-input quote along a swap-order path, on its venue's quoter. */
  async quote(path: RoutePath, amountIn: bigint): Promise<bigint> {
    return (await this.quoteWithGas(path, amountIn)).out;
  }

  /**
   * The same quote plus the quoters' summed gas estimate: one `quoteExactInput` for a
   * single-venue path, `quoteExactInputSingle` hop by hop on each hop's venue for a
   * mixed one (./poolQuote.ts). Throws for a venue that is not routable (init) and on
   * a revert / RPC failure.
   */
  async quoteWithGas(path: RoutePath, amountIn: bigint): Promise<{ out: bigint; gasUnits: bigint }> {
    const bad = pathVenues(path).find((v) => !this.quoters.has(v));
    if (bad !== undefined) throw new Error(`venue ${bad} (${venueName(bad)}) is not routable`);
    const [q] = await this.quoteMany([path], amountIn, "in");
    if (!q!.ok) throw new Error(q!.reason);
    return { out: q!.amount, gasUnits: q!.gasUnits };
  }

  /** The input an exact-OUTPUT of `amountOut` along `path` needs (the backward chain), plus the summed gas estimate. */
  async quoteExactOut(path: RoutePath, amountOut: bigint): Promise<{ need: bigint; gasUnits: bigint }> {
    const [q] = await this.quoteMany([path], amountOut, "out");
    if (!q!.ok) throw new Error(q!.reason);
    return { need: q!.amount, gasUnits: q!.gasUnits };
  }

  /**
   * RBTC wei → `token` units, rounded up. WRBTC is 1:1; otherwise a pool quote of
   * {@link NATIVE_REF} along the best WRBTC→token pool path — configured or over the
   * pool graph, pruned like a fill's candidates (cached for a minute) — and, for a $1 token, the configured RBTC_PRICE_USD — the higher of the
   * two when both exist.
   */
  async nativeToToken(wei: bigint, token: Address): Promise<bigint | undefined> {
    if (wei === 0n) return 0n;
    if (token.toLowerCase() === this.cfg.wrbtc.toLowerCase()) return wei;
    await this.init(); // the routable venues (and their quoters) come from the solver
    const key = token.toLowerCase();
    const hit = this.prices.get(key);
    let perRef = hit && Date.now() - hit.at < PRICE_TTL_MS ? hit.perRef : undefined;
    if (perRef === undefined) {
      const paths = this.select(this.pathsFor(this.cfg.wrbtc, token), NATIVE_REF, token, 0n);
      const qs = await this.quoteMany(paths, NATIVE_REF, "in");
      for (const q of qs) if (q.ok && q.amount > (perRef ?? 0n)) perRef = q.amount;
      this.prices.set(key, { at: Date.now(), perRef });
    }
    // Both sources when available, and the HIGHER one: a thin or manipulated pool
    // can only make gas look dearer, never cheaper than the configured RBTC price.
    const fromPool = perRef ? nativeToTokenAtQuote(wei, NATIVE_REF, perRef) : undefined;
    const fromUsd =
      this.rc.rbtcUsd && this.rc.usdTokens.some((t) => t.toLowerCase() === key)
        ? nativeToUsdToken(wei, this.rc.rbtcUsd, await this.tokenDecimals(token))
        : undefined;
    if (fromPool === undefined) return fromUsd;
    if (fromUsd === undefined) return fromPool;
    return fromPool > fromUsd ? fromPool : fromUsd;
  }

  private async tokenDecimals(token: Address): Promise<number> {
    const k = token.toLowerCase();
    let d = this.decimals.get(k);
    if (d === undefined) {
      d = await this.chain.pub.readContract({ address: token, abi: erc20Abi, functionName: "decimals" });
      this.decimals.set(k, d);
    }
    return d;
  }
}

/** Whether `p` is the configured path `c`, in either direction. */
function samePathEitherWay(c: RoutePath, p: RoutePath): boolean {
  const v = pathVenues(c);
  const rev: RoutePath = { tokens: [...c.tokens].reverse(), fees: [...c.fees].reverse(), venues: [...v].reverse() };
  const k = pathKey(p);
  return k === pathKey(c) || k === pathKey(rev);
}

/** Every error ABI a route fill can surface: the solver's, its sandbox's, the executor wrapper, Sushi's. */
const ERROR_ABI = [...AGGREGATOR_FILL_SOLVER_ABI, ...SUSHI_RED_SNWAPPER_ABI];

/** Decode revert data, unwrapping `CallbackFailed(bytes)` / `RouteFailed(bytes)` layers. */
export function decodeRevert(data: Hex, depth = 0): string | undefined {
  if (data.length < 10 || depth > 4) return undefined;
  try {
    const d = decodeErrorResult({ abi: ERROR_ABI, data });
    const args = (d.args ?? []) as readonly unknown[];
    if ((d.errorName === "CallbackFailed" || d.errorName === "RouteFailed") && typeof args[0] === "string") {
      const inner = decodeRevert(args[0] as Hex, depth + 1);
      return `${d.errorName}(${inner ?? args[0]})`;
    }
    return `${d.errorName}(${args.map(String).join(", ")})`;
  } catch {
    return undefined;
  }
}

/** First line of an error, with the solver's (and its route's) custom errors decoded when present. */
export function errorReason(e: unknown): string {
  let cur = e as { cause?: unknown; data?: unknown; message?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (typeof cur.data === "string") {
      const d = decodeRevert(cur.data as Hex);
      if (d) return d;
    }
    cur = cur.cause as typeof cur;
  }
  const msg = e instanceof Error ? e.message : String(e);
  const m = /custom error (0x[0-9a-fA-F]{8}):?\s*([0-9a-fA-F]*)/.exec(msg);
  if (m) {
    const d = decodeRevert(`${m[1]}${m[2]}` as Hex);
    if (d) return d;
  }
  return msg.split("\n")[0]!;
}

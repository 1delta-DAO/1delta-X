import {
  AGGREGATOR_FILL_SOLVER_ABI,
  QUOTER_V2_ABI,
  ROUTE_SANDBOX_ABI,
  SUSHI_RED_SNWAPPER_ABI,
  decodeAggregatorExecuteFillResult,
  encodeAggregatorExecuteFill,
  encodeV3Path,
  type Order,
  type RoutePlan,
} from "@1delta-x/sdk";
import { decodeErrorResult, erc20Abi, type Address, type Hex } from "viem";

import { previewBump, previewFill, type Chain } from "./chain";
import type { Config, RouteConfig, RoutePath } from "./config";
import type { FillOutcome } from "./filler";
import { gasShape, GasRatios } from "./gasRatio";
import type { BookEntry } from "./intake";
import { broadcast, Guard } from "./guard";
import type { Budget, Verdict } from "./policy";
import type { PricedCandidate, QuoteBook } from "./quote";
import { isAuctionNotStarted, recheckAtMs, scaleUp } from "./recheck";
import {
  buildRoutePlan,
  candidatePaths,
  classifyRoute,
  grossUp,
  haircutBps,
  nativeToTokenAtQuote,
  nativeToUsdToken,
  liveDecayPerBlock,
  patchesLiveOutput,
  PPM,
  rankRoutes,
  routeProfitable,
  TYPED_CALLBACK_GAS,
  type RouteCandidate,
} from "./route";
import { sanitize } from "./sanitize";
import { buildSushiPlan, fetchSushiRoute, type SushiQuote } from "./sushi";

/** One ranked candidate: an Oku path (built locally) or a validated Sushi route. */
type Candidate = RouteCandidate & ({ source: "oku"; path: RoutePath } | { source: "sushi"; quote: SushiQuote });

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
 * the solver takes the maker's input, runs the route in its `RouteSandbox` and
 * delivers the owed output (pull, or direct to the maker for a delta-verify order
 * naming the solver). No inventory: the hot key holds only RBTC for gas.
 *
 * Per order: backoff check → classify → gas price ≤ MAX_GAS_PRICE_GWEI →
 * previewFill (filler = the SOLVER contract, which is msg.sender to Settlement) →
 * quote: every configured Oku path on QuoterV2 and, for a PULL order, a Sushi API
 * route (decoded and validated, ./sushi.ts; capped per sweep) → rank by output net
 * of each route's own gas → profitability gate at ROUTE_GAS_ESTIMATE (quote × (1 −
 * slippage) ≥ owed + grossUp(gas + min profit), gas in output units, grossed up
 * for the solver's maker/protocol surplus split) → build → eth_call executeFill
 * from the operator and decode → **re-price**: priced gas P = max(estimate,
 * simulated) × r (r = the learned receipt/estimate ratio of the fill's shape,
 * gasRatio.ts); if P exceeds what the plan was priced at, REBUILD the plan's floor
 * (minOut / amountInMaximum) at P and RE-SIMULATE → send with gas limit
 * G = max(P, simulated × 1.25) ≤ MAX_ROUTE_GAS. The gas price is the send price
 * (latest block minimumGasPrice × GAS_PRICE_MIN_MULT_BPS, chain.ts).
 */
export class RouteFiller {
  private readonly rc: RouteConfig;
  private sandbox: Address | undefined;
  private ready = false;
  /** Our share of each fill's surplus after the solver's maker/protocol split, ppm. */
  private keepPpm = PPM;
  private sushiCalls = 0;
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
    if (this.rc.sushi.enabled && this.rc.sushi.executors.length === 0) {
      this.log(`⚠ SUSHI_EXECUTORS is empty: snwap executors are NOT pinned (any executor the API returns is accepted)`);
    }
    this.log(
      `route strategy: solver ${s} (${gated ? "gated" : "OPEN"}), sandbox ${sandbox}, surplus split maker ${makerPpm} / protocol ${protocolPpm} ppm (we keep ${keep}), ${this.rc.pools.length} pool(s), ${this.rc.paths.length} path(s), sushi ${this.rc.sushi.enabled ? `on (${this.rc.sushi.router}, ≤${this.rc.sushi.maxPerSweep}/sweep)` : "off"}`,
    );
    this.ready = true;
  }

  /** Reset the per-sweep Sushi API call counter. */
  beginSweep(): void {
    this.sushiCalls = 0;
  }

  /** Whether this strategy would even look at the order (cheap, no RPC). */
  accepts(entry: BookEntry): boolean {
    return classifyRoute(entry.announce.order, this.rc, this.extras(entry)).ok;
  }

  private extras(entry: BookEntry) {
    return { hasPermitBatch: !!entry.announce.permitBatch, sigless: !!entry.announce.sigless };
  }

  async consider(entry: BookEntry): Promise<FillOutcome> {
    const { orderHash } = entry;
    const order = entry.announce.order;
    const cls = classifyRoute(order, this.rc, this.extras(entry));
    if (!cls.ok) return this.skip(orderHash, cls.reason, true);
    const fillable = entry.state?.fillableAmount ?? 0n;
    if (fillable === 0n) return this.skip(orderHash, "nothing fillable", true);
    try {
      const blocked = this.guard.admit(orderHash, "route", Date.now());
      if (blocked) return { ...this.skip(orderHash, blocked.reason), final: blocked.global };
      await this.init();
      return await this.tryFill(orderHash, order, entry.announce.sig, fillable, cls.direct, cls.paths);
    } catch (e) {
      // The latest block predates the auction's start (Rootstock's ~30 s blocks lag
      // the wall clock the app stamped it with): not a failure — try the next tick.
      if (isAuctionNotStarted(e)) return this.skip(orderHash, "auction not started at the latest block");
      // Nothing was sent (a sent tx is handled inside tryFill): short strategy-scoped backoff.
      this.guard.onSimFail(orderHash, "route", Date.now());
      const reason = sanitize(errorReason(e));
      this.log(`✗ [route] ${orderHash} ${reason}`);
      return { orderHash, status: "failed", reason, strategy: "route" };
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
    const shape = gasShape("route", direct ? "direct" : "pull", order.legsIn[0]!.token, order.legsOut[0]!.token);
    const pricedGas = (estimate: bigint) => this.gasRatios.priced(shape, estimate);
    const earlyGas = rc.gasEstimate + (liveCandidate ? TYPED_CALLBACK_GAS : 0n);

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

    // 2. Candidates: every configured Oku path (QuoterV2), plus — PULL orders
    //    only, at most SUSHI_MAX_PER_SWEEP API calls per sweep — a Sushi API route,
    //    decoded and validated against this fill.
    const tokenOut = order.legsOut[0]!.token;
    // An order signed from a quote WE issued (matched by its terms, ./quote.ts) is gated
    // WITHOUT the haircut: the quote already charged gas + its gas margin, and it would
    // be refused for a cushion the quote never asked for. The plan's on-chain floor
    // (minOut / amountInMaximum at owed + gas) still turns a move before inclusion into
    // a revert, never a loss. Every other order keeps the haircut.
    const quoted = this.quotes?.match(orderHash, order, now, cfg.quote.matchGraceSeconds);
    const slippageBps = quoted ? 0n : haircutBps(rc, order.legsIn[0]!.token, tokenOut);
    const raw: Array<{ source: "oku"; path: RoutePath; out: bigint; gasUnits: bigint } | { source: "sushi"; quote: SushiQuote; out: bigint; gasUnits: bigint }> = [];
    // A quote we could not GET (an RPC failure, the Sushi per-sweep cap, an API error)
    // says nothing about the order: a skip then is not a resting verdict.
    let transient = false;
    for (const path of direct || rc.okuPull ? paths : []) {
      const q = await this.quoteWithGas(path, received).catch((e: unknown) => {
        if (!isRevert(e)) transient = true;
        return undefined;
      });
      if (q && q.out > 0n) raw.push({ source: "oku", path, out: q.out, gasUnits: q.gasUnits });
    }
    if (!direct && rc.sushi.enabled) {
      if (this.sushiCalls >= rc.sushi.maxPerSweep) {
        transient = true;
        this.log(`· [route] ${orderHash} sushi: per-sweep cap (${rc.sushi.maxPerSweep}) reached`);
      } else {
        this.sushiCalls++;
        const v = await fetchSushiRoute(rc.sushi, {
          chainId: cfg.chainId,
          tokenIn: order.legsIn[0]!.token,
          tokenOut,
          amountIn: received,
          sender: this.sandbox!,
          recipient: rc.solver,
          slippageBps,
        });
        if (v.ok) raw.push({ source: "sushi", quote: v, out: v.amountOut, gasUnits: v.gasUnits });
        else {
          transient = true;
          this.log(`· [route] ${orderHash} ${sanitize(v.reason)}`);
        }
      }
    }
    if (raw.length === 0) return this.skip(orderHash, "no quote from any source", !transient);

    // 3. Gas (+ min profit) in output units; rank by output net of each route's gas.
    const profitOut = await this.nativeToToken(rc.minProfitWei, tokenOut);
    const gasOutAt = (gasUnits: bigint) => this.nativeToToken(gasPrice * gasUnits, tokenOut);
    let liveOut = false;
    if (liveCandidate) {
      const typedOut = await gasOutAt(pricedGas(TYPED_CALLBACK_GAS));
      liveOut = typedOut !== undefined && liveDecayPerBlock(order, owed, nowSec) > typedOut;
    }
    const gasEstimate = rc.gasEstimate + (liveOut ? TYPED_CALLBACK_GAS : 0n);
    const gasOut = await gasOutAt(pricedGas(gasEstimate));
    if (gasOut === undefined || profitOut === undefined) {
      return this.skip(orderHash, `cannot price RBTC in ${tokenOut} (configure a WRBTC path or RBTC_PRICE_USD)`);
    }
    const cands: Candidate[] = [];
    for (const r of raw) {
      const routeGasOut = (await this.nativeToToken(gasPrice * r.gasUnits, tokenOut)) ?? 0n;
      cands.push({ ...r, routeGasOut } as Candidate);
    }
    const gate = (c: Candidate, g: bigint) =>
      routeProfitable({ quotedOut: c.out, owed, slippageBps, gasOut: g, minProfitOut: profitOut, keepPpm: this.keepPpm });
    const build = (c: Candidate, costOut: bigint): Verdict<{ plan: RoutePlan }> => {
      if (c.source === "sushi") return buildSushiPlan({ quote: c.quote, owed, costOut, profitRecipient: rc.profitRecipient, minBumpBps });
      try {
        const { plan } = buildRoutePlan({
          direct,
          path: c.path,
          router: cfg.uniswap.router,
          solver: rc.solver,
          maker: order.maker,
          received,
          owed,
          quotedOut: c.out,
          costOut,
          profitRecipient: rc.profitRecipient,
          minBumpBps,
          liveOut,
        });
        return { ok: true, plan };
      } catch (e) {
        return { ok: false, reason: (e as Error).message };
      }
    };
    const simulate = async (plan: RoutePlan): Promise<Simulated> => {
      const data = encodeAggregatorExecuteFill({ order, sig, fillAmount, plan });
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
      const g = gate(c, gasOut);
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
    const passesAt = (list: readonly Candidate[], g: bigint) => (pd: bigint, rv: bigint) =>
      list.some((c) => routeProfitable({ quotedOut: scaleUp(c.out, rv, received), owed: pd, slippageBps, gasOut: g, minProfitOut: profitOut, keepPpm: this.keepPpm }).ok);
    const recheck = (passes: (pd: bigint, rv: bigint) => boolean) => recheckAtMs(order, minBumpBps, owed, received, nowSec, passes);
    // Every candidate failed the profit gate (or could not be built): the order's price against the pools.
    if (viable.length === 0) {
      return this.skip(orderHash, refusals.join("; "), !transient, transient || buildFailed ? undefined : recheck(passesAt(cands, gasOut)));
    }

    // 5. Simulate from the operator and decode — the best viable candidate first,
    //    falling through to the next if its simulation reverts (e.g. a Sushi route
    //    quoted on state that has since moved, failing snwap's own amountOutMin).
    let picked: { c: Candidate; sim: Simulated; tag: string; margin: bigint } | undefined;
    let lastReason = "";
    for (const v of viable) {
      const via = v.c.source === "oku" ? `oku ${v.c.path.tokens.length - 1} hop` : "sushi";
      const tag = `${direct ? (liveOut ? "direct+live" : "direct") : "pull"}${quoted ? ` quoted ${quoted.id}` : ""} ${orderHash} in ${received} ${order.legsIn[0]!.token} → owed ${owed} ${tokenOut} (${via}, quote ${v.c.out}, margin ${v.margin})`;
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
      if (!g2.ok) return this.skip(orderHash, `${g2.reason} (simulated gas ${sim.gasUsed}, priced ${priced})`, true, recheck(passesAt([best], g2Out)));
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
   * `amountIn` over every configured Oku path (and, for a PULL ticket, a Sushi API
   * route), ranked like a fill — by output net of each route's own gas — and one fill's
   * cost in the output token, priced as the fill gate prices it: estimate × r × the send
   * gas price, + MIN_PROFIT_RBTC, grossed up for the solver's surplus split. With no
   * order to simulate, the estimate is max(ROUTE_GAS_ESTIMATE, the largest estimate
   * learned for the shape, else QUOTE_GAS_ESTIMATE_DIRECT / _PULL).
   */
  async quoteRoute(a: { tokenIn: Address; tokenOut: Address; amountIn: bigint; direct: boolean; gasPrice: bigint }): Promise<Verdict<{ candidate: PricedCandidate }>> {
    const { cfg, rc } = this;
    await this.init();
    const inList = (t: Address) => rc.routeTokens.some((x) => x.toLowerCase() === t.toLowerCase());
    if (!inList(a.tokenIn) || !inList(a.tokenOut)) return { ok: false, reason: "route: pair outside ROUTE_TOKENS" };
    const paths = candidatePaths(a.tokenIn, a.tokenOut, rc);
    const sushi = !a.direct && rc.sushi.enabled;
    if (paths.length === 0 && !sushi) return { ok: false, reason: "route: no configured pool/path for the pair" };
    const raw: Array<{ source: "oku" | "sushi"; out: bigint; gasUnits: bigint; hops?: number }> = [];
    for (const path of a.direct || rc.okuPull ? paths : []) {
      const q = await this.quoteWithGas(path, a.amountIn).catch(() => undefined);
      if (q && q.out > 0n) raw.push({ source: "oku", out: q.out, gasUnits: q.gasUnits, hops: path.tokens.length - 1 });
    }
    if (sushi) {
      const v = await fetchSushiRoute(rc.sushi, {
        chainId: cfg.chainId,
        tokenIn: a.tokenIn,
        tokenOut: a.tokenOut,
        amountIn: a.amountIn,
        sender: this.sandbox!,
        recipient: rc.solver,
        slippageBps: haircutBps(rc, a.tokenIn, a.tokenOut),
      });
      if (v.ok) raw.push({ source: "sushi", out: v.amountOut, gasUnits: v.gasUnits });
    }
    if (raw.length === 0) return { ok: false, reason: "route: no quote from any source" };
    const shape = gasShape("route", a.direct ? "direct" : "pull", a.tokenIn, a.tokenOut);
    const learned = this.gasRatios.typicalEstimate(shape);
    const fallback = a.direct ? cfg.quote.gasEstimateDirect : cfg.quote.gasEstimatePull;
    const base = learned ?? fallback;
    const estimate = base > rc.gasEstimate ? base : rc.gasEstimate;
    const gasUnits = this.gasRatios.priced(shape, estimate);
    const gasOut = await this.nativeToToken(a.gasPrice * gasUnits, a.tokenOut);
    const profitOut = await this.nativeToToken(rc.minProfitWei, a.tokenOut);
    if (gasOut === undefined || profitOut === undefined) return { ok: false, reason: `route: cannot price RBTC in ${a.tokenOut}` };
    const cands: Array<RouteCandidate & { hops?: number; source: "oku" | "sushi" }> = [];
    for (const r of raw) cands.push({ ...r, routeGasOut: (await this.nativeToToken(a.gasPrice * r.gasUnits, a.tokenOut)) ?? 0n });
    const best = rankRoutes(cands)[0]!;
    return {
      ok: true,
      candidate: {
        strategy: "route",
        grossOut: best.out,
        costOut: grossUp(gasOut + profitOut, this.keepPpm),
        gasUnits,
        source: best.source,
        ...(best.hops !== undefined ? { hops: best.hops } : {}),
      },
    };
  }

  /** QuoterV2 exact-input quote along a swap-order path. */
  async quote(path: RoutePath, amountIn: bigint): Promise<bigint> {
    return (await this.quoteWithGas(path, amountIn)).out;
  }

  /** The same quote plus QuoterV2's own gas estimate for the swap. */
  async quoteWithGas(path: RoutePath, amountIn: bigint): Promise<{ out: bigint; gasUnits: bigint }> {
    const { result } = await this.chain.pub.simulateContract({
      address: this.cfg.uniswap.quoter,
      abi: QUOTER_V2_ABI,
      functionName: "quoteExactInput",
      args: [encodeV3Path(path.tokens, path.fees), amountIn],
    });
    return { out: result[0], gasUnits: result[3] };
  }

  /**
   * RBTC wei → `token` units, rounded up. WRBTC is 1:1; otherwise a pool quote of
   * {@link NATIVE_REF} along the best configured WRBTC→token path (cached for a
   * minute) and, for a $1 token, the configured RBTC_PRICE_USD — the higher of the
   * two when both exist.
   */
  async nativeToToken(wei: bigint, token: Address): Promise<bigint | undefined> {
    if (wei === 0n) return 0n;
    if (token.toLowerCase() === this.cfg.wrbtc.toLowerCase()) return wei;
    const key = token.toLowerCase();
    const hit = this.prices.get(key);
    let perRef = hit && Date.now() - hit.at < PRICE_TTL_MS ? hit.perRef : undefined;
    if (perRef === undefined) {
      for (const path of candidatePaths(this.cfg.wrbtc, token, this.rc)) {
        const out = await this.quote(path, NATIVE_REF).catch(() => 0n);
        if (out > (perRef ?? 0n)) perRef = out;
      }
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

/** Whether an error is an execution revert (deterministic for the state it ran on), not an RPC failure. */
function isRevert(e: unknown): boolean {
  let cur = e as { name?: unknown; message?: unknown; cause?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (cur.name === "ContractFunctionRevertedError") return true;
    if (typeof cur.message === "string" && /execution reverted/i.test(cur.message)) return true;
    cur = cur.cause as typeof cur;
  }
  return false;
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

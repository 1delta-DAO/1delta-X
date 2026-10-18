import {
  buildFlashMatchPlan,
  decodeMatchFlashResult,
  encodeFlashPath,
  encodeMatchFlashExecute,
  FlashKind,
  isFillOnce,
  ItemOp,
  MATCH_FLASH_SOLVER_ABI,
  type FlashMatch,
  type Order,
  type PoolVenue,
  type RaceCheck,
} from "@1delta-x/sdk";
import { decodeErrorResult, zeroAddress, type Address, type Hex } from "viem";

import { previewFill, type Chain } from "./chain";
import type { Config, RouteConfig, RoutePath } from "./config";
import type { FillOutcome } from "./filler";
import { gasShape, type GasRatios } from "./gasRatio";
import { broadcast, RACE_PROBE_ABI, type Guard, type RaceProbe } from "./guard";
import type { Budget, Verdict } from "./policy";
import { pathVenues } from "./poolGraph";
import { haircutBps, mulDivUp } from "./route";
import { sanitize } from "./sanitize";

/**
 * THE FLASH PATH for FLASH-REQUIRED item orders (review 2026-10-18 S-4 / M-3).
 *
 * The SDK classifier (`classifyItemFill`) marks an item order `needsFlash` when no
 * zero-capital schedule exists: a CYCLE — a fused composite (one item both consumes the
 * delivery and funds the pull: AaveV3Credit Leverage, Dolomite Open/BatchOpen/BatchClose,
 * Euler Open/Batch*, FluidTakeFor, FluidOperate Open/Close, RiverOpen), a leg-reference
 * TAKE_FOR whose proceeds pay the input, or a schedule the maker's ItemPolicy forbids.
 * `executeItemFill` fills none of them; `MatchFlashSolver.executeMatch` does: one flash in
 * the DELIVERED token around a one-order `matchSettle`, repaid from the plan's proceeds.
 *
 * `MATCH_FLASH_SOLVER` unset → {@link flashUnavailable}: a resting skip. Set → {@link FlashFiller}:
 *
 *   1. shape: one input leg (X, the proceeds the items credit), one output leg (C, the
 *      delivery the flash fronts), no SETTLE item (`SettleUnsupported`), PULL;
 *   2. preview as the FLASH SOLVER (Settlement's msg.sender): `received` R of X, `owed` O of C;
 *   3. candidates over the route's pool paths X→C (configured + discovered, quoted on each
 *      venue's QuoterV2), restricted to venues the flash solver derives IDENTICALLY to the
 *      route solver (`poolVenue(i)` equal):
 *        • UNI_V3_SWAP on a direct X/C pool — one pool flashes O of C and is repaid in X:
 *          profit (X) = R − the exact-output quote of O, grossed for the haircut;
 *        • UNI_V3_FLASH of O of C from a direct X/C pool, repaid by an exact-input swap of
 *          all of R along a path that does NOT touch that pool (a v3 pool is `lock`ed during
 *          its own flash — `LOK`): profit (C) = quote(R) × (1 − haircut) − O − the flash fee;
 *   4. gate (the route's min-profit rule): profit ≥ gas (estimate × r, at the send gas
 *      price, in the profit token) + MIN_PROFIT_RBTC — and that sum becomes the job's
 *      on-chain floor (`minProfit`, `SweptShort`), the analogue of a route plan's `minOut`;
 *   5. `eth_call` executeMatch from the operator and decode `(tokens, profit)`; estimateGas;
 *      re-price at max(estimate, measured) × r — unprofitable there is a resting verdict;
 *      a floor below the re-priced cost is raised and the call re-simulated;
 *   6. send through the shared Guard (one tx in flight, gas budget, route fill budget) with
 *      the race guard (`filled(hash)` / the fill-once nonce, `RaceCheck`) and the lost-race
 *      probe (guard.ts `RaceProbe`).
 */

/** The resting refusal when no flash solver is configured. */
export function flashUnavailable(reason: string): { ok: false; rest: true; reason: string } {
  return { ok: false, rest: true, reason: `flash-required (${reason}) — no MATCH_FLASH_SOLVER configured` };
}

/** One priced flash candidate. */
export interface FlashCandidate {
  kind: FlashKind.UNI_V3_FLASH | FlashKind.UNI_V3_SWAP;
  /** The pool the flash comes from (a direct X/C pool). */
  flashPool: { fee: number; venue: number };
  /** UNI_V3_FLASH: the repayment path X → C (exact-input of all of X). */
  repay?: RoutePath;
  /** The token the profit lands in: C (flash) or X (flash swap). */
  profitToken: Address;
  /** Haircut profit, in `profitToken`. */
  profit: bigint;
  /** What the provider takes back: UNI_V3_FLASH O + fee (C), UNI_V3_SWAP the quoted X owed. */
  repayAmount: bigint;
}

const PPM = 1_000_000n;
const BPS = 10_000n;
const GAS_LIMIT_PCT = 125n;

/** The v3 flash fee on `amount` at `fee` (hundredths of a bip), rounded up as the pool does. */
export function v3FlashFee(amount: bigint, fee: number): bigint {
  return mulDivUp(amount, BigInt(fee), PPM);
}

/** Whether `path` runs a hop on the pool (pair, fee, venue) — the `LOK` trap. */
export function pathUsesPool(path: RoutePath, a: Address, b: Address, fee: number, venue: number): boolean {
  const v = pathVenues(path);
  for (let i = 0; i < path.fees.length; i++) {
    const x = path.tokens[i]!.toLowerCase();
    const y = path.tokens[i + 1]!.toLowerCase();
    const pair = (x === a.toLowerCase() && y === b.toLowerCase()) || (x === b.toLowerCase() && y === a.toLowerCase());
    if (pair && path.fees[i] === fee && v[i] === venue) return true;
  }
  return false;
}

/** What the flash filler needs from the route strategy (quotes, paths, pricing). */
export interface FlashRouteHost {
  init(): Promise<void>;
  flashPaths(tokenIn: Address, tokenOut: Address): Promise<RoutePath[]>;
  quote(path: RoutePath, amountIn: bigint): Promise<bigint>;
  quoteExactOut(path: RoutePath, amountOut: bigint): Promise<{ need: bigint; gasUnits: bigint }>;
  nativeToToken(wei: bigint, token: Address): Promise<bigint | undefined>;
  tokenValueWei(token: Address, amount: bigint): Promise<bigint | undefined>;
  venue(i: number): PoolVenue | undefined;
}

/**
 * Price every flash candidate for a cycle that delivers `owed` of `c` and leaves
 * `received` of `x` (pure apart from the quotes `host` makes). Best first by RBTC value.
 */
export async function flashCandidates(
  host: Pick<FlashRouteHost, "quote" | "quoteExactOut" | "tokenValueWei">,
  a: { x: Address; c: Address; received: bigint; owed: bigint; paths: readonly RoutePath[]; slippageBps: bigint },
): Promise<FlashCandidate[]> {
  const direct = a.paths.filter((p) => p.fees.length === 1);
  const out: FlashCandidate[] = [];
  for (const p of direct) {
    const venue = pathVenues(p)[0]!;
    const fee = p.fees[0]!;
    // UNI_V3_SWAP: this pool flashes `owed` of C, repaid in X.
    try {
      const { need } = await host.quoteExactOut(p, a.owed);
      const needH = mulDivUp(need, BPS + a.slippageBps, BPS);
      if (needH < a.received) out.push({ kind: FlashKind.UNI_V3_SWAP, flashPool: { fee, venue }, profitToken: a.x, profit: a.received - needH, repayAmount: needH });
    } catch {
      // unquotable: not a candidate
    }
    // UNI_V3_FLASH from this pool, repaid on every path that does not touch it.
    const flashFee = v3FlashFee(a.owed, fee);
    for (const q of a.paths) {
      if (pathUsesPool(q, a.x, a.c, fee, venue)) continue;
      try {
        const got = await host.quote(q, a.received);
        const gotH = (got * (BPS - a.slippageBps)) / BPS;
        const repay = a.owed + flashFee;
        if (gotH > repay) out.push({ kind: FlashKind.UNI_V3_FLASH, flashPool: { fee, venue }, repay: q, profitToken: a.c, profit: gotH - repay, repayAmount: repay });
      } catch {
        // unquotable
      }
    }
  }
  const valued = await Promise.all(out.map(async (c) => ({ c, v: (await host.tokenValueWei(c.profitToken, c.profit).catch(() => undefined)) ?? 0n })));
  return valued.sort((p, q) => (q.v > p.v ? 1 : q.v < p.v ? -1 : 0)).map((x) => x.c);
}

/** The `FlashMatch` for a candidate, with `floor` = the on-chain profit floor in its profit token. */
export function flashJob(cand: FlashCandidate, a: { x: Address; c: Address; owed: bigint; received: bigint; recipient: Address; floor: bigint }): FlashMatch {
  const flash = {
    kind: cand.kind,
    token: a.c,
    amount: a.owed,
    pairToken: a.x,
    fee: cand.flashPool.fee,
    venue: cand.flashPool.venue,
    vault: zeroAddress,
    // Never let the provider take more than the candidate was priced at.
    maxRepay: cand.kind === FlashKind.UNI_V3_SWAP ? a.received : cand.repayAmount,
  };
  const swaps =
    cand.kind === FlashKind.UNI_V3_FLASH && cand.repay
      ? [{ path: encodeFlashPath(cand.repay.tokens, cand.repay.fees, pathVenues(cand.repay)), amountIn: 0n, minOut: cand.repayAmount }]
      : [];
  return { flash, swaps, recipient: a.recipient, extraSweep: [], minProfit: [{ token: cand.profitToken, min: a.floor }] };
}

/** Decode a MatchFlashSolver revert, if the data is one. */
function decodeFlashRevert(e: unknown): string {
  let cur = e as { cause?: unknown; data?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (typeof cur.data === "string" && cur.data.length >= 10) {
      try {
        const d = decodeErrorResult({ abi: MATCH_FLASH_SOLVER_ABI, data: cur.data as Hex });
        return `${d.errorName}(${((d.args ?? []) as readonly unknown[]).map(String).join(", ")})`;
      } catch {
        // not ours
      }
    }
    cur = cur.cause as typeof cur;
  }
  return sanitize(e instanceof Error ? e.message.split("\n")[0] : e);
}

export class FlashFiller {
  private ready = false;
  /** Venue indices the flash solver derives exactly as the route solver does. */
  private readonly venues = new Set<number>();

  constructor(
    private readonly cfg: Config,
    private readonly rc: RouteConfig,
    private readonly chain: Chain,
    private readonly guard: Guard,
    private readonly gasRatios: GasRatios,
    private readonly budget: Budget,
    /** The route-fill budget key (routeFiller.ts `ROUTE_FILLS`). */
    private readonly budgetKey: Address,
    private readonly host: FlashRouteHost,
    private readonly log: (m: string) => void,
  ) {}

  get solver(): Address {
    return this.rc.matchFlashSolver!;
  }

  /** Start-up checks: code, our operator seat, its Settlement, and the venues it shares with the route solver. */
  async init(): Promise<void> {
    if (this.ready) return;
    const { pub, me } = this.chain;
    const s = this.solver;
    const read = <T>(functionName: string, args: unknown[] = []) => pub.readContract({ address: s, abi: MATCH_FLASH_SOLVER_ABI, functionName: functionName as never, args: args as never }) as Promise<T>;
    const code = await pub.getCode({ address: s });
    if (!code || code === "0x") throw new Error(`MATCH_FLASH_SOLVER ${s} has no code`);
    const [settlement, isOp, count] = await Promise.all([read<Address>("SETTLEMENT"), read<boolean>("isOperator", [me]), read<bigint | number>("POOL_VENUES")]);
    if (settlement.toLowerCase() !== this.cfg.settlement.toLowerCase()) throw new Error(`flash solver ${s} is wired to Settlement ${settlement}, not ${this.cfg.settlement}`);
    if (!isOp) throw new Error(`${me} is not an operator of the flash solver ${s}`);
    await this.host.init();
    this.venues.clear();
    for (let i = 0; i < Number(count); i++) {
      const [factory, hash] = await read<readonly [Address, Hex]>("poolVenue", [BigInt(i)]);
      const mine = this.host.venue(i);
      if (mine && mine.factory.toLowerCase() === factory.toLowerCase() && mine.initCodeHash.toLowerCase() === hash.toLowerCase()) this.venues.add(i);
      else this.log(`⚠ [flash] venue ${i}: the flash solver derives (${factory}) differently from the route solver — not used`);
    }
    this.ready = true;
    this.log(`flash path: MatchFlashSolver ${s}, venues ${[...this.venues].join(",") || "none"}`);
  }

  private skip(orderHash: Hex, reason: string, rest = false): FillOutcome {
    this.log(`· [flash] skip ${orderHash}: ${reason}`);
    return { orderHash, status: "skipped", reason: `flash: ${reason}`, strategy: "route", ...(rest ? { rest: true } : {}) };
  }

  private shape(order: Order): Verdict<{}> {
    if (order.legsIn.length !== 1 || order.legsOut.length !== 1) return { ok: false, reason: "one input and one output leg only" };
    const k = order.items.findIndex((it) => it.op === ItemOp.SETTLE);
    if (k !== -1) return { ok: false, reason: `item ${k} is a SETTLE (the flash solver refuses it)` };
    return { ok: true };
  }

  /** Where the sweep goes: the route's profit recipient, unless that is a solver (retain mode) → the operator. */
  private recipient(): Address {
    const pr = this.rc.profitRecipient;
    const solvers = [this.rc.solver, ...this.rc.legacySolvers, this.solver].map((a) => a.toLowerCase());
    return pr === zeroAddress || solvers.includes(pr.toLowerCase()) ? zeroAddress : pr;
  }

  async fill(orderHash: Hex, order: Order, sig: Hex, fillAmount: bigint): Promise<FillOutcome> {
    const shape = this.shape(order);
    if (!shape.ok) return this.skip(orderHash, shape.reason, true);
    const { cfg, rc, chain } = this;
    try {
      await this.init();
      const now = Date.now();
      if (this.budget.remaining(this.budgetKey, now) < 1n) return this.skip(orderHash, "hourly fill budget exhausted");
      const gasPrice = await chain.pub.getGasPrice();
      const priceErr = this.guard.checkGasPrice(gasPrice);
      if (priceErr) return this.skip(orderHash, priceErr);
      const early = this.guard.gasRoom(gasPrice * rc.matchFlashGas, now);
      if (early) return this.skip(orderHash, early);

      const x = order.legsIn[0]!.token;
      const c = order.legsOut[0]!.token;
      const pv = await previewFill(chain, cfg.lens, order, fillAmount, this.solver, gasPrice);
      const received = pv.received[0] ?? 0n;
      const owed = pv.paid[0] ?? 0n;
      if (received === 0n || owed === 0n) return this.skip(orderHash, "zero-sized preview", true);

      const paths = (await this.host.flashPaths(x, c)).filter((p) => pathVenues(p).every((v) => this.venues.has(v)));
      const cands = await flashCandidates(this.host, { x, c, received, owed, paths, slippageBps: haircutBps(rc, x, c) });
      if (cands.length === 0) return this.skip(orderHash, `no flash source repays ${owed} ${c} from ${received} ${x} (${paths.length} path(s))`, true);

      const gasKey = gasShape("flash", "pull", x, c, this.solver);
      const priced = (est: bigint) => this.gasRatios.priced(gasKey, est);
      /** gas (priced units) + MIN_PROFIT_RBTC, in `token`. */
      const costIn = async (token: Address, gasUnits: bigint) => {
        const g = await this.host.nativeToToken(gasPrice * gasUnits, token);
        const p = await this.host.nativeToToken(rc.minProfitWei, token);
        return g === undefined || p === undefined ? undefined : g + p;
      };
      const best = cands[0]!;
      const cost0 = await costIn(best.profitToken, priced(rc.matchFlashGas));
      if (cost0 === undefined) return this.skip(orderHash, `cannot price RBTC in ${best.profitToken}`);
      if (best.profit < cost0) return this.skip(orderHash, `unprofitable: flash profit ${best.profit} ${best.profitToken} < gas + min profit ${cost0}`, true);

      // The race guard: the fill progress / fill-once nonce the plan is priced on.
      const filledBefore = (await chain.pub.readContract({ address: cfg.settlement, abi: RACE_PROBE_ABI, functionName: "filled", args: [orderHash] })) as bigint;
      const once = isFillOnce(order);
      const race: RaceCheck = { orderHashes: [orderHash], expectedFilled: [filledBefore], nonceMakers: once ? [order.maker] : [], nonces: once ? [order.nonce] : [] };
      const probe: RaceProbe = { settlement: cfg.settlement, filledBefore: filledBefore.toString(), ...(once ? { fillOnce: { maker: order.maker, nonce: order.nonce.toString() } } : {}) };
      const plan = buildFlashMatchPlan({ order, sig, fillAmount, solver: this.solver, flashToken: c });
      const recipient = this.recipient();
      const encode = (floor: bigint) => encodeMatchFlashExecute({ race, job: flashJob(best, { x, c, owed, received, recipient, floor }), plan, settlement: cfg.settlement });
      const simulate = async (data: Hex) => {
        const sim = await chain.pub.call({ account: chain.me, to: this.solver, data, gasPrice });
        if (!sim.data) throw new Error("simulation returned no data");
        const r = decodeMatchFlashResult(sim.data);
        const k = r.tokens.findIndex((t) => t.toLowerCase() === best.profitToken.toLowerCase());
        return k === -1 ? 0n : r.profit[k]!;
      };

      let data = encode(cost0);
      let simProfit: bigint;
      let est: bigint;
      try {
        simProfit = await simulate(data);
        est = await chain.pub.estimateGas({ account: chain.me, to: this.solver, data, gasPrice });
      } catch (e) {
        this.guard.onSimFail(orderHash, "route", Date.now());
        return this.skip(orderHash, `simulation reverted: ${decodeFlashRevert(e)}`);
      }
      // Re-price at the MEASURED gas; raise the on-chain floor to it and re-simulate.
      const pricedGas = priced(est > rc.matchFlashGas ? est : rc.matchFlashGas);
      const cost = await costIn(best.profitToken, pricedGas);
      if (cost === undefined) return this.skip(orderHash, `cannot price RBTC in ${best.profitToken}`);
      if (simProfit < cost) return this.skip(orderHash, `unprofitable at the measured gas: simulated profit ${simProfit} < ${cost} ${best.profitToken} (simulated gas ${est})`, true);
      if (cost > cost0) {
        data = encode(cost);
        try {
          simProfit = await simulate(data);
        } catch (e) {
          this.guard.onSimFail(orderHash, "route", Date.now());
          return this.skip(orderHash, `re-simulation at gas ${pricedGas} reverted: ${decodeFlashRevert(e)}`);
        }
      }
      const measured = (est * GAS_LIMIT_PCT + 99n) / 100n;
      const gasLimit = measured > pricedGas ? measured : pricedGas;
      if (gasLimit > rc.maxGas) {
        this.guard.onSimFail(orderHash, "route", Date.now());
        return this.skip(orderHash, `gas limit ${gasLimit} above MAX_ROUTE_GAS ${rc.maxGas}`);
      }
      const room = this.guard.gasRoom(gasLimit * gasPrice, Date.now());
      if (room) return this.skip(orderHash, room);
      const tag = `flash ${FlashKind[best.kind]} ${orderHash} deliver ${owed} ${c} ← ${received} ${x} (pool fee ${best.flashPool.fee} venue ${best.flashPool.venue}, profit ${simProfit} ${best.profitToken})`;
      if (cfg.dryRun) {
        this.log(`[dry-run] [flash] would executeMatch ${tag}, gas limit ${gasLimit} (simulated ${est})`);
        return { orderHash, status: "dry-run", paid: owed, received, strategy: "route" };
      }
      const r = await broadcast(chain, this.guard, {
        to: this.solver,
        data,
        gas: gasLimit,
        gasPrice,
        kind: "fill",
        strategy: "route",
        orderHash,
        expiry: order.expiry,
        reserve: { budget: "route", token: this.budgetKey, amount: 1n },
        gasMeter: { shape: gasKey, estimate: est.toString() },
        race: probe,
        info: { tag: `${tag} (limit ${gasLimit})`, payToken: c, paid: owed.toString(), recvToken: x, received: received.toString(), profitEst: simProfit.toString(), profitToken: best.profitToken },
      });
      if (r.kind === "refused") return this.skip(orderHash, r.reason);
      if (r.kind === "failed") throw new Error(r.reason);
      this.log(`→ [flash] sent executeMatch ${tag} tx ${r.tx} (gas limit ${gasLimit} @ ${gasPrice} wei)`);
      return { orderHash, status: "pending", tx: r.tx, paid: owed, received, strategy: "route", final: true };
    } catch (e) {
      this.guard.onSimFail(orderHash, "route", Date.now());
      const reason = decodeFlashRevert(e);
      this.log(`✗ [flash] ${orderHash} ${reason}`);
      return { orderHash, status: "failed", reason: `flash: ${reason}`, strategy: "route" };
    }
  }
}

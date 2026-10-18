import { encodeFunctionData, erc20Abi, toFunctionSelector, type Address, type Hex } from "viem";

import type { Chain } from "./chain";
import type { SolverSweepConfig } from "./config";
import { broadcast, GAS_LIMIT_PCT, type Guard } from "./guard";
import { sanitize } from "./sanitize";

/**
 * THE OPERATOR SWEEP (review 2026-10-18 §4): nothing off-chain used to call the solver's
 * `sweep`, so whatever an AggregatorFillSolver RETAINS — the filler's spread in retain
 * mode (`ROUTE_PROFIT_RECIPIENT` = the solver, the beta's configuration) and receipts no
 * route sells (a foreign-token SETTLE receipt, review S-2) — sat there until an operator
 * ran e2e/sweep-solver.sh by hand.
 *
 * One {@link SolverSweeper.step} per idle tick (nothing else was sent), at most one tx:
 *   1. a solver whose check is due (every SOLVER_SWEEP_SECONDS, or at once after a route
 *      fill landed when SOLVER_SWEEP_AFTER_FILL) is read: `isOperator(us)` once, then the
 *      balance of every SOLVER_SWEEP_TOKENS token;
 *   2. what is above the 1-wei self-seeded floor of each token is valued in RBTC (the
 *      route's own pricing; an unpriceable token counts 0 but is swept along);
 *   3. it is swept only if that value reaches SOLVER_SWEEP_MIN_RBTC AND SOLVER_SWEEP_GAS_MULT ×
 *      the sweep's own gas cost — with `sweepAll(tokens, to, 1)` where the solver has it
 *      (v3: one tx, amounts read on-chain at execution), else `sweep(token, to, bal − 1)`
 *      for the most valuable token (one per tick);
 *   4. the call is estimated (= simulated from the operator) first, and sent through the
 *      shared {@link Guard} (hourly gas budget, gas-price ceiling, one tx in flight).
 * Only the operator key can do it (the solver reverts `NotOperator` otherwise), and only
 * to SOLVER_SWEEP_TO — never a solver (config.ts refuses it). DRY_RUN logs the plan.
 */

/** `sweepAll(address[],address,uint256)` (solver v3) and `sweep(address,address,uint256)`. */
export const SOLVER_SWEEP_ABI = [
  {
    type: "function",
    name: "sweepAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokens", type: "address[]" },
      { name: "to", type: "address" },
      { name: "keep", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "sweep",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  { type: "function", name: "isOperator", stateMutability: "view", inputs: [{ name: "who", type: "address" }], outputs: [{ name: "", type: "bool" }] },
] as const;

export const SWEEP_ALL_SELECTOR = toFunctionSelector("sweepAll(address[],address,uint256)");

/** The 1-wei floor each token keeps (README "Dust is worth having"): `keep` of `sweepAll`. */
export const SWEEP_KEEP = 1n;

/** Value of `amount` of `token` in RBTC wei, or undefined when the token cannot be priced. */
export type TokenValuer = (token: Address, amount: bigint) => Promise<bigint | undefined>;

export interface SweepPlan {
  solver: Address;
  data: Hex;
  /** Tokens and amounts above the floors (what the call moves at the read). */
  tokens: Array<{ token: Address; amount: bigint; valueWei?: bigint }>;
  valueWei: bigint;
  batched: boolean;
}

export type SweepOutcome =
  | { status: "sent"; solver: Address; tx: Hex; valueWei: bigint; tokens: number }
  | { status: "dry-run"; solver: Address; valueWei: bigint; tokens: number }
  | { status: "skipped"; solver: Address; reason: string };

/** Per-solver sweep bookkeeping, persisted with the filler state: last check (ms) and the operator verdict. */
export interface SweepState {
  checkedAt?: Record<string, number>;
}

/**
 * Pick what to sweep from `balances` (pure). `batched`: the solver has `sweepAll` — every
 * token above the floor in one call; else the single most valuable one (`sweep`).
 */
export function planSweep(
  solver: Address,
  to: Address,
  balances: ReadonlyArray<{ token: Address; balance: bigint; valueWei?: bigint }>,
  batched: boolean,
): SweepPlan | undefined {
  const over = balances
    .filter((b) => b.balance > SWEEP_KEEP)
    .map((b) => ({ token: b.token, amount: b.balance - SWEEP_KEEP, ...(b.valueWei !== undefined ? { valueWei: b.valueWei } : {}) }));
  if (over.length === 0) return undefined;
  if (batched) {
    const valueWei = over.reduce((a, t) => a + (t.valueWei ?? 0n), 0n);
    const data = encodeFunctionData({ abi: SOLVER_SWEEP_ABI, functionName: "sweepAll", args: [over.map((t) => t.token), to, SWEEP_KEEP] });
    return { solver, data, tokens: over, valueWei, batched };
  }
  const best = [...over].sort((a, b) => ((b.valueWei ?? 0n) > (a.valueWei ?? 0n) ? 1 : (b.valueWei ?? 0n) < (a.valueWei ?? 0n) ? -1 : 0))[0]!;
  const data = encodeFunctionData({ abi: SOLVER_SWEEP_ABI, functionName: "sweep", args: [best.token, to, best.amount] });
  return { solver, data, tokens: [best], valueWei: best.valueWei ?? 0n, batched };
}

/** The value gate (pure): enough RBTC value, and enough of it over the sweep's own gas cost. */
export function sweepWorthIt(valueWei: bigint, gasCostWei: bigint, cfg: Pick<SolverSweepConfig, "minWei" | "gasMult">): string | undefined {
  if (valueWei < cfg.minWei) return `retained value ${valueWei} wei below SOLVER_SWEEP_MIN_RBTC (${cfg.minWei} wei)`;
  if (valueWei < cfg.gasMult * gasCostWei) return `retained value ${valueWei} wei below ${cfg.gasMult} × the sweep's gas cost (${gasCostWei} wei)`;
  return undefined;
}

export class SolverSweeper {
  private readonly checkedAt: Record<string, number>;
  private readonly batched = new Map<string, boolean>();
  private readonly operatorOf = new Map<string, boolean>();

  constructor(
    private readonly cfg: SolverSweepConfig,
    /** Every solver instance to sweep: the primary first, then the legacy ones. */
    readonly solvers: readonly Address[],
    private readonly chain: Chain,
    private readonly guard: Guard,
    private readonly value: TokenValuer,
    private readonly log: (m: string) => void,
    private readonly dryRun: boolean,
    state: SweepState = {},
    private readonly persist: () => void = () => {},
  ) {
    this.checkedAt = { ...(state.checkedAt ?? {}) };
  }

  get state(): SweepState {
    return { checkedAt: { ...this.checkedAt } };
  }

  /** A route fill landed: with SOLVER_SWEEP_AFTER_FILL the next idle tick checks every solver. */
  noteFill(): void {
    if (!this.cfg.afterFill) return;
    for (const s of this.solvers) delete this.checkedAt[s.toLowerCase()];
    this.persist();
  }

  /** The first solver whose check is due at `now`, if any. */
  private due(now: number): Address | undefined {
    for (const s of this.solvers) {
      const at = this.checkedAt[s.toLowerCase()];
      if (at === undefined || now - at >= this.cfg.intervalMs) return s;
    }
    return undefined;
  }

  private mark(solver: Address, now: number): void {
    this.checkedAt[solver.toLowerCase()] = now;
    this.persist();
  }

  /** One check (and at most one tx) — see the module note. `undefined` = nothing due. */
  async step(now: number = Date.now()): Promise<SweepOutcome | undefined> {
    if (this.guard.pending) return undefined;
    const solver = this.due(now);
    if (!solver) return undefined;
    const key = `sweep:${solver.toLowerCase()}`;
    const blocked = this.guard.admit(key, "route", now);
    if (blocked) return { status: "skipped", solver, reason: blocked.reason };
    const { pub, me } = this.chain;
    try {
      const k = solver.toLowerCase();
      if (!this.operatorOf.has(k)) {
        this.operatorOf.set(k, (await pub.readContract({ address: solver, abi: SOLVER_SWEEP_ABI, functionName: "isOperator", args: [me] })) as boolean);
      }
      if (!this.operatorOf.get(k)) {
        this.mark(solver, now);
        return { status: "skipped", solver, reason: `${me} is not an operator of ${solver}: it cannot sweep` };
      }
      if (!this.batched.has(k)) {
        const code = (await pub.getCode({ address: solver })) ?? "0x";
        this.batched.set(k, code.toLowerCase().includes(SWEEP_ALL_SELECTOR.slice(2).toLowerCase()));
      }
      const balances: Array<{ token: Address; balance: bigint; valueWei?: bigint }> = [];
      for (const token of this.cfg.tokens) {
        const balance = (await pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [solver] })) as bigint;
        if (balance <= SWEEP_KEEP) continue;
        const v = await this.value(token, balance - SWEEP_KEEP).catch(() => undefined);
        balances.push({ token, balance, ...(v !== undefined ? { valueWei: v } : {}) });
      }
      const plan = planSweep(solver, this.cfg.to, balances, this.batched.get(k)!);
      if (!plan) {
        this.mark(solver, now);
        return { status: "skipped", solver, reason: "nothing retained above the 1-wei floors" };
      }
      const gasPrice = await pub.getGasPrice();
      const priceErr = this.guard.checkGasPrice(gasPrice);
      if (priceErr) return { status: "skipped", solver, reason: priceErr }; // transient: not marked
      // The estimate simulates the call from the operator (NotOperator / Reentrancy / a failed transfer throw here).
      const est = await pub.estimateGas({ account: me, to: solver, data: plan.data, gasPrice });
      const gas = (est * GAS_LIMIT_PCT + 99n) / 100n;
      const notWorth = sweepWorthIt(plan.valueWei, est * gasPrice, this.cfg);
      if (notWorth) {
        this.mark(solver, now);
        return { status: "skipped", solver, reason: notWorth };
      }
      const what = `${plan.batched ? "sweepAll" : "sweep"} ${plan.tokens.length} token(s) worth ~${plan.valueWei} wei from ${solver} to ${this.cfg.to}`;
      if (this.dryRun) {
        this.log(`[dry-run] [sweep] would ${what} (gas ${est})`);
        this.mark(solver, now);
        return { status: "dry-run", solver, valueWei: plan.valueWei, tokens: plan.tokens.length };
      }
      const r = await broadcast(this.chain, this.guard, { to: solver, data: plan.data, gas, gasPrice, kind: "sweep", strategy: "route", backoffKey: key, info: { note: what } }, now);
      if (r.kind !== "sent") return { status: "skipped", solver, reason: r.reason };
      this.mark(solver, now);
      this.log(`→ [sweep] ${what} tx ${r.tx}`);
      return { status: "sent", solver, tx: r.tx, valueWei: plan.valueWei, tokens: plan.tokens.length };
    } catch (e) {
      this.guard.onSimFail(key, "route", now);
      const reason = sanitize(e instanceof Error ? e.message.split("\n")[0] : e);
      this.log(`✗ [sweep] ${solver}: ${reason}`);
      return { status: "skipped", solver, reason };
    }
  }
}

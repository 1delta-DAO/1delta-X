import { keccak256, TransactionNotFoundError, type Address, type Hex } from "viem";

import type { Chain } from "./chain";
import type { GasPolicy } from "./config";
import { Budget } from "./policy";
import { sanitize } from "./sanitize";
import type { SpendEntry } from "./state";

/** Budget key of the shared hourly RBTC gas budget (both strategies). */
export const GAS = "gas" as Address;

/**
 * Per-order backoff schedule.
 *
 *  • An ON-CHAIN revert (a tx we paid for) is a STRIKE and blocks the order for
 *    EVERY strategy: 1 min, 4 min, 16 min, 1 h (capped); the 5th strike blacklists
 *    it until the order's own expiry. Dispatch never falls through to the next
 *    strategy on an order whose tx just reverted.
 *  • A failure BEFORE sending (simulation revert, gas above MAX_ROUTE_GAS, RPC
 *    error) blocks only that strategy, briefly: 30 s doubling to 5 min. The other
 *    strategy may still try (e.g. inventory short of balance → route).
 *  • Every sent tx is PENDING until a later tick reads its receipt (nothing waits
 *    for one): success → the order is cleared; revert → a strike; not found after
 *    15 min and not in the mempool, or its nonce mined by another tx → dropped,
 *    short backoff. While a tx is pending NOTHING else is sent (one outstanding
 *    tx, so nonces are trivially right).
 */
/** The largest value `new Date(ms)` accepts (ECMA-262): ±100,000,000 days. */
const MAX_DATE_MS = 8_640_000_000_000_000;

export const BACKOFF = {
  baseMs: 60_000,
  factor: 4,
  maxMs: 3_600_000,
  maxStrikes: 5,
  simBaseMs: 30_000,
  simMaxMs: 300_000,
  pendingDropMs: 15 * 60_000,
  /** Strike history is forgotten this long after the block lapses. */
  forgetMs: 24 * 3_600_000,
  /** Blacklist length for an order with no expiry (0). */
  noExpiryBlacklistMs: 7 * 24 * 3_600_000,
} as const;

/**
 * A pending tx the node does NOT know (a definite `TransactionNotFoundError`, never
 * an RPC error) is re-broadcast verbatim — the recorded signed bytes: same nonce,
 * same hash, so it is idempotent — once no broadcast happened for `afterMs`, at
 * most `max` times. A broadcast lost in flight (a crash between the commit and the
 * send, a dropped connection) used to stall every send until the 15-minute drop rule.
 */
export const REBROADCAST = {
  afterMs: 60_000,
  max: 5,
} as const;


export interface BackoffEntry {
  /** On-chain reverts so far. */
  strikes: number;
  /** Blocked for every strategy until this time, ms. */
  until: number;
  /** Order expiry, unix seconds (as a decimal string), for the blacklist. */
  expiry: string;
  /** Pre-2026-10 STATE_FILE only: a per-order pending tx (adopted as {@link GuardState.pending} on load). */
  pending?: { tx: Hex; at: number };
  reason: string;
}

export interface SimBackoffEntry {
  fails: number;
  until: number;
}

/** What a sent tx was for. */
export type TxKind = "fill" | "approve" | "redeem" | "sell-rif" | "mint";
/** Who sent it. */
export type TxStrategy = "inventory" | "route" | "rebalance";

/** Optional bookkeeping carried with a fill tx, for logs and the P&L record. */
export interface TxInfo {
  /** The human log tag of the fill (`direct 0x… in … → owed …`). */
  tag?: string;
  payToken?: string;
  paid?: string;
  recvToken?: string;
  received?: string;
  /** Estimated gross profit (before gas), in `profitToken` units. */
  profitEst?: string;
  profitToken?: string;
  note?: string;
}

/**
 * THE outstanding transaction. Recorded (and committed to the state store)
 * after signing and BEFORE the broadcast, so a crash between the two cannot
 * lose track of a tx that may be in the mempool.
 */
export interface PendingTx {
  hash: Hex;
  /** -1 = unknown (adopted from a pre-2026-10 state file). */
  nonce: number;
  /** The signed raw tx, re-broadcast verbatim if the node loses it (absent on pre-2026-10 records). */
  raw?: Hex;
  /** Re-broadcasts so far (at most {@link REBROADCAST}.max). */
  rebroadcasts?: number;
  /** The last broadcast of the raw bytes (the send or a re-broadcast), ms; `sentAt` when unset. */
  lastBroadcastAt?: number;
  /**
   * Fills: the book's `fillableAmount` for the order when this fill was sent
   * (decimal). After a successful fill the engine skips the order until the book
   * reports a different fillable (or a hold expires) — the book needs ~60–80 s on
   * Rootstock to index a fill, and until then it still serves the order.
   */
  bookFillable?: string;
  gasLimit: string;
  gasPrice: string;
  value?: string;
  kind: TxKind;
  strategy: TxStrategy;
  /** Fills: the order (its backoff key). */
  orderHash?: Hex;
  /** Non-fill txs: the backoff key of the action (`rebalance:redeem`, `approve:<token>:<spender>`). */
  backoffKey?: string;
  /** Order expiry, unix seconds (decimal string); "0" for non-fill txs. */
  expiry: string;
  sentAt: number;
  /**
   * Set once `RECEIPT_TIMEOUT_MS` passed without a receipt: the conservative
   * budget reservation made at send time (the inventory outflow / one route fill)
   * is then FINAL — a later receipt no longer releases it on a revert. The gas
   * charge is still settled to the receipt's real cost (a no-op once the entry left
   * the hourly window), so the fills row and the budget agree on what was paid.
   */
  timedOut?: boolean;
  /** A strategy-budget reservation made at send time (released on a timely revert). */
  reserved?: { budget: string; token: string; amount: string };
  info?: TxInfo;
}

export interface GuardState {
  gasSpends?: SpendEntry[];
  backoff?: Record<string, BackoffEntry>;
  simBackoff?: Record<string, SimBackoffEntry>;
  pending?: PendingTx;
  untracked?: UntrackedInFlight;
}

/**
 * The account's pending nonce was ahead of its mined nonce when a send was tried —
 * a tx this filler does not track is in flight (another host on the same key, a
 * hand-sent tx, a record lost in a crash), and every send is refused until it mines.
 * `since` = first refusal of the current streak, `lastAt` = the latest one.
 */
export interface UntrackedInFlight {
  since: number;
  lastAt: number;
  count: number;
}

export type Admission = { reason: string; /** blocks every strategy (dispatch stops) */ global: boolean };

/**
 * State shared by both strategies and the rebalancer: ONE hourly RBTC gas
 * budget, the gas-price ceiling, the per-order backoff, and the one outstanding
 * tx. `persist` marks the state dirty (cheap, called on every change); `commit`
 * durably saves it and is awaited before a broadcast.
 */
export class Guard {
  readonly gas: Budget;
  private readonly backoff: Record<string, BackoffEntry>;
  private readonly simBackoff: Record<string, SimBackoffEntry>;
  private pendingTx: PendingTx | undefined;
  private untrackedTx: UntrackedInFlight | undefined;
  /** Strategy budgets that sends reserve against (by name), see {@link register}. */
  readonly budgets: Record<string, Budget> = {};
  private readonly commitFn: () => Promise<void>;

  constructor(
    readonly policy: GasPolicy,
    state: GuardState = {},
    private readonly persist: () => void = () => {},
    commit?: () => Promise<void>,
  ) {
    this.gas = new Budget({ [GAS]: policy.hourlyWei }, state.gasSpends ?? []);
    this.backoff = { ...(state.backoff ?? {}) };
    this.simBackoff = { ...(state.simBackoff ?? {}) };
    this.pendingTx = state.pending ? { ...state.pending } : undefined;
    this.untrackedTx = state.untracked ? { ...state.untracked } : undefined;
    this.commitFn = commit ?? (async () => this.persist());
    // A pre-2026-10 state file parked pending txs per order: adopt one as THE
    // pending tx (its charges were already final), keep the rest as a short block.
    for (const [k, e] of Object.entries(this.backoff)) {
      if (!e.pending) continue;
      if (!this.pendingTx) {
        this.pendingTx = {
          hash: e.pending.tx, nonce: -1, gasLimit: "0", gasPrice: "0", kind: "fill", strategy: "route",
          orderHash: k as Hex, expiry: e.expiry, sentAt: e.pending.at, timedOut: true,
        };
      }
      delete e.pending;
    }
  }

  /** Make `budget` reservable by name (the inventory outflow, the route fill counter). */
  register(name: string, budget: Budget): void {
    this.budgets[name] = budget;
  }

  /** The outstanding tx, if any. */
  get pending(): PendingTx | undefined {
    return this.pendingTx;
  }

  setPending(p: PendingTx | undefined): void {
    this.pendingTx = p;
    this.persist();
  }

  /** The current "untracked tx in flight" refusal streak, if any. */
  get untracked(): UntrackedInFlight | undefined {
    return this.untrackedTx;
  }

  /** A send was refused: the pending nonce is `count` ahead of the mined one. */
  noteUntracked(now: number, count: number): void {
    this.untrackedTx = { since: this.untrackedTx?.since ?? now, lastAt: now, count };
    this.persist();
  }

  /** A send passed the nonce check: no untracked tx in flight. */
  clearUntracked(): void {
    if (!this.untrackedTx) return;
    this.untrackedTx = undefined;
    this.persist();
  }

  /** Durably save the state (awaited before a broadcast). */
  async commit(): Promise<void> {
    await this.commitFn();
  }

  /** Refusal reason when `gasPrice` is above MAX_GAS_PRICE_GWEI. */
  checkGasPrice(gasPrice: bigint): string | undefined {
    if (gasPrice > this.policy.maxGasPriceWei) {
      return `gas price ${gasPrice} wei above MAX_GAS_PRICE_GWEI (${this.policy.maxGasPriceWei} wei)`;
    }
    return undefined;
  }

  /** Refusal reason when the hourly gas budget cannot cover `costWei` (gas LIMIT × price). */
  gasRoom(costWei: bigint, now: number): string | undefined {
    const left = this.gas.remaining(GAS, now);
    if (left < costWei) return `hourly gas budget exhausted (${left} wei left < ${costWei} wei for this tx)`;
    return undefined;
  }

  chargeGas(wei: bigint, now: number, ref?: string): void {
    this.gas.spend(GAS, wei, now, ref);
    this.persist();
  }

  /**
   * Whether `strategy` may act on `key` (an order hash, or a rebalancer / approval
   * action key) now. Synchronous: pending txs are resolved by the tick, not here.
   * `undefined` = go ahead.
   */
  admit(key: string, strategy: string, now: number): Admission | undefined {
    const k = key.toLowerCase();
    const p = this.pendingTx;
    if (p && (p.orderHash?.toLowerCase() === k || p.backoffKey === k)) return { reason: `tx ${p.hash} still pending`, global: true };
    const e = this.backoff[k];
    if (e && now < e.until) {
      const what = e.strikes >= BACKOFF.maxStrikes ? "blacklisted" : "backoff";
      return { reason: `${what} after ${e.strikes} on-chain revert(s) until ${new Date(e.until).toISOString()} (${e.reason})`, global: true };
    }
    const s = this.simBackoff[`${strategy}:${k}`];
    if (s && now < s.until) return { reason: `${strategy} backoff after ${s.fails} failed attempt(s)`, global: false };
    return undefined;
  }

  /** A pre-send failure (simulation, gas cap, RPC): short, strategy-scoped backoff. */
  onSimFail(key: string, strategy: string, now: number): void {
    const k = `${strategy}:${key.toLowerCase()}`;
    const prev = this.simBackoff[k];
    const fails = (prev && now - prev.until < BACKOFF.forgetMs ? prev.fails : 0) + 1;
    const delay = Math.min(BACKOFF.simBaseMs * 2 ** (fails - 1), BACKOFF.simMaxMs);
    this.simBackoff[k] = { fails, until: now + delay };
    this.prune(now);
    this.persist();
  }

  /** An on-chain revert: a strike, blocking every strategy. */
  onRevert(key: string, now: number, expiry: bigint, reason: string): void {
    const k = key.toLowerCase();
    const prev = this.backoff[k];
    const strikes = (prev && now - prev.until < BACKOFF.forgetMs ? prev.strikes : 0) + 1;
    let until: number;
    if (strikes >= BACKOFF.maxStrikes) {
      // Capped at the largest `Date` (8.64e15 ms): an absurd expiry — not
      // reachable through the book's MAX_TTL, but `fill-json` and other books
      // exist — would otherwise make every later `toISOString()` of `until` throw
      // and take `/status` down with it. Every real expiry is unchanged.
      until = expiry > 0n ? Math.min(Number(expiry) * 1000, MAX_DATE_MS) : now + BACKOFF.noExpiryBlacklistMs;
      if (until <= now) until = now + BACKOFF.maxMs;
    } else {
      until = now + Math.min(BACKOFF.baseMs * BACKOFF.factor ** (strikes - 1), BACKOFF.maxMs);
    }
    this.backoff[k] = { strikes, until, expiry: expiry.toString(), reason: sanitize(reason, 120) };
    this.prune(now);
    this.persist();
  }

  /** A sent tx vanished (dropped): keep the strike count, retry after a short block. */
  onDropped(key: string, now: number, expiry: bigint, reason: string): void {
    const k = key.toLowerCase();
    const prev = this.backoff[k];
    this.backoff[k] = { strikes: prev?.strikes ?? 0, until: now + BACKOFF.simBaseMs, expiry: expiry.toString(), reason: sanitize(reason, 120) };
    this.persist();
  }

  /** A tx landed: forget every block on the key. */
  onSuccess(key: string): void {
    const k = key.toLowerCase();
    delete this.backoff[k];
    for (const sk of Object.keys(this.simBackoff)) if (sk.endsWith(`:${k}`)) delete this.simBackoff[sk];
    this.persist();
  }

  private prune(now: number): void {
    for (const [k, e] of Object.entries(this.backoff)) {
      if (now - e.until > BACKOFF.forgetMs) delete this.backoff[k];
    }
    for (const [k, e] of Object.entries(this.simBackoff)) {
      if (now - e.until > BACKOFF.forgetMs) delete this.simBackoff[k];
    }
  }

  /** A read-only view of one key's on-chain backoff (status / tests). */
  entry(key: string): BackoffEntry | undefined {
    const e = this.backoff[key.toLowerCase()];
    return e ? { ...e } : undefined;
  }

  /** Every key currently blocked (status). */
  blocked(now: number): Array<{ key: string; until: number; strikes?: number; fails?: number; reason?: string; scope: string }> {
    const out: Array<{ key: string; until: number; strikes?: number; fails?: number; reason?: string; scope: string }> = [];
    for (const [k, e] of Object.entries(this.backoff)) if (now < e.until) out.push({ key: k, until: e.until, strikes: e.strikes, reason: e.reason, scope: "all" });
    for (const [k, e] of Object.entries(this.simBackoff)) {
      if (now < e.until) out.push({ key: k.slice(k.indexOf(":") + 1), until: e.until, fails: e.fails, scope: k.slice(0, k.indexOf(":")) });
    }
    return out;
  }

  toJSON(): GuardState {
    return {
      gasSpends: this.gas.toJSON(),
      backoff: this.backoff,
      simBackoff: this.simBackoff,
      ...(this.pendingTx ? { pending: this.pendingTx } : {}),
      ...(this.untrackedTx ? { untracked: this.untrackedTx } : {}),
    };
  }
}

/** A send request: everything but the nonce, which {@link broadcast} reads. */
export interface SendRequest {
  to: Address;
  data: Hex;
  value?: bigint;
  /** The gas LIMIT the caller priced — sent as is. */
  gas: bigint;
  gasPrice: bigint;
  kind: TxKind;
  strategy: TxStrategy;
  orderHash?: Hex;
  backoffKey?: string;
  expiry?: bigint;
  /** Reserve `amount` of `token` on the registered budget `budget` until the receipt. */
  reserve?: { budget: string; token: Address; amount: bigint };
  info?: TxInfo;
}

export type BroadcastResult =
  | { kind: "refused"; reason: string }
  | { kind: "sent"; tx: Hex; pending: PendingTx }
  /** The node refused the raw tx (and does not know it): nothing was sent, nothing stays charged. */
  | { kind: "failed"; reason: string };

/**
 * The ONE send path (fills, approvals, rebalancing). Never waits for a receipt:
 *
 *  1. refuses while another tx is pending (one outstanding tx at a time), above
 *     MAX_GAS_PRICE_GWEI, or when the hourly gas budget cannot cover the gas
 *     LIMIT × price; and when the account's pending nonce is ahead of its mined
 *     nonce (a tx we do not track is in flight);
 *  2. signs a legacy (type-0) tx at the mined nonce — Rootstock has no EIP-1559
 *     market — and computes its hash;
 *  3. CHARGES conservatively (gas at the full limit, plus the caller's budget
 *     reservation), records the tx as pending and COMMITS the state;
 *  4. broadcasts the raw bytes.
 *
 * A later tick resolves it ({@link resolvePending}): the receipt's real gas cost
 * replaces the limit-priced charge, a revert releases the reservation and is a
 * strike — unless RECEIPT_TIMEOUT_MS passed first, after which the reservation is final.
 * A commit that throws undoes step 3 and rethrows: nothing is broadcast.
 */
export async function broadcast(chain: Chain, guard: Guard, a: SendRequest, now: number = Date.now()): Promise<BroadcastResult> {
  if (guard.pending) return { kind: "refused", reason: `tx ${guard.pending.hash} still pending` };
  const priceErr = guard.checkGasPrice(a.gasPrice);
  if (priceErr) return { kind: "refused", reason: priceErr };
  const cost = a.gas * a.gasPrice;
  const roomErr = guard.gasRoom(cost, now);
  if (roomErr) return { kind: "refused", reason: roomErr };
  const nonce = await chain.pub.getTransactionCount({ address: chain.me, blockTag: "latest" });
  let inFlight: number | undefined;
  try {
    inFlight = await chain.pub.getTransactionCount({ address: chain.me, blockTag: "pending" });
  } catch {
    inFlight = undefined; // a node without the pending tag: rely on our own record
  }
  if (inFlight !== undefined && inFlight > nonce) {
    guard.noteUntracked(now, inFlight - nonce);
    return { kind: "refused", reason: `account has ${inFlight - nonce} untracked tx(s) in flight (pending nonce ${inFlight} > ${nonce})` };
  }
  guard.clearUntracked();
  const raw = await chain.account.signTransaction({
    type: "legacy",
    chainId: chain.chainId,
    nonce,
    to: a.to,
    data: a.data,
    value: a.value ?? 0n,
    gas: a.gas,
    gasPrice: a.gasPrice,
  });
  const hash = keccak256(raw);
  const pending: PendingTx = {
    hash,
    nonce,
    raw,
    lastBroadcastAt: now,
    gasLimit: a.gas.toString(),
    gasPrice: a.gasPrice.toString(),
    ...(a.value ? { value: a.value.toString() } : {}),
    kind: a.kind,
    strategy: a.strategy,
    ...(a.orderHash ? { orderHash: a.orderHash.toLowerCase() as Hex } : {}),
    ...(a.backoffKey ? { backoffKey: a.backoffKey.toLowerCase() } : {}),
    expiry: (a.expiry ?? 0n).toString(),
    sentAt: now,
    ...(a.reserve ? { reserved: { budget: a.reserve.budget, token: a.reserve.token.toLowerCase(), amount: a.reserve.amount.toString() } } : {}),
    ...(a.info ? { info: a.info } : {}),
  };
  guard.chargeGas(cost, now, hash);
  if (a.reserve) guard.budgets[a.reserve.budget]?.spend(a.reserve.token, a.reserve.amount, now, hash);
  guard.setPending(pending);
  try {
    await guard.commit();
  } catch (e) {
    // Nothing was sent: roll the charges and the in-memory pending record back, so
    // a failed storage put neither blocks every send until the 60 s re-broadcast
    // nor broadcasts a tx the state store does not know about.
    guard.gas.settle(hash, GAS, 0n);
    if (a.reserve) guard.budgets[a.reserve.budget]?.settle(hash, a.reserve.token, 0n);
    guard.setPending(undefined);
    throw e;
  }
  try {
    await chain.pub.sendRawTransaction({ serializedTransaction: raw });
  } catch (e) {
    // Only a DEFINITE "not found" proves the node refused the bytes. An RPC error /
    // timeout / 429 on the check is no evidence either way: the tx stays pending
    // (nothing else is sent), and resolvePending re-broadcasts it if it was lost.
    const known = await txKnown(chain.pub, hash);
    if (known === false) {
      // Refused by the node: undo the charges and the pending record.
      guard.gas.settle(hash, GAS, 0n);
      if (a.reserve) guard.budgets[a.reserve.budget]?.settle(hash, a.reserve.token, 0n);
      guard.setPending(undefined);
      await guard.commit();
      return { kind: "failed", reason: `broadcast refused: ${sanitize(e instanceof Error ? e.message.split("\n")[0] : e)}` };
    }
  }
  return { kind: "sent", tx: hash, pending };
}

/** Headroom on `eth_estimateGas` for the tx gas limit of a fixed-shape tx (approve, redeem, swap). */
export const GAS_LIMIT_PCT = 125n;

/**
 * Estimate (which also simulates — a reverting call throws) and {@link broadcast}
 * a fixed-shape call at the current gas price with limit = estimate × 1.25.
 */
export async function estimateAndBroadcast(
  chain: Chain,
  guard: Guard,
  a: Omit<SendRequest, "gas" | "gasPrice"> & { gasPrice?: bigint },
  now: number = Date.now(),
): Promise<BroadcastResult> {
  if (guard.pending) return { kind: "refused", reason: `tx ${guard.pending.hash} still pending` };
  const gasPrice = a.gasPrice ?? (await chain.pub.getGasPrice());
  const priceErr = guard.checkGasPrice(gasPrice);
  if (priceErr) return { kind: "refused", reason: priceErr };
  const est = await chain.pub.estimateGas({ account: chain.me, to: a.to, data: a.data, value: a.value ?? 0n, gasPrice });
  const gas = (est * GAS_LIMIT_PCT + 99n) / 100n;
  return broadcast(chain, guard, { ...a, gas, gasPrice }, now);
}

/** The outcome of reading the outstanding tx's status once. */
export interface Resolution {
  status: "success" | "reverted" | "dropped" | "timeout" | "waiting";
  pending: PendingTx;
  gasUsed?: bigint;
  /** The gas cost charged for it (wei): the receipt's when mined, else the limit's. */
  gasCostWei?: bigint;
  /** `dropped` because the account's mined nonce passed the tx's own: another tx took the nonce. */
  replaced?: boolean;
  /** The raw tx was re-broadcast this call (it was unknown to the node). */
  rebroadcast?: { attempt: number; error?: string };
}

type ReceiptPub = Pick<Chain["pub"], "getTransactionReceipt" | "getTransaction"> &
  Partial<Pick<Chain["pub"], "sendRawTransaction" | "getTransactionCount">>;

/** viem's `TransactionNotFoundError` anywhere in an error's cause chain (by class or name). */
export function isTxNotFound(e: unknown): boolean {
  let cur = e as { name?: unknown; cause?: unknown } | undefined;
  for (let i = 0; cur && i < 6; i++) {
    if (cur instanceof TransactionNotFoundError || cur.name === "TransactionNotFoundError") return true;
    cur = cur.cause as typeof cur;
  }
  return false;
}

/**
 * Whether the node knows `hash` (mempool or chain): `true` / `false`, or `undefined`
 * when the RPC could not say — an error that is not a definite "not found"
 * (timeout, 429, a 5xx) is NO evidence that the tx was dropped.
 */
export async function txKnown(pub: Pick<Chain["pub"], "getTransaction">, hash: Hex): Promise<boolean | undefined> {
  try {
    return !!(await pub.getTransaction({ hash }));
  } catch (e) {
    return isTxNotFound(e) ? false : undefined;
  }
}

/**
 * Read the outstanding tx's receipt ONCE (never waits) and apply it:
 *
 *  • mined: the gas charge becomes the receipt's real cost (`gasUsed ×
 *    effectiveGasPrice`, also on a revert, also after RECEIPT_TIMEOUT_MS — a no-op
 *    once the entry left the hourly window); a revert is a strike on the order /
 *    action and, before the timeout only, releases the budget reservation;
 *  • not mined after RECEIPT_TIMEOUT_MS: marked timed out (the reservation is final);
 *  • overdue ({@link REBROADCAST}.afterMs after its last broadcast) and the account's
 *    MINED nonce is past the tx's own: another tx took the nonce (a hand-replaced
 *    tx) — dropped at once, the charges kept (a same-data speed-up may have filled);
 *  • not mined, and DEFINITELY unknown to the node (`TransactionNotFoundError`)
 *    {@link REBROADCAST}.afterMs after its last broadcast: the recorded raw bytes
 *    are re-broadcast (same nonce, same hash), at most {@link REBROADCAST}.max times;
 *  • not mined after 15 min and definitely unknown to the node: dropped — short
 *    backoff, the gas and the reservation stay charged. An RPC error on the check
 *    never drops it.
 */
export async function resolvePending(chain: { pub: ReceiptPub; me?: Address }, guard: Guard, now: number = Date.now()): Promise<Resolution | undefined> {
  const p = guard.pending;
  if (!p) return undefined;
  const key = p.orderHash ?? p.backoffKey;
  let receipt = await readReceipt(chain.pub, p.hash);
  if (receipt) return applyReceipt(guard, p, receipt, now);
  const age = now - p.sentAt;
  // Is the node still holding it? Asked only once it is overdue: a receipt usually
  // comes within a block or two, and a lost broadcast shows here as "not found".
  const sinceBroadcast = now - (p.lastBroadcastAt ?? p.sentAt);
  let known: boolean | undefined = true;
  let rebroadcast: Resolution["rebroadcast"];
  if (sinceBroadcast >= REBROADCAST.afterMs || age >= BACKOFF.pendingDropMs) {
    // One extra read, overdue path only: a mined nonce past ours means this tx can
    // never mine. Re-read the receipt first — it may have mined since the first read.
    if (p.nonce >= 0 && chain.me && chain.pub.getTransactionCount) {
      const mined = await chain.pub.getTransactionCount({ address: chain.me, blockTag: "latest" }).catch(() => undefined);
      if (mined !== undefined && mined > p.nonce) {
        receipt = await readReceipt(chain.pub, p.hash);
        if (receipt) return applyReceipt(guard, p, receipt, now);
        if (key) guard.onDropped(key, now, BigInt(p.expiry), `tx ${p.hash} replaced (nonce ${p.nonce} used by another tx)`);
        guard.setPending(undefined);
        return { status: "dropped", pending: p, gasCostWei: BigInt(p.gasLimit) * BigInt(p.gasPrice), replaced: true };
      }
    }
    known = await txKnown(chain.pub, p.hash);
    const attempts = p.rebroadcasts ?? 0;
    if (known === false && p.raw && chain.pub.sendRawTransaction && attempts < REBROADCAST.max && sinceBroadcast >= REBROADCAST.afterMs && age < BACKOFF.pendingDropMs) {
      let error: string | undefined;
      try {
        await chain.pub.sendRawTransaction({ serializedTransaction: p.raw });
      } catch (e) {
        error = sanitize(e instanceof Error ? e.message.split("\n")[0] : e, 160);
      }
      guard.setPending({ ...p, rebroadcasts: attempts + 1, lastBroadcastAt: now });
      rebroadcast = { attempt: attempts + 1, ...(error ? { error } : {}) };
    }
  }
  const cur = guard.pending!;
  const extra = rebroadcast ? { rebroadcast } : {};
  if (!cur.timedOut && age >= guard.policy.receiptTimeoutMs) {
    guard.setPending({ ...cur, timedOut: true });
    return { status: "timeout", pending: guard.pending!, ...extra };
  }
  if (age < BACKOFF.pendingDropMs || known !== false) return { status: "waiting", pending: cur, ...extra };
  // Definitely unknown to the node 15 min after the send. The gas was charged at the limit already; retry soon.
  if (key) guard.onDropped(key, now, BigInt(p.expiry), `tx ${p.hash} dropped`);
  guard.setPending(undefined);
  return { status: "dropped", pending: cur, gasCostWei: BigInt(cur.gasLimit) * BigInt(cur.gasPrice) };
}

type Receipt = { status: string; gasUsed: bigint; effectiveGasPrice?: bigint };

async function readReceipt(pub: ReceiptPub, hash: Hex): Promise<Receipt | undefined> {
  try {
    return (await pub.getTransactionReceipt({ hash })) as Receipt | undefined;
  } catch {
    return undefined; // not mined (yet), or the RPC hiccupped: stay pending
  }
}

function applyReceipt(guard: Guard, p: PendingTx, receipt: Receipt, now: number): Resolution {
  const key = p.orderHash ?? p.backoffKey;
  const gasCostWei = receipt.gasUsed * (receipt.effectiveGasPrice ?? BigInt(p.gasPrice));
  // Also after a timeout: the gas paid is known now (review 2026-10-05 §6).
  guard.gas.settle(p.hash, GAS, gasCostWei);
  const ok = receipt.status === "success";
  if (ok) {
    if (key) guard.onSuccess(key);
  } else {
    if (!p.timedOut && p.reserved) guard.budgets[p.reserved.budget]?.settle(p.hash, p.reserved.token as Address, 0n);
    if (key) guard.onRevert(key, now, BigInt(p.expiry), `tx ${p.hash} reverted`);
  }
  guard.setPending(undefined);
  return { status: ok ? "success" : "reverted", pending: p, gasUsed: receipt.gasUsed, gasCostWei };
}

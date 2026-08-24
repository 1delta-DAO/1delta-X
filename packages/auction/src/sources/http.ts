import type { Address } from "viem";

/** Minimal injectable fetch, so adapters are testable without a network. */
export type FetchLike = (url: string, init?: { signal?: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
}>;

export interface HttpSourceOptions {
  /** Defaults to the global `fetch`. */
  fetchImpl?: FetchLike;
  /** Per-request timeout, ms. Default 3000 — a solver bids against a clock. */
  timeoutMs?: number;
  /** Slippage as a PERCENT (0.3 = 0.3%). Default 0.5. */
  slippagePercent?: number;
}

const NATIVE_PLACEHOLDER = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * The placeholder caller used when a solver is PRICING rather than preparing to
 * execute. Mirrors the upstream fetchers: both APIs want a `from`/`sender` and
 * reject or misprice a zero address, so a price-only request needs a stand-in.
 *
 * ⚠ A quote fetched under this address must NEVER carry its `tx` back to the
 * caller — the calldata is built to deliver to the dummy. {@link isRealRecipient}
 * is what gates that, and both adapters drop `route` when it is false.
 */
export const DUMMY_CALLER = "0x0000000000000000000000000000000000000001" as Address;

/**
 * Whether this recipient can actually receive a swap — a well-formed, non-zero,
 * non-placeholder address.
 *
 * When false, both adapters switch to their price-only behaviour: Sushi asks
 * `quote/v6` (which takes no recipient at all), Nordstern asks its one endpoint
 * with {@link DUMMY_CALLER}. Either way the returned quote is a NUMBER ONLY,
 * with no executable route attached.
 */
export function isRealRecipient(addr: Address | undefined): boolean {
  if (!isAddress(addr)) return false;
  const a = addr.toLowerCase();
  return a !== ZERO.toLowerCase() && a !== DUMMY_CALLER.toLowerCase();
}

/**
 * A well-formed 20-byte hex address.
 *
 * ⚠ TYPES ARE NOT VALIDATION HERE. An `Address` reaching a route source came
 * from an order leg, and an order arrives over the wire as JSON — TypeScript
 * checks nothing at runtime, so the field is whatever the poster wrote. Every
 * value interpolated into an outbound URL is checked with this, not just the
 * recipient: an unvalidated token like `0xA0b8…&recipient=0xATTACKER` injects a
 * second `recipient` parameter ahead of the legitimate one, and an aggregator
 * that resolves duplicate keys first-wins then returns calldata paying the
 * attacker. {@link searchParams} is the belt to this suspenders — use both.
 */
export function isAddress(addr: string | undefined): addr is Address {
  return typeof addr === "string" && /^0x[0-9a-fA-F]{40}$/.test(addr);
}

/**
 * Query string from a parameter map, with every value percent-encoded.
 *
 * Concatenating `?a=${x}&b=${y}` by hand is how a value smuggles in a `&` and
 * becomes a parameter. `URLSearchParams` encodes it instead, so an injected key
 * arrives as literal text the upstream will reject rather than obey.
 */
export function searchParams(params: Record<string, string | number>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) q.set(k, String(v));
  return q.toString();
}

/** True for either native convention a caller might pass in. */
export function isNative(token: Address): boolean {
  const t = token.toLowerCase();
  return t === ZERO.toLowerCase() || t === NATIVE_PLACEHOLDER.toLowerCase();
}

/** Sushi wants the `0xEeee…` placeholder for native; Nordstern wants the zero address. */
export function nativeAs(token: Address, convention: "placeholder" | "zero"): Address {
  if (!isNative(token)) return token;
  return (convention === "placeholder" ? NATIVE_PLACEHOLDER : ZERO) as Address;
}

/**
 * GET + JSON with a timeout. Returns `null` on ANY failure — a route source
 * that cannot answer must not throw into a bidding loop, and one aggregator
 * being down must not stop the solver bidding from the other.
 */
export async function getJson(url: string, opts: HttpSourceOptions): Promise<unknown | null> {
  const doFetch = opts.fetchImpl ?? (globalThis.fetch as unknown as FetchLike);
  if (!doFetch) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? 3_000);
  try {
    const res = await doFetch(url, { signal: controller.signal });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Integer part of an amount an API returned as a JSON NUMBER.
 *
 * ⚠ Flooring is deliberate and it must stay that way. These are amounts the
 * solver expects to RECEIVE, and the bid it derives is a promise to deliver
 * against them — so every rounding decision has to land on the side the solver
 * can honour. Overstating by one wei is a round won and not fillable.
 *
 * ⚠ A JSON number above 2^53 has already lost precision before we see it, in
 * either direction. For 18-decimal tokens that is ordinary, not exotic. Carry a
 * non-zero `minProfitBps` on any solver quoting such a source; it is the only
 * margin that covers this.
 */
export function floorNumericAmount(value: unknown): bigint | null {
  if (value === null || value === undefined) return null;
  let parsed: bigint;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    // `Math.floor`, never `toFixed(0)` — toFixed ROUNDS (1800.9 → "1801"), which
    // overstates what the solver will receive by up to a full unit and is exactly
    // how a won round becomes a failed fill. It also renders large magnitudes in
    // exponential form, which `BigInt` then rejects.
    parsed = BigInt(Math.floor(value));
  } else {
    const integer = String(value).trim().split(".")[0];
    if (!integer || !/^-?\d+$/.test(integer)) return null;
    parsed = BigInt(integer);
  }
  return parsed > 0n ? parsed : null;
}

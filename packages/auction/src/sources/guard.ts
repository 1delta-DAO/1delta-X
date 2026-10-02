import type { Address, Hex } from "viem";

import type { RouteRequest } from "../solver";
import { isNative } from "./http";

/**
 * Validation for THIRD-PARTY route calldata (Sushi `swap/v7`, Nordstern) before it
 * reaches a STANDING `AggregatorFillSolver` (audit 2026-09-30 AUCTION-AGG4).
 *
 * A standing instance funds routes from maximal router approvals primed for every
 * token it trades, and its router allowlist pins WHERE a call goes, not WHAT it
 * says. A compromised or buggy aggregator API returning `sweepToken(token, self)`,
 * a `transferFrom` path or a swap to another recipient would spend the standing
 * approval on a token the order never touched. So an API-sourced route bound for a
 * standing executor is decoded first: an allowlisted router, an allowlisted
 * selector, no native value unless the input is native, and the request's tokens
 * and recipient present in the calldata as word-aligned ABI words (not merely as
 * a substring — see {hasWord}). Anything else is dropped. The token / recipient
 * test is a PRESENCE check, not a decode: it cannot prove the named recipient is
 * the one the router pays when the calldata also names another. The selector
 * allowlist is what bounds that — admit only swap entrypoints whose recipient is
 * a fixed head word, never a multicall / sweep / transfer-capable selector. A per-fill
 * (`standing = false`) instance spends only this fill's deltas, so it needs none of
 * this — send API routes there when no guard is configured.
 */
export interface RouteGuard {
  /** Router addresses the executor's allowlist admits. */
  routers: readonly Address[];
  /** 4-byte selectors of the swap entrypoints those routers expose. */
  selectors: readonly Hex[];
}

export interface ApiRoute {
  to: Address;
  data: Hex;
  value: bigint;
}

const word = (a: Address): string => a.toLowerCase().slice(2).padStart(64, "0");

/**
 * Whether `body` (the calldata after the selector, as lower-case hex without `0x`)
 * carries `w` as one of its 32-byte ABI WORDS — i.e. at a word-aligned offset.
 *
 * A plain substring test also matches the 64 hex digits at ANY offset, so a
 * hostile route could pay someone else in its real `recipient` word and still
 * "name" the requested recipient (or a token) by embedding those bytes, shifted
 * off the word grid, inside a dynamic `bytes` argument. ABI-encoded arguments,
 * including every head word and every element of a static tail, sit on the
 * 32-byte grid, so an honest route always passes the aligned test (audit
 * 2026-09-30 AUCTION-AGG4 completion, AGG-4).
 */
function hasWord(body: string, w: string): boolean {
  for (let i = 0; i + 64 <= body.length; i += 64) {
    if (body.slice(i, i + 64) === w) return true;
  }
  return false;
}

/** `null` when `route` passes `guard` for `req`, else the reason it is refused. */
export function checkApiRoute(route: ApiRoute, req: RouteRequest, guard: RouteGuard): string | null {
  const lc = (a: string) => a.toLowerCase();
  if (!guard.routers.some((r) => lc(r) === lc(route.to))) return "router not allowlisted";
  const data = lc(route.data);
  if (!/^0x[0-9a-f]*$/.test(data) || data.length < 10) return "calldata malformed";
  const selector = data.slice(0, 10);
  if (!guard.selectors.some((s) => lc(s) === selector)) return `selector ${selector} not allowlisted`;
  if (route.value !== 0n && !isNative(req.tokenIn)) return "native value on an ERC-20-input route";
  const body = data.slice(10);
  if (!isNative(req.tokenIn) && !hasWord(body, word(req.tokenIn))) return "calldata does not name tokenIn";
  if (!isNative(req.tokenOut) && !hasWord(body, word(req.tokenOut))) return "calldata does not name tokenOut";
  if (!hasWord(body, word(req.recipient))) return "calldata does not pay the requested recipient";
  return null;
}

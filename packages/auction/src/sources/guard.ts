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
 * and recipient present in the calldata. Anything else is dropped. A per-fill
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
  if (!isNative(req.tokenIn) && !body.includes(word(req.tokenIn))) return "calldata does not name tokenIn";
  if (!isNative(req.tokenOut) && !body.includes(word(req.tokenOut))) return "calldata does not name tokenOut";
  if (!body.includes(word(req.recipient))) return "calldata does not pay the requested recipient";
  return null;
}

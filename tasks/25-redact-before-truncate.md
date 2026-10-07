# 25. Book + filler: truncate-then-redact can leak a partial RPC key

- **Status:** open
- **Layer:** backend
- **Package:** `packages/orderbook-worker` (`core.ts`), `packages/filler-worker` (`do.ts`), `packages/beta-filler` (`engine.ts`)
- **Severity:** low
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

A keyed RPC URL cut by a length limit no longer matches the full-URL or origin+path
replacement, so only the host is replaced and a prefix of the key can reach output:
- [orderbook-worker core.ts:208](../packages/orderbook-worker/src/core.ts#L208) `/health`
  (`slice(0, 200)` before `redact`); `maintain()` at :830 already does it right;
- [filler-worker do.ts:195](../packages/filler-worker/src/do.ts#L195)
  `redact(sanitize(m, 600))`;
- `beta-filler/src/engine.ts` truncates to 200 before the worker redacts.
Also info: `/status` shows the RPC origin, which leaks providers that key the
subdomain (admin-only).

## Change

Always redact first, then truncate. Consider redacting the host in `/status` too.

## Acceptance

- A test per site with a URL whose key straddles the cut.

# 23. Book: per-IP rate limit keys on the full IPv6 address

- **Status:** open
- **Layer:** backend
- **Package:** `packages/orderbook-worker` (`clientIp.ts`, `core.ts`, `ratelimit.ts`)
- **Severity:** medium — DoS / storage-billing surface
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`clientIp` ([clientIp.ts:43](../packages/orderbook-worker/src/clientIp.ts#L43)) returns
the full address; one client with an ordinary /64 mints unlimited `ip:` buckets, each a
fresh burst. Reads (`GET /orders`, `/fills`, `/status`) have no maker bucket behind
them. Compounding: refusals do not touch `updated_at`, so the `maxKeys` cap evicts
drained abuser buckets first ([ratelimit.ts:92](../packages/orderbook-worker/src/ratelimit.ts#L92)).

## Change

Key IPv6 on its /64 (IPv4 unchanged). Touch `updated_at` on refusal (or evict by
least-recently-ALLOWED) so a drained bucket is not recycled first.

## Acceptance

- Tests: two addresses in one /64 share a bucket; a drained bucket survives key
  pressure.

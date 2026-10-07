# 27. Auction: `guard.ts` says the sandbox has no standing approvals

- **Status:** open
- **Layer:** backend (docs)
- **Package:** `packages/auction` (`src/sources/guard.ts`)
- **Severity:** low — risk reasoning understated
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

[guard.ts:12](../packages/auction/src/sources/guard.ts#L12) says routes run in
`RouteSandbox` "with no router allowlist and no standing approvals".
`RouteSandbox.exec` sets a standing max approval per (token, target); the SDK
(`sdk/src/aggregator.ts`) documents it correctly. A hostile router's exposure is
therefore whatever the sandbox holds in that token on later fills, not only the
current fill's in-flight input.

## Change

Correct the comment and the risk sentence; link the sandbox's own docs.

## Acceptance

- `make docs-check` passes.

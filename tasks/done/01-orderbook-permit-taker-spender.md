# 01. Check taker-permit spenders in the permit-announce path

- **Status:** done (2026-10-06)
- **Package:** `packages/orderbook`
- **Severity:** low, liveness and book hygiene only. No on-chain authorization is affected.
- **Source:** [SIGNATURE-VALIDATION-REVIEW.md](../../SIGNATURE-VALIDATION-REVIEW.md), finding F1
- **Opened:** 2026-10-06

## Problem

Layer 1 of the orderbook verifier admits a single-signature (`fillWithPermit`)
announce only if every permit in the batch grants the configured settlement as
spender. The check at [verify.ts:240](../../packages/orderbook/src/verify.ts#L240)
iterates `batch.tokens` only. `batch.takers` is never inspected, so a batch whose
taker grant names a foreign spender is admitted. On-chain the fill then fails at
the TAKE item unless the maker happens to hold a standing taker grant for the
settlement, and the order sits in the book until a later sweep evicts it.

The existing token-leg check has no negative test.

Confirmed by a throwaway test: a maker-signed batch with
`tokenPermit(settlement, …)` plus `takerPermit(0x…ff, …)` returns `ok: true`
from `verifyLayer1`; the same foreign address on the token leg is rejected with
`"permit batch grants a spender other than this settlement"`.

## Change

In `verifyLayer1`, apply the same `spender.toLowerCase() === settlement` test to
`batch.takers` next to the existing `batch.tokens` test. One combined check is
fine; keep the existing rejection reason so the hardening tests and any client
matching on it stay valid.

## Acceptance

- A permit announce whose taker permit names a spender other than the
  configured settlement is rejected at Layer 1 with the existing reason.
- A permit announce whose token permit names a foreign spender is rejected
  (pins the check that exists today but is untested).
- The A-FLEX-2 positive case in `test/audit20260930.test.ts` still passes.
- Tests live next to the A-FLEX-2 block in `packages/orderbook/test/audit20260930.test.ts`
  or in `test/verify.test.ts`, named after the finding.
- `cd packages/orderbook && npx tsc -p tsconfig.json && npx vitest run` green.

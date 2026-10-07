# 22. Filler: a send error is rolled back on one immediate "not found"

- **Status:** open
- **Layer:** backend
- **Package:** `packages/beta-filler` (`guard.ts`)
- **Severity:** low — budget under-count, possible nonce collision
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

After `sendRawTransaction` throws ([guard.ts:470](../packages/beta-filler/src/guard.ts#L470)),
a single `getTransaction` returning not-found undoes the gas charge, the budget
reservation and the pending record. A proxy that times out after relaying, or a
check that lands on a backend that has not seen the tx yet, leaves a tx that mines
uncounted; the next tick may sign another tx at the same nonce (the loser then
resolves via task 21).

## Change

Keep the pending record (and charges) on a send error unless the error is a
definite rejection (nonce too low, insufficient funds, invalid tx); let the normal
re-broadcast / drop path resolve it.

## Acceptance

- Test: send throws a timeout, tx later mines ⇒ charged once, recorded as filled.

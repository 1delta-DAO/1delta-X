# 09. Filler runtime follow-ups (filler-worker DO + beta-filler engine)

- **Status:** done (2026-10-06); all six items landed with tests, none struck
- **Package:** `packages/filler-worker`, `packages/beta-filler`
- **Severity:** low — accounting precision, operator ergonomics, docs
- **Source:** [REVIEW-2026-10-05-amount-mismatch.md](../../REVIEW-2026-10-05-amount-mismatch.md), §6 "Documented / accepted"
- **Opened:** 2026-10-06

Already fixed with tests in the review: alert cooldown under the hourly cap,
idempotent `Budget.spend` per `(ref, token)`, `/status` reason redaction, backoff
horizon capped at the largest `Date`.

## Remaining

1. **Settle gas on ANY receipt, also after `RECEIPT_TIMEOUT_MS`**
   ([guard.ts](../../packages/beta-filler/src/guard.ts) `resolvePending`): a late receipt
   leaves one fills row with `gas_used` from the receipt and `gas_cost_wei` from the
   limit; the e2e verifier (`filler-worker/e2e/load.ts`) flags exactly that row. Settle
   the gas entry (still inside the 1 h window; `settle` is a no-op if pruned) and keep
   only the inventory reservation "final" after the timeout — or add a `charged_wei`
   column and make the verifier read it.
2. **Detect a replaced nonce on the overdue path:** when there is no receipt and
   `getTransactionCount(latest) > pending.nonce`, resolve at once as replaced/dropped
   instead of 5 futile re-broadcasts and a 15 min wait (one extra RPC, overdue path
   only). The README tells operators to hand-replace a stuck tx, so this happens.
3. **Roll back the in-memory pending on a failed `guard.commit()`** (`broadcast`): a
   storage put that throws leaves `pending` set with nothing sent; the 60 s
   re-broadcast self-heals, but the order also takes a sim-backoff. On commit failure
   settle gas/reservation to 0, clear pending, rethrow.
4. **README wording** ([filler-worker/README.md](../../packages/filler-worker/README.md)):
   after an eviction the sweep restarts from the oldest `addedAt` (the in-memory
   `seen` set is empty) — say so or persist `seen`; "same semantics as the Node CLI"
   → "same engine, different bounds" (rebalance cadence, per-tick bounds, intake
   2×500 vs 20×500, receipt poll 3 s vs 1 s); a drop keeps the inventory reservation
   for the hour, not only the gas.
5. **Tests for the gaps the review listed:** late receipt (item 1), storage failure
   in `commit` (item 3), RPC-URL redaction of outcome reasons in `/status` (only alert
   bodies are tested today).
6. Minor: sell-side `profit_est` omits the MoC mint fee the sell gate includes (units
   fine, estimate optimistic) — note it or include it.

## Acceptance

- Each item either lands with a test or is struck here with a reason.
- `cd packages/beta-filler && npx vitest run` and `cd packages/filler-worker && npx vitest run` green.

## Resolution (2026-10-06)

1. **Done — first design** (settle on any receipt; no `charged_wei` column).
   `resolvePending` settles the gas entry to `gasUsed × effectiveGasPrice` on every
   receipt (a no-op once pruned) and returns that cost as `gasCostWei`; only the
   budget reservation stays final after `RECEIPT_TIMEOUT_MS` (a late revert is a strike
   but does not release it). The fills row's `gas_used` and `gas_cost_wei` now come
   from the same receipt, so `e2e/load.ts` needs no change. Tests:
   `beta-filler/test/rebroadcast.test.ts` "a receipt after RECEIPT_TIMEOUT_MS still
   settles the gas" (late success / late revert / gasUsed < limit / past the hourly
   window); `audit.test.ts` L-5 updated (asserted the old limit-priced charge);
   `filler-worker/test/filler.test.ts` "a receipt after RECEIPT_TIMEOUT_MS".
2. **Done.** On the overdue path (≥ 60 s since the last broadcast, or ≥ 15 min) with
   a known nonce, one `getTransactionCount(latest)`; if it is past the tx's nonce the
   receipt is re-read once (our own tx may have mined in between) and otherwise the tx
   resolves as `dropped` with `replaced: true` — no re-broadcasts, short backoff,
   charges kept (a same-data speed-up may have filled under another hash). RPC errors
   on the read change nothing; pre-2026-10 records (`nonce -1`) are never checked.
   Tests: `rebroadcast.test.ts` "a nonce taken by another tx resolves at once" (3),
   `filler.test.ts` "a nonce mined by another tx …". The `audit.test.ts` fake's
   `getTransactionCount` now excludes an unmined tx (it assumed instant mining).
3. **Done.** `broadcast` wraps `guard.commit()`: on a throw it settles the gas and the
   reservation to 0, clears the pending record and rethrows (nothing is broadcast).
   Test: `rebroadcast.test.ts` "a failed commit rolls the send back".
4. **Done.** `filler-worker/README.md`: eviction restarts the sweep from the oldest
   `addedAt` (`seen` stays in memory, not persisted); "exactly the Node CLI's
   semantics" → "same engine, different bounds" with the four differences; a drop keeps
   the reservation for the hour, not only the gas; late-receipt and replaced-nonce
   rules. `beta-filler/README.md` updated to match (timeout rule, replaced nonce,
   `RECEIPT_TIMEOUT_MS` row).
5. **Done.** Late receipt and commit failure: see 1 and 3. `/status` / `/tick` outcome
   reason redaction: `filler-worker/test/monitor.test.ts` "outcome reasons in /status
   and /tick are redacted" (a simulation failure quoting the RPC URL; new
   `world.callError` fake knob in `test/helpers.ts`).
6. **Done — included.** New `mintReplaceUsdt0()` in `policy.ts`, used by both the
   sell-side all-in gate and the recorded `profitEst`. Tests: `inventoryGas.test.ts`
   (rounding) and `audit.test.ts` "the sell side's recorded profit_est includes the
   MoC mint fee" (102 USDT0 for 100 USDRIF → 1.8, was 2.0).

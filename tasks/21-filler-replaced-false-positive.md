# 21. Filler: a mined tx can be resolved as "replaced" on a flaky RPC

- **Status:** open
- **Layer:** backend
- **Package:** `packages/beta-filler` (`guard.ts`), runs in `filler-worker`
- **Severity:** medium — wrong fills log / P&L, early re-quote; no principal at risk
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`readReceipt` ([guard.ts:620](../packages/beta-filler/src/guard.ts#L620)) maps every
error (429, 5xx, timeout) to "not mined". On the overdue path `resolvePending` reads
the mined nonce; if that read succeeds and is past ours while both receipt reads
failed (rate-limited public node, lagging backend), our own mined tx is resolved
`dropped` / `replaced: true`. Effects: a real fill logged as dropped; no own-fill hold,
so the order is re-quoted after the 30 s `onDropped` backoff; a real revert gets no
strike; a mined `redeem` never reaches `onRedeemMined`.

## Change

Declare "replaced" only on a definite not-found: `TransactionReceiptNotFoundError`
AND `getTransaction(hash)` not found — the same rule the drop path uses. Any other
error keeps the tx pending.

## Acceptance

- Test: nonce advanced + receipt read throws a 429 ⇒ stays pending; a later receipt
  settles it as filled.
- Existing replaced-nonce tests still pass.

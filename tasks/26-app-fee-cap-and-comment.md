# 26. App: cap the indexer's pool fee; fix the `applyPoolFee` comment

- **Status:** open
- **Layer:** frontend
- **Package:** `packages/app` (`poolbook.ts`, `univ3.ts`)
- **Severity:** low
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

- [poolbook.ts:215](../packages/app/src/lib/poolbook.ts#L215) takes
  `max(pinned feeBps, indexer meta.fee)` with any `meta.fee < 1e6`: the indexer can
  lower bids / raise asks by up to ~100 % "fee", widening a market order's signed
  floor (loosens, never tightens). Not a new trust boundary — the indexer already
  supplies ticks — but cheap to bound.
- [univ3.ts:186](../packages/app/src/lib/univ3.ts#L186) says the quote side of each
  rung is unchanged; true for bids only (asks scale by `1/(1−f)`). Math is right.

## Change

Use the pinned tier; accept the indexer's only if it equals a known v3 tier and is
≤ the pinned one (or ≤ 1 %). Fix the comment.

## Acceptance

- App test: an indexer fee of 500000 is ignored.

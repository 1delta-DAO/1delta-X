# Open tasks

One numbered file per task (`NN-slug.md`), each with a status / package / severity /
source / opened header and Problem → Change → Acceptance sections. A finished task
is marked `done` in its header and moved to `done/`.

## Done (2026-10-06)

| # | task | kind | status |
| --- | --- | --- | --- |
| 01 | orderbook: taker-permit spenders in the permit-announce path | off-chain fix | done → `done/` |
| 02 | orderbook: Layer-1 recovery with ecrecover semantics | off-chain fix | done → `done/` |
| 03 | ~~[e2e: the app's real market shape against production gates](done/03-e2e-app-market-shape.md)~~ | test | done 2026-10-06 (`staging.sh app-shape`; gates verified — market fills blocked by economics at the 50 bps floor, see Resolution and task 15) |
| 04 | ~~[decide the market order's life (300 s applied)](done/04-market-order-ttl-decision.md)~~ | decision | done 2026-10-06 (300 s confirmed) |
| 05 | ~~[direct-path SELL forgoes the decay — accept or reclaim](done/05-direct-path-decay-decision.md)~~ | decision | done 2026-10-06 (option 3: live `amountOutOffset` on still-decaying direct SELLs) |
| 06 | ~~[solver: typed-callback `onFill`](done/06-solver-typed-callback.md)~~ | contract | done 2026-10-06 |
| 07 | ~~[core: self-sufficient PRESEND bound (B-1)](done/07-core-b1-presend-bound.md)~~ | contract (core) | done 2026-10-06 |
| 08 | ~~[core: `minBumpBps` on `fillWithCallback`](done/08-core-fillwithcallback-minbump.md)~~ | contract (core) | done 2026-10-06 |
| 09 | filler runtime follow-ups | off-chain | done → `done/` |
| 10 | ~~[docs: label the gas figures](done/10-docs-gas-figures.md)~~ | docs | done 2026-10-06 |
| 11 | ~~[Lista SmartTaker: tie the LP-unit item to the coin-unit leg](done/11-lista-smart-taker-unit-split.md)~~ | module + lens | done 2026-10-06 |
| 12 | ~~[Exactly: non-zero floor on a pre-maturity fixed withdraw](done/12-exactly-fixed-withdraw-floor.md)~~ | module + lens | done 2026-10-06 |
| 13 | ~~[module library liveness notes](done/13-module-lib-liveness-notes.md)~~ | lib / lens / docs | done 2026-10-06 |
| 14 | ~~[shapes checker: rule 9 per branch](done/14-shapes-checker-per-branch.md)~~ | tooling | done 2026-10-06 |
| 15 | ~~[app market orders unprofitable at the 50 bps floor](done/15-market-floor-economics.md)~~ | decision | done 2026-10-06 (fee-net ladder + 5 bps stable haircut, 0 min profit; e2e passes) |


## Open — smart contracts

Solver items need a solver redeploy; the lens item a lens redeploy. Settlement is untouched by all of them.

| # | task | layer | severity |
| --- | --- | --- | --- |
| 16 | [Solver: the live `amountOutOffset` patch writes `pricedOut[0]`, not the anchor output leg](16-solver-live-patch-anchor-leg.md) | contract | low |
| 17 | [Solver: `executeItemFill` silently ignores `minBumpBps` and `amountOutOffset`](17-solver-itemfill-ignored-fields.md) | contract | low |
| 18 | [Lens: the `ITakeFloor` check rejects valid multi-leg and multi-item orders](18-lens-takefloored-leg-selection.md) | contract | medium-low |
| 19 | [Shapes checker: rule 9 can be satisfied by accident](19-shapes-rule9-gaps.md) | contract (tooling) | low |
| 20 | [Contract docs drift (solver header, Exactly repay behaviour)](20-contract-docs-drift.md) | contract (docs) | info |

## Open — backend / frontend

No contract change; none waits on a deploy.

| # | task | layer | severity |
| --- | --- | --- | --- |
| 21 | [Filler: a mined tx can be resolved as "replaced" on a flaky RPC](21-filler-replaced-false-positive.md) | backend | medium |
| 22 | [Filler: a send error is rolled back on one immediate "not found"](22-filler-send-error-rollback.md) | backend | low |
| 23 | [Book: per-IP rate limit keys on the full IPv6 address](23-book-ipv6-ratelimit.md) | backend | medium |
| 24 | [Book: permit announces stay Fillable after the permit deadline](24-book-permit-deadline-staleness.md) | backend | medium |
| 25 | [Book + filler: truncate-then-redact can leak a partial RPC key](25-redact-before-truncate.md) | backend | low |
| 26 | [App: cap the indexer's pool fee; fix the `applyPoolFee` comment](26-app-fee-cap-and-comment.md) | frontend | low |
| 27 | [Auction: `guard.ts` says the sandbox has no standing approvals](27-auction-guard-comment.md) | backend (docs) | low |

Sources: `../REVIEW-2026-10-05-amount-mismatch.md` (03–15),
`../SIGNATURE-VALIDATION-REVIEW.md` (01–02), the 2026-10-06 pre-merge audit (16–27,
recorded in the review doc's §11).
